#!/usr/bin/env python3
"""Generated, disposable project-skills acceptance fixture. Numeric loopback only.

No outbound requests, credential discovery, installation, automatic trust, or GUI
launch. Headers are never logged. Exact model-request bodies are retained only in
this explicitly generated fixture's evidence directory; ordinary JSONL logs hold
structural facts/hashes. Use generated content only, never personal files.
"""
import argparse
import base64
import collections
import hashlib
import json
import shutil
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_REQUEST = 32 * 1024 * 1024
MAX_CONTROL = 8192
GIF = "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
SKILLS = {"alpha": "a-review", "beta": "b-review"}
POLICY = "policy:\n  allow_implicit_invocation: false\n"
SUMMARY = """## Objective and constraints
Exercise the generated project-only skill picker through the normal saved runtime.
## Progress and evidence
Generated selections were retained in user rows. No external service was contacted.
## Decisions and uncertainty
Historical selections are not fresh authorization; no extra tools were granted.
## Next steps and references
Retain the original skill-bearing input carriers and continue isolated checks."""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def body(skill, version=1):
    return ("---\nname: review\ndescription: Generated " + skill + " review fixture\n"
            "disable-model-invocation: true\n---\n"
            "Review only the generated fixture. Do not run any helper or script.\n"
            f"SKILL_{skill.upper()}_BODY_V{version}\n")


def root_for(path):
    if path.is_symlink():
        raise ValueError("Fixture root must not be a symlink")
    path = path.resolve(strict=True)
    marker = path / "fixture.json"
    if marker.is_symlink() or marker.stat().st_size > MAX_CONTROL:
        raise ValueError("Invalid fixture marker")
    value = json.loads(marker.read_text(encoding="utf-8"))
    if value.get("kind") != "generated-project-skills-v1":
        raise ValueError("Not a generated project-skills fixture")
    uuid.UUID(value["id"])
    if not 1024 <= value["port"] <= 65535:
        raise ValueError("Invalid numeric-loopback fixture port")
    return path, value


def source_facts(root):
    files = [root / "profile.json", root / "fixtures/generated.gif"]
    files += sorted((root / "portals").glob("*"))
    files += sorted(path for path in (root / "project").rglob("*") if path.is_file())
    result = []
    for path in files:
        if path.is_symlink():
            raise ValueError("Generated fixture sources must not be symlinks")
        data = path.read_bytes()
        if len(data) > 2 * 1024 * 1024:
            raise ValueError("Generated fixture source unexpectedly large")
        result.append({"path": str(path.relative_to(root)), "bytes": len(data),
                       "sha256": digest(data), "canonical_path": str(path.resolve()),
                       "selection_id": digest(str(path.resolve()).encode()) if path.name == "SKILL.md" else None})
    return result


def initialize(args):
    root = args.root.absolute()
    if root.exists() or root.is_symlink():
        raise ValueError("Choose a new fixture root; initialization never overwrites existing files")
    if not 1024 <= args.port <= 65535:
        raise ValueError("Use an unprivileged numeric-loopback port")
    root.mkdir(parents=True)
    for relative in ["project", "fixtures", "state", "evidence/requests", "evidence/screenshots", "home", "config", "data", "cache", "bin", "portals"]:
        (root / relative).mkdir(parents=True, exist_ok=True)
    (root / "portals/gtk.portal").write_text("[portal]\nDBusName=org.freedesktop.impl.portal.desktop.gtk\nInterfaces=org.freedesktop.impl.portal.FileChooser;\nUseIn=XFCE\n", encoding="utf-8")
    (root / "portals/portals.conf").write_text("[preferred]\ndefault=none\norg.freedesktop.impl.portal.FileChooser=gtk\n", encoding="utf-8")
    fixture_id = str(uuid.uuid4())
    write_json(root / "fixture.json", {"kind": "generated-project-skills-v1", "id": fixture_id, "port": args.port})
    (root / "project/AGENTS.md").write_text("Generated project only. Never execute skill scripts.\nPROJECT_INSTRUCTION_V1\n", encoding="utf-8")
    for key, folder in SKILLS.items():
        skill = root / "project/.agents/skills" / folder
        (skill / "agents").mkdir(parents=True)
        (skill / "SKILL.md").write_text(body(key), encoding="utf-8")
        (skill / "agents/openai.yaml").write_text(POLICY, encoding="utf-8")
    attention = root / "project/.agents/skills/c-needs-attention"
    (attention / "agents").mkdir(parents=True)
    (attention / "SKILL.md").write_text("---\nname: unavailable\ndescription: Inspectable failed policy fixture\n---\nNever execute this fixture.\n", encoding="utf-8")
    (attention / "agents/openai.yaml").write_text("policy:\n  allow_implicit_invocation: invalid\n", encoding="utf-8")
    (root / "fixtures/generated.gif").write_bytes(base64.b64decode(GIF))
    write_json(root / "profile.json", {"id": str(uuid.uuid4()), "api": "openai-responses", "providerId": "litellm",
               "baseUrl": f"http://127.0.0.1:{args.port}", "modelId": "project-skills-fixture", "contextWindow": 32000,
               "maxOutputTokens": 4096, "input": ["text", "image"]})
    write_json(root / "evidence/generated-baseline.json", {"fixture_id": fixture_id, "files": source_facts(root)})
    print(json.dumps({"root": str(root), "fixture_id": fixture_id, "port": args.port,
                      "project": str(root / "project"), "profile": str(root / "profile.json")}, sort_keys=True))


