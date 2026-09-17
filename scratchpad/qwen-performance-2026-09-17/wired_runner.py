"""Experimento nativo de residência da memória: sem mudar operações do modelo."""
import os
import mlx.core as mx
from mlx_qwen3_asr.cli import main

info = mx.device_info()
# Não muda o limite do sistema, e deixa pelo menos metade da RAM para o macOS.
if os.environ.get('QWEN_DISABLE_WIRE') != '1':
    mx.set_wired_limit(min(info['max_recommended_working_set_size'], info['memory_size']//2))
if os.environ.get('QWEN_CACHE_LIMIT_MB'):
    mx.set_cache_limit(int(os.environ['QWEN_CACHE_LIMIT_MB']) * 1024**2)
main()
