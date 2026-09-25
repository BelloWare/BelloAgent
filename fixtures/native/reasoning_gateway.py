"""A loopback Responses gateway whose model reasons, for the live e2e fixture mode.

`scripts/live-compaction-e2e.py --fixture` runs its scenarios against this
gateway instead of a real one. It answers at once, but it spends output
tokens the way a reasoning model does, which the helper's other fixtures
never do:

- Reasoning grows with the requested effort: about 12,000 tokens at high for
  a summary (a summary has the whole conversation to think over), a tenth of
  that for a turn. The answer comes after the reasoning, in the same output
  budget.
- A request whose max_output_tokens is below its reasoning plus its answer
  ends as the Responses API ends it: `response.incomplete`, reason
  `max_output_tokens`, with the reasoning spent and no complete answer.
- Input tokens are counted as the helper estimates them (characters over
  four); an input over the model's window is refused as a context overflow.
- Each session's prompt cache is simulated (the shared prefix of its previous
  request), and the terminal event reports cost as LiteLLM's Responses
  iterator does (`usage.cost`), at a GPT-5-class price.

`summary_limit` is the debug switch that proves the harness can fail: it
caps every summary's output at that many tokens, as the 0.1.90 helper capped
them at 13,107, so a summary at high effort stops at its limit.

The model is a scripted agent. A turn whose task names evidence files
(`E2E-READ-TASK`) reads the next unread file, one call per request, then
answers with the marker of each file; any other turn answers briefly. Its
summaries keep the task, the files read and the markers seen, so the task
survives compaction as it would with a real model. Every request is first
checked against the shared wire contract (`litellm_contract.py`).

No network beyond loopback and no real credentials.
"""
import hashlib
import http.server
import json
import math
import re
import threading
import uuid

import litellm_contract as contract

# Output tokens a request reasons for, by effort. A summary reasons over the
# whole conversation; a turn that reads the next file reasons a tenth of it.
SUMMARY_REASONING = {"none": 0, "minimal": 1_000, "low": 5_000, "medium": 10_000, "high": 12_000, "xhigh": 30_000, "max": 40_000}
TURN_REASONING_SHARE = 10
# USD per million tokens: GPT-5-class input, cached input and output.
PRICES = {"input": 1.25, "cached": 0.125, "output": 10.0}
TASK_TAG = "E2E-READ-TASK"
MARKER = re.compile(r"E2E-MARKER (part-\d+): ([A-Za-z0-9-]+)")
EVIDENCE = re.compile(r"evidence/part-\d+\.txt")
SUMMARY_PREFIX = "The conversation history before this point was compacted into the following summary:"
# Tools a seeded history may have used in an editing session before this
# read-only one; the contract checks their arguments against these.
HISTORICAL_TOOLS = {
    "bash": {"type": "object", "properties": {"command": {"type": "string"}, "timeout": {"type": "integer"}}, "required": ["command"]},
    "write": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]},
    "edit": {"type": "object", "properties": {"path": {"type": "string"}, "oldText": {"type": "string"}, "newText": {"type": "string"}}, "required": ["path", "oldText", "newText"]},
}


# Pi's summary prompts (CompactionSourceBuilder), by the words each begins with.
SUMMARY_PROMPTS = (("history-update", "The messages above are NEW conversation messages to incorporate"),
                   ("history", "The messages above are a conversation to summarize."),
                   ("turn-prefix", "This is the PREFIX of a turn that was too large to keep."))
# Ours: a compaction is one request, so a split turn's prefix comes in the
# history's request, in <turn-prefix>, with this instruction last.
SPLIT_TURN = "The messages in <turn-prefix> are the PREFIX of a turn that was too large to keep."


def parse_summary_prompt(prompt):
    """Splits a summary prompt into its kind, its conversation text (a split
    turn's prefix after the history) and the previous summary it updates. The
    fixed prompt comes last, so the last one found is the request's own; a
    conversation can quote any of them. A request that also summarizes a
    split turn's prefix is "<kind>+turn-prefix"."""
    if prompt.startswith("Create a concise continuation checkpoint"):
        return "continuation", "", None
    position, kind = max((prompt.rfind(start), kind) for kind, start in SUMMARY_PROMPTS)
    if position < 0:
        return None, prompt, None
    head, previous, prefix = prompt[:position], None, None
    if head.endswith("\n</previous-summary>\n\n"):
        begin = head.rfind("<previous-summary>\n")
        previous, head = head[begin + len("<previous-summary>\n"):-len("\n</previous-summary>\n\n")], head[:begin]
    if kind != "turn-prefix" and head.endswith("\n</turn-prefix>\n\n") and prompt.rfind(SPLIT_TURN) > position:
        begin = head.rfind("<turn-prefix>\n")
        prefix, head = head[begin + len("<turn-prefix>\n"):-len("\n</turn-prefix>\n\n")], head[:begin]
        kind += "+turn-prefix"
    head = head[len("<conversation>\n"):] if head.startswith("<conversation>\n") else head
    conversation = head[:-len("\n</conversation>\n\n")] if head.endswith("\n</conversation>\n\n") else head
    return kind, conversation if prefix is None else conversation + "\n\n" + prefix, previous


