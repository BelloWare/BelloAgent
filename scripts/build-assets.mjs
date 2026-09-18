import { build } from 'esbuild';
import { mkdir, copyFile } from 'node:fs/promises';
import { join } from 'node:path';
const root = process.env.PI_BUILD_ROOT;
if (!root) throw new Error('PI_BUILD_ROOT must point to session scratch');
const output = join(root, 'bundle', 'Transcript');
await mkdir(output, { recursive: true });
await build({ entryPoints: ['packages/transcript/src/main.tsx'], bundle: true, minify: true,
  outfile: join(output, 'transcript.js'), platform: 'browser', format: 'iife', target: ['safari17'],
  define: { 'process.env.NODE_ENV': '"production"' }, jsx: 'automatic', legalComments: 'linked' });
await copyFile('packages/transcript/index.html', join(output, 'index.html'));
