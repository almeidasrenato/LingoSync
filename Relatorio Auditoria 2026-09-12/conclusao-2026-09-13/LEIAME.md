# Conclusão de 13/09/2026 — o que cada arquivo é

## O que vale como resultado

- `matriz-final/` — **24 execuções** dos dois fluxos: 4 vídeos × janela e item
  de menu × Apple × com e sem locutores, mais Whisper, Parakeet, Qwen 0.6B e
  Qwen 1.7B, mais um vídeo de 40 s atenuado em 40 dB. 22 passaram de primeira;
  as 2 reprovações eram a verificação de progresso no vídeo curto demais para
  o Whisper relatar fração alguma, corrigida depois (`progresso.json`).
- `matriz-espaco/` — 10 execuções conferindo o conserto do espaço espúrio.
- `matriz-cjk/` — 4 execuções conferindo a largura de linha por idioma.
- `phrases-final-*.json` — agrupamento antes contra depois, **com o mesmo
  reconhecimento dos dois lados**. É o número que vale: comparar duas gerações
  mediria a variação do reconhecedor, que é maior que o efeito.
- `prefix-comparison.json` — o mesmo para o confirmador de prefixo ao vivo.
- `gain-*.json`, `gain-low-*.json`, `diargain-summary.json` — ganho de volume,
  por motor e na identificação de vozes.
- `player-comparison.json` — a corrida do player.

## O que NÃO vale

`estado-intermediario/` guarda arquivos de estados que foram superados no meio
do trabalho. **Não tire conclusão deles.** Em particular:

- `gates.json` mostra o gate `tempos` como FALHA. Ele foi corrigido logo
  depois e passa; o arquivo é de antes.
- `matrix.json` tem 2 execuções, não 24: é a matriz que morreu junto com a
  sessão que a lançou. A boa é `matriz-final/matriz.json`.
- `measurements.json` e `baseline-hashes.json` são de um instantâneo de
  código que o histórico do git já cobre.
- `studio-ja-longo-apple-sortformer/` e `job-ja-longo-apple-sortformer/` são
  as duas execuções dessa matriz morta.

## O que saiu daqui

`medicoes-claude/v/` guardava 194 MB de cópia byte a byte dos vídeos de
`Videos Exemplo/`. Apagado — os originais estão lá.

O arnês que produziu os números `phrases-*` e `prefix-*` está em
`scratchpad/arnes-2026-09-13/`, com o seu próprio LEIAME.
