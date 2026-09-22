"""WER só com roteiro conhecido. Energia é proxy de alcance, não acerto textual."""
import collections, json, math, re, statistics, sys, unicodedata
from pathlib import Path
here=Path(__file__).resolve().parent
phase=sys.argv[1] if len(sys.argv)>1 else 'baseline'
def norm(s):
 return re.findall(r'[^\W_]+',unicodedata.normalize('NFC',s).lower(),re.UNICODE)
def equivalent_pt(s):
 # Equivalências de escrita do roteiro, não correção de erros do reconhecedor.
 s=re.sub(r'R\$\s*123,50|123,50 reais', 'cento e vinte e três reais e cinquenta centavos',s,flags=re.I)
 for digit,word in [('9','nove'),('15','quinze'),('50','cinquenta')]:
  s=re.sub(r'\b'+digit+r'\b',word,s)
 return norm(s.replace('sextafeira','sexta-feira'))
def distance(a,b):
 row=list(range(len(b)+1))
 for i,x in enumerate(a,1):
  new=[i]
  for j,y in enumerate(b,1):new.append(min(new[-1]+1,row[j]+1,row[j-1]+(x!=y)))
  row=new
 return row[-1]
def union(items):
 out=[]
 for s,e in sorted((r['start'],r['end']) for r in items):
  if out and s<=out[-1][1]:out[-1][1]=max(e,out[-1][1])
  else:out.append([s,e])
 return out
def length(items):return sum(e-s for s,e in items)
def overlap(a,b):return sum(max(0,min(e,v)-max(s,u)) for s,e in a for u,v in b)
punct='.!?,;:。！？、，；：…'
def summarize(phase):
 rows=[]
 for path in sorted((here/'results'/phase).glob('*.json')):
  if path.name=='audio-sha256.json':continue
  data=json.loads(path.read_text())
  if 'pieces' not in data:continue
  name,engine=path.stem.rsplit('-',1)
  reference=json.loads((here/'audio'/f'{name}.audio.json').read_text())
  pieces,cues,draft=data['pieces'],data['cues'],data['draft']
  text=' '.join(r['text'] for r in pieces)
  before=''.join(r['source'] for r in draft);after=''.join(r['source'] for r in cues)
  voice=union(reference['regions']);visible=union(cues)
  speech=length(voice);captions=length(visible)
  cps=sorted(len(r['translated'] or r['source'])/(r['end']-r['start']) for r in cues if r['end']>r['start'])
  blocks=[b.splitlines()[2:] for b in data['srt'].strip().split('\n\n') if b]
  row=dict(sample=name,engine=engine,seconds=round(data['seconds'],3),asr_s=round(data['asrSeconds'],3),
   pieces=len(pieces),cues=len(cues),chars=len(''.join(norm(text))),
   questions=text.count('?')+text.count('？'),exclamations=text.count('!')+text.count('！'),
   punctuation=sum(text.count(c) for c in punct),
   source_punctuation_lost=sum(max(0,before.count(c)-after.count(c)) for c in punct),
   source_lexical_loss=len(''.join(norm(before)))-len(''.join(norm(after))),
   speech_uncovered_pct=round(100*(1-overlap(voice,visible)/speech),2) if speech else 0,
   caption_without_voice_s=round(captions-overlap(voice,visible),2),
   over_2_lines=sum(len(b)>2 for b in blocks),over_7s=sum(r['end']-r['start']>7.001 for r in cues),
   under_700ms=sum(r['end']-r['start']<.7-.001 for r in cues),
   p95_cps=round(cps[min(len(cps)-1,math.ceil(len(cps)*.95)-1)],1) if cps else 0)
  truth=here/'audio'/f'{name}.truth.json'
  if truth.exists():
   refs=json.loads(truth.read_text());expected=' '.join(r['text'] for r in refs)
   row['wer_pct']=round(100*distance(norm(expected),norm(text))/len(norm(expected)),2)
   row['cer_pct']=round(100*distance(''.join(norm(expected)),''.join(norm(text)))/len(''.join(norm(expected))),2)
   row['wer_number_normalized_pct']=round(100*distance(equivalent_pt(expected),equivalent_pt(text))/len(equivalent_pt(expected)),2)
   row['reference_questions']=expected.count('?');row['reference_exclamations']=expected.count('!')
  rows.append(row)
 (here/'results'/phase/'summary.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
 for r in rows:
  print(f"{r['sample']:12} {r['engine']:9} {r['asr_s']:6.2f}s | chars {r['chars']:4} | ? {r['questions']:2} | voz sem legenda {r['speech_uncovered_pct']:5.1f}% | pontuação perdida {r['source_punctuation_lost']:2} | >2L {r['over_2_lines']} | >7s {r['over_7s']} | WER {r.get('wer_pct','—')}")
if __name__ == "__main__": summarize(phase)
