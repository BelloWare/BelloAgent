import { readFileSync } from 'node:fs';
export function sdkVersions(): { pi: string; ai: string } {
  const version = (name: string): string => {
    const entry = import.meta.resolve(name);
    return (JSON.parse(readFileSync(new URL('../package.json', entry), 'utf8')) as { version: string }).version;
  };
  const pi = version('@earendil-works/pi-coding-agent'), ai = version('@earendil-works/pi-ai');
  if (pi !== '0.85.1' || ai !== '0.85.1') throw new Error('Packaged Pi version mismatch');
  return { pi, ai };
}
