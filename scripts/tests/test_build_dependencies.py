"""Exercise dependency reuse with temporary trees and a mocked npm installer."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import build_dependencies as dependencies


class BuildDependenciesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pi-dependencies-test-")
        self.addCleanup(self.temporary.cleanup)
        # ensure_dependencies resolves its root; on macOS /var is a symlink to /private/var.
        self.root = Path(self.temporary.name).resolve()
        (self.root / "scripts").mkdir()
        (self.root / "scripts/runtime-lock.json").write_text('{"node": "24.21.0", "npm": "11.19.0"}')
        (self.root / "scripts/with-runtime.sh").write_text("#!/bin/sh\nexec \"$@\"\n")
        (self.root / "package.json").write_text(json.dumps({
            "dependencies": {"react": "19.3.0"}, "devDependencies": {"esbuild": "0.28.2"}}))
        (self.root / "package-lock.json").write_text('{"lockfileVersion": 3}')
        self.configuration = {"omit": [], "ignore-scripts": False, "registry": "https://registry.npmjs.org/"}
        self.config = self.enterContext(patch.object(dependencies.subprocess, "check_output",
            side_effect=lambda *args, **kwargs: json.dumps(self.configuration)))
        self.install = self.enterContext(patch.object(dependencies.subprocess, "run", side_effect=self.create_install))
        self.enterContext(patch.dict(os.environ, {"NODE_ENV": "development", "NODE_OPTIONS": "", "ESBUILD_BINARY_PATH": ""}))
        self.stamp = self.root / "node_modules" / dependencies.STAMP_NAME

    def create_install(self, *args, **kwargs):
        self.assertFalse(self.stamp.exists(), "A failed reinstall must not retain a successful stamp")
        modules = self.root / "node_modules"
        if modules.exists():
            shutil.rmtree(modules)
        packages = {
            "node_modules/react": {"version": "19.3.0"},
            "node_modules/esbuild": {"version": "0.28.2", "bin": {"esbuild": "bin/esbuild"}},
            "node_modules/transitive": {"version": "1.0.0"},
        }
        for relative, metadata in packages.items():
            directory = self.root / relative
            directory.mkdir(parents=True)
            (directory / "package.json").write_text(json.dumps({"version": metadata["version"]}))
        binary = modules / "esbuild/bin/esbuild"
        binary.parent.mkdir()
        binary.write_text("#!/bin/sh\nexit 0\n")
        binary.chmod(0o755)
        (modules / ".bin").mkdir()
        (modules / ".bin/esbuild").symlink_to("../esbuild/bin/esbuild")
        (modules / ".package-lock.json").write_text(json.dumps({"lockfileVersion": 3, "packages": packages}))

    def test_successful_install_is_reused(self):
        self.assertTrue(dependencies.ensure_dependencies(self.root))
        self.assertTrue(self.stamp.is_file())
        self.assertFalse(dependencies.ensure_dependencies(self.root))
        self.install.assert_called_once_with(
            [str(self.root / "scripts/with-runtime.sh"), "npm", "ci", "--no-audit", "--no-fund"],
            cwd=self.root, check=True)
        self.config.assert_called_with(
            [str(self.root / "scripts/with-runtime.sh"), "npm", "config", "list", "--json"],
            cwd=self.root, text=True, stderr=subprocess.PIPE)

    def test_npm_configuration_values_are_not_saved_in_stamp(self):
        self.configuration["_authToken"] = "test-secret-token"
        (self.root / ".npmrc").write_text("//registry.npmjs.org/:_authToken=project-secret-token\n")
        dependencies.ensure_dependencies(self.root)
        stamp = json.loads(self.stamp.read_text())
        self.assertEqual(set(stamp), {"inputs", "installed"})
        for digest in stamp.values():
            self.assertRegex(digest, r"^[a-f0-9]{64}$")

    def test_input_files_invalidate_successful_install(self):
        dependencies.ensure_dependencies(self.root)
        for relative in ("package.json", "package-lock.json", "scripts/runtime-lock.json",
                         "scripts/with-runtime.sh", ".npmrc"):
            with self.subTest(relative=relative):
                path = self.root / relative
                original = path.read_bytes() if path.exists() else b""
                path.write_bytes(original + b"\n")
                self.assertTrue(dependencies.ensure_dependencies(self.root))
                self.assertFalse(dependencies.ensure_dependencies(self.root))
        self.assertEqual(self.install.call_count, 6)

    def test_effective_npm_configuration_and_install_environment_invalidate(self):
        dependencies.ensure_dependencies(self.root)
        self.configuration["ignore-scripts"] = True
        self.assertTrue(dependencies.ensure_dependencies(self.root))
        with patch.dict(os.environ, {"NODE_ENV": "production"}):
            self.assertTrue(dependencies.ensure_dependencies(self.root))
            self.assertFalse(dependencies.ensure_dependencies(self.root))
        self.assertEqual(self.install.call_count, 3)

    def test_missing_tree_package_lock_dependency_or_executable_reinstalls(self):
        dependencies.ensure_dependencies(self.root)
        for relative in ("node_modules", "node_modules/.package-lock.json", "node_modules/react",
                         "node_modules/transitive", "node_modules/esbuild/bin/esbuild", "node_modules/.bin/esbuild"):
            with self.subTest(relative=relative):
                path = self.root / relative
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()
                self.assertTrue(dependencies.ensure_dependencies(self.root))
                self.assertFalse(dependencies.ensure_dependencies(self.root))
        self.assertEqual(self.install.call_count, 7)

    def test_changed_package_or_hidden_lock_reinstalls(self):
        dependencies.ensure_dependencies(self.root)
        package = self.root / "node_modules/react/package.json"
        for content in ('{"version": "19.2.0"}', '{"version": "19.3.0", "modified": true}'):
            with self.subTest(content=content):
                package.write_text(content)
                self.assertTrue(dependencies.ensure_dependencies(self.root))
        hidden = self.root / "node_modules/.package-lock.json"
        hidden.write_text(hidden.read_text() + "\n")
        self.assertTrue(dependencies.ensure_dependencies(self.root))
        self.assertEqual(self.install.call_count, 4)

    def test_replaced_package_or_executable_symlink_reinstalls(self):
        dependencies.ensure_dependencies(self.root)
        package = self.root / "node_modules/react"
        replacement = self.root / "linked-react"
        package.rename(replacement)
        package.symlink_to(replacement, target_is_directory=True)
        self.assertTrue(dependencies.ensure_dependencies(self.root))
        executable = self.root / "node_modules/.bin/esbuild"
        replacement = self.root / "different-esbuild"
        shutil.copy2(executable, replacement)
        executable.unlink()
        executable.symlink_to(replacement)
        self.assertTrue(dependencies.ensure_dependencies(self.root))
        self.assertEqual(self.install.call_count, 3)

    def test_missing_or_malformed_stamp_reinstalls(self):
        dependencies.ensure_dependencies(self.root)
        for content in (None, "partial write", "[]", "{}"):
            with self.subTest(content=content):
                if content is None:
                    self.stamp.unlink()
                else:
                    self.stamp.write_text(content)
                self.assertTrue(dependencies.ensure_dependencies(self.root))
        self.assertEqual(self.install.call_count, 5)

    def test_failed_reinstall_cannot_reuse_old_stamp_even_when_inputs_are_restored(self):
        dependencies.ensure_dependencies(self.root)
        lock = self.root / "package-lock.json"
        original = lock.read_bytes()
        lock.write_bytes(original + b"\n")

        def fail_install(*args, **kwargs):
            self.assertFalse(self.stamp.exists())
            raise subprocess.CalledProcessError(1, args[0])

        self.install.side_effect = fail_install
        with self.assertRaises(subprocess.CalledProcessError):
            dependencies.ensure_dependencies(self.root)
        self.assertFalse(self.stamp.exists())
        lock.write_bytes(original)
        self.install.side_effect = self.create_install
        self.assertTrue(dependencies.ensure_dependencies(self.root))
        self.assertFalse(dependencies.ensure_dependencies(self.root))
        self.assertEqual(self.install.call_count, 3)

    def test_incomplete_successful_install_is_not_stamped(self):
        def incomplete_install(*args, **kwargs):
            self.create_install()
            shutil.rmtree(self.root / "node_modules/react")

        self.install.side_effect = incomplete_install
        with self.assertRaisesRegex(RuntimeError, "npm ci completed without"):
            dependencies.ensure_dependencies(self.root)
        self.assertFalse(self.stamp.exists())
        self.install.side_effect = self.create_install
        self.assertTrue(dependencies.ensure_dependencies(self.root))


if __name__ == "__main__":
    unittest.main()
