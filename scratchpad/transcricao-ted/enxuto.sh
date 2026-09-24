#!/bin/bash
# Lote enxuto: tradução antes x final nos outros vídeos, e quem fala.
cd "$(dirname "$0")/../.."
R=scratchpad/transcricao-ted/resultados
ANTES=/private/tmp/claude-501/base-wt/.build/release/tradutor-verify
FINAL=./.build/release/tradutor-verify
TED="TEDにもの申す一一人前で上手にしゃべるのってそんなに大事ですか？ | Masahiko Abe | TEDxWasedaU.mp4"
um() { # saida binario video origem motor tradutor [--locutores --modelo m]
  local f="$1" b="$2" v="$3" l="$4" m="$5" t="$6"; shift 6
  [ -s "$f" ] && return
  $b gerar "Videos Exemplo/$v" $l pt $m $t "$f" "$@" > /dev/null 2>&1
  [ -s "$f" ] || { sleep 20; $b gerar "Videos Exemplo/$v" $l pt $m $t "$f" "$@" > /dev/null 2>&1; }
  echo "$(basename $f): $([ -s "$f" ] && echo ok || echo FALHOU)"
}
mkdir -p $R/traducao $R/locutores
for m in apple qwenLarge; do
  for par in "ja9:video exemplo conversa de pessoas.mp4:ja" "anime:video exemplo 2 (Conversa mais complexa).mp4:ja" \
             "perda:Video perca de fala japones.mp4:ja" "en1:video exemplo conversa de pessoas ingles.mp4:en" \
             "en2:video exemplo conversa de pessoas 2 ingles.mp4:en"; do
    IFS=: read r v l <<< "$par"
    um $R/traducao/$r-$m-apple-antes.json $ANTES "$v" $l $m apple
    um $R/traducao/$r-$m-apple-final.json $FINAL "$v" $l $m apple
  done
done
for m in apple qwenLarge; do
  for par in "anime:video exemplo 2 (Conversa mais complexa).mp4:ja" "en2:video exemplo conversa de pessoas 2 ingles.mp4:en" \
             "ja9:video exemplo conversa de pessoas.mp4:ja"; do
    IFS=: read r v l <<< "$par"
    for mod in sortformer clustering; do
      um $R/locutores/$r-$m-$mod-final.json $FINAL "$v" $l $m apple --locutores --modelo $mod
    done
    um $R/locutores/$r-$m-sortformer-antes.json $ANTES "$v" $l $m apple --locutores --modelo sortformer
  done
done
for mod in sortformer clustering; do
  um $R/locutores/ted-apple-$mod-final.json $FINAL "$TED" ja apple transcricao --locutores --modelo $mod
done
um $R/locutores/ted-apple-sem-final.json $FINAL "$TED" ja apple transcricao
echo FIM
