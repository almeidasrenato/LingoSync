"""Replays sequenciais: nenhuma disputa de GPU entre modelos ou chamadas ao Gemini."""
import json, os, subprocess, sys
from pathlib import Path

here=Path(__file__).resolve().parent
exe=Path(sys.argv[1]); mode=sys.argv[2]
phase=sys.argv[3] if len(sys.argv)>3 else mode
dest=here/'results'/phase; dest.mkdir(parents=True,exist_ok=True)
if mode=='layout':
 inputs=sorted((here/'results'/'baseline').glob('*.json'))
 jobs=[(p.stem, [mode,p,p.stem[:2]]) for p in inputs if isinstance(json.loads(p.read_text()),dict) and 'pieces' in json.loads(p.read_text())]
elif mode=='gemini':
 jobs=[(f'{name}-{engine}', [mode,here/'results/baseline'/f'{name}-{engine}.json',name[:2]])
       for name in ['pt-clean','ja-dificil','en-conversa'] for engine in ['apple','whisper','qwenLarge']]
elif mode=='confirm':
 jobs=[]
 for name in ['pt-thanks','pt-thanks-rocko','pt-other','pt-silence','pt-noise','pt-clicks']:
  prefix=here/'audio'/name
  if not prefix.with_suffix('.prepared.f32').exists():
   subprocess.run([str(exe),'freeze',str(prefix.with_suffix('.wav')),'pt',str(prefix)],check=True,cwd=here.parent.parent)
  jobs.append((name,['confirm',prefix,'pt']))
else:
 jobs=[(f'{name}-{engine}', ['live',here/'audio'/name,name[:2],engine])
       for name in ['pt-clean','pt-quiet','ja-dificil','ja-musica','en-conversa'] for engine in ['apple','whisper']]
for name,args in jobs:
 output=dest/(name+'.json')
 if output.exists(): continue
 with output.with_suffix('.log').open('w') as out:
  try:
   p=subprocess.run([str(exe),*map(str,args),str(output)],stdout=out,stderr=subprocess.STDOUT,timeout=600,cwd=here.parent.parent)
   print(name,'OK' if p.returncode==0 else 'FALHA',flush=True)
  except subprocess.TimeoutExpired:
   print(name,'TIMEOUT',flush=True)
