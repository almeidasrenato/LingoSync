"""Controles de fala real sintetizada, outra fala, silêncio, ruído e cliques."""
import array, json, random, subprocess, wave
from pathlib import Path
out=Path(__file__).resolve().parent/'audio'
out.mkdir(exist_ok=True)
for name,voice,text in [
 ('pt-thanks','Luciana','Obrigado por assistir.'),
 ('pt-thanks-rocko','Rocko (Português (Brasil))','Obrigado por assistir.'),
 ('pt-other','Luciana','Até amanhã. A reunião terminou.')]:
 aiff=out/(name+'.aiff');wav=out/(name+'.wav')
 subprocess.run(['say','-v',voice,'-r','165','-o',str(aiff),text],check=True)
 subprocess.run(['afconvert','-f','WAVE','-d','LEI16@16000','-c','1',str(aiff),str(wav)],check=True)
 with wave.open(str(wav)) as f: duration=f.getnframes()/f.getframerate()
 (out/(name+'.truth.json')).write_text(json.dumps([dict(text=text,start=0,end=duration,voice=voice)],ensure_ascii=False,indent=2))
 aiff.unlink()
rng=random.Random(220926)
for name in ['pt-silence','pt-noise','pt-clicks']:
 data=[0]*48000
 if name=='pt-noise': data=[round(rng.uniform(-.004,.004)*32767) for _ in data]
 if name=='pt-clicks':
  for i in [8000,24000,40000]: data[i]=20000
 with wave.open(str(out/(name+'.wav')),'wb') as f:
  f.setparams((1,2,16000,0,'NONE','not compressed'));f.writeframes(array.array('h',data).tobytes())
