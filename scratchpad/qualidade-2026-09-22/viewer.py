"""Autoteste em bundle próprio; só cópias temporárias dos exemplos são usadas."""
import json, plistlib, shutil, subprocess, tempfile
from pathlib import Path
here=Path(__file__).resolve().parent;root=here.parent.parent
name='Tradutor Qualidade'
info=plistlib.loads((root/'Resources/app-Info.plist').read_bytes())
info.update(CFBundleExecutable=name,CFBundleName=name,CFBundleDisplayName=name,
            CFBundleIdentifier='app.tradutor.qualidade')
plist=root/'build/qualidade-Info.plist';plist.parent.mkdir(exist_ok=True)
plist.write_bytes(plistlib.dumps(info))
subprocess.run(['Scripts/bundle.sh','TradutorApp',name,str(plist.relative_to(root)),'release'],cwd=root,check=True)
app=root/'build'/(name+'.app')
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
dest=here/'results/viewer';dest.mkdir(parents=True,exist_ok=True)
results=[]
with tempfile.TemporaryDirectory(prefix='tradutor-quality-viewer-') as tmp:
 for sample,media,lang,target,engine in [
  ('pt',here/'audio/pt-clean.wav','pt','en','apple'),
  ('pt',here/'audio/pt-clean.wav','pt','en','whisper'),
  ('pt',here/'audio/pt-clean.wav','pt','en','qwenLarge'),
  ('ja',root/'Videos Exemplo/video exemplo 2 (Conversa mais complexa).mp4','ja','pt','qwenLarge')]:
  tag=sample+'-'+engine
  previous=dest/(tag+'.txt')
  if previous.exists() and previous.read_text().rstrip().endswith('PASSOU'):
   results.append(dict(sample=sample,engine=engine,passed=True));continue
  if previous.exists(): shutil.copy2(previous,dest/(tag+'-initial.txt'))
  copy=Path(tmp)/(tag+media.suffix);shutil.copy2(media,copy)
  with (dest/(tag+'.log')).open('w') as out:
   p=subprocess.run([str(app/'Contents/MacOS'/name),'--selftest-studio',str(copy),lang,target,
                     '--motor',engine,'--tradutor','gemini'],cwd=root,stdout=out,stderr=subprocess.STDOUT,timeout=600)
  report=Path('/tmp/tradutor-studio.txt');text=report.read_text()
  (dest/(tag+'.txt')).write_text(text)
  if Path('/tmp/studio.png').exists(): shutil.copy2('/tmp/studio.png',dest/(tag+'.png'))
  passed=p.returncode==0 and text.rstrip().endswith('PASSOU')
  results.append(dict(sample=sample,engine=engine,passed=passed))
  print(tag,'PASSOU' if passed else 'FALHA',flush=True)
(here/'viewer-checks.json').write_text(json.dumps(results,indent=2)+'\n')
assert all(r['passed'] for r in results),results
