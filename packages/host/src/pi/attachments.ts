import { createHash } from 'node:crypto';
import { open, realpath } from 'node:fs/promises';
import type { ImageContent } from '@earendil-works/pi-ai';
import { CommandError } from '../sessions/command-ledger.ts';
export interface Attachment { id: string; path: string; sha256: string; bytes: number; mimeType: string }
export function attachmentsFrom(value: unknown): Attachment[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > 4) throw new CommandError('attachment_limit', 'At most four images per submission');
  let total = 0;
  for (const item of value) {
    if (!item || typeof item !== 'object' || typeof item.id !== 'string' || !/^[a-zA-Z0-9-]{1,128}$/.test(item.id) || typeof item.path !== 'string' || item.path.length > 4096 || !/^[a-f0-9]{64}$/.test(item.sha256) || !Number.isSafeInteger(item.bytes) || item.bytes <= 0 || item.bytes > 8 * 1024 * 1024 || !['image/png','image/jpeg','image/gif','image/webp'].includes(item.mimeType)) throw new CommandError('invalid_attachment', 'Invalid image reference or 8 MiB image limit exceeded');
    total += item.bytes;
  }
  if (total > 16 * 1024 * 1024) throw new CommandError('attachment_limit', 'Image references exceed the 16 MiB submission limit');
  return structuredClone(value) as Attachment[];
}
export async function readAttachments(items: Attachment[]): Promise<ImageContent[]> {
  const images: ImageContent[] = [];
  for (const item of items) {
    const path = await realpath(item.path), file = await open(path, 'r');
    try {
      const before = await file.stat({bigint:true});
      if (!before.isFile() || before.size !== BigInt(item.bytes)) throw new CommandError('attachment_changed', 'The selected image changed; remove and select it again');
      const bytes = Buffer.alloc(item.bytes); let offset = 0;
      while (offset < bytes.length) { const read = await file.read(bytes, offset, Math.min(65536, bytes.length-offset), offset); if (!read.bytesRead) break; offset += read.bytesRead; }
      const after = await file.stat({bigint:true});
      if (offset !== item.bytes || after.size !== before.size) throw new CommandError('attachment_changed', 'The image size changed during reading');
      if (before.mtimeNs !== after.mtimeNs || before.ctimeNs !== after.ctimeNs || createHash('sha256').update(bytes).digest('hex') !== item.sha256 || path !== await realpath(item.path)) throw new CommandError('attachment_changed', 'The selected image changed before execution; select it again');
      const mime = bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])) ? 'image/png' : bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255 ? 'image/jpeg' : /^GIF8[79]a/.test(bytes.subarray(0,6).toString('ascii')) ? 'image/gif' : bytes.subarray(0,4).toString() === 'RIFF' && bytes.subarray(8,12).toString() === 'WEBP' ? 'image/webp' : null;
      if (mime !== item.mimeType) throw new CommandError('invalid_attachment', 'The selected file signature does not match a supported image');
      images.push({ type: 'image', mimeType: mime, data: bytes.toString('base64') });
    } finally { await file.close(); }
  }
  return images;
}
