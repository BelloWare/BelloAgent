"""Generated loopback-only gateway that appends sized replies to a journal.

Every streamed reply carries `<root>/size` bytes of ASCII text (1 MiB when
the file is absent), so a measurement can grow a helper-owned journal
through real turns without any provider, credential or user data.
"""
import http.server
import json
import os
import pathlib
import sys
import threading
import time

root = pathlib.Path(sys.argv[1])
CHUNK = 65_536


def reply_text(size):
    line = "Appended generated history text for committed-history measurements.\n"
    text = (line * (size // len(line) + 1))[:size]
    return text


class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.path == "/v1/responses"
        assert self.headers["Authorization"] == "Bearer synthetic-only"
        assert body["stream"] is True
        try:
            size = int((root / "size").read_text())
        except (OSError, ValueError):
            size = 1_048_576
        text = reply_text(size)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def emit(value):
            self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
            self.wfile.flush()

        response = dict(id="append-response", status="in_progress", output=[])
        try:
            emit(dict(type="response.created", response=response))
            for start in range(0, len(text), CHUNK):
                emit(dict(type="response.output_text.delta", output_index=0, item_id="append-part", content_index=0,
                          delta=text[start:start + CHUNK]))
            message = dict(type="message", id="append-part", role="assistant", status="completed",
                           content=[dict(type="output_text", text=text)])
            emit(dict(type="response.completed", response=dict(response, status="completed", output=[message],
                 usage=dict(input_tokens=10, output_tokens=3, total_tokens=13))))
        except (BrokenPipeError, ConnectionResetError):
            pass


def exit_with_parent(poll=2.0):
    """Leave with the test host, even one that dies before its teardown."""
    parent = os.getppid()
    while os.getppid() == parent:
        time.sleep(poll)
    os._exit(0)


threading.Thread(target=exit_with_parent, daemon=True).start()
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
(root / "ready.tmp").write_text(json.dumps(dict(port=server.server_port)))
(root / "ready.tmp").replace(root / "ready.json")
server.serve_forever()
