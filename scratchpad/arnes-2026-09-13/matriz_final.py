from pathlib import Path
import subprocess,time,json,shutil,re,os,sys
root=Path('/Users/renatoalmeidasilva/Documentos/Tradutor instantaneo')
out=root/'Relatorio Auditoria 2026-09-12'/'conclusao-2026-09-13'/'matriz-final'
out.mkdir(parents=True,exist_ok=True)
tmp=Path('/tmp/conclusao-tradutor-20260913'); app=tmp/'Tradutor.app'; temp=Path(os.environ['TMPDIR'])
rows=[]
def run(mode,video,engine,diar='sortformer'):
 name=f'{mode}-{video}-{engine}-{diar}'; report=Path('/tmp/tradutor-'+mode+'.txt')
 folder=out/name; folder.mkdir(exist_ok=True)
 for item in [report,Path('/tmp/studio.png'),Path('/tmp/studio-locutores.png')]:
  if item.exists():item.unlink()
 lang='ja' if video.startswith('ja') else 'en'; media=tmp/(video+'.mp4')
 args=['open','-n','-W',str(app),'--args','--selftest-'+mode,str(media),lang,'pt',
       '--tradutor','apple','-motorDeTraducao','apple','--motor',engine,
       '-motorDeReconhecimento',engine,
       '-identificarLocutores','YES' if diar!='off' else 'NO',
       '-modeloDeLocutor',diar if diar!='off' else 'sortformer',
       '-coresPorLocutor','YES' if diar!='off' else 'NO']
 if diar!='off':args+=['--locutores','--cores','--modelo',diar]
 t=time.monotonic()
 with (folder/'launch.log').open('w') as log:
  proc=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT)
  while proc.poll() is None and time.monotonic()-t<900: time.sleep(.2)
  timedout=proc.poll() is None
  if timedout:proc.terminate()
 txt=report.read_text() if report.exists() else ''
 if report.exists():shutil.copy2(report,folder/'resultado.txt')
 if mode=='job' and media.with_suffix('.pt.srt').exists():
  shutil.copy2(media.with_suffix('.pt.srt'),folder/'gerado.srt')
 for f in [Path('/tmp/studio.png'),Path('/tmp/studio-locutores.png')]:
  if mode=='studio' and f.exists():shutil.copy2(f,folder/f.name)
 row=dict(name=name,mode=mode,video=video,engine=engine,diar=diar,
          wall=round(time.monotonic()-t,2),ok=len(re.findall(r'^  ok ',txt,re.M)),
          failures=re.findall(r'^.*FALHA.*$',txt,re.M),passed='PASSOU' in txt,timeout=timedout)
 for key,pattern in [('cues',r'^legendas: (.+)$'),('speakers',r'^locutores: (.+)$')]:
  m=re.search(pattern,txt,re.M)
  if m:row[key]=m.group(1)
 rows.append(row);(out/'matriz.json').write_text(json.dumps(rows,indent=1,ensure_ascii=False))
 print(json.dumps(row,ensure_ascii=False),flush=True)

plano=[]
for video in ['ja-longo','ja-musica','en-conversa','en-dialogo']:
 for mode in ['studio','job']:
  for diar in ['off','sortformer']: plano.append((mode,video,'apple',diar))
for video,engine in [('ja-musica','whisper'),('en-conversa','parakeet'),('ja-musica','qwen'),('en-dialogo','qwenLarge')]:
 plano.append(('job',video,engine,'sortformer'))
for mode in ['studio','job']:
 for diar in ['off','sortformer']: plano.append((mode,'ja-quiet','whisper',diar))
print(f'{len(plano)} execucoes',flush=True)
for p in plano: run(*p)
print('FIM',flush=True)
