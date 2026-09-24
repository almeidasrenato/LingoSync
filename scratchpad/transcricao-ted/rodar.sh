#!/bin/bash
# Uso: scratchpad/transcricao-ted/rodar.sh <pasta> [motores...]
cd "$(dirname "$0")/../.."
OUT="scratchpad/transcricao-ted/resultados/$1"; shift
MOTORES="${@:-apple whisper qwen qwenLarge}"
mkdir -p "$OUT"
V="Videos Exemplo/TEDにもの申す一一人前で上手にしゃべるのってそんなに大事ですか？ | Masahiko Abe | TEDxWasedaU.mp4"
R="Videos Exemplo/TEDにもの申す一一人前で上手にしゃべるのってそんなに大事ですか？ | Masahiko Abe | TEDxWasedaU (legenda original do video).srt"
for m in $MOTORES; do
  ./.build/release/tradutor-verify referencia "$V" "$R" ja $m --saida "$OUT/$m.srt" --json "$OUT/$m.json" --diff > "$OUT/$m.txt" 2>&1
done
grep -h -E "^== |CER|oracao|legenda  |tempo|tamanho" "$OUT"/*.txt
