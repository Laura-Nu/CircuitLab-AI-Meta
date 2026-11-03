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
  return {api:sandbox.circuitLabUsb,writes,sandbox,events,port,
    sendText(text) {input.enqueue(new TextEncoder().encode(text));}};
}
const command={protocol_version:'1',command_id:'SYNTHETIC-protocol-fixture',device_id:'fixture',session_id:'fixture',
  action:'read_voltage',point_id:'TP1',sample_count:20,deadline_ms:1000};
const good=(c)=>({command_id:c.command_id,point_id:c.point_id,status:'ok',sample_count:20,value:2.5});
const send=(input,value)=>input.enqueue(new TextEncoder().encode(JSON.stringify(value)+'\n'));

test('Board monitor reads actual multi-sensor serial output without writing commands',async()=>{
  const f=fixture(); let speed;
  f.port.open=async(options)=>{speed=options.baudRate;};
  assert.equal(JSON.parse(await f.api.connectMonitor(9600)).status,'connected');
  f.sendText('DHT11 temperature=23.');
  f.sendText('5 C humidity=48 %\r\nRFID detected=true\nGPS fix=false\n');
  await new Promise(resolve=>setTimeout(resolve,5));
  const snapshot=JSON.parse(f.api.monitorSnapshot());
  assert.equal(speed,9600); assert.equal(snapshot.connected,true);
  assert.equal(snapshot.baud_rate,9600);
  assert.equal(JSON.parse(f.api.monitorSnapshot()).baud_rate,9600);
  assert.deepEqual(snapshot.lines,['DHT11 temperature=23.5 C humidity=48 %','RFID detected=true','GPS fix=false']);
  assert.equal(snapshot.sequence,3); assert.equal(f.writes.length,0);
  assert.equal(JSON.parse(await f.api.read(JSON.stringify(command),'["TP1"]')).status,'precondition_failed');
  await f.api.disconnect();
  assert.deepEqual(JSON.parse(f.api.monitorSnapshot()).lines,[]);
});

test('Board monitor has bounded output and does not invent readings on silence',async()=>{
  const f=fixture(); await f.api.connectMonitor(115200);
  assert.deepEqual(JSON.parse(f.api.monitorSnapshot()).lines,[]);
  for(let i=0;i<120;i++) f.sendText('sensor sample '+i+'\n');
  f.sendText('x'.repeat(501)+'\n');
  await new Promise(resolve=>setTimeout(resolve,5));
  const snapshot=JSON.parse(f.api.monitorSnapshot());
  assert.equal(snapshot.lines.length,100); assert.equal(snapshot.dropped,21);
  assert.equal(f.writes.length,0); await f.api.disconnect();
});

test('Board monitor rejects unsupported baud rates and shares the exclusive port',async()=>{
  const f=fixture();
  assert.equal(JSON.parse(await f.api.connectMonitor(123)).status,'port_unavailable');
  await f.api.connect();
  assert.equal(JSON.parse(await f.api.connectMonitor(9600)).status,'busy');
  assert.equal(JSON.parse(f.api.monitorSnapshot()).connected,false);
  await f.api.disconnect();
});

test('Structured board telemetry preserves multiple sensor types, false and zero without USB writes',async()=>{
  const f=fixture(); await f.api.connectMonitor(115200);
  const samples=[
    {channel:'dht11.temperature',value:23.5,unit:'°C',sensor:'DHT11',board:'Arduino UNO',label:'Temperature'},
    {channel:'dht11.humidity',value:0,unit:'%',sensor:'DHT11'},
    {channel:'gps.fix',value:false,unit:'boolean',sensor:'NEO-8M'},
    {channel:'rfid.uid',value:' AB12CD34 ',unit:'text',sensor:'RC522'},
    {channel:'supply',value:3.3,unit:'V'},
  ];
  for(const sample of samples) f.sendText(JSON.stringify({circuitlab:1,...sample})+'\n');
  await new Promise(resolve=>setTimeout(resolve,5));
  const actual=JSON.parse(f.api.monitorSnapshot()).observations;
  assert.equal(actual.length,samples.length);
  for(let i=0;i<samples.length;i++) {
    const {line,received_at,sequence,...sample}=actual[i];
    assert.deepEqual(sample,samples[i]);
    assert.deepEqual(JSON.parse(line),{circuitlab:1,...samples[i]});
    assert.equal(sequence,i+1); assert.ok(Number.isFinite(received_at));
  }
  assert.equal(f.writes.length,0); await f.api.disconnect();
  assert.deepEqual(JSON.parse(f.api.monitorSnapshot()).observations,[]);
  f.port.readable=new ReadableStream({start(){}});
  assert.equal(JSON.parse(await f.api.connectMonitor(115200)).status,'connected');
  const reopened=JSON.parse(f.api.monitorSnapshot());
  assert.deepEqual(reopened.observations,[]); assert.equal(reopened.sequence,0);
  await f.api.disconnect();
});

