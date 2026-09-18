/** Only ranges of the currently displayed native message may reach the clipboard. */
export interface CopyRange { start: number; end: number }
export interface MarkdownCopySelection { source: string; ranges: CopyRange[] }
export interface MarkdownCopyTarget extends MarkdownCopySelection { label: string }

interface Position { start: { offset?: number }; end: { offset?: number } }
export interface MarkdownNode {
  type: string; depth?: number; value?: string; position?: Position; children?: MarkdownNode[];
  data?: { hName?: string; hProperties?: Record<string, string>; [key: string]: unknown };
}

export const MAX_COPY_BYTES = 65_536;
export const MAX_COPY_RANGES = 4_096;

export function selectedMarkdown({ source, ranges }: MarkdownCopySelection): string | null {
  if (new TextEncoder().encode(source).length > MAX_COPY_BYTES || ranges.length === 0 || ranges.length > MAX_COPY_RANGES) return null;
  let previousEnd = 0;
  const pieces: string[] = [];
  for (const { start, end } of ranges) {
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < previousEnd || start < 0 || end <= start || end > source.length) return null;
    // JavaScript offsets are UTF-16; never split a surrogate pair at the bridge.
    if (splitsSurrogate(source, start) || splitsSurrogate(source, end)) return null;
    pieces.push(source.slice(start, end)); previousEnd = end;
  }
  return pieces.join('');
}

function splitsSurrogate(source: string, offset: number): boolean {
  return offset > 0 && offset < source.length && /[\uD800-\uDBFF]/.test(source[offset - 1]!) && /[\uDC00-\uDFFF]/.test(source[offset]!);
}

function addRange(ranges: CopyRange[], start: number, end: number): void {
  if (end <= start) return;
  const previous = ranges.at(-1);
  if (previous?.end === start) previous.end = end;
  else ranges.push({ start, end });
}

interface SourceLine { start: number; contentEnd: number; end: number }
function sourceLines(source: string, start: number, end: number): SourceLine[] {
  const lines: SourceLine[] = [];
  for (let cursor = start; cursor < end;) {
    const lf = source.indexOf('\n', cursor), cr = source.indexOf('\r', cursor);
    const newline = lf < 0 ? cr : cr < 0 ? lf : Math.min(lf, cr);
    const contentEnd = newline < 0 || newline >= end ? end : newline;
    const lineEnd = contentEnd === end ? end : Math.min(end, contentEnd + (source[contentEnd] === '\r' && source[contentEnd + 1] === '\n' ? 2 : 1));
    lines.push({ start: cursor, contentEnd, end: lineEnd }); cursor = lineEnd;
  }
  return lines;
}

/** Preserve source line endings/spacing, excluding fences and Markdown container indentation. */
export function codeCopyRanges(source: string, node: MarkdownNode): CopyRange[] | null {
  const start = node.position?.start.offset, end = node.position?.end.offset;
  if (node.type !== 'code' || typeof node.value !== 'string' || start === undefined || end === undefined) return null;
  const lines = sourceLines(source, start, end), first = lines[0];
  if (!first) return null;
  const fenced = /^[ \t]{0,3}(`{3,}|~{3,})/.test(source.slice(first.start, first.contentEnd));
  const bodyLines = fenced ? lines.slice(1) : lines;
  const values = node.value.split(/\r\n|\n|\r/);
  if (!node.value && (!bodyLines[0] || /^[ \t>]*(?:`{3,}|~{3,})[ \t]*$/.test(source.slice(bodyLines[0].start, bodyLines[0].contentEnd)))) return null;
  if (bodyLines.length < values.length) return null;
  const ranges: CopyRange[] = [];
  for (let index = 0; index < values.length; index++) {
    const line = bodyLines[index]!, value = values[index]!;
    const content = source.slice(line.start, line.contentEnd);
    // mdast removes the block/list indentation. Matching the exact suffix
    // avoids copying a fence, quote marker, or the parser's synthetic newline.
    if (!content.endsWith(value)) return null;
    addRange(ranges, line.contentEnd - value.length, line.end);
  }
  return selectedMarkdown({ source, ranges }) === null ? null : ranges;
}

function headingText(node: MarkdownNode): string {
  if (typeof node.value === 'string') return node.value;
  return node.children?.map(headingText).join('') ?? '';
}

/** Uses parsed top-level headings; fenced, quoted, and list headings are not boundaries. */
export function addMarkdownCopyTargets(tree: MarkdownNode, source: string, targets: Map<string, MarkdownCopyTarget>): void {
  targets.clear();
  if (new TextEncoder().encode(source).length > MAX_COPY_BYTES) return;
  const children = tree.children ?? [], headings = children.filter(node => node.type === 'heading' && node.position?.start.offset !== undefined);
  let nextKey = 0;
  const add = (node: MarkdownNode, ranges: CopyRange[], label: string): void => {
    if (!selectedMarkdown({ source, ranges })) return;
    const key = String(nextKey++);
    targets.set(key, { source, ranges, label });
    node.data = { ...node.data, hProperties: { ...node.data?.hProperties, 'data-copy-key': key } };
  };
  for (let index = 0; index < headings.length; index++) {
    const heading = headings[index]!, start = heading.position!.start.offset!;
    const next = headings.slice(index + 1).find(node => node.depth! <= heading.depth!);
    const end = next?.position?.start.offset ?? source.length;
    add(heading, [{ start, end }], `Copy ${headingText(heading).trim().slice(0, 100) || 'section'} as Markdown`);
  }
  const introductionEnd = headings[0]?.position?.start.offset ?? source.length;
  if (source.slice(0, introductionEnd).trim()) {
    const control: MarkdownNode = { type: 'copyControl', data: { hName: 'span' } };
    add(control, [{ start: 0, end: introductionEnd }], headings.length ? 'Copy introduction as Markdown' : 'Copy as Markdown');
    tree.children = [control, ...children];
  }
  const walk = (node: MarkdownNode): void => {
    if (node.type === 'code') {
      const ranges = codeCopyRanges(source, node);
      if (ranges) add(node, ranges, 'Copy code');
    }
    node.children?.forEach(walk);
  };
  children.forEach(walk);
}
