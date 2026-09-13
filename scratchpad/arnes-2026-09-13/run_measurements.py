from pathlib import Path
import subprocess,time,json
root=Path('/Users/renatoalmeidasilva/Documentos/Tradutor instantaneo');tmp=Path('/tmp/conclusao-tradutor-20260913');out=root/'Relatorio Auditoria 2026-09-12/conclusao-2026-09-13';media=Path('/tmp/auditoria-tradutor-20260912')
cases=[('ja-longo','ja'),('ja-musica','ja'),('en-conversa','en'),('en-dialogo','en')];runs=[]
def run(mode,video,lang,engine=None):
 name=f'{mode}-{video}'+(f'-{engine}' if engine else '');start=time.monotonic()
 args=[str(tmp/'measure'),mode,str(media/(video+'.mp4')),lang,str(out/(name+'.json'))]
 if engine:args.append(engine)
 with (out/(name+'.log')).open('w') as log:r=subprocess.run(args,stdout=log,stderr=subprocess.STDOUT,timeout=600)
 runs.append(dict(name=name,exit=r.returncode,seconds=round(time.monotonic()-start,2)));(out/'measurements.json').write_text(json.dumps(runs,indent=2));print(runs[-1],flush=True)
for v,l in cases:run('phrases',v,l)
for v,l in cases:run('live',v,l)
for v,l in cases:
 for engine in ['apple','whisper']+(['parakeet'] if l=='en' else []):run('gain',v,l,engine)