test('Telemetry never guesses plain logs and rejects malformed or ambiguous samples before sanitization',async()=>{
  const f=fixture(); await f.api.connectMonitor(115200);
  const base={circuitlab:1,channel:'sensor.value',value:1,unit:'%'};
  const invalid=[
    {circuitlab:2},{circuitlab:'1'},{channel:'sensor bad'},{channel:'x'.repeat(81)},
    {unit:''},{unit:' '},{unit:' %'},{unit:'% '},{unit:'x'.repeat(25)},{unit:'°\u0001C'},
    {value:null},{value:[]},{value:{}},{value:false},{value:1,unit:'boolean'},
    {value:'1'},{value:'',unit:'text'},{value:'\n',unit:'text'},
    {value:6,unit:'V'},{value:-1,unit:'V'},{value:5001,unit:'mV'},
    {sensor:'x'.repeat(81)},{board:'x'.repeat(121)},{label:'x'.repeat(121)},
    {sensor:1},{sensor:' DHT11'},{sensor:'DHT11 '},{board:' '},{board:' Arduino UNO'},
    {label:'Temperature '},{extra:true},
  ];
  for(const changes of invalid) f.sendText(JSON.stringify({...base,...changes})+'\n');
  f.sendText('DHT11 temperature=23.5 C\n'+JSON.stringify({...base,circuitlab:undefined})+'\n');
  f.sendText('{"circuitlab":1,"channel":"sensor.value","value":1e999,"unit":"%"}\n');
  f.sendText('{"circuitlab":1,"channel":"sensor.value","value":23.5,"unit":"°C","sensor":"DHT\u000111"}\n');
  f.sendText(JSON.stringify({...base,label:'x'.repeat(120),board:'y'.repeat(120),sensor:'z'.repeat(80),value:'v'.repeat(180),unit:'text'})+'\n');
  await new Promise(resolve=>setTimeout(resolve,5));
  const rejected=JSON.parse(f.api.monitorSnapshot()).observations;
  assert.equal(rejected.length,1);
  assert.equal(rejected[0].channel,'sensor.value');
  assert.equal(rejected[0].invalid,true);
  assert.equal(rejected[0].value,undefined);
  assert.equal(f.writes.length,0); await f.api.disconnect();
});

test('An explicit invalid sensor sample replaces its older valid reading until recovery',async()=>{
  const f=fixture(); await f.api.connectMonitor(115200);
  const base={circuitlab:1,channel:'dht11.temperature',value:23.5,unit:'°C'};
  f.sendText(JSON.stringify(base)+'\n');
  await new Promise(resolve=>setTimeout(resolve,5));
  const good=JSON.parse(f.api.monitorSnapshot()).observations[0];
  f.sendText('dht11.temperature unrelated plain log\n');
  await new Promise(resolve=>setTimeout(resolve,5));
  assert.deepEqual(JSON.parse(f.api.monitorSnapshot()).observations[0],good);
  for(const value of [null,'NaN',false]) {
    f.sendText(JSON.stringify({...base,value})+'\n');
    await new Promise(resolve=>setTimeout(resolve,5));
    const invalid=JSON.parse(f.api.monitorSnapshot()).observations[0];
    assert.equal(invalid.channel,base.channel); assert.equal(invalid.invalid,true);
    assert.equal(invalid.value,undefined); assert.ok(invalid.sequence>good.sequence);
  }
  f.sendText(JSON.stringify({...base,value:0})+'\n');
  await new Promise(resolve=>setTimeout(resolve,5));
  const recovered=JSON.parse(f.api.monitorSnapshot()).observations[0];
  assert.equal(recovered.value,0); assert.equal(recovered.invalid,undefined);
  assert.equal(f.writes.length,0); await f.api.disconnect();
});

test('Telemetry retains only 32 channels and never refreshes a silent sensor from other logs',async()=>{
  const f=fixture(); let now=1000; f.sandbox.Date={now:()=>now};
  await f.api.connectMonitor(115200);
  for(let i=0;i<33;i++) f.sendText(JSON.stringify({circuitlab:1,channel:'sensor.'+i,value:i,unit:'%'})+'\n');
  await new Promise(resolve=>setTimeout(resolve,5));
  const first=JSON.parse(f.api.monitorSnapshot()).observations;
  assert.equal(first.length,32); assert.equal(first[0].received_at,1);
  assert.equal(first.some(sample=>sample.channel==='sensor.32'),false);
  now=9000;
  f.sendText('unrelated boot log\n');
  f.sendText(JSON.stringify({circuitlab:1,channel:'sensor.31',value:0,unit:'%'})+'\n');
  await new Promise(resolve=>setTimeout(resolve,5));
  const latest=JSON.parse(f.api.monitorSnapshot());
  assert.deepEqual(latest.observations[0],first[0]);
  assert.equal(latest.observations[31].value,0);
  assert.equal(latest.observations[31].received_at,9);
  assert.equal(latest.observations[31].sequence,35);
  await f.api.disconnect();
});

test('A partial telemetry line received during board startup survives the startup wait',async()=>{
  const f=fixture();
  const raw=JSON.stringify({circuitlab:1,channel:'gps.fix',value:false,unit:'boolean'});
  f.api.onState=stage=>{if(stage==='starting_instrument')f.sendText(raw.slice(0,30));};
  assert.equal(JSON.parse(await f.api.connectMonitor(115200)).status,'connected');
  f.sendText(raw.slice(30)+'\r\n');
  await new Promise(resolve=>setTimeout(resolve,5));
  const snapshot=JSON.parse(f.api.monitorSnapshot());
  assert.equal(snapshot.observations.length,1);
  assert.equal(snapshot.observations[0].value,false);
  assert.equal(snapshot.observations[0].line,raw+'\r');
  await f.api.disconnect();
});

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
