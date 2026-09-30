import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
COMMIT = "a" * 40


class CheckNextTests(unittest.TestCase):
    """Exercise ref selection without fetching, building, or running an app."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls.jsonl"
        stub = f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["CHECK_CALLS"], "a") as output:
    output.write(json.dumps([name, args]) + "\\n")
if name == "git":
    if args[:1] == ["-C"]:
        args = args[2:]
    if args[:1] == ["fetch"] and os.environ.get("CHECK_FAIL_FETCH"):
        sys.exit(1)
    if args[:1] == ["rev-parse"]:
        if os.environ.get("CHECK_BAD_REF"):
            sys.exit(1)
        print("a" * 40)
    if args[:2] == ["worktree", "add"]:
        target = pathlib.Path(args[-2])
        target.mkdir(parents=True, exist_ok=True)
        (target / ".git").write_text("fixture")
    if args[:2] == ["status", "--porcelain"] and os.environ.get("CHECK_DIRTY"):
        print(" M preserved.swift")
    if args[:1] == ["log"]:
        print("aaaaaaa fixture")
'''
        for name in ["git", "python3", "xcodegen", "xcodebuild"]:
            path = self.bin / name
            path.write_text(stub)
            path.chmod(0o755)
        self.environment = dict(os.environ, HOME=str(self.root),
                                PATH=str(self.bin) + os.pathsep + os.environ["PATH"], CHECK_CALLS=str(self.calls))
        self.environment.pop("PI_NEXT_REF", None)

    def run_check(self, **environment):
        result = subprocess.run(["bash", str(ROOT / "scripts/check-next.sh")],
                                env=dict(self.environment, **environment), text=True, capture_output=True)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        return result, calls

    def test_local_branch_is_resolved_once_and_never_fetches(self):
        result, calls = self.run_check(PI_NEXT_REF="dev/next", CHECK_FAIL_FETCH="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        git = [args[2:] if args[:1] == ["-C"] else args for name, args in calls if name == "git"]
        self.assertFalse(any(args[0] == "fetch" for args in git))
        self.assertEqual(sum(args[0] == "rev-parse" for args in git), 1)
        self.assertEqual(next(args for args in git if args[0] == "rev-parse")[-1], "dev/next^{commit}")
        self.assertEqual(next(args for args in git if args[:2] == ["worktree", "add"])[-1], COMMIT)
        self.assertEqual(next(args for args in git if args[0] == "checkout")[-1], COMMIT)
        self.assertIn("dev/next at aaaaaaa", result.stdout)

    def test_default_still_fetches_the_remote_branch(self):
        result, calls = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(any(name == "git" and "fetch" in args for name, args in calls))
        self.assertTrue(any(name == "git" and args[-1] == "origin/dev/next^{commit}" for name, args in calls))

    def test_bad_ref_stops_before_worktree_or_build_changes(self):
        result, calls = self.run_check(PI_NEXT_REF="missing", CHECK_BAD_REF="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown check ref: missing", result.stdout)
        self.assertFalse(any("worktree" in args for _, args in calls))
        self.assertFalse(any(name != "git" for name, _ in calls))

    def test_dirty_check_worktree_is_preserved(self):
        result, calls = self.run_check(PI_NEXT_REF="dev/next", CHECK_DIRTY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local changes; not touching them", result.stdout)
        self.assertFalse(any("checkout" in args for _, args in calls))
        self.assertFalse(any(name != "git" for name, _ in calls))
