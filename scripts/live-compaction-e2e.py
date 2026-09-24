#!/usr/bin/env python3
"""Opt-in live end-to-end test of the helper's compaction, against a real
LiteLLM gateway and a real model.

Why: 0.1.90 shipped summaries capped at 13,107 output tokens. At high effort
a real model spent that on reasoning, every summary stopped at its cap and
was rejected, and the run looped. Every other helper test answers from a fake
gateway that never reasons, so none could see it. This test drives the real
release helper (pi-native-host) over its wire protocol, as the app does, on
seeded tool-heavy sessions built from this repository's own text:

  compact-now   "Compact now" on a session at about 75% of the window, then
                a turn that must start from the summary.
  mid-run       One turn told to read ten large files in a temp workspace
                with the real read tool: the threshold is crossed between
                rounds, the helper compacts mid-run, and the turn must finish.
  over-window   "Compact now" on a history larger than the window, so it is
                summarized in chained chunks, then a turn from the summary.

Each scenario must show: every compaction completed and its summary adopted;
no summary request stopped at max_output_tokens; every summary request left
at least a quarter of the window for its output (when the model's own limit
allows); the context estimate after each compaction under the threshold; no
loop (a bounded number of summary requests, never the same summary asked
again after an answer, no compaction tried again after one failed); the run
ending idle; the reported cost under the cap.

Live run (billed to the gateway key; configuration only from the environment):

  PI_BUILD_ROOT=/path/to/build-root \\
  PI_LIVE_BASE_URL=https://gateway.example.com/v1 PI_LIVE_API_KEY=... \\
  PI_LIVE_MODEL=gpt-5.1 PI_LIVE_CONTEXT_WINDOW=128000 \\
  [PI_LIVE_MODEL_OUTPUT_LIMIT=128000] [PI_LIVE_THINKING=high] [PI_LIVE_MAX_COST_USD=5] \\
  python3 scripts/live-compaction-e2e.py

PI_LIVE_CONTEXT_WINDOW may be left out when the bundled model catalog lists
the model (its window is then used, and the scenarios scale with it: a
smaller declared window is the cheaper test). The cost cap is the helper's own
per-chat cost limit: each session opens with what is left of
PI_LIVE_MAX_COST_USD, less the dearest request so far, because a request
already sent finishes past a chat's limit. A completed request whose cost the
gateway does not report stops the run. The key goes to the helper over its
wire protocol only; it is never printed or written, and every report file is
scanned for it.

Free rehearsal, against a local gateway whose model reasons (about 20,000
tokens at high for a summary):

  PI_BUILD_ROOT=... python3 scripts/live-compaction-e2e.py --fixture
  PI_BUILD_ROOT=... python3 scripts/live-compaction-e2e.py --fixture --fixture-summary-limit 13107

The second run caps every summary at 0.1.90's 13,107 tokens and must FAIL.

The helper is $PI_BUILD_ROOT/swift-host/arm64-apple-macosx/release/pi-native-host
(what scripts/build-bundle.py builds) unless --helper names another. Reports
go to $PI_BUILD_ROOT/live-e2e/<UTC timestamp>/ (report.txt and report.json).
The exit status is non-zero on any failure.
"""
import argparse
import base64
import datetime
import hashlib
import json
import math
import os
import pathlib
import queue
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "fixtures/native"))
import reasoning_gateway  # noqa: E402 (the fixture gateway, and pi's summary prompt parser)

SCENARIOS = ("compact-now", "mid-run", "over-window")
THINKING_LEVELS = ("default", "off", "minimal", "low", "medium", "high", "xhigh", "max")
# The app's onboarding output budget: a local reserve, never sent.
OUTPUT_BUDGET = 8192
# CompactionPolicy: pi's reserve and recent tail, and the context safety margin.
RESERVE, KEEP_RECENT, SAFETY = 16_384, 20_000, 4_096
FIXTURE = {"model": "fixture-reasoner", "window": 128_000, "limit": 128_000, "thinking": "high", "max_cost": 5.0,
           "key": "fixture-live-e2e-key-" + "0" * 12}
TASK_TAG, SUMMARY_PREFIX = reasoning_gateway.TASK_TAG, reasoning_gateway.SUMMARY_PREFIX
EVIDENCE_FILES = 10
FOLLOW_UP = ("E2E follow-up. Do not use any tools. In at most three sentences, say what this session has been "
             "working on, according to the conversation so far.")


class Failure(Exception):
    """A setup problem that stops the run before any scenario can be judged."""


# -- configuration ---------------------------------------------------------------

