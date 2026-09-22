"""Executa GPU e site sequencialmente; nenhuma saída ao lado dos vídeos."""
import hashlib, json, subprocess, sys
from pathlib import Path

here=Path(__file__).resolve().parent
root=here.parent.parent
exe=Path(sys.argv[1])
mode=sys.argv[2] if len(sys.argv)>2 else 'baseline'
files={
 'ja-dificil':('Video perca de fala japones.mp4','ja'),
 'ja-musica':('video exemplo 2 (Conversa mais complexa).mp4','ja'),
 'en-conversa':('video exemplo conversa de pessoas ingles.mp4','en'),
 'en-dialogo':('video exemplo conversa de pessoas 2 ingles.mp4','en'),
 'ja-longo':('video exemplo conversa de pessoas.mp4','ja'),
 'pt-clean':(str(here/'audio/pt-clean.wav'),'pt'),
 'pt-quiet':(str(here/'audio/pt-quiet.wav'),'pt'),
 'pt-thanks':(str(here/'audio/pt-thanks.wav'),'pt'),
 'pt-thanks-rocko':(str(here/'audio/pt-thanks-rocko.wav'),'pt'),
}
dest=here/'results'/mode;dest.mkdir(parents=True,exist_ok=True)
def run(args,log):
 with log.open('w') as out:
  p=subprocess.run([str(exe),*map(str,args)],stdout=out,stderr=subprocess.STDOUT,timeout=600,cwd=root)
 if p.returncode: print('FALHA',log.name,flush=True)
 return p.returncode==0
for name,(media,lang) in files.items():
 prefix=here/'audio'/name
 if not prefix.with_suffix('.prepared.f32').exists():
  if not run(['freeze',root/'Videos Exemplo'/media,lang,prefix],dest/(name+'-freeze.log')):continue
 for engine in ['apple','whisper','qwenLarge']:
  output=dest/f'{name}-{engine}.json'
  if output.exists():continue
  if run(['measure',prefix,lang,engine,output],output.with_suffix('.log')):
   data=json.loads(output.read_text())
   print(name,engine,round(data['seconds'],2),'s',len(data['pieces']),'trechos',len(data['cues']),'legendas',flush=True)
manifest={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (here/'audio').glob('*.f32')}
(dest/'audio-sha256.json').write_text(json.dumps(manifest,indent=2))
