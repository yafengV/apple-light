import { diffWordsWithSpace } from 'diff';

const trimEnding = text => text.endsWith('\n')
  ? text.slice(0, text.endsWith('\r\n') ? -2 : -1) : text;

// Word-alt joins an internal single neutral code unit to the preceding change.
// The final neutral piece always stays separate. Offsets use UTF-16, as do
// Shiki decorations and the native text system.
export function wordRanges(oldSource, newSource) {
  const old = trimEnding(oldSource), next = trimEnding(newSource);
  if (old.length > 1000 || next.length > 1000) return { left: [], right: [] };
  const parts = diffWordsWithSpace(old, next), left = [], right = [];
  function push(arr, part, changed, last) {
    const previous = arr.at(-1);
    if (previous && !last && (previous.changed === changed || !changed && part.value.length === 1 && previous.changed)) {
      previous.text += part.value;
    } else arr.push({ text: part.value, changed });
  }
  for (const [index, part] of parts.entries()) {
    const last = index === parts.length - 1;
    if (!part.added) push(left, part, !!part.removed, last);
    if (!part.removed) push(right, part, !!part.added, last);
  }
  function ranges(parts) {
    let offset = 0;
    return parts.flatMap(part => {
      const range = { location: offset, length: part.text.length };
      offset += range.length;
      return part.changed && range.length ? [range] : [];
    });
  }
  return { left: ranges(left), right: ranges(right) };
}

export function diffWordRanges(lines) {
  const result = new Map();
  // Whole-file new/removed content has no pairs. Large changes use plain lines,
  // matching CodeDiff's 2,000 changed-line cutoff.
  if (lines.filter(line => line.left !== line.right).length > 2000) return result;
  let left = [], right = [], hunk;
  function flush() {
    for (let index = 0; index < Math.min(left.length, right.length); index++) {
      const a = left[index], b = right[index];
      const ending = line => line.text + (line.hasNewline === false ? '' : '\n');
      const ranges = wordRanges(ending(a), ending(b));
      result.set(a.id, ranges.left); result.set(b.id, ranges.right);
    }
    left = []; right = [];
  }
  for (const line of lines) {
    if (hunk !== line.hunk || line.left && line.right) flush();
    hunk = line.hunk;
    if (line.left && !line.right) left.push(line);
    if (line.right && !line.left) right.push(line);
  }
  flush();
  return result;
}
