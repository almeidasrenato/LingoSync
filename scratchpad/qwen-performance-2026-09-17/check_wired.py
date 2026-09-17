"""Exercita o launcher real do Swift com APIs MLX simuladas, sem GPU/modelos."""
import re
import sys
import textwrap
from pathlib import Path
from types import ModuleType
from unittest.mock import patch

root = Path(__file__).resolve().parents[2]
source = (root/'Sources/TradutorCore/QwenEngine.swift').read_text()
launcher = textwrap.dedent(re.search(r'private static let memoryLauncher = """\n(.*?)\n    """', source, re.S)[1])


def check():
    gib = 1024**3
    for ram, recommended, failure, expected in [
        (16*gib, 12*gib, None, 8*gib),
        (8*gib, 3*gib, None, 3*gib),
        (64*gib, 48*gib, None, 32*gib),
        (16*gib, 12*gib, RuntimeError('limit unavailable'), 8*gib),
        (16*gib, 12*gib, ValueError('limit unavailable'), 8*gib),
        (0, 0, AttributeError('old MLX'), None),
        (0, 0, KeyError('old device info'), None),
    ]:
        limits, calls, caches = [], [], []
        mx, mlx, cli, package = [ModuleType(n) for n in ['mlx.core', 'mlx', 'mlx_qwen3_asr.cli', 'mlx_qwen3_asr']]
        def device_info():
            if isinstance(failure, (AttributeError, KeyError)):
                raise failure
            return {'memory_size': ram, 'max_recommended_working_set_size': recommended}
        def set_wired_limit(limit):
            limits.append(limit)
            if failure:
                raise failure
        mx.set_cache_limit = lambda limit: caches.append(limit)
        mx.device_info = device_info
        mx.set_wired_limit = set_wired_limit
        mlx.core = mx
        package.cli = cli
        cli.main = lambda: calls.append(sys.argv.copy())
        arguments = ['-c', '--model', 'Qwen/Qwen3-ASR-1.7B', '--language', 'Japanese', '/pasta com espaços/áudio.wav']
        with patch.dict(sys.modules, {'mlx': mlx, 'mlx.core': mx, 'mlx_qwen3_asr': package, 'mlx_qwen3_asr.cli': cli}), patch.object(sys, 'argv', arguments):
            exec(launcher, {})
        assert caches == [512 * 1024**2]
        assert limits == ([] if expected is None else [expected])
        assert calls == [arguments], 'CLI precisa rodar uma vez, com todos os argumentos intactos'
    # Uma instalação antiga pode não expor nenhum dos controles em mx.core.
    del mx.set_cache_limit
    calls.clear()
    with patch.dict(sys.modules, {'mlx': mlx, 'mlx.core': mx, 'mlx_qwen3_asr': package, 'mlx_qwen3_asr.cli': cli}), patch.object(sys, 'argv', arguments):
        exec(launcher, {})
    assert calls == [arguments]
    print('OK: cache de 512 MiB, residência até meia RAM/teto do dispositivo, fallback e argumentos preservados')


if __name__ == '__main__':
    check()
