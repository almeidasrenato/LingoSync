from pathlib import Path
import subprocess,time,json,shutil,re,os
out=Path('/Users/renatoalmeidasilva/Documentos/Tradutor instantaneo/Relatorio Auditoria 2026-09-12/conclusao-2026-09-13/matriz-final')
tmp=Path('/tmp/conclusao-tradutor-20260913'); app=tmp/'Tradutor.app'
rows=[]
def run(video,diar='off'):
 name=f'progresso-studio-{video}-whisper-{diar}'; report=Path('/tmp/tradutor-studio.txt')
 folder=out/name; folder.mkdir(exist_ok=True)
 if report.exists():report.unlink()
 lang='ja' if video.startswith('ja') else 'en'
 args=['open','-n','-W',str(app),'--args','--selftest-studio',str(tmp/(video+'.mp4')),lang,'pt',
       '--tradutor','apple','-motorDeTraducao','apple','--motor','whisper',
       '-motorDeReconhecimento','whisper','-identificarLocutores','NO',
       '-modeloDeLocutor','sortformer','-coresPorLocutor','NO']
 t=time.monotonic()
 with (folder/'launch.log').open('w') as log:
  proc=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT)
  while proc.poll() is None and time.monotonic()-t<900: time.sleep(.2)
 txt=report.read_text() if report.exists() else ''
 if report.exists():shutil.copy2(report,folder/'resultado.txt')
 linha=[l for l in txt.splitlines() if 'progresso' in l]
 row=dict(name=name,ok=len(re.findall(r'^  ok ',txt,re.M)),
          failures=re.findall(r'^.*FALHA.*$',txt,re.M),passed='PASSOU' in txt,
          progresso=linha, wall=round(time.monotonic()-t,2))
 rows.append(row);print(json.dumps(row,ensure_ascii=False),flush=True)
 (out/'progresso.json').write_text(json.dumps(rows,indent=1,ensure_ascii=False))
run('ja-quiet')
run('ja-longo')
print('FIM',flush=True)