def tokens(text):
    """Characters over four, rounded up, as the helper estimates."""
    return math.ceil(len(text) / 4)


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


class ReasoningGateway:
    """One loopback server. `records` lists every request it answered."""

    def __init__(self, *, api_key, model, window, summary_limit=None):
        self.api_key, self.model, self.window, self.summary_limit = api_key, model, window, summary_limit
        self.records, self.lock, self.prefixes = [], threading.Lock(), {}
        gateway = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                gateway.handle(self)

        class Server(http.server.ThreadingHTTPServer):
            daemon_threads = True

        self.server = Server(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.server.server_port}/v1"

    def start(self):
        self.thread.start()
        return self

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    # -- request handling -------------------------------------------------

    def handle(self, handler):
        raw = handler.rfile.read(int(handler.headers.get("Content-Length", "0")))
        record = {"sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}
        try:
            body = json.loads(raw)
            semantic = contract.validate_request("POST", handler.path, dict(handler.headers), body, api_key=self.api_key, model=self.model,
                                                 native_items="portable", historical_tool_schemas=HISTORICAL_TOOLS)
        except (ValueError, contract.FixtureContractError) as error:
            # The contract compares the key in memory and never names it.
            return self.refuse(handler, record, 422, {"error": {"type": "fixture_contract", "message": str(error)}})
        summary = semantic["is_compaction"]
        effort = (body.get("reasoning") or {}).get("effort") or ("medium" if body.get("reasoning") is None else "none")
        input_tokens = self.input_tokens(body)
        record.update(purpose="summary" if summary else "turn", session=handler.headers.get("x-session-id"), effort=effort,
                      input_tokens=input_tokens, max_output_tokens=body.get("max_output_tokens"))
        if input_tokens > self.window:
            return self.refuse(handler, record, 400, {"error": {"type": "invalid_request_error", "code": "context_length_exceeded",
                               "message": f"This model's maximum context length is {self.window} tokens. Your input has {input_tokens} tokens."}})
        reasoning = SUMMARY_REASONING.get(effort, SUMMARY_REASONING["medium"])
        if summary:
            prompt = semantic["user_texts"][-1]
            text, call = self.summarize(prompt, input_tokens, body=body), None
            record["summary_kind"] = parse_summary_prompt(prompt)[0]
        else:
            reasoning //= TURN_REASONING_SHARE
            text, call = self.act(body)
        answer = tokens(text) if call is None else tokens(call["name"] + call["arguments"])
        # The debug switch: a summary carries at most `summary_limit`, as 0.1.90 sent it.
        limit = body.get("max_output_tokens")
        if summary and self.summary_limit is not None:
            limit = min(limit, self.summary_limit) if limit is not None else self.summary_limit
        record["effective_limit"] = limit
        complete = limit is None or reasoning + answer <= limit
        spent = reasoning + answer if complete else limit
        cached = self.cached_tokens(body, input_tokens)
        cost = ((input_tokens - cached) * PRICES["input"] + cached * PRICES["cached"] + spent * PRICES["output"]) / 1_000_000
        usage = {"input_tokens": input_tokens, "input_tokens_details": {"cached_tokens": cached},
                 "output_tokens": spent, "output_tokens_details": {"reasoning_tokens": min(reasoning, spent)},
                 "total_tokens": input_tokens + spent, "cost": round(cost, 8)}
        record.update(reasoning=min(reasoning, spent), answer_tokens=answer, output_tokens=spent, cached_tokens=cached, cost=usage["cost"],
                      status="completed" if complete else "incomplete", reason=None if complete else "max_output_tokens",
                      call=call and {"name": call["name"], "arguments": call["arguments"]})
        self.stream(handler, record, usage, text, call, reasoning, complete, limit)

    def refuse(self, handler, record, status, payload):
        record.update(status="refused", http_status=status, error=payload["error"]["message"])
        with self.lock:
            self.records.append(record)
        output = encoded(payload)
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(output)))
        handler.end_headers()
        handler.wfile.write(output)

    @staticmethod
    def input_tokens(body):
        """The text a model reads: every message, call, result and tool schema."""
        chars = len(json.dumps(body.get("tools", []), separators=(",", ":"))) if body.get("tools") else 0
        for item in body["input"]:
            kind = item.get("type", "message")
            if kind == "function_call":
                chars += len(item.get("name", "")) + len(item.get("arguments", ""))
            elif kind == "function_call_output":
                output = item.get("output")
                chars += len(output) if isinstance(output, str) else len(json.dumps(output))
            elif isinstance(item.get("content"), str):
                chars += len(item["content"])
            else:
                chars += sum(len(part.get("text", "")) for part in item.get("content", []))
        return math.ceil(chars / 4) + 4 * len(body["input"])

    def cached_tokens(self, body, input_tokens):
        """A session's prompt cache: the prefix it shares with the previous request, in 128-token blocks from 1,024."""
        key = body.get("prompt_cache_key")
        if not key:
            return 0
        text = json.dumps(body["input"], separators=(",", ":"))
        with self.lock:
            previous, self.prefixes[key] = self.prefixes.get(key, ""), text
        low, high = 0, min(len(previous), len(text))
        while low < high:
            middle = (low + high + 1) // 2
            low, high = (middle, high) if previous[:middle] == text[:middle] else (low, middle - 1)
        shared_tokens = min(input_tokens, low // 4)
        return shared_tokens // 128 * 128 if shared_tokens >= 1024 else 0

    # -- the scripted model -----------------------------------------------

    def summarize(self, prompt, input_tokens, body=None):
        """A structured summary in pi's format that keeps the task, files and markers."""
        kind, conversation, previous = parse_summary_prompt(prompt)
        previous = previous or ""
        if kind == "continuation" and body:
            pieces = []
            for item in body["input"][1:-1]:
                if item.get("type") == "function_call":
                    args = json.loads(item["arguments"])
                    pieces.append(item["name"] + "(" + ", ".join(f'{key}={json.dumps(value)}' for key, value in args.items()) + ")")
                elif item.get("type") == "function_call_output":
                    pieces.append("[Tool result]: " + str(item["output"]))
                else:
                    text = "".join(part.get("text", "") for part in item.get("content", []) if isinstance(part, dict))
                    if text.startswith(SUMMARY_PREFIX):
                        previous = text
                    else:
                        pieces.append("[" + item.get("role", "assistant").title() + "]: " + text)
            conversation = "\n\n".join(pieces)
        users = [part[len("[User]: "):] for part in conversation.split("\n\n") if part.startswith("[User]: ")]
        task = next((user for user in users if TASK_TAG in user), None) or next((line for line in previous.split("\n") if TASK_TAG in line), None)
        files = sorted(set(re.findall(r'read\(path="([^"]+)"', conversation)) | set(self.listed(previous, "Files read: ")))
        markers = dict(MARKER.findall(previous))
        markers.update(MARKER.findall(conversation))
        goal = task or (users[0][:300] if users else "Continue the work in progress.")
        lines = ["## Goal", goal.replace("\n", " ") if task else goal, "", "## Constraints & Preferences", "- (none)", "", "## Progress", "### Done",
                 f"- [x] Read {len(files)} files", "", "### In Progress", "- [ ] Continue the task", "", "### Blocked", "- (none)", "",
                 "## Key Decisions", "- **Summarize before continuing**: the context reached its limit", "", "## Next Steps", "1. Continue the task", "",
                 "## Critical Context", "- Files read: " + ", ".join(files),
                 "- Markers seen: " + ", ".join(f"E2E-MARKER {part}: {word}" for part, word in sorted(markers.items()))]
        # A real summary grows with what it summarizes: one token of summary per
        # twenty of input, from 800 to 4,000, filled with the conversation's own lines.
        target, notes = max(800, min(3_000, input_tokens // 30)) * 4, [line.strip() for line in conversation.split("\n") if len(line.strip()) > 40]
        index = 0
        while sum(len(line) + 1 for line in lines) < target and notes:
            lines.append("- Evidence: " + notes[(index * 7919) % len(notes)][:160])
            index += 1
        if kind and kind.endswith("+turn-prefix"):
            # The split turn's section, as the one request asks for it.
            lines += ["", "---", "", "**Turn Context (split turn):**", "", "## Original Request", goal.replace("\n", " "), "",
                      "## Early Progress", f"- [x] Read {len(files)} files", "", "## Context for Suffix", "- The kept messages continue this turn"]
        return "\n".join(lines)

    @staticmethod
    def listed(text, label):
        """The items of every `- label a, b` line (a checkpoint can hold two summaries)."""
        return [item.strip() for line in text.split("\n") if line.startswith("- " + label)
                for item in line[len("- " + label):].split(",") if item.strip()]

    def act(self, body):
        """The next step of a turn: a read call for the next evidence file, or an answer."""
        users, calls, outputs = [], [], []
        for item in body["input"][1:]:
            kind = item.get("type", "message")
            if kind == "function_call":
                calls.append(item)
            elif kind == "function_call_output":
                outputs.append(item.get("output") if isinstance(item.get("output"), str) else json.dumps(item.get("output")))
            elif item.get("role") == "user":
                users.append("\n".join(part.get("text", "") for part in item.get("content", [])))
        task = next((text for text in reversed(users) if TASK_TAG in text), None)
        if task is None:
            summarized = any(text.startswith(SUMMARY_PREFIX) for text in users)
            return ("Acknowledged. " + ("The summary above describes the session's goal, the files read and the next steps; "
                                        "I can continue from it." if summarized else "Continuing.")), None
        wanted = list(dict.fromkeys(EVIDENCE.findall(task.split("Each file starts", 1)[0])))
        read = {json.loads(call.get("arguments") or "{}").get("path") for call in calls if call.get("name") == "read"}
        markers = {}
        for text in users:
            if text.startswith(SUMMARY_PREFIX):
                read |= set(self.listed(text, "Files read: "))
                block = re.search(r"<read-files>\n(.*?)\n</read-files>", text, re.S)
                read |= set(block.group(1).split("\n")) if block else set()
                markers.update(MARKER.findall(text))
        for output in outputs:
            markers.update(MARKER.findall(output))
        pending = [path for path in wanted if path not in read]
        if pending:
            ident = uuid.uuid4().hex[:24]
            return "", {"type": "function_call", "id": "fc_" + ident, "call_id": "call_" + ident, "name": "read",
                        "arguments": json.dumps({"path": pending[0]}, separators=(",", ":"))}
        parts = [re.search(r"part-\d+", path).group(0) for path in wanted]
        return "\n".join(f"{part}: {markers.get(part, '(not recalled)')}" for part in parts), None

    # -- the stream ---------------------------------------------------------

    def stream(self, handler, record, usage, text, call, reasoning, complete, limit):
        ident = uuid.uuid4().hex[:24]
        reasoning_item = {"type": "reasoning", "id": "rs_" + ident, "summary": [{"type": "summary_text", "text": "Reviewing the input before answering."}],
                          "encrypted_content": "fixture-opaque-" + ident}
        events = [{"type": "response.created", "response": {"id": "resp_" + ident, "model": self.model, "status": "in_progress", "output": []}}]
        output = []
        if reasoning:
            events += [{"type": "response.output_item.added", "output_index": 0, "item": {"type": "reasoning", "id": reasoning_item["id"], "summary": []}},
                       {"type": "response.output_item.done", "output_index": 0, "item": reasoning_item}]
            output.append(reasoning_item)
        index = len(output)
        if complete and call is not None:
            events += [{"type": "response.output_item.added", "output_index": index, "item": {**call, "arguments": ""}},
                       {"type": "response.function_call_arguments.delta", "output_index": index, "item_id": call["id"], "delta": call["arguments"]},
                       {"type": "response.function_call_arguments.done", "output_index": index, "item_id": call["id"], "arguments": call["arguments"]},
                       {"type": "response.output_item.done", "output_index": index, "item": call}]
            output.append(call)
        elif text and (complete or limit > reasoning):
            # An incomplete answer is cut where the output budget ran out.
            shown = text if complete else text[:max(0, limit - reasoning) * 4]
            message = {"type": "message", "id": "msg_" + ident, "role": "assistant", "status": "completed" if complete else "incomplete",
                       "content": [{"type": "output_text", "text": shown, "annotations": []}]}
            events.append({"type": "response.output_item.added", "output_index": index, "item": {**message, "status": "in_progress", "content": []}})
            events += [{"type": "response.output_text.delta", "output_index": index, "content_index": 0, "delta": shown[start:start + 2048]}
                       for start in range(0, len(shown), 2048)]
            events.append({"type": "response.output_item.done", "output_index": index, "item": message})
            output.append(message)
        final = {"id": "resp_" + ident, "object": "response", "model": self.model, "status": "completed" if complete else "incomplete",
                 "output": output, "usage": usage}
        if not complete:
            final["incomplete_details"] = {"reason": "max_output_tokens"}
        events.append({"type": "response.completed" if complete else "response.incomplete", "response": final})
        payload = b"".join(b"event: " + event["type"].encode() + b"\ndata: " + encoded(event) + b"\n\n" for event in events)
        with self.lock:
            self.records.append(record)
        handler.send_response(200)
        handler.send_header("Content-Type", "text/event-stream")
        handler.end_headers()
        try:
            handler.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            record["cancelled"] = True
