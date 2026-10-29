"""Generated loopback-only streaming gate for committed-history parity."""
import http.server
import json
import pathlib
import sys
import time

root = pathlib.Path(sys.argv[1])


class Gateway(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.path == "/v1/responses"
        assert self.headers["Authorization"] == "Bearer synthetic-only"
        assert body["model"] == "fixture" and body["stream"] is True
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def emit(value):
            self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
            self.wfile.flush()

        response = dict(id="history-response", status="in_progress", output=[])
        try:
            emit(dict(type="response.created", response=response))
            emit(dict(type="response.output_text.delta", output_index=0, item_id="live-part", content_index=0, delta="Live partial response"))
            (root / "streaming").touch()
            until = time.monotonic() + 60
            while not (root / "finish").exists() and time.monotonic() < until:
                time.sleep(.01)
            message = dict(type="message", id="live-part", role="assistant", status="completed",
                           content=[dict(type="output_text", text="Live partial response")])
            emit(dict(type="response.completed", response=dict(response, status="completed", output=[message],
                 usage=dict(input_tokens=10, output_tokens=3, total_tokens=13))))
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
(root / "ready.tmp").write_text(json.dumps(dict(port=server.server_port)))
(root / "ready.tmp").replace(root / "ready.json")
server.serve_forever()
