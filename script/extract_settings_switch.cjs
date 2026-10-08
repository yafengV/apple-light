const fs = require('fs'), vm = require('vm'), crypto = require('crypto');
const [sourcePath, cssPath, outputPath] = process.argv.slice(2);
const hashes = ['eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab','4ea4b25e3f4f3225a3bf212fa767afe7655b16bbd5919ebf4fb12c656f974720'];
const [source, css] = [sourcePath, cssPath].map((path, index) => {const value = fs.readFileSync(path,'utf8');if(crypto.createHash('sha256').update(value).digest('hex')!==hashes[index])throw Error('Unverified reference');return value;});
const cache = {c: n => Array(n).fill(Symbol.for('react.memo_cache_sentinel'))};
const jsx = (type, props) => typeof type === 'function' ? type(props) : {type, props};
const context = {t: fn => fn,c: () => cache,fh: () => {},K: () => ({jsx}),q: (...items) => items.flat(Infinity).filter(Boolean).join(' ')};
vm.createContext(context);
for(const name of ['gyi','_yi','xyi']) {const a=source.indexOf('function '+name+'('),b=source.indexOf('function ',a+10);if(a<0||b<0)throw Error('Missing '+name);vm.runInContext(source.slice(a,b),context);}
context.xyi();
const cases=[];
for(const checked of [false,true])for(const disabled of [false,true])for(const size of ['default','sm'])for(const tone of ['accent','neutral']){
 let changes=[],event={defaultPrevented:false,preventDefault(){this.defaultPrevented=true;}};
 const tree=context.gyi({checked,disabled,size,tone,ariaLabel:'Switch',onChange:value=>changes.push(value)});
 tree.props.onClick(event);
 let preventedChanges=[];
 const prevented=context.gyi({checked,disabled,size,tone,onChange:value=>preventedChanges.push(value),onClick:event=>event.preventDefault()});
 prevented.props.onClick({defaultPrevented:false,preventDefault(){this.defaultPrevented=true;}});
 if(changes.length!==(disabled?0:1)||changes.some(value=>value!==!checked)||preventedChanges.length)throw Error('Unexpected switch callbacks');
 cases.push({checked,disabled,size,tone,changes,preventedChanges,tree});
}
const duration=css.match(/--transition-duration-basic:([\d.]+)s;/)?.[1];if(!duration)throw Error('Missing transition duration');
fs.writeFileSync(outputPath,JSON.stringify({version:'26.930.51102',build:13100,sourceSHA256:hashes,
 boundaries:'Actual gyi/_yi/xyi with controlled React memo cache and click events; browser keyboard defaults/focus heuristics are not executed',duration:Number(duration),cases},null,2)+'\n');
console.log('Extracted 16 actual switch variants and guarded click callbacks');