def mutate(args):
    root, marker = root_for(args.root)
    skill = root / "project/.agents/skills" / SKILLS[args.skill]
    before = source_facts(root)
    if args.change == "body":
        (skill / "SKILL.md").write_text(body(args.skill, 2), encoding="utf-8")
    elif args.change == "policy":
        (skill / "agents/openai.yaml").write_text("policy:\n  allow_implicit_invocation: invalid\n", encoding="utf-8")
    elif args.change == "delete":
        (skill / "SKILL.md").unlink()
    elif args.change == "restore":
        (skill / "SKILL.md").write_text(body(args.skill), encoding="utf-8")
        (skill / "agents/openai.yaml").write_text(POLICY, encoding="utf-8")
    event = {"fixture_id": marker["id"], "skill": args.skill, "change": args.change,
             "before": before, "after": source_facts(root)}
    with (root / "evidence/mutations.jsonl").open("a", encoding="utf-8") as output:
        output.write(json.dumps(event, sort_keys=True) + "\n")
    print(json.dumps({"skill": args.skill, "change": args.change}, sort_keys=True))


def user_text(item):
    content = item.get("content", [])
    if isinstance(content, str):
        return content
    return "\n".join(part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") in {"input_text", "text"})


def request_facts(body_json):
    rows = []
    for item in body_json.get("input", []):
        if not isinstance(item, dict) or item.get("role") != "user":
            continue
        text = user_text(item)
        explicit = []
        for line in text.splitlines():
            if line.startswith("Current explicit selection IDs: "):
                explicit = line.removeprefix("Current explicit selection IDs: ").split(", ")
        parts = item.get("content", [])
        if not isinstance(parts, list):
            parts = [{"type": "input_text", "text": parts}]
        images = []
        for part in parts:
            if isinstance(part, dict) and part.get("type") == "input_image":
                url = part.get("image_url", "")
                header, _, data = url.partition(",")
                images.append({"mime": header.split(";")[0].removeprefix("data:"),
                               "base64_bytes": len(data), "sha256": digest(data.encode())})
        rows.append({"types": [part.get("type") for part in parts if isinstance(part, dict)],
                     "text_bytes": len(text.encode()), "text_sha256": digest(text.encode()),
                     "selection_line_ids": explicit, "images": images,
                     "fixture_markers": [f"SKILL_{key}_BODY_V{version}" for key in ["ALPHA", "BETA"] for version in [1, 2]
                                         if f"SKILL_{key}_BODY_V{version}" in text]})
    return {"model": body_json.get("model"), "users": rows,
            "tool_names": [tool.get("name") for tool in body_json.get("tools", []) if isinstance(tool, dict)],
            "tool_results": sum(isinstance(item, dict) and item.get("type") == "function_call_output" for item in body_json.get("input", [])),
            "compaction": any(user_text(item).startswith("Create a concise continuation checkpoint")
                              for item in body_json.get("input", []) if isinstance(item, dict) and item.get("role") == "user")}


class FixtureState:
    def __init__(self, root, marker):
        self.root, self.marker = root, marker
        self.lock = threading.Lock()
        self.actions, self.held = collections.deque(), {}
        existing = [int(path.stem.split("-")[-1]) for path in (root / "evidence/requests").glob("request-*.json")]
        self.count = max(existing, default=0)

    def record(self, event):
        with self.lock, (self.root / "evidence/requests.jsonl").open("a", encoding="utf-8") as output:
            output.write(json.dumps(event, sort_keys=True) + "\n")

    def accept(self, data, body_json):
        with self.lock:
            self.count += 1
            index = self.count
            action = self.actions.popleft() if self.actions else {"mode": "complete"}
            if action["mode"] in {"hold", "hold-tool"}:
                self.held[index] = threading.Event()
            path = self.root / f"evidence/requests/request-{index:04}.json"
            with path.open("xb") as output:
                output.write(data)
        facts = request_facts(body_json)
        self.record({"kind": "request", "request": index, "wire_bytes": len(data),
                     "wire_sha256": digest(data), "mode": action["mode"], **facts})
        return index, action, facts

    def control(self, value):
        if not isinstance(value, dict) or set(value) - {"enqueue", "release"}:
            raise ValueError("Invalid fixture control")
        actions = value.get("enqueue", [])
        if not isinstance(actions, list) or len(actions) > 32:
            raise ValueError("Invalid control queue")
        prepared = []
        for action in actions:
            if not isinstance(action, dict) or set(action) - {"mode", "seconds"}:
                raise ValueError("Invalid control action")
            if action.get("mode") not in {"complete", "fail", "hold", "tool", "hold-tool", "large"}:
                raise ValueError("Invalid control mode")
            seconds = action.get("seconds", 120)
            if not isinstance(seconds, int) or not 1 <= seconds <= 300:
                raise ValueError("Hold ceiling must be 1–300 seconds")
            prepared.append({"mode": action["mode"], "seconds": seconds})
        with self.lock:
            if len(self.actions) + len(prepared) > 32:
                raise ValueError("Control queue exceeds 32 actions")
            release = value.get("release")
            if release is not None and release != "all" and (not isinstance(release, int) or release not in self.held):
                raise ValueError("Unknown held request")
            self.actions.extend(prepared)
            for index, event in self.held.items():
                if release == "all" or release == index:
                    event.set()
        return self.status()

    def status(self):
        with self.lock:
            return {"fixture_id": self.marker["id"], "requests": self.count,
                    "queued_actions": list(self.actions), "held_requests": sorted(self.held)}


def handler_for(state):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def setup(self):
            super().setup()
            self.connection.settimeout(10)

        def reply(self, value, status=200):
            data = json.dumps(value, sort_keys=True).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path != "/status":
                self.reply({"error": "Not found"}, 404)
            else:
                self.reply(state.status())

        def do_POST(self):
            if self.path not in {"/control", "/v1/responses", "/responses"}:
                self.reply({"error": "Not found"}, 404)
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                maximum = MAX_CONTROL if self.path == "/control" else MAX_REQUEST
                if not 0 < length <= maximum:
                    raise ValueError("Invalid size")
                data = self.rfile.read(length)
                value = json.loads(data)
                if len(data) != length or not isinstance(value, dict):
                    raise ValueError("Invalid object")
                if self.path == "/control":
                    self.reply(state.control(value))
                    return
                index, action, facts = state.accept(data, value)
            except (ValueError, TypeError, AttributeError, TimeoutError):
                self.reply({"error": "Invalid bounded fixture request"}, 400)
                return
            if action["mode"] == "fail":
                self.reply({"error": "Generated fixture failure"}, 503)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                if action["mode"] in {"hold", "hold-tool"}:
                    if action["mode"] == "hold":
                        self.event({"type": "response.output_text.delta", "delta": "Generated fixture partial response. "})
                    deadline = time.monotonic() + action["seconds"]
                    while not state.held[index].wait(0.2):
                        self.wfile.write(b": controlled fixture hold\n\n")
                        self.wfile.flush()
                        if time.monotonic() >= deadline:
                            state.record({"kind": "hold-ceiling", "request": index})
                            break
                if action["mode"] in {"tool", "hold-tool"}:
                    if "ls" not in facts["tool_names"]:
                        raise ValueError("This fixture requires the real saved-runtime ls capability")
                    output = [{"type": "function_call", "id": f"fixture-call-{index}", "call_id": f"fixture-ls-{index}", "name": "ls", "arguments": '{"path":"."}'}]
                else:
                    answer = SUMMARY if facts["compaction"] else f"Generated fixture response {index}. No external model was contacted."
                    if action["mode"] == "large" and not facts["compaction"]:
                        answer += "\nGenerated continuation evidence; earlier selections remain historical. " * 500
                    output = [{"type": "message", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": answer}]}]
                self.event({"type": "response.completed", "response": {"status": "completed", "output": output}})
                state.record({"kind": "completed", "request": index})
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                state.record({"kind": "client-closed", "request": index})
            except ValueError:
                state.record({"kind": "fixture-capability-error", "request": index})
            finally:
                with state.lock:
                    state.held.pop(index, None)
                self.close_connection = True

        def event(self, value):
            self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
            self.wfile.flush()
    return Handler


def serve(args):
    root, marker = root_for(args.root)
    state = FixtureState(root, marker)
    server = ThreadingHTTPServer(("127.0.0.1", marker["port"]), handler_for(state))
    print(json.dumps({"listening": f"http://127.0.0.1:{marker['port']}", "fixture_id": marker["id"]}), flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


def seal(args):
    root, marker = root_for(args.root)
    binary = args.binary.resolve(strict=True)
    if not binary.is_file():
        raise ValueError("Binary must be an existing regular file")
    binary_sha = digest(binary.read_bytes())
    copied = root / "bin" / ("bello-agent-skills-" + binary_sha[:16])
    if copied.exists():
        if digest(copied.read_bytes()) != binary_sha:
            raise ValueError("Existing frozen binary differs")
    else:
        shutil.copyfile(binary, copied)
        copied.chmod(0o555)
    source = args.source_root.resolve(strict=True)
    paths = [path for path in (source / "rust").rglob("*") if path.is_file()
             and "target" not in path.relative_to(source).parts
             and (path.suffix in {".rs", ".py", ".sh"} or path.name in {"Cargo.toml", "Cargo.lock"})]
    icon = source / "assets/branding/bello-agent-icon-128.png"
    if icon.exists():
        paths.append(icon)
    if any(path.is_symlink() for path in paths):
        raise ValueError("Source sealing refuses symlinked source files")
    files = [{"path": str(path.relative_to(source)), "sha256": digest(path.read_bytes())} for path in sorted(paths)]
    result = {"fixture_id": marker["id"], "source_id": args.source_id, "binary": str(copied),
              "binary_sha256": binary_sha, "source_files": files, "generated_files": source_facts(root)}
    write_json(root / "evidence/sealed-build.json", result)
    print(json.dumps({"binary": str(copied), "binary_sha256": binary_sha, "source_files": len(files)}, sort_keys=True))


def inspect(args):
    root, marker = root_for(args.root)
    snapshots = []
    for path in sorted((root / "state").rglob("*.json")):
        if path.is_symlink() or path.stat().st_size > 256 * 1024 * 1024:
            raise ValueError("Unexpected checkpoint")
        data = path.read_bytes()
        value = json.loads(data)
        rows = []
        for row in value.get("messages", []):
            content = row.get("user_content") or {}
            if row.get("role") == "user":
                rows.append({"id": row.get("id"), "task_root_id": row.get("task_root_id"),
                             "raw_text_sha256": digest(row.get("text", "").encode()),
                             "skills": [{"selection": skill.get("selection"), "name": skill.get("name"), "path": skill.get("path")} for skill in content.get("skills", [])],
                             "retained_content_sha256": digest(json.dumps(content, sort_keys=True).encode())})
        snapshots.append({"path": str(path.relative_to(root)), "sha256": digest(data), "bytes": len(data),
                          "version": value.get("version"), "users": rows, "pending": len(value.get("pending", [])),
                          "draft_count": len(value.get("drafts", {})), "receipt_count": len(value.get("intents", {}))})
    write_json(root / "evidence/checkpoints.json", {"fixture_id": marker["id"], "snapshots": snapshots,
                                                     "current_sources": source_facts(root)})
    print(json.dumps({"snapshots": len(snapshots)}, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init"); init.add_argument("--root", type=Path, required=True); init.add_argument("--port", type=int, default=47887); init.set_defaults(run=initialize)
    for name, function in [("serve", serve), ("inspect", inspect)]:
        command = sub.add_parser(name); command.add_argument("--root", type=Path, required=True); command.set_defaults(run=function)
    mutation = sub.add_parser("mutate"); mutation.add_argument("--root", type=Path, required=True); mutation.add_argument("--skill", choices=SKILLS, required=True); mutation.add_argument("--change", choices=["body", "policy", "delete", "restore"], required=True); mutation.set_defaults(run=mutate)
    build = sub.add_parser("seal"); build.add_argument("--root", type=Path, required=True); build.add_argument("--binary", type=Path, required=True); build.add_argument("--source-root", type=Path, required=True); build.add_argument("--source-id", required=True); build.set_defaults(run=seal)
    args = parser.parse_args()
    try:
        args.run(args)
    except (ValueError, OSError, KeyError) as error:
        parser.exit(2, f"Fixture error: {error}\n")


if __name__ == "__main__":
    main()
