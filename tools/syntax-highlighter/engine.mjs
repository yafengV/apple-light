import { createHighlighterCore } from 'shiki/core';
import { createJavaScriptRegexEngine } from 'shiki/engine/javascript';
import { bundledLanguages } from 'shiki/langs';
import { getFiletypeFromFileName } from './node_modules/@pierre/diffs/dist/utils/getFiletypeFromFileName.js';
import catalog from './theme-catalog.json' with { type: 'json' };
import { themes } from './theme-registry.mjs';
import { tokenizeSource } from './tokenize.mjs';
import { diffWordRanges } from './word-diff.mjs';

let engine;
const languages = new Map();
const loadedThemes = new Map();
function theme(id, variant) {
  return catalog.presets.find(p => p.id === id)?.variants[variant]?.themeName ?? `shipios-codex-${variant}`;
}
async function highlighter(language, selection) {
  engine ??= createHighlighterCore({ themes: [], langs: [],
    engine: createJavaScriptRegexEngine() });
  const value = await engine;
  for (const name of Object.values(selection)) {
    if (!loadedThemes.has(name)) {
      const pending = value.loadTheme(themes[name]);
      loadedThemes.set(name, pending); pending.catch(() => loadedThemes.delete(name));
    }
    await loadedThemes.get(name);
  }
  if (language !== 'text' && !languages.has(language)) {
    const pending = value.loadLanguage(bundledLanguages[language]);
    languages.set(language, pending);
    pending.catch(() => languages.delete(language));
  }
  if (language !== 'text') await languages.get(language);
  return value;
}

function style(value) {
  return { color: value?.color || null, fontStyle: value?.fontStyle ?? 0 };
}
function plain(content) { return { content, light: style(), dark: style() }; }

export async function highlight(input) {
  const guessed = getFiletypeFromFileName(input.path.replaceAll('\\', '/'));
  const language = guessed && bundledLanguages[guessed] ? guessed : 'text';
  const selection = { light: theme(input.themes?.light, 'light'), dark: theme(input.themes?.dark, 'dark') };
  const value = await highlighter(language, selection);
  const result = { language, left: [], right: [], recoveredTokenizations: 0 };
  const changes = input.wordDiffs === true ? diffWordRanges(input.lines) : new Map();
  for (const side of ['left', 'right']) {
    const groups = new Map();
    for (const line of input.lines.filter(line => line[side])) {
      const key = line.hunk ?? 0;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(line);
    }
    for (const rows of groups.values()) {
      // Partial diffs reset their grammar state at each hunk, as in the reference
      // worker. Within each side, preserve multi-line state and exclude metadata.
      const source = rows.map(row => row.text).join('\n');
      const highlighted = language !== 'text'
        ? tokenizeSource(value, language, source, selection)
        : { tokens: [], recovered: false };
      const tokens = highlighted.tokens;
      if (highlighted.recovered) result.recoveredTokenizations += 1;
      let start = 0, index = 0;
      for (const row of rows) {
        const end = start + row.text.length, spans = [];
        let cursor = start;
        while (index < tokens.length && tokens[index].offset < end) {
          const token = tokens[index++];
          if (token.offset < start) continue;
          if (token.offset > cursor) spans.push(plain(source.slice(cursor, token.offset)));
          spans.push({ content: token.content, light: style(token.variants.light), dark: style(token.variants.dark) });
          cursor = token.offset + token.content.length;
        }
        // Shiki excludes line endings. Preserve CR and every source character;
        // the transport and Swift rendering never normalize or rewrite the code.
        if (cursor < end) spans.push(plain(source.slice(cursor, end)));
        result[side].push({ id: row.id, tokens: spans, changes: changes.get(row.id) ?? [] });
        start = end + 1;
      }
    }
  }
  return result;
}

globalThis.shipiosSyntax = { highlight };
