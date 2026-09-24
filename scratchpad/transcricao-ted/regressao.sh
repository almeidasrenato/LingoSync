#!/bin/bash
# Antes (commit 57e4c82, worktree) x depois, nos outros vídeos de exemplo.
cd "$(dirname "$0")/../.."
OUT=scratchpad/transcricao-ted/resultados/regressao; mkdir -p $OUT
ANTES=/private/tmp/claude-501/base-wt/.build/release/tradutor-verify
DEPOIS=./.build/release/tradutor-verify
run() { # video idioma rotulo motores...
  local v="$1" l="$2" r="$3"; shift 3
  for m in "$@"; do
    $ANTES gerar "Videos Exemplo/$v" $l $m "$OUT/$r-$m-antes.srt" > /dev/null 2>&1
    $DEPOIS referencia "Videos Exemplo/$v" "$OUT/$r-$m-antes.srt" $l $m --saida "$OUT/$r-$m-depois.srt" > "$OUT/$r-$m.txt" 2>&1
    echo "$r $m: $(grep -E 'CER|palavra' "$OUT/$r-$m.txt" | tr '\n' ' ')"
  done
}
run "video exemplo conversa de pessoas 2 ingles.mp4" en en2 apple parakeet whisper qwenLarge
run "video exemplo conversa de pessoas ingles.mp4" en en1 apple parakeet whisper qwenLarge
run "video exemplo conversa de pessoas.mp4" ja ja9min apple whisper qwen qwenLarge
run "video exemplo 2 (Conversa mais complexa).mp4" ja jaanime apple whisper qwen qwenLarge
run "Video perca de fala japones.mp4" ja japerda apple whisper qwen qwenLarge
