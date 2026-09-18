import test from 'node:test';
import assert from 'node:assert/strict';
import { FrameDecoder, encodeFrame, MAX_FRAME_BYTES } from '../../protocol/src/framing.ts';
import { fragment } from '../../../fixtures/providers/server.ts';

test('NDJSON handles split UTF-8 and multiple frames without using characters as the byte limit', () => {
  const decoder = new FrameDecoder(); const received: unknown[] = [];
  const values = [{ text: '🌍\n漢字', v: 1 }, { text: 'next' }];
  for (const bytes of fragment(Buffer.concat(values.map(encodeFrame)))) decoder.feed(bytes, value => received.push(value));
  decoder.end(); assert.deepEqual(received, values);
});
test('NDJSON rejects oversize input before decoding, invalid UTF-8, empty and truncated frames', () => {
  assert.throws(() => new FrameDecoder().feed(Buffer.alloc(MAX_FRAME_BYTES + 1, 32), () => {}), /exceeds/);
  assert.throws(() => new FrameDecoder().feed(Buffer.from([34, 255, 34, 10]), () => {}));
  assert.throws(() => new FrameDecoder().feed(Buffer.from('\n'), () => {}), /Empty/);
  const decoder = new FrameDecoder(); decoder.feed(Buffer.from('{'), () => {}); assert.throws(() => decoder.end(), /Truncated/);
  assert.throws(() => encodeFrame({ text: '🌍'.repeat(MAX_FRAME_BYTES / 4) }), /exceeds/);
});
