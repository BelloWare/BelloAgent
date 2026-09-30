"""The helper's stdio protocol, driven as the app drives it.

One client for the wire scripts: test-native-host.py (and
test-native-acceptance.py through it), test-concurrent-native-host.py and
live-compaction-e2e.py. It owns the framing: the process, a reader thread
that acknowledges capture frames and queues every other frame, a write lock,
NDJSON sends and closing. Each script keeps its own policy on top of it: the
handshake it expects, its deadlines, and what it does with events, failures
and the helper's standard error.

Load it by path (scripts/ is not on the import path of every runner):

    spec = importlib.util.spec_from_file_location('native_host_client', pathlib.Path(__file__).with_name('native_host_client.py'))
"""
import json
import queue
import subprocess
import threading
import time
import uuid


class HostPeer:
    """One helper process and its frames.

    `capture(frame)` runs on the reader thread for each capture frame, before
    it is acknowledged: True or False is the acknowledgement's `accepted`,
    None sends none. By default every capture is accepted. `stall` seconds
    are slept before every `stall_every`th line is parsed, as a reader that
    is busy now and then. Reader failures are kept in `errors`.
    """

    def __init__(self, binary, cwd, *, env=None, stderr=subprocess.PIPE, ensure_ascii=False,
                 capture=None, stall=0, stall_every=40, skip_bad_lines=False, drop_events=False):
        self.process = subprocess.Popen([str(binary)], cwd=cwd, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=stderr, env=env)
        self.frames = queue.Queue()
        self.write_lock = threading.Lock()
        self.errors = []
        self.epoch = None
        self._ensure_ascii = ensure_ascii
        self._capture = capture or (lambda frame: True)
        self._stall, self._stall_every = stall, stall_every
        self._skip_bad_lines, self._drop_events = skip_bad_lines, drop_events
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            count = 0
            for line in self.process.stdout:
                count += 1
                if self._stall and count % self._stall_every == 0:
                    time.sleep(self._stall)
                try:
                    frame = json.loads(line)
                except ValueError:
                    if self._skip_bad_lines:
                        continue
                    raise
                if frame.get('kind') == 'capture':
                    accepted = self._capture(frame)
                    if accepted is not None:
                        self.send({'v': 1, 'kind': 'capture.ack', 'hostEpoch': frame['hostEpoch'],
                                   'transferId': frame['transferId'], 'accepted': accepted})
                elif self._drop_events and frame.get('kind') == 'event':
                    continue
                else:
                    self.frames.put(frame)
        except Exception as error:
            self.errors.append(str(error))

    def encode(self, value):
        return json.dumps(value, ensure_ascii=self._ensure_ascii, separators=(',', ':')).encode()

    def send(self, value):
        with self.write_lock:
            self.process.stdin.write(self.encode(value) + b'\n')
            self.process.stdin.flush()

    def hello(self, timeout, **extra):
        """Sends the handshake and returns the first frame, the ready one."""
        self.send({'v': 1, 'kind': 'hello', 'major': 1, 'minor': 1, **extra})
        return self.frames.get(timeout=timeout)

    def post(self, method, params=None, session=None, command_id=None):
        """Sends one command and returns its identity."""
        command_id = command_id or str(uuid.uuid4())
        self.send({'v': 1, 'kind': 'command', 'hostEpoch': self.epoch, 'commandId': command_id,
                   'sessionId': session, 'method': method, 'params': params or {}})
        return command_id

    def next_frame(self, timeout):
        return self.frames.get(timeout=timeout)

    def close(self, wait=5, join=2, close_stderr=True):
        if self.process.poll() is None:
            try:
                self.process.stdin.close()
            except OSError:
                pass
            try:
                self.process.wait(timeout=wait)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.reader.join(timeout=join)
        self.process.stdout.close()
        if close_stderr and self.process.stderr is not None:
            self.process.stderr.close()
