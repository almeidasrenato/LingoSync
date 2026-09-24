#!/bin/bash
# Autoteste da janela "Assistir com legenda", em sequência.
cd "$(dirname "$0")/../.."
OUT=scratchpad/transcricao-ted/resultados/janela; mkdir -p $OUT
TED="TEDにもの申す一一人前で上手にしゃべるのってそんなに大事ですか？ | Masahiko Abe | TEDxWasedaU.mp4"
roda() { # rotulo video origem destino flags...
  local r="$1" v="$2" o="$3" d="$4"; shift 4
  rm -f /tmp/tradutor-studio.txt
  open -n build/Tradutor.app --args --selftest-studio "Videos Exemplo/$v" $o $d "$@"
  local limite=$((SECONDS + 1500))
  until command grep -qE "^(PASSOU|REPROVOU|FALHA)|[0-9]+ falhas|teste ok" /tmp/tradutor-studio.txt 2>/dev/null || [ $SECONDS -gt $limite ]; do sleep 5; done
  sleep 3; cp /tmp/tradutor-studio.txt $OUT/$r.txt 2>/dev/null; cp /tmp/studio.png $OUT/$r.png 2>/dev/null
  cp /tmp/studio-locutores.png $OUT/$r-locutores.png 2>/dev/null
  echo "$r: $(tail -1 $OUT/$r.txt)"
}
roda ted-apple "$TED" ja pt --tradutor apple --motor apple
roda anime-qwenL-sortformer "video exemplo 2 (Conversa mais complexa).mp4" ja pt --tradutor apple --motor qwenLarge --locutores --modelo sortformer
roda en2-qwen-clustering "video exemplo conversa de pessoas 2 ingles.mp4" en pt --tradutor apple --motor qwen --locutores --modelo clustering
roda ja9-whisper-sortformer "video exemplo conversa de pessoas.mp4" ja pt --tradutor apple --motor whisper --locutores
echo FIM
