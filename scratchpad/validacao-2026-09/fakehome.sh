#!/bin/bash
# Monta um HOME falso em que o motor qwenLarge do app roda o aw_shim.py.
# Só symlinks para leitura; nada é escrito na pasta real do app.
# Uso: CFFIXED_USER_HOME=$PWD/fakehome ../../.build/release/tradutor-verify ... qwenLarge
cd "$(dirname "$0")"
V=$PWD; REAL="$HOME/Library/Application Support/Tradutor"
F="$V/fakehome/Library/Application Support/Tradutor"
mkdir -p "$F/models" "$F/qwen/venv/bin" "$F/qwen/hf/hub/models--Qwen--Qwen3-ASR-1.7B" "$F/qwen/hf/hub/models--Qwen--Qwen3-ASR-0.6B"
for d in "$REAL/models/"*; do ln -sfn "$d" "$F/models/$(basename "$d")"; done
ln -sfn "$REAL/speaker-diarization" "$F/speaker-diarization"
ln -sfn "$REAL/qwen/hf/hub/models--Qwen--Qwen3-ForcedAligner-0.6B" "$F/qwen/hf/hub/models--Qwen--Qwen3-ForcedAligner-0.6B"
for b in python mlx-qwen3-asr; do
  cat > "$F/qwen/venv/bin/$b" <<SH
#!/bin/bash
[ "\$1" = "-c" ] && shift 2
exec "$V/venv/bin/python" "$V/aw_shim.py" "\$@"
SH
  chmod +x "$F/qwen/venv/bin/$b"
done
