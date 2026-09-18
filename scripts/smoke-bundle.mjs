// Compatibility entry point for the existing release.sh. Node is build tooling
// only: the application under test launches the native Swift helper directly.
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
if (!process.argv[2]) throw new Error('Pass the packaged Bello Agent.app path');
execFileSync('python3', [fileURLToPath(new URL('./smoke-native-bundle.py', import.meta.url)), process.argv[2]], { stdio: 'inherit' });
