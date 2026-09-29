import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import vm from 'node:vm';
import { highlight } from './engine.mjs';
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
