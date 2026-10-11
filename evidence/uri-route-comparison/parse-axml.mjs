import fs from 'node:fs';
import crypto from 'node:crypto';
const [input, output] = process.argv.slice(2);
const b = fs.readFileSync(input);
const u16 = p => b.readUInt16LE(p);
const u32 = p => b.readUInt32LE(p);
if (u16(0) !== 3 || u32(4) !== b.length) throw new Error('Invalid XML chunk');
let strings = [], elements = [], resourceIds = [];
const str = i => i === 0xffffffff ? null : strings[i];
function len8(p) { const n = b[p]; return n & 0x80 ? [(n & 0x7f) * 256 + b[p + 1], 2] : [n, 1]; }
function len16(p) { const n = u16(p); return n & 0x8000 ? [(n & 0x7fff) * 65536 + u16(p + 2), 4] : [n, 2]; }
for (let p = u16(2); p < b.length;) {
  const type = u16(p), header = u16(p + 2), size = u32(p + 4);
  if (size < header || p + size > b.length) throw new Error(`Bad chunk ${p}`);
  if (type === 1) {
    const count = u32(p + 8), utf8 = !!(u32(p + 16) & 256), base = p + u32(p + 20);
    strings = Array.from({length:count}, (_, i) => {
      let q = base + u32(p + header + i * 4);
      if (utf8) { const [a, n] = len8(q); q += n; const [length, m] = len8(q); q += m; return b.toString('utf8', q, q + length); }
      const [length, n] = len16(q); q += n; return b.toString('utf16le', q, q + length * 2);
    });
  } else if (type === 0x180) {
    for (let q = p + header; q < p + size; q += 4) resourceIds.push(u32(q));
  } else if (type === 0x102) {
    const attrs = [], start = p + 16 + u16(p + 24), attrSize = u16(p + 26), count = u16(p + 28);
    for (let i=0; i<count; i++) {
      const q = start + i * attrSize, nameIndex=u32(q+4), rawIndex=u32(q+8), valueType=b[q+15], data=u32(q+16);
      let value = rawIndex !== 0xffffffff ? str(rawIndex) : valueType === 3 ? str(data) : valueType === 0x12 ? !!data : valueType === 0x10 ? data : `0x${data.toString(16)}`;
      attrs.push({namespace:str(u32(q)),name:str(nameIndex),value,raw:str(rawIndex),type:valueType,data,resourceId:resourceIds[nameIndex] ? `0x${resourceIds[nameIndex].toString(16)}` : null});
    }
    elements.push({name:str(u32(p+20)),line:u32(p+8),offset:p,attributes:attrs});
  }
  p += size;
}
const report={input,sha256:crypto.createHash('sha256').update(b).digest('hex'),bytes:b.length,elements};
fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(elements.filter(e=>['manifest','uses-sdk','application','uses-permission'].includes(e.name)),null,2));
