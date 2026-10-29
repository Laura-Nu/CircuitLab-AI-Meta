const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
function fixture(reply, requestError) {
  const writes = [], events = {};
  let input;
  const port = {
    readable: new ReadableStream({start(controller) {input=controller;}}),
    writable: new WritableStream({write(bytes) {
      const command=JSON.parse(new TextDecoder().decode(bytes)); writes.push(command);
      return reply?.(command,input);
    }}),
    async open(options) {assert.equal(options.baudRate,115200);},
    async close() {}
  };
  const sandbox = {
    isSecureContext:true, navigator:{serial:{async requestPort() {if(requestError)throw requestError;return port;}}},
    document:{hidden:false,addEventListener(name,fn){events[name]=fn;}},
    addEventListener(name,fn){events[name]=fn;}, TextDecoder,TextEncoder,queueMicrotask,
    setTimeout(fn,ms){return setTimeout(fn,ms===2000?0:Math.min(ms,30));},clearTimeout,
  };
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname,'../web/usb_serial.js'),'utf8'),sandbox);
  return {api:sandbox.circuitLabUsb,writes,sandbox,events,port};
}
const command={protocol_version:'1',command_id:'SYNTHETIC-protocol-fixture',device_id:'fixture',session_id:'fixture',
  action:'read_voltage',point_id:'TP1',sample_count:20,deadline_ms:1000};
const good=(c)=>({command_id:c.command_id,point_id:c.point_id,status:'ok',sample_count:20,value:2.5});
const send=(input,value)=>input.enqueue(new TextEncoder().encode(JSON.stringify(value)+'\n'));
test('Actual framing handles partial lines and never reacquires a duplicate command',async()=>{
  const f=fixture((c,input)=>{
    const text=JSON.stringify(good(c))+'\n';
    input.enqueue(new TextEncoder().encode('unrelated boot text\n'+text.slice(0,15)));
    input.enqueue(new TextEncoder().encode(text.slice(15)));
  });
  assert.equal(JSON.parse(await f.api.connect()).status,'connected');
  const first=JSON.parse(await f.api.read(JSON.stringify(command),'["TP1"]'));
  assert.deepEqual(first,{status:'ok',sample_count:20,value:2.5});
  assert.deepEqual(JSON.parse(await f.api.read(JSON.stringify(command),'["TP1"]')),first);
  assert.equal(f.writes.length,1); await f.api.disconnect();
});
for(const changes of [{action:'upload_firmware'},{point_id:'TP8'},{sample_count:200},{protocol_version:'2'}]){
  test('Unauthorized instrument command is never written: '+JSON.stringify(changes),async()=>{
    const f=fixture();await f.api.connect();
    assert.equal(JSON.parse(await f.api.read(JSON.stringify({...command,...changes}),'["TP1"]')).status,'precondition_failed');
    assert.equal(f.writes.length,0);await f.api.disconnect();
  });
}
for(const changes of [{value:6},{value:'2.5'},{sample_count:19},{point_id:'TP2'}]){
  test('Incompatible USB response has no numeric reading: '+JSON.stringify(changes),async()=>{
    const f=fixture((c,input)=>send(input,{...good(c),...changes}));await f.api.connect();
    const result=JSON.parse(await f.api.read(JSON.stringify(command),'["TP1"]'));
    assert.notEqual(result.status,'ok');assert.equal(result.value,undefined);await f.api.disconnect();
  });
}
test('A silent instrument times out and does not become zero',async()=>{
  const f=fixture();await f.api.connect();
  const result=JSON.parse(await f.api.read(JSON.stringify(command),'["TP1"]'));
  assert.equal(result.status,'timeout');assert.equal(result.value,undefined);await f.api.disconnect();
});
test('A blocked USB write is bounded by the command deadline',async()=>{
  const f=fixture(()=>new Promise(()=>{}));await f.api.connect();
  const result=JSON.parse(await f.api.read(JSON.stringify(command),'["TP1"]'));
  assert.equal(result.status,'timeout');await f.api.disconnect();
});
test('Unplugging during a read returns disconnected',async()=>{
  const f=fixture();await f.api.connect();
  const pending=f.api.read(JSON.stringify(command),'["TP1"]');
  await f.api.disconnect();
  assert.equal(JSON.parse(await pending).status,'disconnected');
});
test('Permission cancellation and unsupported browsers never connect',async()=>{
  const cancelled=fixture(null,{name:'NotFoundError'});
  assert.equal(JSON.parse(await cancelled.api.connect()).status,'cancelled');
  const unsupported=fixture();unsupported.sandbox.navigator.serial=undefined;
  assert.equal(unsupported.api.supported,false);
  assert.equal(JSON.parse(await unsupported.api.connect()).status,'unsupported');
});
test('A hidden tab releases its USB port',async()=>{
  const f=fixture();await f.api.connect();let disconnected=false;
  f.api.onDisconnect=()=>disconnected=true;
  f.sandbox.document.hidden=true;f.events.visibilitychange();
  await new Promise(resolve=>setTimeout(resolve,10));
  assert.equal(disconnected,true);
  assert.equal(JSON.parse(await f.api.read(JSON.stringify(command),'["TP1"]')).status,'disconnected');
});

