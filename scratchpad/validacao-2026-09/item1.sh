#!/bin/bash
# Item 1: anime-whisper x Qwen3-ASR 1.7B, pelo caminho do app (gate referencia).
# O anime-whisper entra no lugar do CLI do Qwen por um HOME falso (fakehome.sh).
cd "$(dirname "$0")/../.."
V=scratchpad/validacao-2026-09; R=$V/resultados/item1; mkdir -p $R
VE="Videos Exemplo"
TED="$VE/TEDにもの申す一一人前で上手にしゃべるのってそんなに大事ですか？ | Masahiko Abe | TEDxWasedaU"
run() { # rotulo video referencia
  ./.build/release/tradutor-verify referencia "$2" "$3" ja qwenLarge --saida $R/$1-qwen.srt --json $R/$1-qwen.json --diff > $R/$1-qwen.txt 2>&1
  AW_CHUNKS=30 CFFIXED_USER_HOME=$PWD/$V/fakehome AW_LOG=$PWD/$R/$1-aw.log \
    ./.build/release/tradutor-verify referencia "$2" "$3" ja qwenLarge --saida $R/$1-aw.srt --json $R/$1-aw.json --diff > $R/$1-aw.txt 2>&1
  AW_NGRAM=5 AW_CHUNKS=30 CFFIXED_USER_HOME=$PWD/$V/fakehome AW_LOG=$PWD/$R/$1-aw5.log \
    ./.build/release/tradutor-verify referencia "$2" "$3" ja qwenLarge --saida $R/$1-aw5.srt --json $R/$1-aw5.json --diff > $R/$1-aw5.txt 2>&1
}
run anime "$VE/video exemplo 2 (Conversa mais complexa).mp4" "$VE/video exemplo 2 (Conversa mais complexa).ja.srt"
run 9min "$VE/video exemplo conversa de pessoas.mp4" $R/../reguas/9min-ocr.srt
run ted "$TED.mp4" "$TED (legenda original do video).srt"
grep -H -E "legendas em|CER|oracao|legenda  |palavra" $R/*-qwen.txt $R/*-aw.txt
