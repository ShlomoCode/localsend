// Cloud-only OCR qualification. It emits real screenshot coordinates, not fixed
// positions. Raw pixels/TSV and this admission record require independent review.
const fs = require('node:fs');
const [mode, boundsPath, ...args] = process.argv.slice(2);
const bounds = JSON.parse(fs.readFileSync(boundsPath, 'utf8'));
if (!Array.isArray(bounds) || bounds.length !== 4 || !bounds.every(Number.isInteger)) {
  throw new Error('Capture bounds are not four integers');
}
const [x, y, width, height] = bounds;
if (x < 0 || y < 0 || width < 200 || height < 200 || x + width > 1280 || y + height > 800) {
  throw new Error('Capture bounds do not fit the admitted 1280x800 screenshot');
}
if (mode === 'crop') {
  process.stdout.write(`${width}x${height}+${x}+${y}\n`);
} else if (mode === 'row' || mode === 'target' || mode === 'file') {
  const [tsvPath, namesPath, receiptPath] = args;
  const names = mode === 'file' ? new Set(['3417-control.txt']) : new Set(JSON.parse(fs.readFileSync(namesPath, 'utf8')));
  const lines = new Map();
  for (const raw of fs.readFileSync(tsvPath, 'utf8').split('\n').slice(1)) {
    const fields = raw.replace(/\r$/, '').split('\t');
    if (fields.length !== 12 || fields[0] !== '5' || !fields[11].trim()) continue;
    const [left, top, wordWidth, wordHeight, confidence] = fields.slice(6, 11).map(Number);
    if (![left, top, wordWidth, wordHeight, confidence].every(Number.isFinite)) throw new Error('Invalid OCR word');
    const key = fields.slice(1, 5).join(':');
    const words = lines.get(key) || [];
    words.push({ text: fields[11].trim(), left, top, width: wordWidth, height: wordHeight, confidence });
    lines.set(key, words);
  }
  const matches = [];
  for (const words of lines.values()) {
    words.sort((a, b) => a.left - b.left);
    const text = words.map(word => word.text).join(' ');
    if (text.length < 4 || !names.has(text) || words.some(word => word.confidence < 70)) continue;
    const left = Math.min(...words.map(word => word.left));
    const top = Math.min(...words.map(word => word.top));
    const right = Math.max(...words.map(word => word.left + word.width));
    const bottom = Math.max(...words.map(word => word.top + word.height));
    // Exclude header/action bars. The observed app label must lie in the body.
    if (left < 8 || top < 55 || right > width - 8 || bottom > height - 55) continue;
    matches.push({ text, words, bounds: [left, top, right - left, bottom - top],
      point: [x + Math.floor((left + right) / 2), y + Math.floor((top + bottom) / 2)] });
  }
  if (mode === 'file') {
    const visibleWords = [...lines.values()].flat().filter(word => word.confidence >= 70).map(word => word.text);
    if (!visibleWords.includes('Files') || !visibleWords.includes('Documents')) {
      throw new Error('Files/Documents is not rendered in the file-selection screenshot');
    }
  }
  const targetName = mode === 'file' ? '3417-control.txt' : 'LocalSend';
  const targets = matches.filter(match => match.text === targetName);
  const counts = new Map();
  for (const match of matches) counts.set(match.text, (counts.get(match.text) || 0) + 1);
  const unique = matches.filter(match => counts.get(match.text) === 1).sort((a, b) => a.point[1] - b.point[1]);
  const chosen = targets.length === 1 ? targets[0] : mode === 'row' && targets.length === 0 ? unique[0] : undefined;
  fs.writeFileSync(receiptPath, JSON.stringify({ mode, [mode === 'file' ? 'screenBounds' : 'dialogBounds']: bounds, matches, chosen: chosen || null }, null, 2));
  if (!chosen) throw new Error('No unique qualified rendered target');
  process.stdout.write(`${chosen.point[0]} ${chosen.point[1]} ${chosen.text === targetName ? 'target' : 'focus'}\n`);
} else {
  throw new Error('Unknown visual qualification mode');
}