class Config:
    def __init__(self, **values):
        self.__dict__.update(values)

    @property
    def threshold(self):
        """Pi's compaction threshold: the window less its reserve."""
        return self.window - min(RESERVE, self.window // 2)

    @property
    def quarter(self):
        """The least output room a summary request must leave, within the model's limit."""
        return min(self.window // 4, self.limit) if self.limit else self.window // 4

    @property
    def summary_room(self):
        """What the helper keeps free beside each summary chunk (CompactionPolicy.summaryRoom)."""
        share = min(min(RESERVE, self.window // 2) * 8 // 10, self.limit or 1 << 60)
        return max(share, min(self.limit or 1 << 60, self.window // 4))


def load_catalog():
    try:
        data = json.loads((ROOT / "catalogs/bello-agent.models.json").read_text())
    except (OSError, ValueError):
        return {}
    models = data.get("models", data) if isinstance(data, dict) else data
    return {model["id"]: model for model in models if isinstance(model, dict) and "id" in model}


def positive_int(name, text):
    try:
        value = int(text)
    except ValueError:
        raise Failure(f"{name} must be a whole number of tokens, not {text!r}")
    if value <= 0:
        raise Failure(f"{name} must be positive")
    return value


def load_config(args):
    env = os.environ
    build_root = env.get("PI_BUILD_ROOT")
    if not build_root:
        raise Failure("Set PI_BUILD_ROOT to the build root (reports go to $PI_BUILD_ROOT/live-e2e/)")
    build_root = pathlib.Path(build_root).expanduser()
    helper = pathlib.Path(args.helper).expanduser() if args.helper else build_root / "swift-host/arm64-apple-macosx/release/pi-native-host"
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise Failure(f"No release helper at {helper}. Build it with scripts/build-bundle.py (or pass --helper).")
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    common = {"helper": helper.resolve(), "out": build_root / "live-e2e" / stamp, "stamp": stamp,
              "scenarios": args.scenario or list(SCENARIOS), "keep": args.keep}
    if args.fixture_summary_limit is not None and not args.fixture:
        raise Failure("--fixture-summary-limit is a switch of the fixture gateway; add --fixture")
    if args.fixture:
        return Config(mode="fixture", base_url=None, api_key=FIXTURE["key"], model=FIXTURE["model"], window=FIXTURE["window"],
                      limit=FIXTURE["limit"], thinking=FIXTURE["thinking"], max_cost=FIXTURE["max_cost"],
                      window_source="fixture", limit_source="fixture", summary_limit=args.fixture_summary_limit, **common)
    missing = [name for name in ("PI_LIVE_BASE_URL", "PI_LIVE_API_KEY", "PI_LIVE_MODEL") if not env.get(name)]
    if missing:
        raise Failure("Set " + ", ".join(missing) + " (live mode reads its configuration only from the environment; "
                      "use --fixture for the free rehearsal)")
    model = env["PI_LIVE_MODEL"]
    entry = load_catalog().get(model, {})
    if env.get("PI_LIVE_CONTEXT_WINDOW"):
        window, window_source = positive_int("PI_LIVE_CONTEXT_WINDOW", env["PI_LIVE_CONTEXT_WINDOW"]), "PI_LIVE_CONTEXT_WINDOW"
    elif isinstance(entry.get("contextWindow"), int):
        window, window_source = entry["contextWindow"], "model catalog"
    else:
        raise Failure(f"Set PI_LIVE_CONTEXT_WINDOW: the model catalog does not list {model!r}")
    if env.get("PI_LIVE_MODEL_OUTPUT_LIMIT"):
        limit, limit_source = positive_int("PI_LIVE_MODEL_OUTPUT_LIMIT", env["PI_LIVE_MODEL_OUTPUT_LIMIT"]), "PI_LIVE_MODEL_OUTPUT_LIMIT"
    elif isinstance(entry.get("maxOutputTokens"), int):
        limit, limit_source = entry["maxOutputTokens"], "model catalog"
    else:
        limit, limit_source = None, "unknown (no output limit is sent)"
    thinking = env.get("PI_LIVE_THINKING", "high")
    if thinking not in THINKING_LEVELS:
        raise Failure("PI_LIVE_THINKING must be one of " + ", ".join(THINKING_LEVELS))
    try:
        max_cost = float(env.get("PI_LIVE_MAX_COST_USD", "5"))
    except ValueError:
        raise Failure("PI_LIVE_MAX_COST_USD must be a number of US dollars")
    if not (max_cost > 0 and math.isfinite(max_cost)):
        raise Failure("PI_LIVE_MAX_COST_USD must be positive")
    if window < 32_768 or window > 10_000_000:
        raise Failure("The context window must be from 32,768 to 10,000,000 tokens")
    return Config(mode="live", base_url=env["PI_LIVE_BASE_URL"], api_key=env["PI_LIVE_API_KEY"], model=model, window=window, limit=limit,
                  thinking=thinking, max_cost=max_cost, window_source=window_source, limit_source=limit_source, summary_limit=None, **common)


# -- output ----------------------------------------------------------------------

class Output:
    """Everything printed or written goes through here, with the key redacted."""

    def __init__(self, secrets):
        self.secrets = sorted({secret for secret in secrets if secret and len(secret) >= 4}, key=len, reverse=True)
        self.lines = []

    def redact(self, text):
        for secret in self.secrets:
            text = text.replace(secret, "[REDACTED]")
        return text

    def say(self, text=""):
        text = self.redact(str(text))
        self.lines.append(text)
        print(text, flush=True)

    def progress(self, text):
        """A line for whoever watches the run; the report leaves it out."""
        print(self.redact(str(text)), flush=True)

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.redact(text))

    def scan(self, folder):
        """Redacts any file that still holds a secret; returns the files it had to fix."""
        fixed = []
        for path in sorted(folder.rglob("*")):
            if not path.is_file():
                continue
            data = path.read_bytes()
            if any(secret.encode() in data for secret in self.secrets):
                for secret in self.secrets:
                    data = data.replace(secret.encode(), b"[REDACTED]")
                path.write_bytes(data)
                fixed.append(path.name)
        return fixed


def number(value):
    return "–" if value is None else f"{value:,}" if isinstance(value, int) else str(value)


def dollars(value):
    return "–" if value is None else f"${value:.4f}" if value < 1 else f"${value:.2f}"


# -- the helper over its wire protocol ---------------------------------------------

class HelperError(Exception):
    def __init__(self, method, error):
        self.code, self.message = error.get("code", "unknown"), error.get("message", "")
        super().__init__(f"{method}: {self.code}: {self.message}")


class Helper:
    """The release helper, driven as the app drives it (scripts/test-native-host.py's Peer)."""

    def __init__(self, binary, cwd, stderr_path):
        # The helper takes the key over its wire protocol only.
        environment = {name: value for name, value in os.environ.items() if not name.startswith("PI_LIVE_")}
        self.stderr = open(stderr_path, "wb")
        self.process = subprocess.Popen([str(binary)], cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr, env=environment)
        self.frames, self.write_lock = queue.Queue(), threading.Lock()
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()
        try:
            self.send({"v": 1, "kind": "hello", "major": 1, "minor": 1})
            try:
                ready = self.frames.get(timeout=20)
            except queue.Empty:
                raise Failure("The helper did not answer its handshake")
            if ready.get("kind") != "ready" or "responses" not in ready.get("capabilities", []):
                raise Failure("The helper's handshake was not a Responses-capable ready frame")
            if "cost-limit" not in ready["capabilities"]:
                raise Failure("This helper predates per-chat cost limits, so the cost cap cannot be enforced")
            self.epoch = ready["hostEpoch"]
        except BaseException:
            self.close()
            raise

    def read(self):
        for line in self.process.stdout:
            try:
                frame = json.loads(line)
            except ValueError:
                continue
            if frame.get("kind") == "capture":
                self.send({"v": 1, "kind": "capture.ack", "hostEpoch": frame["hostEpoch"], "transferId": frame["transferId"], "accepted": True})
            elif frame.get("kind") != "event":
                self.frames.put(frame)

    def send(self, value):
        with self.write_lock:
            self.process.stdin.write(json.dumps(value, separators=(",", ":")).encode() + b"\n")
            self.process.stdin.flush()

    def command(self, method, params=None, session=None, timeout=120):
        ident = str(uuid.uuid4())
        self.send({"v": 1, "kind": "command", "hostEpoch": self.epoch, "commandId": ident, "sessionId": session, "method": method, "params": params or {}})
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or self.process.poll() is not None:
                raise Failure(f"The helper did not answer {method}" + (" (it exited)" if self.process.poll() is not None else ""))
            try:
                frame = self.frames.get(timeout=min(remaining, 1))
            except queue.Empty:
                continue
            if frame.get("commandId") == ident:
                if not frame.get("ok"):
                    raise HelperError(method, frame.get("error") or frame.get("result") or {})
                return frame.get("result")

    def body(self, session, attempt, kind):
        """A captured request or response body, page by page."""
        output, offset = bytearray(), 0
        while True:
            page = self.command("debug.body", {"attemptId": attempt, "body": kind, "offset": offset}, session)
            output.extend(base64.b64decode(page["bytes"]))
            if page.get("next") is None:
                return bytes(output), page.get("state")
            offset = page["next"]

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.close()
            except OSError:
                pass
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.reader.join(timeout=5)
        self.process.stdout.close()
        self.stderr.close()


# -- seeded history from the repository's own text ---------------------------------

def utf16(text):
    return len(text.encode("utf-16-le")) // 2


def ceil4(chars):
    return -(-chars // 4)


def arguments_text(arguments):
    return json.dumps(arguments, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def estimate(message):
    """PiContext.estimateTokens: characters over four of what the message carries."""
    chars = 0
    for block in message["content"]:
        if block["type"] == "text":
            chars += utf16(block["text"])
        elif block["type"] == "thinking" and message["role"] == "assistant":
            chars += utf16(block["thinking"])
        elif block["type"] == "toolCall":
            chars += utf16(block["name"]) + utf16(arguments_text(block["arguments"]))
    return ceil4(chars)


def serialized(message):
    """CompactionSourceBuilder.serialize: the characters a message adds to a summary source."""
    texts = [block["text"] for block in message["content"] if block["type"] == "text"]
    if message["role"] == "assistant":
        size = sum(utf16("[Assistant thinking]: " + block["thinking"]) + 2 for block in message["content"] if block["type"] == "thinking")
        size += utf16("[Assistant]: " + "\n".join(texts)) + 2 if texts else 0
        calls = [block["name"] + "(" + ", ".join(f"{key}={json.dumps(value)}" for key, value in sorted(block["arguments"].items())) + ")"
                 for block in message["content"] if block["type"] == "toolCall"]
        return size + (utf16("[Assistant tool calls]: " + "; ".join(calls)) + 2 if calls else 0)
    text = "".join(texts)
    if message["role"] == "toolResult":
        length = utf16(text)
        # A result over 2,000 characters keeps its first 2,000, a note and its reference.
        return utf16("[Tool result]: ") + (length if length <= 2000 else 2000 + 110) + 2
    return utf16("[User]: " + text) + 2


class Corpus:
    """Real text from this repository: the helper's sources and tests, the docs and the scripts."""

    PATTERNS = ("packages/swift-host/Sources/PiAgentCore/*.swift", "packages/swift-host/Tests/PiAgentCoreTests/*.swift",
                "docs/*.md", "scripts/*.py", "fixtures/native/*.py")

    def __init__(self):
        self.files = {}
        for pattern in self.PATTERNS:
            for path in sorted(ROOT.glob(pattern)):
                try:
                    text = path.read_text()
                except (OSError, UnicodeDecodeError):
                    continue
                if 2_000 <= len(text) <= 400_000:
                    self.files[str(path.relative_to(ROOT))] = text.split("\n")
        if len(self.files) < 20:
            raise Failure("Too little repository text to build a realistic history")
        self.paths = sorted(self.files)
        self.code = [path for path in self.paths if path.endswith((".swift", ".py"))]
        self.docs = [path for path in self.paths if path.endswith(".md")]

    def symbols(self, path):
        found = []
        for line in self.files[path]:
            match = re.match(r"\s*(?:public |private |static |final |@\w+ )*(?:func|def|class|struct|enum|actor|extension)\s+([A-Za-z_]\w*)", line)
            if match:
                found.append(match.group(1))
            elif line.startswith("## "):
                found.append(line[3:].strip())
        return [symbol for symbol in dict.fromkeys(found) if len(symbol) > 3] or [pathlib.Path(path).stem]


class History:
    """Builds a realistic tool-heavy history: tasks of read and bash rounds, with assistant text."""

    VERBS = ("Walk me through", "Review", "Explain", "Audit", "Check")
    CONCERNS = ("where it is called and what it depends on", "whether anything in it could loop or stall",
                "what happens when the gateway fails halfway", "how its limits are chosen and where they are enforced",
                "whether the tests cover its edge cases")

    def __init__(self, corpus, seed, text_heavy=False):
        self.corpus, self.rng, self.text_heavy = corpus, random.Random(seed), text_heavy
        self.messages, self.tokens = [], 0
        self.clock = time.time() * 1000 - 2 * 86_400_000

    # Message shapes as the helper journals them (ChatMessage.pi).
    def add(self, role, content, root, **extra):
        self.clock += self.rng.uniform(800, 9000)
        message = {"role": role, "content": content, "timestamp": self.clock, "nativeReplayEligible": True,
                   "nativeTaskRoot": root, "nativeTurn": root, "isError": False, **extra}
        ident = str(uuid.uuid4()).upper()
        self.messages.append((ident, message))
        self.tokens += estimate(message)
        return ident

    def user(self, text):
        root = str(uuid.uuid4()).upper()
        self.clock += self.rng.uniform(20_000, 300_000)
        message = {"role": "user", "content": [{"type": "text", "text": text}], "timestamp": self.clock, "nativeReplayEligible": True,
                   "nativeTaskRoot": root, "nativeTurn": root, "isError": False}
        self.messages.append((root, message))
        self.tokens += estimate(message)
        return root

    def assistant(self, root, text, calls=(), thinking=None):
        content = []
        if thinking:
            content.append({"type": "thinking", "thinking": thinking})
        if text:
            content.append({"type": "text", "text": text})
        content += [{"type": "toolCall", "id": call[0], "name": call[1], "arguments": call[2]} for call in calls]
        return self.add("assistant", content, root, nativeModelMs=round(self.rng.uniform(900, 30_000), 1))

    def result(self, root, call, name, text):
        return self.add("toolResult", [{"type": "text", "text": text}], root, toolCallId=call, toolName=name,
                        nativeToolStats={"durationMs": round(self.rng.uniform(2, 900), 1), "outcome": "completed"})

    # Tool results as the helper's own tools return them.
    def read(self, path, offset=None, limit=None):
        lines = self.corpus.files[path]
        start, count = (offset or 1), (limit or 2000)
        selected = "\n".join(lines[start - 1:start - 1 + count])
        text = selected.encode()[:32_768].decode(errors="ignore")
        if start - 1 + count < len(lines) or len(text) < len(selected):
            text += f"\n[Truncated. {len(lines)} total lines; read another range.]"
        return text

    def grep(self, symbol, folder, limit):
        rows = []
        for path in self.corpus.paths:
            if not path.startswith(folder):
                continue
            for number_, line in enumerate(self.corpus.files[path], 1):
                if symbol in line:
                    rows.append(f"{path}:{number_}:{line.strip()[:220]}")
                    if len(rows) >= limit:
                        return "\n".join(rows) + "\nExit code: 0"
        return ("\n".join(rows) + "\nExit code: 0") if rows else "Exit code: 1"

    def excerpt(self, path, first, last):
        return "\n".join(self.corpus.files[path][first - 1:last]) + "\nExit code: 0"

    def quote(self, text, lines):
        body = [line for line in text.split("\n") if line.strip() and not line.startswith(("Exit code", "[Truncated"))]
        if not body:
            return ""
        start = self.rng.randrange(max(1, len(body) - lines))
        return "\n".join(body[start:start + lines])

    def task(self, limit=None):
        """One task: a request, rounds of tool calls, and an answer. Its rounds
        stop early once the history reaches `limit` tokens."""
        rng, corpus = self.rng, self.corpus
        path = rng.choice(corpus.code if rng.random() < 0.75 else corpus.docs)
        symbol = rng.choice(corpus.symbols(path))
        root = self.user(f"{rng.choice(self.VERBS)} `{symbol}` in {path}: {rng.choice(self.CONCERNS)}. "
                         f"Read the code before answering and quote the lines that matter.")
        folder = str(pathlib.Path(path).parent)
        seen, last = [path], ""
        for round_ in range(rng.randint(4, 9)):
            if limit and round_ and self.tokens >= limit:
                break
            ident = "call_" + uuid.uuid4().hex[:24]
            kind = rng.random()
            read_share = 0.25 if self.text_heavy else 0.55
            if kind < read_share:
                target = path if round_ == 0 else rng.choice(corpus.paths if rng.random() < 0.3 else [p for p in corpus.paths if p.startswith(folder)] or corpus.paths)
                lines = len(corpus.files[target])
                if self.text_heavy or lines > 400:
                    window = rng.randint(60, 150) if self.text_heavy else rng.randint(150, 420)
                    offset = rng.randint(1, max(1, lines - window))
                    arguments, output = {"path": target, "offset": offset, "limit": window}, self.read(target, offset, window)
                else:
                    arguments, output = {"path": target}, self.read(target)
                name, seen = "read", seen + [target]
                intro = f"Reading {target}" + (f" around line {arguments['offset']}" if "offset" in arguments else "") + "."
            elif kind < read_share + 0.25:
                pattern = rng.choice(corpus.symbols(rng.choice(seen)))
                rows = rng.randint(8, 24) if self.text_heavy else rng.randint(15, 60)
                arguments = {"command": f"grep -rn '{pattern}' {folder} | head -{rows}", "timeout": 60}
                name, output = "bash", self.grep(pattern, folder, rows)
                intro = f"Searching {folder} for `{pattern}`."
            else:
                target = rng.choice(seen)
                lines = len(corpus.files[target])
                first = rng.randint(1, max(1, lines - 40))
                last_line = min(lines, first + (rng.randint(15, 35) if self.text_heavy else rng.randint(30, 110)))
                arguments = {"command": f"sed -n '{first},{last_line}p' {target}", "timeout": 60}
                name, output = "bash", self.excerpt(target, first, last_line)
                intro = f"Looking at lines {first}–{last_line} of {target}."
            text = intro
            if last and rng.random() < (0.7 if self.text_heavy else 0.35):
                quoted = self.quote(last, rng.randint(6, 30) if self.text_heavy else rng.randint(3, 12))
                if quoted:
                    text = f"The last result matters here:\n\n```\n{quoted}\n```\n\nThat settles part of it. {intro}"
            thinking = f"I need to see how {symbol} behaves here before answering." if rng.random() < 0.5 else None
            self.assistant(root, text, [(ident, name, arguments)], thinking)
            self.result(root, ident, name, output)
            last = output
        findings = "\n".join(f"- `{item}`: {self.quote(self.read(item), 1)[:180]}" for item in dict.fromkeys(seen))
        quoted = self.quote(last, rng.randint(12, 40) if self.text_heavy else rng.randint(6, 20))
        self.assistant(root, f"Here is what I found about `{symbol}`.\n\n{findings}\n\nThe key lines:\n\n```\n{quoted}\n```\n\n"
                             f"Nothing here needs a change yet; the next step is to confirm the behaviour with a test.")

    def grow(self, tokens):
        """Adds tasks until the history's estimate reaches `tokens`."""
        while self.tokens < tokens:
            self.task(limit=tokens)
        return self

    def tail_tokens(self, keep):
        """Estimated tokens and summary-source size of all but pi's recent tail."""
        used, index = 0, len(self.messages)
        while index > 0 and used < keep:
            index -= 1
            used += estimate(self.messages[index][1])
        return ceil4(sum(serialized(message) for _, message in self.messages[:index]))


def seed_journal(path, messages):
    """Appends the history to a journal the helper created, as one valid branch."""
    records = [json.loads(line) for line in pathlib.Path(path).read_bytes().split(b"\n") if line]
    parent = records[-1].get("id") if len(records) > 1 else None
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(path, "ab") as journal:
        for ident, message in messages:
            record = {"type": "message", "message": message, "id": ident, "parentId": parent, "timestamp": stamp}
            journal.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode() + b"\n")
            parent = ident


def evidence(corpus, folder, seed):
    """Ten ~28 KB files of repository text, each opening with a marker line. Each
    fits one read: the read tool returns up to 32 KB and 2,000 lines."""
    rng = random.Random(seed)
    words = ("amber", "basalt", "cedar", "delta", "ember", "fjord", "garnet", "harbor", "indigo", "juniper", "kelp", "lumen")
    sources = [path for path in corpus.paths if sum(len(line) + 1 for line in corpus.files[path]) > 12_000]
    markers = {}
    (folder / "evidence").mkdir(parents=True, exist_ok=True)
    for index in range(1, EVIDENCE_FILES + 1):
        part, word = f"part-{index:02d}", f"{words[index - 1]}-{rng.randint(100, 999)}"
        markers[part] = word
        lines, size = [f"E2E-MARKER {part}: {word}"], 0
        while size < 27_000:
            source = rng.choice(sources)
            text = corpus.files[source]
            start = rng.randrange(max(1, len(text) - 200))
            lines.append(f"--- excerpt of {source}, from line {start + 1} ---")
            for line in text[start:start + 200]:
                line = line[:300]
                if size + len(line.encode()) > 28_500:
                    break
                lines.append(line)
                size += len(line.encode()) + 1
        (folder / "evidence" / f"{part}.txt").write_text("\n".join(lines) + "\n")
    return markers


def task_prompt():
    files = "\n".join(f"evidence/part-{index:02d}.txt" for index in range(1, EVIDENCE_FILES + 1))
    return (f"{TASK_TAG}. This is an automated end-to-end test of a long, tool-heavy turn.\n"
            f"Use the read tool to read each of these {EVIDENCE_FILES} files in full, one read call per file and one file at a time, in this order:\n"
            f"{files}\n"
            f"Each file starts with a line of the form \"E2E-MARKER part-NN: WORD\". Do not skip a file, do not pass offset or limit, "
            f"and do not use any other tool.\n"
            f"When you have read all {EVIDENCE_FILES} files, reply with exactly {EVIDENCE_FILES} lines, one per file in order, "
            f"each of the form \"part-NN: WORD\", and nothing else.")


# -- one scenario's session ---------------------------------------------------------

class Session:
    def __init__(self, run, name, history, workspace=None):
        self.run, self.name, self.cfg = run, name, run.cfg
        self.root = run.temp / name
        self.workspace, self.directory = self.root / "workspace", self.root / "sessions"
        for folder in (self.workspace, self.directory, self.root / "codex"):
            folder.mkdir(parents=True, exist_ok=True)
        self.markers = workspace(self.workspace) if workspace else {}
        self.helper = Helper(self.cfg.helper, self.workspace, self.cfg.out / f"{name}-helper-stderr.log")
        self.id, self.path, self.turn, self.watched = f"e2e-{name}-{uuid.uuid4().hex[:8]}", None, None, set()
        try:
            self.helper.command("workspace.open", {"cwd": str(self.workspace), "directory": str(self.directory),
                                                   "resources": {"codexHome": str(self.root / "codex")}})
            # The helper writes the journal's header and binding; the history follows them.
            self.path = self.open()["path"]
            self.helper.command("session.close", {}, self.id)
            seed_journal(self.path, history.messages)
            self.opened = self.open(path=self.path)
        except BaseException:
            self.helper.close()
            raise

    def profile(self):
        profile = {"id": "live-e2e", "revision": "1", "providerId": "litellm", "modelId": self.cfg.model, "api": "openai-responses",
                   "baseUrl": self.run.base_url, "contextWindow": self.cfg.window, "maxOutputTokens": OUTPUT_BUDGET,
                   "reasoning": True, "thinkingLevel": self.cfg.thinking, "routing": {"replayPolicy": "portable"}}
        if self.cfg.limit:
            profile["modelOutputLimit"] = self.cfg.limit
        return profile

    def open(self, path=None):
        # The cap is the helper's own cost limit for this chat.
        budget = self.run.budget()
        if budget <= 0:
            raise Failure("the cost cap is used up")
        params = {"profile": self.profile(), "apiKey": self.cfg.api_key, "toolMode": "read-only", "costLimit": {"usd": round(budget, 6)}}
        if path:
            params["path"] = path
        return self.helper.command("session.open", params, self.id)

    def status(self):
        return self.helper.command("session.status", {}, self.id)

    def listed(self):
        attempts, offset = [], 0
        while True:
            page = self.helper.command("debug.list", {"offset": offset}, self.id)
            attempts += page["attempts"]
            if page.get("next") is None:
                return attempts
            offset = page["next"]

    def wait(self, bound, timeout, turns=45):
        """Waits for the run to settle. A run that asks for more summaries (or
        turn requests) than the scenario can need is looping, and one past its
        deadline is stuck: either is stopped, and the scenario fails with the
        reason. The helper keeps the last 64 requests for inspection, so a
        bounded run is also one whose every request is in the report."""
        deadline, poll = time.monotonic() + timeout, 0.1 if self.cfg.mode == "fixture" else 1.0
        while True:
            status = self.status()
            if status["state"] in ("idle", "paused", "error"):
                return status, None
            summaries, requests, unpriced = 0, 0, 0
            for attempt in self.listed():
                summaries += attempt["purpose"] == "compaction"
                requests += attempt["purpose"] != "compaction"
                if attempt["outcome"] != "running" and attempt["attemptId"] not in self.watched:
                    self.watched.add(attempt["attemptId"])
                    usage, cost = attempt.get("usage") or {}, ((attempt.get("gateway") or {}).get("cost") or {})
                    self.run.out.progress(f"    · {attempt['purpose']:<10} {attempt['outcome']:<9} in {number(usage.get('input'))} · "
                                          f"out {number(usage.get('output'))} (reasoning {number(usage.get('reasoning'))}) · "
                                          f"{(attempt.get('metrics') or {}).get('httpDurationMs') or 0:,.0f} ms · {dollars(cost.get('usd'))}")
                    # A billed request whose cost went unreported: the cap cannot hold.
                    unpriced += attempt.get("status") == 200 and attempt["outcome"] in ("completed", "truncated") and cost.get("status") != "reported"
            stopped = (f"loop: {summaries} summary requests, more than the {bound} this scenario can need" if summaries > bound
                       else f"loop: {requests} turn requests, more than the {turns} this scenario can need" if requests > turns
                       else "cost: the gateway reported no cost for a completed request, so the cost cap cannot hold"
                       if unpriced and self.cfg.mode == "live" else f"timeout: still running after {timeout:,.0f} s" if time.monotonic() > deadline else None)
            if stopped:
                self.run.out.say(f"    ! stopping the run: {stopped}")
                self.helper.command("turn.stop", {}, self.id)
                settle = time.monotonic() + 120
                while time.monotonic() < settle:
                    status = self.status()
                    if status["state"] in ("idle", "paused", "error"):
                        break
                    time.sleep(poll)
                return status, stopped
            time.sleep(poll)

    def submit(self, text):
        turn = str(uuid.uuid4()).upper()
        self.helper.command("turn.submit", {"clientTurnId": turn, "text": text}, self.id)
        return turn

    def collect(self):
        """Every request of this session: what it asked for, what came back, what it cost."""
        rows = []
        records = {record["sha256"]: record for record in (self.run.gateway.records if self.run.gateway else [])}
        for attempt in sorted(self.listed(), key=lambda item: (item.get("wallTimestamp") or 0)):
            request, _ = self.helper.body(self.id, attempt["attemptId"], "request")
            response, _ = self.helper.body(self.id, attempt["attemptId"], "response")
            rows.append(describe(attempt, request, response, records.get(hashlib.sha256(request).hexdigest())))
        for index, row in enumerate(rows, 1):
            row["index"] = index
        return rows

    def close(self):
        try:
            self.helper.command("session.close", {}, self.id, timeout=30)
        except (HelperError, Failure):
            pass
        self.helper.close()


def describe(attempt, request, response, gateway_record):
    """One request as the report shows it."""
    try:
        body = json.loads(request)
    except ValueError:
        body = {}
    prompt = ""
    items = body.get("input") or []
    if len(items) > 1 and items[1].get("role") == "user":
        prompt = "".join(part.get("text", "") for part in items[1].get("content", []))
    summary = attempt["purpose"] == "compaction"
    kind = reasoning_gateway.parse_summary_prompt(prompt)[0] if summary else None
    terminal = terminal_event(response)
    status = attempt.get("status")
    usage = attempt.get("usage") or {}
    if terminal and terminal.get("status") == "incomplete":
        stop = (terminal.get("incomplete_details") or {}).get("reason") or "incomplete"
    elif terminal and terminal.get("status") == "completed":
        stop = "completed"
    elif status and status >= 400:
        stop = f"HTTP {status}"
    else:
        stop = {"truncated": "max_output_tokens"}.get(attempt.get("modelOutcome"), attempt.get("modelOutcome") or attempt.get("outcome"))
    sent = body.get("max_output_tokens")
    effective = gateway_record.get("effective_limit") if gateway_record else sent
    cost = (attempt.get("gateway") or {}).get("cost") or {}
    return {"attempt": attempt["attemptId"], "purpose": attempt["purpose"], "kind": kind, "turn": attempt.get("turnId"),
            "operation": (attempt.get("operation") or {}).get("operationId") if summary else None,
            "effort": (body.get("reasoning") or {}).get("effort"), "maxOutputTokens": sent, "effectiveMaxOutputTokens": effective,
            "inputTokens": usage.get("input"), "cachedTokens": usage.get("cacheRead"), "outputTokens": usage.get("output"),
            "reasoningTokens": usage.get("reasoning"), "stopReason": stop, "httpStatus": status, "outcome": attempt.get("outcome"),
            "modelOutcome": attempt.get("modelOutcome"), "durationMs": (attempt.get("metrics") or {}).get("httpDurationMs"),
            "costUSD": cost.get("usd"), "costStatus": cost.get("status"), "requestBytes": len(request),
            "inputSHA256": hashlib.sha256(json.dumps(items, sort_keys=True).encode()).hexdigest() if items else None,
            "startsFromSummary": prompt.startswith(SUMMARY_PREFIX) and not summary, "answered": terminal is not None and status == 200,
            "costUnreported": terminal is not None and status == 200 and cost.get("status") != "reported"}


def terminal_event(response):
    """The terminal response object of a Responses stream or JSON body."""
    final = None
    text = response.decode("utf-8", errors="replace")
    if text.lstrip().startswith("{"):
        try:
            value = json.loads(text)
        except ValueError:
            return None
        return value if value.get("status") in ("completed", "incomplete", "failed") else None
    for block in re.split(r"\r?\n\r?\n", text):
        for line in block.splitlines():
            if not line.startswith("data:"):
                continue
            try:
                event = json.loads(line[5:].strip())
            except ValueError:
                continue
            if event.get("type") in ("response.completed", "response.incomplete", "response.failed"):
                final = event.get("response")
    return final


def journal(path):
    """The compactions a session's journal records, and the rows around them."""
    records = [json.loads(line) for line in pathlib.Path(path).read_bytes().split(b"\n") if line]
    operations, order = {}, []
    for index, record in enumerate(records):
        message = record.get("message") or {}
        if record.get("type") == "message" and message.get("nativeKind") == "execution" and str(message.get("nativeDetail", "")).startswith("Compaction"):
            operations[record["id"]] = {"row": record["id"], "operation": message.get("nativeOperationID"), "detail": message.get("nativeDetail"),
                                        "terminal": (message.get("nativeResponseTimeline") or {}).get("terminal"), "at": index}
            order.append(record["id"])
        elif record.get("customType") == "pi-app.presentation.update.v1" and record.get("data", {}).get("id") in operations:
            update = record.get("message") or {}
            entry = operations[record["data"]["id"]]
            entry["detail"] = update.get("nativeDetail", entry["detail"])
            entry["terminal"] = (update.get("nativeResponseTimeline") or {}).get("terminal", entry["terminal"])
    checkpoints = []
    for index, record in enumerate(records):
        if record.get("type") == "compaction":
            meta = record.get("nativeCompaction") or {}
            checkpoints.append({"id": record["id"], "at": index, "operation": meta.get("operationId"), "reason": meta.get("reason"),
                                "phase": meta.get("phase"), "tokensBefore": record.get("tokensBefore"),
                                "before": {key: (meta.get("before") or {}).get(key) for key in ("tokens", "requestTokens")},
                                "after": {key: (meta.get("after") or {}).get(key) for key in ("tokens", "requestTokens")},
                                "summaryRequests": len(meta.get("summaryAttemptIds") or []), "kept": len(meta.get("keptIDs") or []),
                                "summaryCharacters": len(record.get("summary") or "")})
    return records, [operations[row] for row in order], checkpoints


# -- checks ---------------------------------------------------------------------------

class Result:
    def __init__(self, name, title):
        self.name, self.title, self.checks, self.requests, self.notes = name, title, [], [], []
        self.operations, self.checkpoints, self.cost, self.seconds, self.error = [], [], {}, 0.0, None

    def check(self, name, passed, detail):
        self.checks.append({"name": name, "passed": bool(passed), "detail": detail})

    @property
    def passed(self):
        return bool(self.checks) and all(check["passed"] for check in self.checks) and self.error is None

    def json(self):
        return {"scenario": self.name, "title": self.title, "passed": self.passed, "seconds": round(self.seconds, 1), "error": self.error,
                "notes": self.notes, "checks": self.checks, "cost": self.cost, "compactions": self.operations, "checkpoints": self.checkpoints,
                "requests": self.requests}


def common_checks(result, status, stopped, bound, run):
    cfg, requests = run.cfg, result.requests
    summaries = [row for row in requests if row["purpose"] == "compaction"]
    completed = [op for op in result.operations if op["terminal"] == "completed"]
    adopted = status.get("latestSuccessfulCompaction") or {}
    last = result.checkpoints[-1]["id"] if result.checkpoints else None
    result.check("compaction completed and its summary adopted",
                 result.operations and len(completed) == len(result.operations) == len(result.checkpoints)
                 and all(point["phase"] == "completed" for point in result.checkpoints) and adopted.get("id") == last,
                 f"{len(completed)} of {len(result.operations)} compactions completed; "
                 + ("; ".join(f"{op['operation'][:8] if op['operation'] else '?'}: {op['terminal']} ({short(op['detail'])})" for op in result.operations) or "none ran")
                 + ("; the live context starts from the last checkpoint" if last and adopted.get("id") == last else "; the last checkpoint is not the live context"))
    exhausted = [row for row in summaries if row["stopReason"] == "max_output_tokens" or row["modelOutcome"] == "truncated"]
    result.check("no summary request ended at max_output_tokens", summaries and not exhausted,
                 f"{len(summaries)} summary requests" + ("" if not exhausted else "; stopped at the limit: " + ", ".join(
                     f"#{row['index']} ({number(row['outputTokens'])} out, {number(row['reasoningTokens'])} reasoning, limit {number(row['effectiveMaxOutputTokens'])})" for row in exhausted)))
    small = [row for row in summaries if row["effectiveMaxOutputTokens"] is not None and row["effectiveMaxOutputTokens"] < cfg.quarter]
    unlimited = [row for row in summaries if row["effectiveMaxOutputTokens"] is None]
    result.check(f"every summary request leaves at least {number(cfg.quarter)} output tokens (the window ÷ 4" + (", within the model's limit)" if cfg.limit and cfg.limit < cfg.window // 4 else ")"),
                 summaries and not small and (not unlimited or not cfg.limit),
                 (f"least sent: {number(min((row['effectiveMaxOutputTokens'] for row in summaries if row['effectiveMaxOutputTokens'] is not None), default=None))}" if summaries else "no summary request")
                 + ("" if not small else "; too small: " + ", ".join(f"#{row['index']} {number(row['effectiveMaxOutputTokens'])}" for row in small))
                 + ("" if not unlimited else f"; {len(unlimited)} sent no limit" + ("" if cfg.limit else " (the model's limit is unknown, as the helper sends it)")))
    over = [point for point in result.checkpoints if (point["after"].get("requestTokens") or point["after"].get("tokens") or 0) >= cfg.threshold]
    result.check(f"context after each compaction under the {number(cfg.threshold)}-token threshold",
                 result.checkpoints and not over,
                 "; ".join(f"{number(point['before'].get('requestTokens'))} → {number(point['after'].get('requestTokens'))} tokens ({point['reason']})"
                           for point in result.checkpoints) or "no checkpoint to measure")
    asked, repeated = {}, []
    for row in summaries:
        if row["answered"] and row["inputSHA256"]:
            if row["inputSHA256"] in asked:
                repeated.append((asked[row["inputSHA256"]], row["index"]))
            asked.setdefault(row["inputSHA256"], row["index"])
    looped = stopped is not None and stopped.startswith("loop")
    # 0.1.90's loop: a failed threshold compaction was tried again every round.
    failed = next((index for index, op in enumerate(result.operations) if op["terminal"] == "failed"), None)
    retried = failed is not None and failed + 1 < len(result.operations)
    result.check("no loop", len(summaries) <= bound and not repeated and not looped and not retried,
                 f"{len(summaries)} summary requests (at most {bound})" + ("; the same summary was asked again after an answer: "
                 + ", ".join(f"#{a} and #{b}" for a, b in repeated) if repeated else "")
                 + (f"; compaction was tried {len(result.operations) - failed - 1} more times after one failed" if retried else "") + (f"; {stopped}" if looped else ""))
    result.check("the run ends idle", status["state"] == "idle" and not status.get("errorCode") and stopped is None,
                 f"state {status['state']}" + (f", {status.get('errorCode')}: {short(status.get('preflightError'))}" if status.get("errorCode") else "")
                 + (f"; {stopped}" if stopped else ""))


def count_spend(run, session, result):
    """Adds this chat's spend, as the helper counted it, to the run's: once,
    also when the scenario stopped early, so the next chat's budget is right."""
    if result.cost:
        return
    try:
        cost = session.status().get("cost") or {}
    except (Failure, HelperError):
        cost = {}
    spent = cost.get("spentUSD") or 0.0
    unreported = sum(row["costUnreported"] for row in result.requests)
    run.spent += spent
    run.unreported += unreported
    run.dearest = max([run.dearest] + [row["costUSD"] or 0 for row in result.requests])
    result.cost = {"spentUSD": spent, "reportedRequests": cost.get("reportedRequests"), "unreportedRequests": cost.get("unreportedRequests"),
                   "completedWithoutCost": unreported, "limitUSD": cost.get("limitUSD"), "runTotalUSD": run.spent}


def cost_check(result, run):
    """The run's spend against its cap. A completed request without a reported
    cost is spend the cap cannot see."""
    cost, unreported = result.cost, result.cost.get("completedWithoutCost", 0)
    result.check(f"reported cost under the {dollars(run.cfg.max_cost)} cap",
                 run.spent < run.cfg.max_cost and not unreported,
                 f"this scenario {dollars(cost.get('spentUSD'))} over {cost.get('reportedRequests')} requests; run total {dollars(run.spent)}"
                 + (f"; {unreported} completed requests reported no cost, so the cap cannot hold" if unreported else ""))


# -- scenarios ------------------------------------------------------------------------

def compaction_scenario(run, result, name, history, bound, timeout):
    """Compact now, then one turn that must start from the summary."""
    session = Session(run, name, history)
    try:
        context = session.opened.get("context") or {}
        result.notes.append(f"seeded {len(history.messages):,} messages: {number(context.get('tokens'))} estimated tokens "
                            f"({(context.get('tokens') or 0) / run.cfg.window:.0%} of the window), summary source ≈ {number(history.tail_tokens(KEEP_RECENT))} tokens")
        run.out.say("  " + result.notes[-1])
        session.helper.command("context.compact", {}, session.id)
        status, stopped = session.wait(bound, timeout)
        if status["state"] == "idle" and stopped is None:
            session.submit(FOLLOW_UP)
            status, stopped = session.wait(bound, timeout)
        return session, status, stopped
    except BaseException:
        session.close()
        raise


def run_compact_now(run, result):
    target = int(run.cfg.window * 0.75)
    history = History(run.corpus, seed=11).grow(tokens=target)
    session, status, stopped = compaction_scenario(run, result, "compact-now", history, bound=4, timeout=180 if run.cfg.mode == "fixture" else 1_800)
    return session, status, stopped, 4


def run_over_window(run, result):
    cfg = run.cfg
    capacity = cfg.window - cfg.summary_room - SAFETY - 700
    history = History(run.corpus, seed=23, text_heavy=True).grow(tokens=int(cfg.window * 1.3))
    while history.tail_tokens(KEEP_RECENT) < capacity * 1.35:
        history.task()
    bound = math.ceil(history.tail_tokens(KEEP_RECENT) / max(1, capacity - 2_000)) + 4
    session, status, stopped = compaction_scenario(run, result, "over-window", history, bound=bound, timeout=240 if cfg.mode == "fixture" else 2_700)
    return session, status, stopped, bound


def run_mid_run(run, result):
    cfg = run.cfg
    per_file = 7_200  # a ~28 KB evidence file read in full, by the helper's estimate
    target = max(int(cfg.window * 0.3), cfg.threshold - int(4.5 * per_file) - 4_000)
    history = History(run.corpus, seed=17).grow(tokens=target)
    session = Session(run, "mid-run", history, workspace=lambda folder: evidence(run.corpus, folder, seed=29))
    try:
        context = session.opened.get("context") or {}
        result.notes.append(f"seeded {len(history.messages):,} messages: {number(context.get('tokens'))} estimated tokens "
                            f"({(context.get('tokens') or 0) / cfg.window:.0%} of the window); {EVIDENCE_FILES} evidence files of about {number(per_file)} tokens")
        run.out.say("  " + result.notes[-1])
        session.turn = session.submit(task_prompt())
        status, stopped = session.wait(10, 240 if cfg.mode == "fixture" else 2_700)
        return session, status, stopped, 10
    except BaseException:
        session.close()
        raise


def mid_run_checks(result, session, records):
    """The threshold compaction ran between the turn's rounds, and the turn then finished."""
    start = next((index for index, record in enumerate(records) if record.get("id") == session.turn), None)
    rows = records[start:] if start is not None else []
    first = next((index for index, record in enumerate(rows) if record.get("type") == "compaction"), None)
    results_before = sum(1 for record in rows[:first] if (record.get("message") or {}).get("role") == "toolResult") if first is not None else 0
    replies_after = [record["message"] for record in rows[first:] if (record.get("message") or {}).get("role") == "assistant"
                     and (record["message"]).get("nativeReplayEligible", True)] if first is not None else []
    reason = next((point["reason"] for point in result.checkpoints), None)
    result.check("the threshold compaction ran mid-run", first is not None and reason == "threshold" and results_before >= 1 and replies_after,
                 (f"first checkpoint ({reason}) after {results_before} tool results of the turn, {len(replies_after)} replies after it"
                  if first is not None else "no checkpoint during the turn"))
    final = next((message for message in reversed([(record.get("message") or {}) for record in rows])
                  if message.get("role") == "assistant" and message.get("nativeReplayEligible", True)), None)
    text = "".join(block.get("text", "") for block in (final or {}).get("content", []) if block.get("type") == "text")
    calls = [block for block in (final or {}).get("content", []) if block.get("type") == "toolCall"]
    recalled = sum(1 for part, word in session.markers.items() if f"{part}: {word}" in text)
    result.check("the turn finished with an answer", final is not None and text.strip() and not calls,
                 f"final reply of {len(text):,} characters; markers recalled {recalled} of {len(session.markers)}")
    reads = sum(1 for record in rows if (record.get("message") or {}).get("role") == "toolResult")
    result.notes.append(f"{reads} tool results in the turn; markers recalled {recalled}/{len(session.markers)} (informational)")


def follow_up_check(result):
    turns = [row for row in result.requests if row["purpose"] == "turn"]
    last = result.checkpoints[-1] if result.checkpoints else None
    result.check("the next turn starts from the summary and completes",
                 last is not None and turns and turns[-1]["startsFromSummary"] and turns[-1]["stopReason"] == "completed",
                 (f"turn request #{turns[-1]['index']}: {'starts from the summary' if turns[-1]['startsFromSummary'] else 'does not start from the summary'}, "
                  f"{turns[-1]['stopReason']}") if turns else "no turn request after the compaction")


def chunk_check(result):
    summaries = [row for row in result.requests if row["purpose"] == "compaction"]
    first = next((row["operation"] for row in summaries), None)
    history = [row for row in summaries if row["operation"] == first and row["kind"] and row["kind"].startswith("history")]
    chained = len(history) >= 2 and not history[0]["kind"].endswith("-update") and all(row["kind"].endswith("-update") for row in history[1:])
    result.check("summarized in chained chunks", chained,
                 f"{len(history)} history summary requests in the first compaction" + (", each after the first carrying the summary so far" if chained else ""))


def run_scenario(run, name):
    titles = {"compact-now": "Compact now at about 75% of the window", "mid-run": "Threshold compaction mid-run, with real tools",
              "over-window": "A history larger than the window, summarized in chained chunks"}
    result = Result(name, titles[name])
    run.out.say(f"\n[{name}] {titles[name]}")
    began = time.monotonic()
    session = None
    try:
        if run.budget() <= 0:
            raise Failure("the cost cap is used up")
        session, status, stopped, bound = {"compact-now": run_compact_now, "mid-run": run_mid_run, "over-window": run_over_window}[name](run, result)
        result.requests = session.collect()
        records, result.operations, result.checkpoints = journal(session.path)
        common_checks(result, status, stopped, bound, run)
        if name == "mid-run":
            mid_run_checks(result, session, records)
        else:
            follow_up_check(result)
        if name == "over-window":
            chunk_check(result)
        count_spend(run, session, result)
        cost_check(result, run)
    except (Failure, HelperError) as error:
        result.error = str(error)
    except Exception as error:  # a harness bug still leaves a report
        result.error = f"{type(error).__name__}: {error}"
        result.notes.append(traceback.format_exc())
    finally:
        if session is not None:
            count_spend(run, session, result)
            if not result.passed and session.path:
                shutil.copy2(session.path, run.cfg.out / f"{name}-session.jsonl")
            session.close()
        result.seconds = time.monotonic() - began
    for check in result.checks:
        run.out.say(f"  {'PASS' if check['passed'] else 'FAIL'} {check['name']}: {check['detail']}")
    if result.error:
        run.out.say(f"  FAIL {result.error}")
    if result.requests:
        run.out.say(table(result.requests))
    return result


def short(text, limit=240):
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def table(rows):
    head = f"    {'#':>2}  {'purpose':<10} {'kind':<18} {'in':>9} {'cached':>9} {'out':>8} {'reasoning':>9} {'max out':>9} {'stop':<17} {'ms':>8} {'cost':>9}"
    lines = [head]
    for row in rows:
        lines.append(f"    {row['index']:>2}  {row['purpose']:<10} {(row['kind'] or '–'):<18} {number(row['inputTokens']):>9} {number(row['cachedTokens']):>9} "
                     f"{number(row['outputTokens']):>8} {number(row['reasoningTokens']):>9} {number(row['effectiveMaxOutputTokens']):>9} "
                     f"{str(row['stopReason'])[:17]:<17} {(row['durationMs'] or 0):>8,.0f} {dollars(row['costUSD']):>9}")
    if any(row["effectiveMaxOutputTokens"] != row["maxOutputTokens"] for row in rows):
        lines.append("    max out: the limit the fixture applied; its debug switch capped the summaries")
    return "\n".join(lines)


# -- the run ----------------------------------------------------------------------------

class Run:
    def __init__(self, cfg, out):
        self.cfg, self.out = cfg, out
        self.spent, self.unreported, self.dearest, self.gateway = 0.0, 0, 0.0, None
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="pi-live-e2e-"))
        self.corpus = Corpus()
        self.base_url = cfg.base_url

    def budget(self):
        """What the next chat may spend: the cap, less what the run has spent and
        less its dearest request so far. The helper stops a chat before its next
        request once the spend reaches the limit, but a request already sent
        finishes, so one request can pass the limit; this keeps it under the cap."""
        return self.cfg.max_cost - self.spent - self.dearest


def main(argv=None):
    parser = argparse.ArgumentParser(description="Live end-to-end compaction test of the release helper (see the module docstring).")
    parser.add_argument("--fixture", action="store_true", help="run against a local gateway whose model reasons (free)")
    parser.add_argument("--fixture-summary-limit", type=int, metavar="TOKENS",
                        help="fixture only: cap every summary's output at TOKENS, as 0.1.90 did with 13107 (the run must fail)")
    parser.add_argument("--helper", help="the pi-native-host binary (default: the release helper under $PI_BUILD_ROOT)")
    parser.add_argument("--scenario", action="append", choices=SCENARIOS, help="run only this scenario (repeatable)")
    parser.add_argument("--keep", action="store_true", help="keep the temporary workspaces and sessions")
    args = parser.parse_args(argv)
    try:
        cfg = load_config(args)
    except Failure as error:
        print(f"live-compaction-e2e: {error}", file=sys.stderr)
        return 2
    out = Output([cfg.api_key])
    cfg.out.mkdir(parents=True, exist_ok=True)
    run = None
    results = []
    began = time.monotonic()
    try:
        run = Run(cfg, out)
        if cfg.mode == "fixture":
            # The model's own window is larger than the one the chat declares, as with real models.
            run.gateway = reasoning_gateway.ReasoningGateway(api_key=cfg.api_key, model=cfg.model, window=2 * cfg.window,
                                                             summary_limit=cfg.summary_limit).start()
            run.base_url = run.gateway.base_url
        mode = "fixture (local gateway whose model reasons)" if cfg.mode == "fixture" else f"LIVE against {cfg.base_url}"
        if cfg.summary_limit is not None:
            mode += f"; every summary capped at {cfg.summary_limit:,} tokens by the fixture's debug switch (0.1.90's cap)"
        out.say(f"Live compaction end-to-end · {mode}")
        out.say(f"model {cfg.model} · window {cfg.window:,} ({cfg.window_source}) · output limit {number(cfg.limit)} ({cfg.limit_source}) · "
                f"thinking {cfg.thinking} · cost cap {dollars(cfg.max_cost)} · threshold {cfg.threshold:,} · helper {cfg.helper}")
        if cfg.window < 100_000:
            out.say(f"note: a quarter of a {cfg.window:,}-token window is {cfg.window // 4:,} tokens; a summary at high effort can need more")
        for name in cfg.scenarios:
            results.append(run_scenario(run, name))
            if cfg.mode == "live" and run.unreported:
                out.say("Stopping: the gateway reported no cost for some requests, so the cost cap cannot be enforced.")
                break
    except Failure as error:
        out.say(f"live-compaction-e2e: {error}")
    finally:
        if run is not None:
            if run.gateway:
                run.gateway.stop()
            if not cfg.keep:
                shutil.rmtree(run.temp, ignore_errors=True)
            else:
                out.say(f"kept the temporary workspaces in {run.temp}")
    passed = bool(results) and len(results) == len(cfg.scenarios) and all(result.passed for result in results)
    total = sum((result.cost or {}).get("spentUSD") or 0 for result in results)
    out.say(f"\n{'PASSED' if passed else 'FAILED'}: {sum(result.passed for result in results)} of {len(cfg.scenarios)} scenarios passed · "
            f"reported cost {dollars(total)} of the {dollars(cfg.max_cost)} cap · {time.monotonic() - began:,.0f} s")
    report = {"version": 1, "mode": cfg.mode, "started": cfg.stamp, "passed": passed, "seconds": round(time.monotonic() - began, 1),
              "helper": str(cfg.helper), "gateway": cfg.base_url if cfg.mode == "live" else "loopback fixture (fixtures/native/reasoning_gateway.py)",
              "model": cfg.model, "contextWindow": cfg.window, "contextWindowSource": cfg.window_source, "modelOutputLimit": cfg.limit,
              "modelOutputLimitSource": cfg.limit_source, "thinking": cfg.thinking, "threshold": cfg.threshold, "summaryRoomRequired": cfg.quarter,
              "costCapUSD": cfg.max_cost, "costUSD": total, "fixtureSummaryLimit": cfg.summary_limit,
              "scenarios": [result.json() for result in results]}
    out.write(cfg.out / "report.json", json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    out.say(f"report: {cfg.out / 'report.txt'} and report.json")
    out.write(cfg.out / "report.txt", "\n".join(out.lines) + "\n")
    for log in cfg.out.glob("*-helper-stderr.log"):
        if not log.stat().st_size:
            log.unlink()
    fixed = out.scan(cfg.out)
    if fixed:
        print("live-compaction-e2e: the key was found in " + ", ".join(fixed) + " and redacted there", file=sys.stderr)
        return 1
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
