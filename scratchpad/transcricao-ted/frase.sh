#!/bin/bash
# Tradução por frase x por legenda, sobre o MESMO rascunho (gerar --ab).
cd "$(dirname "$0")/../.."
OUT=scratchpad/transcricao-ted/resultados/frase; mkdir -p $OUT
B=./.build/release/tradutor-verify
TED="TEDにもの申す一一人前で上手にしゃべるのってそんなに大事ですか？ | Masahiko Abe | TEDxWasedaU.mp4"
ab() { # rotulo video origem motor tradutor [extra...]
  local r="$1" v="$2" l="$3" m="$4" t="$5"; shift 5
  local f="$OUT/$r-$m-$t"; [ -s "$f-legenda.json" ] && return
  $B gerar "Videos Exemplo/$v" $l pt $m $t "$f-frase.json" --ab "$f-legenda.json" "$@" > /dev/null 2>&1 \
    || { sleep 20; $B gerar "Videos Exemplo/$v" $l pt $m $t "$f-frase.json" --ab "$f-legenda.json" "$@" > /dev/null 2>&1; }
  echo "$r $m $t $*: $([ -s "$f-legenda.json" ] && echo ok || echo FALHOU)"
}
for m in apple whisper qwen qwenLarge; do ab ted "$TED" ja $m apple; done
ab ted "$TED" ja qwenLarge google
ab ja9 "video exemplo conversa de pessoas.mp4" ja apple apple
ab ja9 "video exemplo conversa de pessoas.mp4" ja qwenLarge apple
ab ja9loc "video exemplo conversa de pessoas.mp4" ja qwenLarge apple --locutores --modelo sortformer
ab anime "video exemplo 2 (Conversa mais complexa).mp4" ja qwenLarge apple
ab en1 "video exemplo conversa de pessoas ingles.mp4" en apple apple
ab en2 "video exemplo conversa de pessoas 2 ingles.mp4" en qwenLarge apple
echo FIM