test('An opening port that never resolves produces an explicit timeout', {timeout:300}, async()=>{
  const f=fixture(); f.port.open=()=>new Promise(()=>{});
  assert.equal(JSON.parse(await f.api.connect()).status,'open_timeout');
});
test('A recoverable read error during board startup does not drop the connection', async()=>{
  const f=fixture((c,input)=>send(input,good(c)));
  const healthy=f.port.readable;
  const initial=new ReadableStream({start(input){input.error(new DOMException('Synthetic framing fault','FramingError'));}});
  let current=initial;
  const takeReader=initial.getReader.bind(initial);
  initial.getReader=()=>{const input=takeReader();queueMicrotask(()=>current=healthy);return input;};
  Object.defineProperty(f.port,'readable',{get:()=>current});
  assert.equal(JSON.parse(await f.api.connect()).status,'connected');
  assert.equal(JSON.parse(await f.api.read(JSON.stringify(command),'["TP1"]')).status,'ok');
  await f.api.disconnect();
});
test('Connection reports chooser, opening and instrument-startup stages',async()=>{
  const f=fixture(), stages=[];
  f.api.onState=state=>stages.push(state);
  await f.api.connect();
  assert.deepEqual(stages.slice(0,3),['choosing_port','opening_port','starting_instrument']);
  await f.api.disconnect();
});

test('A driver which opens after timeout is closed and cannot connect silently',async()=>{
  const f=fixture(); let finish, closes=0, calls=0;
  f.port.open=()=>++calls===1?new Promise(resolve=>finish=resolve):Promise.resolve();
  f.port.close=async()=>{closes++;};
  assert.equal(JSON.parse(await f.api.connect()).status,'open_timeout');
  assert.equal(JSON.parse(await f.api.connect()).status,'busy');
  finish();await new Promise(resolve=>setTimeout(resolve,5));
  assert.equal(closes,1);
  assert.equal(JSON.parse(await f.api.connect()).status,'connected');
  await f.api.disconnect();
});
test('Cancellation during driver opening closes a late-opened port',async()=>{
  const f=fixture();let finish, closes=0;
  f.port.open=()=>new Promise(resolve=>finish=resolve);
  f.port.close=async()=>{closes++;};
  const attempt=f.api.connect();
  await new Promise(resolve=>setTimeout(resolve,0));
  await f.api.disconnect();finish();
  assert.equal(JSON.parse(await attempt).status,'cancelled');
  await new Promise(resolve=>setTimeout(resolve,5));
  assert.equal(closes,1);
});
test('A synchronous open error does not leave a permanently busy state',async()=>{
  const f=fixture();let calls=0;
  f.port.open=()=>{if(++calls===1)throw {name:'NetworkError'};return Promise.resolve();};
  assert.equal(JSON.parse(await f.api.connect()).status,'port_unavailable');
  assert.equal(JSON.parse(await f.api.connect()).status,'connected');
  await f.api.disconnect();
});

for (const value of [true, false]) {
  test('Digital USB preserves native boolean '+value, async()=>{
    const f=fixture((c,input)=>send(input,{...good(c),value,unit:'boolean'}));
    await f.api.connect();
    const result=JSON.parse(await f.api.read(JSON.stringify({...command,action:'read_digital'}),'["TP1"]'));
    assert.equal(result.status,'ok');assert.equal(result.value,value);
    await f.api.disconnect();
  });
}
for (const changes of [{value:0,unit:'boolean'},{value:1,unit:'boolean'},
                       {value:'false',unit:'boolean'},{value:false,unit:'V'},{value:false}]) {
  test('Digital USB rejects ambiguous type/unit '+JSON.stringify(changes),async()=>{
    const f=fixture((c,input)=>send(input,{...good(c),...changes}));
    await f.api.connect();
    const result=JSON.parse(await f.api.read(JSON.stringify({...command,action:'read_digital'}),'["TP1"]'));
    assert.notEqual(result.status,'ok');assert.equal(result.value,undefined);
    await f.api.disconnect();
  });
}
test('A boolean is never accepted as a voltage',async()=>{
  const f=fixture((c,input)=>send(input,{...good(c),value:false}));
  await f.api.connect();
  const result=JSON.parse(await f.api.read(JSON.stringify(command),'["TP1"]'));
  assert.notEqual(result.status,'ok');await f.api.disconnect();
});
