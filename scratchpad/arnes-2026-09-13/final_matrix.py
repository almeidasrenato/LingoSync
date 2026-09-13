from pathlib import Path
import subprocess,time,json,shutil,re,os,sys
root=Path('/Users/renatoalmeidasilva/Documentos/Tradutor instantaneo')
out=root/'Relatorio Auditoria 2026-09-12'/'conclusao-2026-09-13'; tmp=Path('/tmp/conclusao-tradutor-20260913')
app=tmp/'Tradutor.app'; temp=Path(os.environ['TMPDIR'])
rows=[]
def run(mode,video,engine,diar='sortformer'):
 name=f'{mode}-{video}-{engine}-{diar}'; report=Path('/tmp/tradutor-'+mode+'.txt')
 folder=out/name;folder.mkdir(exist_ok=True)
 for item in [report,Path('/tmp/studio.png'),Path('/tmp/studio-progresso.png'),Path('/tmp/studio-locutores.png')]:
  if item.exists():item.unlink()
 lang='ja' if video.startswith('ja') else 'en'; media=tmp/(video+'.mp4')
 args=['open','-n','-W',str(app),'--args','--selftest-'+mode,str(media),lang,'pt','--tradutor','apple','-motorDeTraducao','apple','--motor',engine,'-motorDeReconhecimento',engine,'-identificarLocutores','YES' if diar!='off' else 'NO','-modeloDeLocutor',diar if diar!='off' else 'sortformer','-coresPorLocutor','YES']
 if diar!='off':args+=['--locutores','--cores','--modelo',diar]
 before=set(temp.glob('backup-*.srt')); t=time.monotonic()
 with (folder/'launch.log').open('w') as log:
  proc=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT)
  while proc.poll() is None and time.monotonic()-t<600:
   for f in set(temp.glob('backup-*.srt'))-before:
    try:shutil.copy2(f,folder/'studio-gerado.srt')
    except OSError:pass
   time.sleep(.1)
  timedout=proc.poll() is None
  if timedout:proc.terminate()
 if report.exists():shutil.copy2(report,folder/'resultado.txt')
 txt=report.read_text() if report.exists() else ''
 if mode=='job' and media.with_suffix('.pt.srt').exists():shutil.copy2(media.with_suffix('.pt.srt'),folder/'gerado.srt')
 for f in [Path('/tmp/studio.png'),Path('/tmp/studio-progresso.png'),Path('/tmp/studio-locutores.png')]:
  if mode=='studio' and f.exists():shutil.copy2(f,folder/f.name)
 row=dict(name=name,mode=mode,video=video,engine=engine,diar=diar,wall=round(time.monotonic()-t,2),ok=len(re.findall(r'^  ok ',txt,re.M)),failures=re.findall(r'^.*FALHA.*$',txt,re.M),passed='PASSOU' in txt,timeout=timedout)
 for key,pattern in [('cues',r'^legendas: (.+)$'),('generation',r'^geracao em (.+)$'),('speakers',r'^locutores: (.+)$'),('colors',r'^no arquivo: (.+)$'),('recognized',r'^(?:motor|reconhecimento): (.+)$')]:
  m=re.search(pattern,txt,re.M)
  if m:row[key]=m.group(1)
 rows.append(row);(out/'matrix.json').write_text(json.dumps(rows,indent=2,ensure_ascii=False));print(json.dumps(row,ensure_ascii=False),flush=True)
 if timedout:raise SystemExit('TIMEOUT; inspect the app before continuing')

# Complemento de ganho: dois modelos Qwen, mantendo tradução fora da medida.
for video,lang,engine in [('ja-longo','ja','qwen'),('ja-musica','ja','qwenLarge'),('en-conversa','en','qwenLarge')]:
 name=f'gain-low-{video}-{engine}'
 with (out/(name+'.log')).open('w') as log:
  result=subprocess.run([str(tmp/'measure'),'gain-low',str(tmp/(video+'.mp4')),lang,str(out/(name+'.json')),engine],stdout=log,stderr=subprocess.STDOUT,timeout=300)
 print(name,result.returncode,flush=True)
for video in ['ja-longo','ja-musica','en-conversa','en-dialogo']:
 for mode in ['studio','job']:run(mode,video,'apple')
for video,engine in [('ja-musica','whisper'),('en-conversa','parakeet'),('ja-musica','qwen'),('en-dialogo','qwenLarge')]:
 run('job',video,engine)
for mode in ['studio','job']:run(mode,'ja-quiet','whisper')
