import fs from 'node:fs';
const baseline=JSON.parse(fs.readFileSync('evidence-cloud/source-baseline/outcome.json'));
const focus=JSON.parse(fs.readFileSync('evidence-cloud/source-focus/outcome.json'));
const b=baseline.visualAssertions, f=focus.visualAssertions;
const gates={
  baselineMouse:baseline.mouseSelected===true,
  focusMouse:focus.mouseSelected===true,
  baselineShortFailure:b.shortSelectionCount===0 && b.shortFocusPixels<100,
  baselineFreshFailure:b.freshSelectionCount===0 && b.freshFocusPixels<100,
  focusShortSelection:f.shortSelectionCount===1,
  focusFreshSelection:f.freshSelectionCount===1,
  focusShortHighlight:f.shortFocusPixels>2000,
  focusFreshHighlight:f.freshFocusPixels>2000,
};
fs.writeFileSync('evidence-cloud/source-pair-verdict.json',JSON.stringify({baseline:b,focus:f,gates},null,2));
if(Object.values(gates).some(value=>!value)) throw new Error('Source causal pair did not satisfy every visible baseline/focus/mouse gate; inspect raw evidence');
