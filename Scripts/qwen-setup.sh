#!/bin/bash
# Instala o Qwen3-ASR 0.6B, o unico reconhecedor do app que nao roda em CoreML.
#
# Nao existe port CoreML dele; o que existe e MLX com Python. Entao ele fica
# fora do .app, num ambiente proprio ao lado dos modelos, e o app so oferece
# esse motor quando este ambiente existe. Sem ele, nada muda no app.
#
#   Scripts/qwen-setup.sh            instala o 0.6B
#   Scripts/qwen-setup.sh --grande   instala tambem o 1.7B (3,4 GB a mais)
#   Scripts/qwen-setup.sh --remove   apaga tudo
set -euo pipefail

RAIZ="$HOME/Library/Application Support/Tradutor/qwen"

if [ "${1:-}" = "--remove" ]; then
    rm -rf "$RAIZ"
    echo "removido: $RAIZ"
    exit 0
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "precisa do uv para criar o ambiente:  brew install uv"
    exit 1
fi

echo "ambiente em $RAIZ"
mkdir -p "$RAIZ"
uv venv --python 3.12 "$RAIZ/venv"
# O extra `aligner` traz o nagisa, sem o qual o japones nao ganha tempo por
# palavra — e tempo por palavra e o que a legenda precisa.
uv pip install --python "$RAIZ/venv/bin/python" "mlx-qwen3-asr[aligner]"

# Baixa o modelo agora, para a primeira legenda nao esperar 1,2 GB de rede.
# HF_HOME dentro da pasta: nada vai para ~/.cache.
echo "baixando Qwen3-ASR-0.6B (1,2 GB)"
HF_HOME="$RAIZ/hf" "$RAIZ/venv/bin/hf" download Qwen/Qwen3-ASR-0.6B >/dev/null

if [ "${1:-}" = "--grande" ]; then
    echo "baixando Qwen3-ASR-1.7B (3,4 GB)"
    HF_HOME="$RAIZ/hf" "$RAIZ/venv/bin/hf" download Qwen/Qwen3-ASR-1.7B >/dev/null
fi

echo "pronto. o app passa a oferecer 'Qwen3-ASR 0.6B' nos modos de video."
du -sh "$RAIZ"
