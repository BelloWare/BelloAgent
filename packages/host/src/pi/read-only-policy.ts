import type { InlineExtension } from '@earendil-works/pi-coding-agent';

export const READ_ONLY_TOOLS = Object.freeze(['read', 'grep', 'find', 'ls']);
const allowed = new Set(READ_ONLY_TOOLS);
// This factory is bundled app policy, not a filesystem-discovered extension.
// Pi's active-tool registry rejects unknown tools; this hook checks dispatch again.
export const readOnlyGuard: InlineExtension = {
  name: 'Pi App read-only tool policy',
  factory(pi) { pi.on('tool_call', event => allowed.has(event.toolName) ? undefined : {block:true,reason:'Read-only side policy: only read, grep, find and ls are available. Skills cannot add tools.'}); },
};
