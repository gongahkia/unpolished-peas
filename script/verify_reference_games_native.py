#!/usr/bin/env python3
"""Serial real SDL routes/reloads and bounded profiles; never opens gameplay saves."""
import argparse, hashlib, json, math, os, platform, re, shutil, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent

def distribution(values):
    values=sorted(values)
    return {key:values[min(len(values)-1,math.ceil(len(values)*q)-1)]/1e6 for key,q in [('median_ms',.5),('p95_ms',.95),('p99_ms',.99),('max_ms',1)]}|{'count':len(values)}

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=ROOT/'zig-out/diagnostics/reference-games-native');p.add_argument('--profile',action='store_true');args=p.parse_args()
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    report={'status':'running','platform':platform.platform(),'machine':platform.machine(),'cpu':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip() if platform.system()=='Darwin' else platform.processor(),'results':[], 'scope':'Profile mode: real SDL CPU draw/GPU present/audio and platform SaveStore. Serial; no frame capture or progress printing in timed callbacks. 120 warmup/240 retained host frames; all raw samples retained.'}
    def persist(): (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    persist()
    for name in ['neon-siege','lantern-leap']:
        game=ROOT/'dogfood'/name;inputs=game/'zig-out/evidence/browser-route-input';meta=json.loads((inputs/'route.json').read_text());exe=game/f'zig-out/verification/{name}-verification'
        result={'game':name,'binary_sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'cases':[]};report['results'].append(result)
        owned=None
        # These IDs belong only to this documented verification build. Refuse
        # pre-existing records rather than guessing that they are disposable.
        if platform.system()=='Darwin':
            identity='polish-'+('neon' if name=='neon-siege' else 'lantern')+'-3ae783d5'
            candidate=Path.home()/'Library/Application Support/peas-reference-verification'/identity
            if candidate.exists(): raise FileExistsError('use a fresh verification-id; preserving '+str(candidate))
        def cleanup():
            if owned and owned.exists():
                assert owned.parent.name=='peas-reference-verification' and owned.name.startswith('polish-')
                shutil.rmtree(owned)
        def run(label,mode,frames,expected=None,limit=None,skip=None):
            nonlocal owned
            target=out/name/label;target.mkdir(parents=True,exist_ok=True)
            env=dict(os.environ,REFERENCE_VERIFY_MODE=mode,REFERENCE_VERIFY_OUTPUT=str(target),REFERENCE_VERIFY_REPLAY=str(inputs/'route.upr'),UP_LOG_LEVEL='warn',UP_DEVELOPER_TOOLS='1',UP_DEVELOPER_OVERLAY='0')
            if expected:env['REFERENCE_EXPECTED_SAVE']=str(expected)
            if limit is not None:env['REFERENCE_VERIFY_LIMIT']=str(limit)
            if skip is not None:env.update(REFERENCE_PROFILE_SKIP=str(skip),UP_NATIVE_TIMING_SAMPLES='1')
            command=[str(exe),'--frames',str(frames)]
            with (target/'host.log').open('w') as f:process=subprocess.run(command,cwd=game,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=90)
            text=(target/'host.log').read_text()
            path=next((line.split(': ',1)[1] for line in text.splitlines() if line.startswith('unpolished-peas app data: ')),None)
            if path:
                found=Path(path).resolve();assert found.parent.name=='peas-reference-verification' and found.name.startswith('polish-')
                if owned:assert owned==found
                owned=found
            assert path is not None, 'owned test path was not reported'
            assert process.returncode==0,text
            assert f'reference native {name} cleanup passed' in text
            case={'label':label,'command':command,'mode':mode,'frames':frames,'status':'passed'}
            if expected:assert (target/'saved.bin').read_bytes()==expected.read_bytes();case['actual_persisted_bytes']=list(expected.read_bytes())
            if mode=='profile':
                host=json.loads(next(line[len('peas-host-samples '):] for line in text.splitlines() if line.startswith('peas-host-samples ')))
                assert len(host['frames'])==360 and host['dropped']==0
                assert all(f['pass_count']==2 for f in host['frames'][120:])
                (target/'host-samples.json').write_text(json.dumps(host))
                case.update(skip=skip,tick_start=skip,tick_end=int(re.search(r'ticks=(\d+)',text).group(1)),framebuffer=host.get('framebuffer'),renderer=next(line for line in text.splitlines() if line.startswith('unpolished-peas native renderer: ')),summary={field:distribution([f[field] for f in host['frames'][120:]]) for field in ['frame_ns','interval_ns','update_ns','draw_ns','present_ns']})
            result['cases'].append(case);persist();print(name+' '+label+' passed',flush=True)
        try:
            if args.profile:
                # No builds or browser captures run during this separate invocation.
                cpu=out/name/'cpu-route.json';cpu.parent.mkdir(exist_ok=True)
                subprocess.run([game/'zig-out/verification/profile-route',inputs/'route.upr',cpu],check=True,cwd=game,timeout=60)
                data=json.loads(cpu.read_text());assert data['live_bytes_after_cleanup']==0
                result['cpu']={k:v for k,v in data.items() if k!='samples'}
                result['cpu']['groups']={}
                for label,active in [('ordinary',False),('active',True)]:
                    samples=[s for s in data['samples'][60:] if s['active']==active and s['playing']];assert samples
                    result['cpu']['groups'][label]={field:distribution([s[field] for s in samples]) for field in ['update_ns','draw_ns','audio_ns']}
                    result['cpu']['groups'][label].update(allocations=sum(s['allocations'] for s in samples),allocated_bytes=sum(s['allocated_bytes'] for s in samples),max_workload_a=max(s['workload_a'] for s in samples),max_workload_b=max(s['workload_b'] for s in samples))
                persist()
                for label,skip in [('early-route',0),('active-route',425 if name=='neon-siege' else 240)]:
                    run(label,'profile',360,skip=skip);cleanup()
            else:
                run('complete-route','route',meta['ticks']+30,inputs/'final-save.bin')
                run('completed-process-reload','reload',3,inputs/'final-save.bin');cleanup()
                if name=='lantern-leap':
                    limit=next(m['tick'] for m in meta['milestones'] if m['label']=='death')+1
                    run('checkpoint-route','route',limit+30,inputs/'checkpoint-save.bin',limit=limit)
                    run('checkpoint-process-reload','reload',3,inputs/'checkpoint-save.bin');cleanup()
        finally:cleanup()
    report['status']='passed';persist()
if __name__=='__main__':main()
