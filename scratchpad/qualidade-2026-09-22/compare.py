"""Falha se a correção perder texto, mudar tempos/tradução ou aceitar fala ausente."""
import json
from pathlib import Path
here=Path(__file__).resolve().parent
base=here/'results/baseline'; after=here/'results/layout-candidate'
hashes=json.loads((base/'audio-sha256.json').read_text())
candidate_hashes=json.loads((here/'results/candidate/audio-sha256.json').read_text())
assert all(candidate_hashes.get(name)==value for name,value in hashes.items())
(here/'audio-sha256.json').write_text(json.dumps(hashes,indent=2)+'\n')
checked=0;before_loss=0;after_loss=0
punct='.!?,;:。！？、，；：…'
compact=lambda s: ''.join(s.split())
for path in sorted(base.glob('*.json')):
 old=json.loads(path.read_text())
 if not isinstance(old,dict) or 'pieces' not in old: continue
 new=json.loads((after/path.name).read_text())
 assert old['pieces']==new['pieces'] and old['draft']==new['draft'],path.name
 assert len(old['cues'])==len(new['cues']),path.name
 # O round-trip JSON pode mover um Double em 1 ULP; o SRT precisa ser idêntico.
 assert all(abs(a['start']-b['start'])<1e-9 and abs(a['end']-b['end'])<1e-9
            and a['translated']==b['translated'] for a,b in zip(old['cues'],new['cues'])),path.name
 original=''.join(r['source'] for r in old['draft'])
 final=''.join(r['source'] for r in new['cues'])
 previous=''.join(r['source'] for r in old['cues'])
 assert compact(original)==compact(final),path.name
 before_loss+=sum(max(0,original.count(c)-previous.count(c)) for c in punct)
 after_loss+=sum(max(0,original.count(c)-final.count(c)) for c in punct)
 assert old['srt']==new['srt'],path.name
 checked+=1
assert checked==27,checked
for name in ['pt-thanks','pt-thanks-rocko','pt-other','pt-silence','pt-noise','pt-clicks']:
 old=json.loads((here/'results/confirm-baseline'/(name+'.json')).read_text())
 new=json.loads((here/'results/confirm-candidate'/(name+'.json')).read_text())
 assert old['kept']==[],name
 assert bool(new['kept'])==name.startswith('pt-thanks'),name
for name in ['pt-thanks','pt-thanks-rocko']:
 for engine in ['apple','whisper','qwenLarge']:
  path=f'{name}-{engine}.json'
  old=json.loads((base/path).read_text());new=json.loads((here/'results/candidate'/path).read_text())
  assert old['pieces']==[],path
  assert compact(''.join(r['text'] for r in new['pieces'])).lower().rstrip('.!')=='obrigadoporassistir',path
report=dict(frozen_replays=checked,source_punctuation_lost_before=before_loss,source_punctuation_lost_after=after_loss,
            positive_capture_tests_before=0,positive_capture_tests_after=6,negative_controls_rejected=4,
            timing_and_displayed_translation_unchanged=True)
(here/'comparison.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(report)
