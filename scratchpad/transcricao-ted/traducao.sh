#!/bin/bash
# Tradução antes x depois (x depois sem o teto de 40 caracteres), mesmo tradutor.
cd "$(dirname "$0")/../.."
OUT=scratchpad/transcricao-ted/resultados/traducao; mkdir -p $OUT
ANTES=/private/tmp/claude-501/base-wt/.build/release/tradutor-verify
DEPOIS=./.build/release/tradutor-verify
TED="TEDにもの申す一一人前で上手にしゃべるのってそんなに大事ですか？ | Masahiko Abe | TEDxWasedaU.mp4"
run() { # rotulo video origem tradutor variantes motores...
  local r="$1" v="$2" l="$3" t="$4" vs="$5"; shift 5
  for m in "$@"; do for x in $vs; do
    f="$OUT/$r-$m-$t-$x.json"; [ -s "$f" ] && continue
    case $x in
      antes) $ANTES gerar "Videos Exemplo/$v" $l pt $m $t "$f" ;;
      depois) $DEPOIS gerar "Videos Exemplo/$v" $l pt $m $t "$f" ;;
      semteto) TRADUTOR_SEM_TETO_DENSO=1 $DEPOIS gerar "Videos Exemplo/$v" $l pt $m $t "$f" ;;
    esac > /dev/null 2>&1
    echo "$r $m $t $x: $([ -s "$f" ] && echo ok || echo FALHOU)"
  done; done
}
run ted "$TED" ja apple "antes depois semteto" apple whisper qwen qwenLarge
run ted "$TED" ja google "antes depois semteto" apple qwenLarge
run ja9 "video exemplo conversa de pessoas.mp4" ja apple "antes depois semteto" apple qwenLarge
run anime "video exemplo 2 (Conversa mais complexa).mp4" ja apple "antes depois semteto" apple qwenLarge
run perda "Video perca de fala japones.mp4" ja apple "antes depois semteto" apple qwenLarge
run en1 "video exemplo conversa de pessoas ingles.mp4" en apple "antes depois" apple parakeet qwenLarge
run en2 "video exemplo conversa de pessoas 2 ingles.mp4" en apple "antes depois" apple parakeet qwenLarge
run en1 "video exemplo conversa de pessoas ingles.mp4" en apple "depois" qwen
echo FIM
