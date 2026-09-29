import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import vm from 'node:vm';
import { highlight } from './engine.mjs';
import { tokenizeSource } from './tokenize.mjs';
import { wordRanges, diffWordRanges } from './word-diff.mjs';
import { getFiletypeFromFileName } from './node_modules/@pierre/diffs/dist/utils/getFiletypeFromFileName.js';

const row = (id, text, left = true, right = true) => ({ id, text, left, right });
const input = (path, lines) => ({ path, lines });
function preserve(result, lines) {
  for (const side of ['left', 'right']) {
    assert.deepEqual(result[side].map(row => row.id), lines.filter(row => row[side]).map(row => row.id));
    assert.deepEqual(result[side].map(row => row.tokens.map(t => t.content).join('')), lines.filter(row => row[side]).map(row => row.text));
  }
}
test('Swift keywords, strings and numbers have independent theme variants', async () => {
  const lines = [row(8, 'let value = "你好 👩🏽‍💻"'), row(9, 'let count = 42')];
  const result = await highlight(input('Sources/Main.swift', lines)); preserve(result, lines);
  assert.equal(result.language, 'swift');
  const keyword = result.right[0].tokens.find(t => t.content === 'let');
  assert.equal(keyword.light.color, '#D53538'); assert.equal(keyword.dark.color, '#F67576');
  assert(result.right[0].tokens.some(t => t.light.color === '#008809'));
  assert(result.right[1].tokens.some(t => t.light.color === '#0071EA'));
});
test('left and right multi-line comment states remain independent', async () => {
  const lines = [row(1, '/* old open', true, false), row(2, 'let newCode = 42', false, true),
    row(3, 'still old comment'), row(4, '*/')];
  const result = await highlight(input('Example.swift', lines)); preserve(result, lines);
  assert(result.left.find(r => r.id === 3).tokens.every(t => t.light.color === '#666666'));
  assert(result.right.find(r => r.id === 2).tokens.some(t => t.light.color === '#D53538'));
});
test('empty lines, CRLF, internal CR, tabs and Unicode preserve exact source text', async () => {
  const lines = [row(1, ''), row(2, '\tlet emoji = "🧑‍🚀é"\r'), row(3, '// abc\rlet c = 1'), row(4, '')];
  preserve(await highlight(input('Example.swift', lines)), lines);
});
test('embedded and non-web grammars load offline', async () => {
  for (const [path, expected, text] of [['component.tsx', 'tsx', 'const C = () => <p>Hello</p>'],
    ['main.rs', 'rust', 'fn main() { println!("hello"); }'], ['main.py', 'python', 'def hello(): return 1'],
    ['main.go', 'go', 'package main'], ['project.pbxproj', 'text', 'plain'], ['Dockerfile', 'dockerfile', 'FROM ubuntu'],
    ['main.cpp', 'cpp', 'int main() { return 1; }'], ['main.yaml', 'yaml', 'key: true']]) {
    const lines = [row(1, text)], result = await highlight(input(path, lines));
    assert.equal(result.language, expected); preserve(result, lines);
  }
});
test('unknown extensions and long lines over the tokenization limit stay readable', async () => {
  for (const [path, text] of [['README.unknown', '<script>alert("text")</script>'], ['Long.swift', 'a'.repeat(100000)]]) {
    const lines = [row(1, text)], result = await highlight(input(path, lines)); preserve(result, lines);
    assert(result.right[0].tokens.every(t => t.light.color === null));
  }
});
test('separate partial hunks reset multi-line grammar state', async () => {
  const lines = [{ ...row(1, '/* open'), hunk: 1 }, { ...row(2, 'let value = 42'), hunk: 2 }];
  const result = await highlight(input('Example.swift', lines)); preserve(result, lines);
  assert(result.right[0].tokens.every(t => t.light.color === '#666666'));
  assert(result.right[1].tokens.some(t => t.light.color === '#D53538'));
});
test('built resource has matching integrity and works without Node or fetch', async () => {
  const root = '../../apps/macos/Sources/ShipiOS/Resources/SyntaxHighlighting/';
  const source = await readFile(root+'engine.js');
  const manifest = JSON.parse(await readFile(root+'manifest.json'));
  assert.equal(source.length, manifest.bytes); assert.equal(createHash('sha256').update(source).digest('hex'), manifest.sha256);
  const context = vm.createContext({ WebAssembly, TextEncoder, TextDecoder,
    atob: value => Buffer.from(value, 'base64').toString('binary') });
  vm.runInContext(source.toString(), context);
  const result = await context.shipiosSyntax.highlight(input('hello.swift', [row(1, 'let a = 1')]));
  assert.equal(result.language, 'swift'); assert(result.right[0].tokens.some(t => t.light.color === '#D53538'));
});
test('current Codex worker reference colors and font styles match all fixed examples', async () => {
  const fixture = JSON.parse(await readFile('../../apps/macos/Tests/ShipiOSTests/Fixtures/code_syntax_reference.json'));
  assert.equal(fixture.referenceVersion, '26.911.61220');
  for (const item of fixture.cases) {
    const lines = item.lines.map((text, id) => ({ ...row(id, text), hunk: 1 }));
    const result = await highlight(input(item.path, lines));
    assert.equal(result.language, item.language);
    assert.deepEqual(result.right.map(row => row.tokens), item.expected, item.path);
    assert.deepEqual(result.left.map(row => row.tokens), item.expected, item.path);
  }
});
test('filename recognition matches the current worker for every default extension and path form', async () => {
  const fixture = JSON.parse(await readFile('../../apps/macos/Tests/ShipiOSTests/Fixtures/code_syntax_reference.json'));
  for (const item of fixture.languageCases) assert.equal(getFiletypeFromFileName(item.path), item.expected, item.path);
  assert.equal(fixture.languageCases.length, 1380);
});

