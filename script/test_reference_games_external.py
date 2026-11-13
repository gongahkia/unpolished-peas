#!/usr/bin/env python3
"""Fresh hashed source-archive consumers for the two polished reference games."""
import argparse, functools, hashlib, http.server, json, os, re, shutil, sys, tempfile, threading
from pathlib import Path
sys.dont_write_bytecode = True
from test_starter_generation import REPO, QuietHandler, prepared_manifest, run, sources

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--output',type=Path,default=REPO/'zig-out/diagnostics/reference-games-external')
    args=p.parse_args(); output=args.output.resolve();output.mkdir(parents=True,exist_ok=True)
    report={'status':'running','games':[],'archive_requests':[]}
    def persist(): (output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    persist()
    with tempfile.TemporaryDirectory(prefix='peas-reference-consumers-') as directory:
        scratch=Path(directory)
        tree=run([REPO/'script/worktree_treeish.sh'],REPO,scratch/'seed-cache').strip();report['source_tree']=tree
        version=re.search(r'\.version = "([^"]+)"',(REPO/'build.zig.zon').read_text()).group(1)
        archive=Path(run([REPO/'script/create_source_archive.sh',f'v{version}',scratch/'archive',tree],REPO,scratch/'seed-cache').strip())
        report['archive_sha256']=hashlib.sha256(archive.read_bytes()).hexdigest()
        package_hash=run(['zig','fetch',archive],scratch,scratch/'seed-cache').strip();report['package_hash']=package_hash
        class Handler(QuietHandler):
            def do_GET(self): report['archive_requests'].append(self.path);super().do_GET()
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(archive.parent)))
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            for name in ['neon-siege','lantern-leap']:
                result={'game':name,'status':'running','commands':[]};report['games'].append(result)
                project=scratch/(name+' consumer with spaces')
                shutil.copytree(REPO/'dogfood'/name,project,ignore=shutil.ignore_patterns('.zig-cache','zig-out','__pycache__'))
                manifest=project/'build.zig.zon';manifest.write_text(prepared_manifest(manifest.read_text(),f'http://127.0.0.1:{server.server_port}/{archive.name}',package_hash))
                before=sources(project);result['authored_sources_sha256']=before
                commands=[['zig','build','test','-j2','--summary','all'],['zig','build','package','-j2','--summary','all'],['zig','build','web','-j2','--summary','all'],['zig','build','export-browser-replay','-j2','--',str(project/'zig-out/exported')]]
                target=output/name;target.mkdir(exist_ok=True)
                for i,command in enumerate(commands):
                    print(name+': '+' '.join(command),flush=True)
                    log=run(command,project,scratch/'consumer-cache')
                    (target/f'command-{i}.log').write_text(log);result['commands'].append({'command':command,'status':'passed','log':f'{name}/command-{i}.log'});persist()
                assert sources(project)==before
                required=[f'bin/{name}','licenses/Basic-OFL.txt','web/unpolished-peas.wasm','web/licenses/Basic-OFL.txt','web/bootstrap.mjs']
                result['artifacts_sha256']={file:hashlib.sha256((project/'zig-out'/file).read_bytes()).hexdigest() for file in required}
                for file in (project/'zig-out/web').rglob('*.mjs'): assert '__peasReplay' not in file.read_text()
                assert (project/'GUIDE.md').is_file() and (project/'src/export_replay.zig').is_file()
                assert (project/'REVIEW-2026-11-12.md').is_file()
                # Fetch the example itself to prove its .paths retain source/docs/notices.
                game_hash=run(['zig','fetch',project],scratch,scratch/'consumer-cache').strip()
                retained=scratch/'consumer-cache/global/p'/game_hash
                for file in ['GUIDE.md','REVIEW-2026-11-12.md','src/export_replay.zig','src/verify_native.zig','src/profile_route.zig','assets/OFL.txt']:
                    assert (retained/file).is_file(), file
                result['game_package_hash']=game_hash
                result['source_package_retains_docs_tools_notices']=True
                shutil.copytree(project/'zig-out/web',target/'web',dirs_exist_ok=True)
                shutil.copytree(project/'zig-out/exported',target/'browser-route-input',dirs_exist_ok=True)
                result.update(status='passed',source_unchanged=True,shipping_replay_instrumentation_absent=True);persist()
            assert report['archive_requests'];report['status']='passed';persist()
        except Exception as error:
            report.update(status='failed',error=str(error));persist();raise
        finally: server.shutdown();server.server_close();thread.join()
if __name__=='__main__':main()
