#!/bin/bash
# Identificação de quem fala: sem, Sortformer e agrupamento; antes x depois.
cd "$(dirname "$0")/../.."
OUT=scratchpad/transcricao-ted/resultados/locutores; mkdir -p $OUT
ANTES=/private/tmp/claude-501/base-wt/.build/release/tradutor-verify
DEPOIS=./.build/release/tradutor-verify
TED="TEDにもの申す一一人前で上手にしゃべるのってそんなに大事ですか？ | Masahiko Abe | TEDxWasedaU.mp4"
run() { # rotulo video origem tradutor versoes modelos motores...
  local r="$1" v="$2" l="$3" t="$4" vs="$5" ms="$6"; shift 6
  for m in "$@"; do for x in $vs; do for mod in $ms; do
    f="$OUT/$r-$m-$mod-$x.json"; [ -s "$f" ] && continue
    B=$DEPOIS; [ $x = antes ] && B=$ANTES
    if [ $mod = sem ]; then $B gerar "Videos Exemplo/$v" $l pt $m $t "$f"
    else $B gerar "Videos Exemplo/$v" $l pt $m $t "$f" --locutores --modelo $mod; fi > /dev/null 2>&1
    echo "$r $m $mod $x: $([ -s "$f" ] && echo ok || echo FALHOU)"
  done; done; done
}
run anime "video exemplo 2 (Conversa mais complexa).mp4" ja apple "antes depois" "sem sortformer clustering" apple qwenLarge whisper qwen
run en2 "video exemplo conversa de pessoas 2 ingles.mp4" en apple "antes depois" "sem sortformer clustering" apple qwenLarge parakeet
run ja9 "video exemplo conversa de pessoas.mp4" ja apple "antes depois" "sem sortformer clustering" apple qwenLarge whisper
run ted "$TED" ja transcricao "depois" "sem sortformer clustering" apple qwenLarge whisper
echo FIM
