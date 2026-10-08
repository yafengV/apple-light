// Extract two literal command definitions from the verified public registry.
// No app initialization, bridge, user state, DOM or network is executed.
const fs = require('fs'), crypto = require('crypto'), vm = require('vm');
const [sourcePath, outputPath] = process.argv.slice(2);
const source = fs.readFileSync(sourcePath, 'utf8');
const sha256 = crypto.createHash('sha256').update(source).digest('hex');
if (sha256 !== '22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3') {
  throw Error('Unverified public registry asset');
}
const commands = [['mqr', 'openCommandMenu', 'palette'], ['vqr', 'newTask', 'new']].map(([scope, id, shipiosID]) => {
  const start = source.indexOf('{id:`' + id + '`', source.indexOf('function ' + scope + '('));
  const end = source.indexOf('},{id:', start) + 1;
  if (start < 0 || end <= start) throw Error('Missing literal command ' + id);
  const command = vm.runInNewContext('(' + source.slice(start, end) + ')', {}, {timeout: 1000});
  if (command.id !== id || command.electron.defaultKeybindings.length !== 2) throw Error('Unexpected command ' + id);
  return {id, shipiosID, defaults: command.electron.defaultKeybindings.map(value => value.key)};
});
fs.writeFileSync(outputPath, JSON.stringify({version: '26.930.51102', build: 13100, sourceSHA256: sha256,
  boundary: 'Literal current electron command definitions only; native execution and rendered acceptance remain separate', commands}, null, 2) + '\n');
console.log('Extracted two canonical commands with two default bindings each');
