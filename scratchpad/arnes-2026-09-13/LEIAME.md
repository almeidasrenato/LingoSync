# Arnês de medição — 13/09/2026

Como as comparações "antes e depois" desta rodada foram feitas. Os binários e
os vídeos ficaram em `/tmp/conclusao-tradutor-20260913/`, que foi apagado; o
que está aqui é o que não dá para refazer sozinho.

## Por que existe

Comparar duas gerações do app não serve para medir mudança de agrupamento: o
reconhecimento da Apple não repete o mesmo texto duas vezes ("homing" numa
execução, "humming" na outra), e essa variação é maior que o efeito que se
quer medir.

`MeasuredApple.swift` resolve isso carregando o áudio **uma vez**, rodando o
`SpeechAnalyzer` **uma vez**, e agrupando o mesmo resultado das duas maneiras
— a antiga e a nova. A diferença que sobra é só a do código.

## Arquivos

- `Measure.swift` — o executável. Modos: `phrases` (agrupamento, antes contra
  depois), `live` (o caminho ao vivo sobre um arquivo), `gain` e `gain-low`
  (ganho de volume por motor), `diargain` (identificação de vozes com e sem
  ganho).
- `MeasuredApple.swift` — as duas versões do `phrases` lado a lado. **Ao mexer
  no `AppleSpeechTranscriber`, a cópia `received` daqui tem de receber a mesma
  mudança**, senão a comparação mede o código velho.
- `OldTracker.swift`, `ReceivedTracker.swift` — o mesmo para o confirmador de
  prefixo.
- `Studio-final.swift`, `Studio-received.swift` — idem para a janela.
- `PlayerRace.swift`, `Noise.swift`, `Replay.swift` — casos isolados.
- `compile.json` — a linha de comando do `swiftc`, com os caminhos de módulo
  do SwiftPM. Recompilar é `python3 -c "import json,subprocess;
  subprocess.run(json.load(open('compile.json')))"`.
- `matriz_final.py`, `sub_matriz.py`, `cjk_matriz.py`,
  `verifica_progresso.py` — as matrizes dos dois fluxos, que abrem o `.app`
  com `--selftest-studio` e `--selftest-job`.

## Armadilha

`compile.json` tem caminhos absolutos para `.build/` e para os artefatos do
FluidAudio. Depois de um `swift package purge` ou de trocar de máquina, eles
mudam — refaça a lista a partir de um `swift build -v`.
