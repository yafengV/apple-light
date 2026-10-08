// The desktop window overrides the @layer theme defaults later in the cascade.
// Do not resolve a CSS variable by taking its first occurrence in the bundle.
function desktopTypography(css) {
  const root = css.match(/@layer theme\{:root,:host\{([^{}]+)\}/)?.[1];
  if (!root) throw Error('Missing public theme root');
  const desktopRules = [...css.matchAll(/\[data-codex-window-type=electron\]\{([^{}]+)\}/g)]
    .filter(match => /--text-sm:/.test(match[1]));
  if (desktopRules.length !== 1) throw Error('Unexpected desktop typography cascade');
  const declarations = text => Object.fromEntries(text.split(';').map(item => {
    const split = item.indexOf(':'); return [item.slice(0, split), item.slice(split + 1)];
  }).filter(([key]) => key.startsWith('--')));
  const defaults = declarations(root), desktop = declarations(desktopRules[0][1]);
  const computed = {...defaults, ...desktop};
  const pixels = key => {
    if (!/^\d+(?:\.\d+)?px$/.test(computed[key])) throw Error('Unexpected ' + key);
    return Number.parseFloat(computed[key]);
  };
  const ratio = computed['--text-sm--line-height'].match(/^calc\(([\d.]+) \/ ([\d.]+)\)$/);
  if (!ratio) throw Error('Unexpected public small text line height');
  const labelSize = pixels('--text-sm'), descriptionSize = pixels('--text-xs');
  const selected = ['--spacing', '--text-sm', '--text-xs', '--text-sm--line-height', '--text-xs--line-height'];
  return {labelSize, descriptionSize, labelLineHeight: labelSize * Number(ratio[1]) / Number(ratio[2]),
    defaults: Object.fromEntries(selected.map(key => [key, defaults[key]])), desktop,
    rootCSS: ':root{' + selected.map(key => key + ':' + defaults[key]).join(';') + '}',
    desktopCSS: desktopRules[0][0]};
}
module.exports = {desktopTypography};
