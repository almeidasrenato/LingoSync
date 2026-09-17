"""Resume os pares finais sem misturar execução de perfil com benchmark."""
import json
from pathlib import Path
from statistics import mean

root = Path(__file__).resolve().parent / 'frozen'
for name, run, prefix in [('ja-dificil','base11','app'), ('ja-musica','base9','bounded'),
                           ('en-conversa','base9','bounded'), ('en-dialogo','base11','app'),
                           ('ja-longo','base11','app')]:
    path = root / f'{name}-times-{run}.json'
    if not path.exists():
        print(name, 'pendente'); continue
    rows = json.loads(path.read_text())
    base = [r for r in rows if r['variant'].startswith('base')]
    fast = [r for r in rows if r['variant'].startswith(prefix)]
    before, after = mean(r['seconds'] for r in base), mean(r['seconds'] for r in fast)
    before_mem = max(r['peak_footprint_bytes'] for r in base) / 1024**3
    after_mem = max(r['peak_footprint_bytes'] for r in fast) / 1024**3
    print(f'{name}: {before:.2f} → {after:.2f}s ({100*(1-after/before):.1f}%); '
          f'pico {before_mem:.2f} → {after_mem:.2f} GiB')
