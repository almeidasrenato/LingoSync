#!/bin/bash
# Item 2: separação de voz antes do reconhecimento.
# Cada vídeo vira WAV 16 kHz de três jeitos (original, htdemucs, roformer) e
# os três passam pelo mesmo `gerar --locutores` do app: a única diferença
# entre as colunas é a separação.
cd "$(dirname "$0")/../.."
V=scratchpad/validacao-2026-09; R=$V/resultados/item2; mkdir -p $R/audio $R/gerar
VE="Videos Exemplo"
declare -a NOMES=(anime 9min en1 en2)
declare -a VIDEOS=("$VE/video exemplo 2 (Conversa mais complexa).mp4" "$VE/video exemplo conversa de pessoas.mp4" \
  "$VE/video exemplo conversa de pessoas ingles.mp4" "$VE/video exemplo conversa de pessoas 2 ingles.mp4")
declare -a LINGUAS=(ja ja en en)
for i in 0 1 2 3; do for m in original htdemucs roformer; do
  f=$R/audio/${NOMES[$i]}-$m.wav; [ -s $f ] && continue
  $V/venv2/bin/python $V/separa.py "${VIDEOS[$i]}" $m $f 2>/dev/null | tee -a $R/separacao-tempos.txt
done; done
for i in 0 1 2 3; do for m in original htdemucs roformer; do for e in apple qwenLarge; do for d in sortformer clustering; do
  f=$R/gerar/${NOMES[$i]}-$m-$e-$d.json; [ -s $f ] && continue
  ./.build/release/tradutor-verify gerar $R/audio/${NOMES[$i]}-$m.wav ${LINGUAS[$i]} pt $e transcricao $f --locutores --modelo $d > /dev/null 2>&1
  echo "${NOMES[$i]} $m $e $d: $(python3 -c "import json;d=json.load(open('$f'));print(len(d['legendas']),'legendas',round(d['segundos'],1),'s')" 2>/dev/null || echo FALHOU)"
done; done; done; done
echo FIM
