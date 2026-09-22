"""Agrega os resultados; cobertura de energia não é acurácia de reconhecimento."""
import json, math
from pathlib import Path
from summary import norm, equivalent_pt, distance, union, length, overlap

here=Path(__file__).resolve().parent
report={}
for phase in ['baseline','candidate','layout-candidate']:
 path=here/'results'/phase/'summary.json'
 if path.exists(): report[phase]=json.loads(path.read_text())
report['live']=[]
for path in sorted((here/'results/live').glob('*.json')):
 data=json.loads(path.read_text());name,engine=path.stem.rsplit('-',1)
 reference=json.loads((here/'audio'/(name+'.audio.json')).read_text())
 voice=union(reference['regions']);captured=union(data['segments'])
 row=dict(sample=name,engine=engine,segments=len(data['segments']),
  raw_voice_time_uncovered_pct=round(100*(1-overlap(voice,captured)/length(voice)),2),
  closed_segment_asr_s=round(sum(r['asrSeconds'] for r in data['segments']),3))
 truth=here/'audio'/(name+'.truth.json')
 if truth.exists():
  refs=json.loads(truth.read_text());expected=' '.join(r['text'] for r in refs)
  text=' '.join(r['text'] for r in data['segments'])
  row['wer_number_normalized_pct']=round(100*distance(equivalent_pt(expected),equivalent_pt(text))/len(equivalent_pt(expected)),2)
  row['cuts_inside_utterances']=sum(any(r['start']+.08<s['end']<r['end']-.08 for r in refs) for s in data['segments'][:-1])
 report['live'].append(row)
report['gemini']=[]
for path in sorted((here/'results/gemini').glob('*.json')):
 data=json.loads(path.read_text());name,engine=path.stem.rsplit('-',1)
 cues=data['cues'];blocks=[b.splitlines()[2:] for b in data['srt'].strip().split('\n\n') if b]
 report['gemini'].append(dict(sample=name,engine=engine,seconds=round(data['postprocessSeconds'],3),
  cues=len(cues),empty_translation=sum(not r['translated'].strip() for r in cues),
  over_2_lines=sum(len(b)>2 for b in blocks),over_7s=sum(r['end']-r['start']>7.001 for r in cues),
  overlaps=sum(a['end']>b['start']+.001 for a,b in zip(cues,cues[1:]))))
(here/'metrics.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
for key in ['live','gemini']:
 print(key)
 for row in report[key]: print(row)
