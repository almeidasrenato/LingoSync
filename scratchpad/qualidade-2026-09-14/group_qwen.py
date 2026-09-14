import json
from pathlib import Path
from mlx_qwen3_asr.transcribe import TranscriptionResult
import mlx_qwen3_asr.writers as writers
out=Path('/tmp/tradutor-qualidade-grupos'); out.mkdir(exist_ok=True)
original=writers.group_subtitle_segments
for name in ['ja','en']:
 data=json.loads(Path('/tmp/qwen-estudo-20260914/'+name+'-normal.json').read_text())
 result=TranscriptionResult(**data)
 for mode in ['baseline','frases']:
  def group(segments,**kwargs):
   return original(segments,**kwargs,**({'max_words':999,'max_chars':150,'max_duration_sec':7.0} if mode=='frases' else {}))
  writers.group_subtitle_segments=group
  writers.write_srt(result,str(out/(name+'-'+mode+'.srt')))
 print(name)