// Deliberately interrupt the underlying tokenizer to exercise cold-start
// recovery deterministically rather than depending on machine timing.
test('interrupted tokenization retries once and restores the original grammar method', () => {
  let calls = 0, limits = [];
  const grammar = { tokenizeLine2() { return { stoppedEarly: ++calls === 1 }; } };
  const original = grammar.tokenizeLine2;
  const value = { getLanguage: () => grammar, codeToTokensWithThemes(_source, options) {
    limits.push(options.tokenizeTimeLimit); grammar.tokenizeLine2(); return [[{ content: calls === 1 ? 'partial' : 'complete' }]];
  } };
  assert.deepEqual(tokenizeSource(value, 'swift', 'source', {}).tokens, [{ content: 'complete' }]);
  assert.equal(calls, 2); assert.deepEqual(limits, [500, 500]); assert.equal(grammar.tokenizeLine2, original);
});
test('persistent tokenization interruption fails after two attempts and restores the grammar', () => {
  let calls = 0;
  const grammar = { tokenizeLine2() { calls++; return { stoppedEarly: true }; } }, original = grammar.tokenizeLine2;
  const value = { getLanguage: () => grammar, codeToTokensWithThemes() { grammar.tokenizeLine2(); return [[]]; } };
  assert.throws(() => tokenizeSource(value, 'swift', 'source', {}), /per-line budget/);
  assert.equal(calls, 2); assert.equal(grammar.tokenizeLine2, original);
});

test('word-alt UTF-16 ranges match 2,062 cases computed by the current Codex worker', async () => {
  const fixture = JSON.parse(await readFile('../../apps/macos/Tests/ShipiOSTests/Fixtures/word_diff_reference.json'));
  assert.equal(fixture.cases.length, 2062);
  for (const [index, item] of fixture.cases.entries()) {
    assert.deepEqual(wordRanges(item.old, item.new), { left: item.left, right: item.right }, 'reference case ' + index);
  }
});
test('word comparison pairs ordinal changed rows only within the same hunk and context block', () => {
  const lines = [row(1, 'old', true, false), row(2, 'unpaired', true, false), row(3, 'new', false, true),
    row(4, 'context'), row(5, 'left alone', true, false),
    { ...row(6, 'new hunk alone', false, true), hunk: 2 }];
  const result = diffWordRanges(lines);
  assert.deepEqual([...result.keys()], [1, 3]);
  assert.deepEqual(result.get(1), [{ location: 0, length: 3 }]);
  assert.equal(diffWordRanges([row(1, 'whole new file', false, true)]).size, 0);
});
test('line limits count UTF-16; large changed files skip words at exactly the reference boundary', () => {
  assert.equal(wordRanges('x'.repeat(998)+' a', 'x'.repeat(998)+' b').left.length, 1);
  assert.equal(wordRanges('x'.repeat(999)+' a', 'x'.repeat(999)+' b').left.length, 0);
  assert.equal(wordRanges('🚀'.repeat(500)+'a', '🚀'.repeat(500)+'b').left.length, 0);
  const make = n => Array.from({ length: n }, (_, id) => ({ ...row(id, id % 2 ? 'new' : 'old', !(id % 2), !!(id % 2)), hunk: 1 }));
  assert.equal(diffWordRanges(make(2000)).size, 2000);
  assert.equal(diffWordRanges(make(2001)).size, 0);
});
test('actual highlighter returns word ranges alongside unchanged tokens and honors missing final newline', async () => {
  const lines = [row(1, 'old\r', true, false), { ...row(2, 'new\r', false, true), hasNewline: false }];
  const result = await highlight({ ...input('unknown.extension', lines), wordDiffs: true }); preserve(result, lines);
  assert.deepEqual(result.left[0].changes, [{ location: 0, length: 3 }]);
  assert.deepEqual(result.right[0].changes, [{ location: 0, length: 4 }]);
  const off = await highlight(input('unknown.extension', lines));
  assert.deepEqual(off.right[0].changes, []);
  assert.deepEqual(off.right[0].tokens, result.right[0].tokens);
});
