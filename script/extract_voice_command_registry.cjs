// Evaluate only three inert command descriptor literals from the shipped bundle.
// No application, DOM, native bridge, user state or network is accessed.
const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [sourcePath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, 'utf8');
const sha = crypto.createHash('sha256').update(source).digest('hex');
if (sha !== '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3')
  throw Error('Unverified current command registry');
const commands = ['globalDictationHold', 'globalDictationSingleTap', 'realtimeVoice'].map(id => {
  const matches = [...source.matchAll(new RegExp('\\{id:`' + id + '`[^{}]*\\}', 'g'))];
  const descriptor = matches.find(match => match[0].includes('shortcutScope:'));
  if (!descriptor) throw Error('Missing descriptor: ' + id);
  const value = vm.runInNewContext('(' + descriptor[0] + ')', Object.create(null));
  if (value.shortcutScope !== 'os-global' || value.allowsBareModifiers !== true)
    throw Error('Unexpected scope or capture capability: ' + id);
  return value;
});
fs.writeFileSync(outputPath, JSON.stringify({
  reference: {version: '26.930.51102', build: 13100, sourceSHA256: sha},
  boundaries: 'Three actual registry descriptor literals, evaluated in an empty VM; no general settings DOM or OS behavior is inferred',
  commands
}, null, 2) + '\n');
console.log('Extracted three global voice commands with bare-modifier capture capability');
