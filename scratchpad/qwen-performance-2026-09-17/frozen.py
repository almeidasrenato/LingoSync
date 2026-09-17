"""Mede o CLI sobre o WAV já preparado pelo app, fixo em todos os tratamentos."""
import json
import os
from pathlib import Path
import subprocess
import time
import re
import textwrap
import sys

root = Path(__file__).resolve().parents[2]
out = Path(__file__).resolve().parent / 'frozen'
out.mkdir(exist_ok=True)
home = Path.home() / 'Library/Application Support/Tradutor/qwen'
files = {
    'ja-dificil': ('Video perca de fala japones.mp4', 'ja', 'Japanese'),
    'ja-musica': ('video exemplo 2 (Conversa mais complexa).mp4', 'ja', 'Japanese'),
    'en-conversa': ('video exemplo conversa de pessoas ingles.mp4', 'en', 'English'),
    'en-dialogo': ('video exemplo conversa de pessoas 2 ingles.mp4', 'en', 'English'),
    'ja-longo': ('video exemplo conversa de pessoas.mp4', 'ja', 'Japanese'),
}
for name in sys.argv[1:] or files:
    filename, lang, language = files[name]
    wav = out / f'{name}.wav'
    env = dict(os.environ, HF_HOME=str(home/'hf'), HF_HUB_OFFLINE='1')
    env.pop('TRADUTOR_QWEN_DRAFT', None)
    env.pop('MLX_METAL_FAST_SYNCH', None)
    if not wav.exists():
        command = [str(root/'.build/release/tradutor-verify'), 'fonte', str(root/'Videos Exemplo'/filename), lang, 'qwenLarge']
        with (out/f'{name}-capture.log').open('w') as log:
            subprocess.run(command, env=dict(env, TRADUTOR_QWEN_GUARDAR_WAV=str(wav)), stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
    rows = []
    for variant in os.environ.get('QWEN_VARIANTS', 'base1,fast1,fast2,base2').split(','):
        dest = out/f'{name}-{variant}'
        dest.mkdir(exist_ok=True)
        command = [str(home/'venv/bin/mlx-qwen3-asr'), '--model', 'Qwen/Qwen3-ASR-1.7B', '--language', language, '--timestamps', '-f', 'all', '-o', str(dest), '--no-progress', '--quiet', str(wav)]
        runenv = dict(env)
        if variant.startswith('fast'):
            runenv['MLX_METAL_FAST_SYNCH']='1'
        if variant.startswith('draft'):
            command += ['--draft-model', 'Qwen/Qwen3-ASR-0.6B', '--num-draft-tokens', '4']
        if variant.startswith('async'):
            command = [str(home/'venv/bin/python'), str(Path(__file__).with_name('async_runner.py')), *command[1:]]
        if variant.startswith(('wired', 'bounded', 'cache')):
            if variant.startswith(('bounded', 'cache')):
                runenv['QWEN_CACHE_LIMIT_MB'] = '512'
            if variant.startswith('cache'):
                runenv['QWEN_DISABLE_WIRE'] = '1'
            command = [str(home/'venv/bin/python'), str(Path(__file__).with_name('wired_runner.py')), *command[1:]]
        if variant.startswith('app'):
            source = (root/'Sources/TradutorCore/QwenEngine.swift').read_text()
            launcher = textwrap.dedent(re.search(r'private static let memoryLauncher = """\n(.*?)\n    """', source, re.S)[1])
            command = [str(home/'venv/bin/python'), '-c', launcher, *command[1:]]
        if variant == 'profile':
            command = [str(home/'venv/bin/python'), '-m', 'cProfile', '-o', str(dest/'profile.pstats'), '-m', 'mlx_qwen3_asr', *command[1:]]
        start = time.monotonic()
        with (dest/'run.log').open('w') as log:
            subprocess.run(['/usr/bin/time', '-l', *command], env=runenv, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
        seconds = time.monotonic()-start
        metrics = (dest/'run.log').read_text()
        rss = re.search(r'(\d+)\s+maximum resident set size', metrics)
        footprint = re.search(r'(\d+)\s+peak memory footprint', metrics)
        rows.append({'variant': variant, 'seconds': seconds, 'max_rss_bytes': int(rss[1]) if rss else None, 'peak_footprint_bytes': int(footprint[1]) if footprint else None})
        print(f'{name} {variant}: {seconds:.2f}s', flush=True)
    (out/f'{name}-times-{rows[0]["variant"]}.json').write_text(json.dumps(rows, indent=2))
    reference = next((r['variant'] for r in rows if r['variant'].startswith('base')), 'base1')
    baseline = (out/f'{name}-{reference}'/f'{name}.srt').read_bytes()
    baseline_json = json.loads((out/f'{name}-{reference}'/f'{name}.json').read_text())
    for row in rows:
        other = (out/f'{name}-{row["variant"]}'/f'{name}.srt').read_bytes()
        parsed = json.loads((out/f'{name}-{row["variant"]}'/f'{name}.json').read_text())
        print(f'  {row["variant"]}: SRT idêntico {baseline==other}; JSON idêntico {baseline_json==parsed}', flush=True)
    assert all((out/f'{name}-{row["variant"]}'/f'{name}.srt').read_bytes() == baseline
               and json.loads((out/f'{name}-{row["variant"]}'/f'{name}.json').read_text()) == baseline_json
               for row in rows), 'A variante mudou texto ou tempos: não aprovar'
