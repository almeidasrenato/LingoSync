"""Compara a mesma entrada pelo caminho do app; nunca escreve junto ao vídeo."""
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
out = Path(__file__).resolve().parent / 'results'
out.mkdir(exist_ok=True)
files = {
    'ja-dificil': ('Video perca de fala japones.mp4', 'ja'),
    'ja-musica': ('video exemplo 2 (Conversa mais complexa).mp4', 'ja'),
    'en-conversa': ('video exemplo conversa de pessoas ingles.mp4', 'en'),
    'en-dialogo': ('video exemplo conversa de pessoas 2 ingles.mp4', 'en'),
    'ja-longo': ('video exemplo conversa de pessoas.mp4', 'ja'),
}
for name in sys.argv[1:] or files:
    filename, language = files[name]
    for variant in os.environ.get('QWEN_VARIANTS', 'base,fast').split(','):
        target = out / f'{name}-{variant}.json'
        env = dict(os.environ)
        env.pop('TRADUTOR_QWEN_DRAFT', None)
        env.pop('MLX_METAL_FAST_SYNCH', None)
        if variant.startswith('fast'):
            env['MLX_METAL_FAST_SYNCH'] = '1'
        command = [str(root / '.build/release/tradutor-verify'), 'fonte',
                   str(root / 'Videos Exemplo' / filename), language, 'qwenLarge', '--json', str(target)]
        with target.with_suffix('.log').open('w') as log:
            subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
        data = json.loads(target.read_text())
        print(f'{name} {variant}: {data["seconds"]:.2f}s; {len(data["pieces"])} trechos', flush=True)
    base = json.loads((out / f'{name}-base.json').read_text())
    fast = json.loads((out / f'{name}-fast.json').read_text())
    print(f'  trechos idênticos: {base["pieces"] == fast["pieces"]}; SRT idêntico: {base["srt"] == fast["srt"]}; '
          f'ganho: {100*(1-fast["seconds"]/base["seconds"]):.1f}%', flush=True)
