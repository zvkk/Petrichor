#!/usr/bin/env python3
"""Compile the production Swift/TS protocol parsers and check shared fixtures + round trips."""
import argparse, json, pathlib, subprocess, tempfile
p=argparse.ArgumentParser();p.add_argument('--ios-root',required=True);a=p.parse_args()
mac=pathlib.Path(__file__).resolve().parents[2];ios=pathlib.Path(a.ios_root).resolve()
fixture=mac/'docs/fixtures/dropbox-playlist-protocol.json'
assert fixture.read_bytes()==(ios/'docs/fixtures/dropbox-playlist-protocol.json').read_bytes(), 'Fixture copies differ'
f=json.loads(fixture.read_text())
swift=r'''
import Foundation
let args=CommandLine.arguments
// Decode via JSONDecoder: JSONSerialization silently strips U+FEFF from values.
struct JSONValue: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let x = try? c.decode(Bool.self) { value = x }
        else if let x = try? c.decode(Int.self) { value = x }
        else if let x = try? c.decode(Double.self) { value = x }
        else if let x = try? c.decode(String.self) { value = x }
        else if let x = try? c.decode([JSONValue].self) { value = x.map { $0.value } }
        else { value = try c.decode([String:JSONValue].self).mapValues { $0.value } }
    }
}
let input=try JSONDecoder().decode(JSONValue.self,from:Data(contentsOf:URL(fileURLWithPath:args[1]))).value as! [String:Any]
func bytes(_ x:Any) throws -> Data { try JSONSerialization.data(withJSONObject:x,options:[.sortedKeys,.fragmentsAllowed]) }
var output:[String:Any]=[:]
var validations:[[String:Any]]=[]
for c in input["validationCases"] as! [[String:Any]] {
    var r:[String:Any]=["name":c["name"]!]
    do { let v=try PlaylistRevision.decode(bytes(c["revision"]!));r["valid"]=true;r["revision"]=try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(v)).value }
    catch { r["valid"]=false }
    validations.append(r)
}
output["validationCases"]=validations
var descriptors:[[String:Any]]=[]
for c in input["descriptorCases"] as? [[String:Any]] ?? [] {
    var r:[String:Any]=["name":c["name"]!]
    do { let d=try JSONDecoder().decode(SyncLibraryDescriptor.self,from:bytes(c["descriptor"]!));try d.validate();r["valid"]=true }
    catch { r["valid"]=false }
    descriptors.append(r)
}
output["descriptorCases"]=descriptors
let revisions=input["revisions"] as! [String:Any]
var graphs:[[String:Any]]=[]
for c in input["graphCases"] as! [[String:Any]] {
    var r:[String:Any]=["name":c["name"]!]
    do { let rs=try (c["revisions"] as! [String]).map { try PlaylistRevision.decode(bytes(revisions[$0]!)) };let g=try RevisionGraph(revisions:rs);r["state"]=g.incomplete ? "pending" : (g.heads.count>1 ? "conflict" : "ready");r["headIds"]=g.heads }
    catch { r["state"]="error";r["headIds"]=[String]() }
    graphs.append(r)
}
output["graphCases"]=graphs
try bytes(output).write(to:URL(fileURLWithPath:args[2]))
'''
node=r'''
const fs=require('fs'),path=require('path'),Module=require('module');
const [root,fixture,out]=process.argv.slice(1);
const ts=require(path.join(root,'node_modules/typescript'));
const src=path.join(root,'src/playlist-sync/protocol.ts');const m=new Module(src,module);
m.filename=src;m.paths=Module._nodeModulePaths(path.dirname(src));
m._compile(ts.transpileModule(fs.readFileSync(src,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText,src);
const p=m.exports,f=JSON.parse(fs.readFileSync(fixture,'utf8'));
const output={validationCases:f.validationCases.map(c=>{try{return {name:c.name,valid:true,revision:p.decodeRevision(JSON.stringify(c.revision))}}catch{return {name:c.name,valid:false}}}),descriptorCases:(f.descriptorCases||[]).map(c=>{try{p.decodeDescriptor(JSON.stringify(c.descriptor));return {name:c.name,valid:true}}catch{return {name:c.name,valid:false}}}),graphCases:f.graphCases.map(c=>{try{const g=p.resolveHeads(c.revisions.map(n=>p.decodeRevision(JSON.stringify(f.revisions[n]))));return {name:c.name,state:g.incomplete?'pending':g.heads.length>1?'conflict':'ready',headIds:g.heads.map(r=>r.revisionId)}}catch{return {name:c.name,state:'error',headIds:[]}}})};
fs.writeFileSync(out,JSON.stringify(output));
'''
nodepath=pathlib.Path('/Users/zakcupido/.nvm/versions/node/v24.17.0/bin/node')
with tempfile.TemporaryDirectory(prefix='crate-protocol-') as tmp:
    t=pathlib.Path(tmp);(t/'main.swift').write_text(swift)
    subprocess.run(['swiftc','-module-cache-path',str(t/'module-cache'),str(mac/'Models/PlaylistSync/PlaylistSyncProtocol.swift'),str(t/'main.swift'),'-o',str(t/'verify')],check=True,capture_output=True,text=True)
    def run(input_path,prefix):
        s=t/(prefix+'-swift.json');j=t/(prefix+'-ts.json')
        subprocess.run([str(t/'verify'),str(input_path),str(s)],check=True)
        subprocess.run([str(nodepath),'-e',node,str(ios),str(input_path),str(j)],check=True)
        return json.loads(s.read_text()),json.loads(j.read_text())
    # JSONSerialization strips literal BOM scalars inside strings; escaped JSON preserves them.
    escaped_fixture=t/'fixtures-ascii.json';escaped_fixture.write_text(json.dumps(f,ensure_ascii=True))
    results=run(escaped_fixture,'fixtures'); failures=[]
    for name,result in zip(('Swift','TypeScript'),results):
        for group,keys in [('validationCases',['valid']),('descriptorCases',['valid']),('graphCases',['state','headIds'])]:
            for expected,actual in zip(f[group],result[group],strict=True):
                for key in keys:
                    if expected[key]!=actual[key]:failures.append(f'{name} {group}/{expected["name"]} {key}: expected {expected[key]!r}, got {actual[key]!r}')
        roundtrip=dict(f,validationCases=[dict(name=c['name'],valid=True,revision=c['revision']) for c in result['validationCases'] if c['valid']],descriptorCases=[],graphCases=[])
        path=t/(name+'-serialized.json');path.write_text(json.dumps(roundtrip,ensure_ascii=True))
        for dest,res in zip(('Swift','TypeScript'),run(path,name)):
            for c in res['validationCases']:
                if not c['valid']: failures.append(f'{name} -> {dest} roundtrip rejected {c["name"]}')
                else:
                    expected=next(x['revision'] for x in roundtrip['validationCases'] if x['name']==c['name'])
                    keys=('protocolVersion','libraryId','playlistId','revisionId','parentRevisionIds','deviceId','name','deleted','tracks')
                    def wire(v): return {k: ([{t:ref[t] for t in ('provider','fileId')} for ref in v[k]] if k=='tracks' else v[k]) for k in keys}
                    if wire(c['revision'])!=wire(expected): failures.append(f'{name} -> {dest} roundtrip changed {c["name"]}')
    if failures:raise SystemExit('\n'.join(failures))
    print(f'PASS: both production parsers agree on {len(f["validationCases"])} revision, {len(f["descriptorCases"])} descriptor and {len(f["graphCases"])} graph cases; accepted revisions round-trip both ways.')
