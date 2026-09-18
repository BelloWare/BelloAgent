// Offsets are UTF-16 code units for Cocoa interop. Reject offsets inside a
// surrogate pair and shorten the end so adjacent pages never invent U+FFFD.
export function textPage(text: string, offset: number, limit = 16384): { text: string; next: number | null; totalCharacters: number } {
  if (!Number.isSafeInteger(offset) || offset < 0 || (offset > 0 && offset < text.length && isLow(text.charCodeAt(offset)) && isHigh(text.charCodeAt(offset-1)))) throw new Error('Offset must be at a Unicode codepoint boundary');
  let end=Math.min(text.length,offset+limit);
  if(end<text.length && end>offset && isHigh(text.charCodeAt(end-1)) && isLow(text.charCodeAt(end))) end--;
  return {text:text.slice(offset,end),next:end<text.length?end:null,totalCharacters:text.length};
}
const isHigh=(code:number)=>code>=0xd800 && code<=0xdbff;
const isLow=(code:number)=>code>=0xdc00 && code<=0xdfff;
