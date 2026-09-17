# Tradutor Instantâneo

App macOS que captura o áudio de um aplicativo ou do microfone, transcreve e
traduz em tempo real, e gera legendas `.srt` de arquivos de vídeo. Tudo local, sem API paga,
sem chave, sem conta — exceto os tradutores de rede, que são opção do usuário.

Alvo: Apple Silicon, macOS 15+. Medido num **MacBook Air M5, 16 GB**.

---

## Construir e testar

Command Line Tools bastam; Xcode não é preciso.

```bash
swift build -c release
Scripts/bundle.sh TradutorApp "Tradutor" Resources/app-Info.plist release
Scripts/bundle.sh tradutor-probe "Tradutor Probe" Resources/probe-app-Info.plist release
open build/Tradutor.app
```

Não há `swift test`: Command Line Tools não trazem `Testing` nem `XCTest`. As
verificações vivem dentro dos binários.

### `tradutor-verify`

Sem áudio no argumento, não carregam modelo e rodam em milissegundos.

| Comando | O que prova |
|---|---|
| `prefixo` | confirmação de prefixo estável; `Tokens.split` em CJK |
| `frases` | corte em frases, sobreposição, tokens |
| `quebra` | quebra de linha, incluindo o travessão do locutor |
| `tempos` | tempos, tetos de legenda, ganho de volume, lote que falha |
| `formatos` | arquivo sem extensão, formato recusado |
| `legendas` | leitura de `.srt` |
| `faixas` | vídeo com duas faixas: escolha pelo idioma |
| `modelos` | trocar de idioma não pode recarregar modelo |
| `lotes` | tamanho de lote e custo por string |
| `sobreposicao` | se reenviar contexto melhora a tradução |
| `motores` | limiares do Whisper, motores, retentativa do ANE |
| `locutores` | atribuição de quem fala, sem modelo |
| `deepl` | blocos, link, leitura atrasada |
| `webapi` | Google: repartição por bytes de URL, código, escape |
| `vivo <audio>` | o que o VAD do tempo real deixa passar |
| `captura` | só transcrever, exportação, lista de captura e de microfones |

Com áudio ou vídeo:

```bash
tradutor-verify fonte <video> [idioma] [motor]        # as falas reconhecidas
tradutor-verify traduzir <linhas.txt> [orig] [dest] [motor]
                                                      # apple|deepl|google|hunyuan
tradutor-verify srt <video> <orig> <dest> <motor> [--locutores]
tradutor-verify alinhamento <video> [motor] [idioma]  # legenda contra onde há voz
tradutor-verify cobertura [audio] [idioma] [motor]    # alcance por locutor
tradutor-verify fronteiras <video> [idioma] [motor]   # trechos com duas vozes
tradutor-verify gabarito <marcado.txt> <audio> [modelo] [limiar]
tradutor-verify vozes <audio> [limiares]              # quantas vozes cada limiar dá
tradutor-verify modelos-de-voz <audio>... [limiar]    # agrupamento x sortformer
tradutor-verify treslinhas <video>                    # caça legenda de 3 linhas
tradutor-verify repescagem <audio> [motor] [idioma] [motor2]
tradutor-verify audio <wav> [orig] [dest] [motor]     # VAD + reconhecimento + tradução
tradutor-verify prefixo-ab <video> ...                # tradução com e sem rótulo
```

`cobertura` aceita `--audio-referencia <wav>` (PCM original, nunca o tratado),
`--referencia <json>` (congela as faixas do Sortformer) e `--json <saída>`.

Diálogo sintético de duas vozes com roteiro conhecido, para medir corte e
alinhamento:

```bash
python3 scratchpad/gera2.py /tmp/dialogo      # gera.py = fácil, gera2.py = difícil
./.build/release/tradutor-verify srt /tmp/dialogo/dificil-pt.wav pt en apple --locutores
python3 scratchpad/mapa.py /tmp/dialogo/dificil-pt.json /tmp/dialogo/dificil-pt.en.srt
```

`compara.py` e `compara-srt.py` põem duas saídas lado a lado e reclamam quando
a contagem não bate.

### Variáveis de ambiente

Existem para refazer medição sem recompilar. Nenhuma muda o comportamento
padrão.

| Variável | O que faz |
|---|---|
| `ASR_DEBUG` | imprime as re-decodificações do Whisper e o filtro `isRealSpeech` |
| `TRADUTOR_SEM_NIVELAMENTO` | desliga `levelQuietSpeech` |
| `TRADUTOR_SEM_PAUSAS` | desliga o corte de legenda por silêncio medido |
| `TRADUTOR_SEM_FUSAO` | desliga `mergeSameVoice` |
| `TRADUTOR_FUSAO_LIMIAR` | troca `sameVoiceThreshold` |
| `TRADUTOR_CLUSTER_OVERLAP` | troca `chunkOverlap` |
| `TRADUTOR_PAUSA_MINIMA` | liga o corte de trecho por silêncio (gate `srt`) |
| `TRADUTOR_IDIOMA`, `TRADUTOR_MOSTRA_CUES`, `TRADUTOR_MOSTRA_CRUZAMENTO` | detalhes de saída dos gates |
| `TRADUTOR_MEASURE_POPOVER` | desenha o painel em `/tmp/painel.png` |

### Autotestes do app inteiro

```bash
open build/Tradutor.app --args --selftest-live ja pt              # → /tmp/tradutor-live.txt
open build/Tradutor.app --args --selftest-studio video.mp4 ja pt  # → /tmp/tradutor-studio.txt, /tmp/studio.png
open build/Tradutor.app --args --selftest-job video.mp4 ja pt     # → /tmp/tradutor-job.txt
open -n build/Tradutor.app --args --selftest-janelas              # → /tmp/tradutor-janelas.txt
open -n build/Tradutor.app --args --selftest-microfone 4          # → /tmp/tradutor-microfone.txt
```

Bandeiras: `--motor <parakeet|whisper|qwen|qwenLarge>`, `--tradutor
<apple|deepl|google|hunyuan>`, `--locutores`, `--cores`, `--modelo
<clustering|sortformer>`, `--retraduzir <motor>`.

Quatro coisas que já custaram tempo:

- **Com o app aberto, `open` ignora os `--args` em silêncio** e o autoteste
  nunca roda. `open -n` resolve; o autoteste termina em `exit()`.
- **Caminho relativo** vale a partir da raiz do projeto: `open` não herda o
  diretório de trabalho, então os autotestes resolvem contra a pasta do `.app`.
- **O aviso de conclusão do item de menu não aparece sob autoteste**
  (`SubtitleJob.silent`): `NSAlert.runModal` segura o laço principal e o
  relatório ficava em "gerando…" para sempre, com o `.srt` já correto.
- **Checagem de locutor exporta junto da geração**: a exportação do fim do
  teste vem depois de carregar um `.srt`, e legenda lida de arquivo não tem
  locutor.

Diagnóstico da captura:

```bash
open "build/Tradutor Probe.app"                    # a captura funciona?
open "build/Tradutor Probe.app" --args isolamento  # a seleção é respeitada?
open "build/Tradutor Probe.app" --args geral       # o tap global funciona?
```

---

## Arquitetura

```
Sources/
  AudioCapture/     tap, ring buffer, reamostragem, VAD      (sem dependências)
  TradutorCore/     reconhecimento, tradução, legendas
  TradutorApp/      painel flutuante, janela de legendas, barra de menus
  tradutor-probe/   verificação da captura
  tradutor-verify/  verificação do resto
Scripts/bundle.sh   monta o .app sem Xcode
```

`AudioCapture` não depende de nada externo de propósito: é a camada mais
arriscada e precisa compilar e rodar em segundos.

### Tempo real

```
áudio do app ──▶ Core Audio process tap (todos os processos do app)
   ou o mic  ──▶ AVAudioEngine na entrada escolhida
             ──▶ 16 kHz mono + VAD de dois limiares
             ──▶ trecho em andamento, re-reconhecido a cada 0,6 s
                   ├──▶ prefixo que ainda oscila ──▶ zona vermelha
                   └──▶ prefixo estável (2 passadas concordam)
                          └──▶ fecha na pontuação ──▶ tradução ──▶ zonas azul e amarela
```

### Arquivo

```
vídeo ──▶ faixa do idioma escolhido ──▶ áudio 16 kHz ──▶ nivela fala baixa
      ──▶ quem fala, quando pedido (fronteiras de voz)
      ──▶ reconhecimento com marcação de tempo
      ──▶ agrupa em frases (150 chars, pausa > 0,8 s, teto 7 s)
      ──▶ traduz em lotes (40 na Apple, DeepL e Google; 20 no Hunyuan)
      ──▶ reparte em legendas de 2 linhas × 42 chars (20 se o destino é CJK)
      ──▶ .srt
```

### O microfone é uma fonte como as outras

`AudioProcess.microphone` entra na mesma lista dos aplicativos, e escolhê-lo
troca o `ProcessTap` por um `MicrophoneTap`. Para o usuário a pergunta é uma só
— "de onde vem o áudio?" —, e um segundo controle ao lado dela responderia a
mesma coisa duas vezes. **Qual** microfone, aí sim, é outra pergunta, e o
seletor só aparece depois que a primeira foi respondida.

- **`AVAudioEngine`, não o HAL cru.** Entrada é o caso que o framework do
  sistema resolve bem; o `ProcessTap` só é CoreAudio puro porque não existe API
  alta para tap de processo. São 30 linhas contra as 300 daquele arquivo.
- **O padrão é "padrão do sistema", e é um `nil`, não um ID gravado.** Gravar o
  ID deixaria o app apontando para o fone anterior depois que o usuário trocasse
  de fone no meio da reunião.
- **O dispositivo tem de ser escolhido ANTES de ler o formato**: trocar de
  entrada troca a taxa de amostragem, e um tap instalado com o formato do
  dispositivo anterior é recusado em tempo de execução.
- **Permissão negada falha igual à de gravação de tela**: o engine roda, o tap
  dispara na cadência certa e todos os quadros vêm zerados. Por isso
  `--selftest-microfone` mede **pico e RMS** — sala silenciosa tem ruído de
  fundo, permissão negada tem zero exato.
- **O aggregate device do próprio tap aparece como entrada** enquanto a captura
  de aplicativo está ligada. `AudioInputList` o descarta pelo nome; oferecê-lo
  seria capturar a si mesmo.

### A lista de captura só mostra o que dá para escolher

O seletor devolvia nove entradas numa máquina comum, entre elas
`com.apple.WebKit.GPU`, `pid:57939` e `exec:coreaudiod` — nomes que o usuário
não reconhece e não tem por que escolher. Três peneiras, medidas em 14/09/2026:

```
sem nome de aplicativo   com.apple.WebKit.GPU, pid:57939, exec:...
`.prohibited`            universalaccessd, SiriNCService, QuickLookUIService
`/System/Library/`       loginwindow, PowerChime, Central de Controle
                                                        9 entradas → 3
```

**Nenhuma das duas últimas basta sozinha**: os três de `/System/Library/` são
`.accessory`, que a política não pega; e há aplicativo legítimo `.accessory` em
`/Applications` que o caminho sozinho derrubaria. **O que estiver tocando som
agora passa de qualquer jeito** — se sai áudio dali, pode ser o que o usuário
quer. O resto continua alcançável por "Todo o áudio do sistema".

O app também some da própria lista: ele aparecia ali por causa do seu aggregate
device.

### Os controles do painel ao vivo

No cabeçalho, da esquerda para a direita: o par de idiomas, os dois botões de
copiar, e à direita pausar, exportar, limpar e ✕. Exportar antes de limpar, na
ordem em que se usam — quem vai apagar a tela costuma querer guardar antes.

- **Pausar não solta a captura.** O tap, o aggregate device e os modelos ficam
  de pé; o áudio é lido do anel e jogado fora. Parar e religar custaria uma
  volta inteira pelo Core Audio, e o que se quer ao pausar é voltar no instante
  do clique. **O anel continua sendo esvaziado**: deixar de ler faria os
  primeiros segundos depois da retomada serem áudio de minutos atrás.
- **O trecho em andamento é descartado ao pausar**, não guardado. Retomar dez
  minutos depois e ver sair a meia frase de antes da pausa seria pior que
  perdê-la. O que já foi confirmado fica na tela.
- **"pausado" aparece escrito.** Sem isso, painel pausado e painel em silêncio
  são a mesma tela.
- **Os botões de copiar levam o código do idioma ao lado do ícone** (`⧉ JA`,
  `⧉ PT`). Dois ícones de prancheta lado a lado seriam indistinguíveis sem
  passar o mouse. Copiam a **sessão inteira**, uma fala por linha: um par de
  botões em cada um dos 60 blocos viraria muro de botões, e quem quer um trecho
  só recorta do que foi colado.

- **O histórico da tela e o registro da sessão são duas listas.** O que rola na
  tela para em `historyLimit` (60) porque rola; a exportação precisa da reunião
  inteira, e `SubtitleStore.transcript` cresce sem teto. São os mesmos blocos, e
  texto não pesa — uma hora de fala não chega a um megabyte.
- **`NSSavePanel.begin`, não `runModal`.** O modal segura o laço principal, que é
  onde a captura roda: o áudio que chegasse durante a escolha do arquivo encheria
  o anel sem ninguém consumindo.
- **A hora sai em `dd/MM/aaaa HH:mm:ss` com locale fixo em pt_BR**: o arquivo é
  lido por quem gravou, e uma máquina em inglês gravaria `9/14/26` no meio de um
  relatório em português. `SubtitleBlock.at` já existia; ninguém o mostrava.
- **Sem tradução, a fala não sai duas vezes** — nem no arquivo nem na tela: o
  bloco tem `source == translated`, e tanto `CaptureExport` quanto a âncora
  apagada do painel comparam os dois antes de escrever.

### A lista de falas, o divisor e as setas

Mudanças pedidas em 14/09/2026, todas na janela de legendas:

- **O original aparece em todas as falas**, apagado, e não só na que está no
  ar. O medo era virar muro de texto; na prática conferir tradução contra
  original era o uso, e reproduzir cada legenda para ver o original tirava a
  lista de serviço.
- **As setas ← e → andam de legenda em legenda**, que é o mesmo que os botões
  de legenda fazem. Os 5 s no tempo passaram para ⌘← e ⌘→, para quando o que
  se procura está no meio de uma fala longa.
- **O divisor não tem mais teto fixo.** Eram 560 px: numa janela larga ele
  travava no meio do caminho e parecia defeito. O limite agora sai da largura
  da linha (`SubtitleStudioModel.clampListWidth`), respeitando 360 px de vídeo
  e 240 px de lista — e vale também quando a janela **encolhe**, senão o vídeo
  ficava com alguns pixels.
- **O arrasto começa em `minimumDistance: 0`**: com os 10 px do padrão, o
  primeiro evento já chega com 10 px acumulados e o divisor pulava esse tanto
  antes de acompanhar o ponteiro. O cursor é `.pointerStyle(.columnResize)`, do
  sistema: `NSCursor.push`/`pop` na mão não se equilibram quando o ponteiro sai
  do divisor no meio do arrasto, e a seta ficava presa em redimensionar.
- **A lista abre com 400 px** em vez de 320, e duplo clique no divisor volta
  para esse valor.

### Mais de uma janela de legendas

`AppDelegate.studios` mapeia janela → modelo e retém os dois; `windowWillClose`
tira a chave e o par cai junto, com `stop()` soltando o player daquela janela.

- **"Assistir com legenda…" levanta as janelas existentes**; quem abre outra é
  "Abrir outra janela". O app é `.accessory` — sem Dock, sem Cmd-Tab, sem menu
  Janela —, então o item do popover é o único caminho de volta para uma janela
  enterrada, e gerar de novo custa minutos. O levantamento segue
  `NSApp.orderedWindows` de trás para a frente.
- **O título é numerado por contador que só cresce** (`Legendas`, `Legendas 2`):
  reaproveitar número daria duas "Legendas 2" ao mesmo tempo.
- **Nada no caminho da geração é compartilhado** (`Translator.make` e
  `SubtitleFileBuilder` por instância, um `AVPlayer` por modelo). O que não tem
  guarda é **gerar em duas janelas ao mesmo tempo**: dois modelos residentes
  disputando GPU (dois Hunyuan não cabem em 16 GB) e duas `WKWebView` no DeepL
  puxam o desafio da Cloudflare. Assistir em várias e gerar numa só é o uso
  seguro.
- **`SubtitleStudioModel` e `SubtitleJob` são arquivos separados**; a geração é
  uma função só, `SubtitleFileBuilder.generate` — antes cada um tinha sua cópia
  e o usuário via legenda diferente saindo de cada um. Interface, progresso e
  cancelamento continuam separados: testar um não testa o outro.

---

## Decisões que vieram de medição

Cada uma custou uma investigação. Não desfaça sem medir de novo.

### Tempo real: por que o áudio não é cortado

Cortar parte palavras e nenhuma metade é reconhecível: "reported" saía como
"Reaper's" no fim de um bloco e "ported" no começo do seguinte. Cortar no ponto
de menor energia ajudou, não resolveu.

O trecho é transcrito inteiro, repetidamente, e vai para a tela o prefixo em que
duas passadas concordam (*LocalAgreement-2*, do `whisper-streaming`). O
reconhecedor às vezes **reescreve o passado**: confirmar por índice sem checar
isso produzia "running in been running in production". Passada que discorda do
que já saiu não confirma nada.

**O confirmador contava palavra separada por espaço, e japonês não tem espaço.**
Em 75 s de japonês a hipótese tinha 224 caracteres e **8 unidades**, a maior com
três frases — a zona azul só andava quando duas passadas repetiam um bloco
inteiro. `Tokens.split` passou a unidade para o **caractere** onde a escrita é
densa, e `Tokens.join` desfaz pela mesma regra:

```
                  caracteres confirmados   frases entregues
ja-longo               51 → 153                6 → 18
ja-musica              40 →  84                3 →  8
en-conversa           393 → 393               16 → 16
en-dialogo            480 → 480               20 → 20
```

**Coreano usa espaço e ficou fora de `isDense`** — a primeira versão o incluía e
teria colado as palavras.

### O que o VAD do tempo real faz com áudio contínuo

```
japonês com música   9 segmentos ·  86,9s de 97s · 38/38 trechos alcançados
japonês limpo        9 segmentos ·  95,9s de 96s · 42/42
inglês              14 segmentos · 161,3s de 161s · 64/64
```

Quase todo segmento fecha por **teto de 12 s, não por silêncio** (7 de 9, 9 de
9, 14 de 14): com música ou ruído a energia nunca cai o bastante.
Consequência: `minimumDuration` (0,4 s) e `framesToOpen` (3 quadros) **nunca
disparam** nesse material — varrer esses limiares dá resultado idêntico.

**Nivelar o áudio ao vivo foi medido e não paga**: 1602 → 1608, 1576 → 1583,
195 → 196 caracteres. O VAD já fecha o segmento no silêncio, e o modelo
normaliza a janela que decodifica. O gate `vivo <audio> <motor>` fica para
refazer se o desenho mudar.

---

## Reconhecimento

`RecognitionEngine` escolhe a família; o seletor de idioma limita ao que cada
uma cobre. Família nova: um caso no enum, um `Transcriber`, e o seletor mostra
sozinho.

| Caso | Cobertura | Observação |
|---|---|---|
| `.apple` (padrão) | de, en, es, fr, it, ja, ko, pt, zh | `SpeechAnalyzer` do macOS 26 |
| `.parakeet` | os 10 idiomas europeus do app | Parakeet TDT v3, ~120× tempo real |
| `.whisper` | todos | Whisper turbo, mais lento e mais amplo |
| `.qwen` | 13 idiomas (sem inglês) | Qwen3-ASR 0.6B, **só em vídeo**, fora do processo |
| `.qwenLarge` | 14 de 18 | o mesmo em 1.7B, com `qwen-setup.sh --grande` |

Parakeet e Whisper eram um item só; são dois modelos com cobertura e velocidade
diferentes, e agora são duas escolhas. `TranscriberKind` ainda manda o Parakeet
para o Whisper quando o idioma não é coberto — rede para preferência gravada
antes de o idioma mudar.

Medido em 161 s de inglês, os três locais transcrevem o **mesmo texto**:

```
                texto      tempo        alinhamento (início / fim)
Parakeet v3     320 pal.   1,8s · 88x   +0,10 / -0,18 s
Apple           319 pal.   1,4s · 116x  -0,42 / +0,08 s
Whisper turbo   328 pal.   5,6s · 29x   -0,65 / +0,43 s
```

Em 96 s de japonês com música, Apple e Whisper dão 735 e 734 caracteres, com a
Apple em 0,6 s contra 3,6 s.

**Comparar motores contando trechos engana**: o v3 sai com um trecho por
palavra, Apple e Unified com trechos de frase. Compare por texto —
`tradutor-verify fonte`.

### O limiar que fazia a legenda mudar a cada execução

O WhisperKit re-decodifica com temperatura 0,2…1,0 quando a confiança do
primeiro token fica abaixo de `firstTokenLogProbThreshold`, e acima de zero o
amostrador sorteia (`Float.random`, sem semente).

```
-1,5 (padrão do WhisperKit): 34 / 25 / 20 / 31 trechos, 7 a 17 retentativas
-3,0 (o que está no código): 30 / 32 / 30 / 32 trechos, nenhuma retentativa
```

Cobertura do `.srt` de 44% para 70%. **Zerar `temperatureFallbackCount` também
acaba com o sorteio e foi medido: cai para 9 trechos** — as retentativas
recuperam texto de verdade. `tradutor-verify motores` falha se o número voltar.

### A loteria do Whisper: repetir quando a passada sai pobre

Em 78 s com fala baixa e vento, três execuções deram 4, 14 e 9 trechos. Com
`ASR_DEBUG`: 14 re-decodificações por três gatilhos diferentes
(`compressionRatioThreshold` 6, `firstTokenLogProbThreshold` 4,
`logProbThreshold` 4). Só o segundo é nosso, e o `Float.random` não aceita
semente.

`transcribeTimed` repete até três vezes e fica com a que **alcançou mais fala**:

```
execução    1ª passada   melhor das 3
1              23%           23%
2              20%           41%
3              30%           32%
```

Texto final, cinco execuções: 150 · 64 · 63 · 161 · 54 caracteres, contra
17 · 97 · 70 de uma passada só. Média de 61 para 98; o piso sobe.

**O critério é alcance, não tempo coberto** — contar segundos pune quem corta
fino, e o Whisper corta fino de propósito (51% do tempo, 96% de alcance no
mesmo vídeo). Contar caracteres premiaria a execução que repete a mesma frase,
que é o defeito. Áudio normal não paga nada: a 1ª passada já passa do piso de
75%.

```
vídeo de 9 min japonês    96%   uma passada · 26 s
97 s japonês com música   79%   uma passada ·  6 s
161 s inglês             100%   uma passada ·  8 s
78 s difícil          20 a 30%  três passadas
```

### Detalhes que custaram investigação

- O botão **+** ao lado do idioma instala o modelo da Apple pelo
  `AssetInventory`. `SpeechTranscriber.supportedLocale(equivalentTo:)` devolve
  variante até para árabe e russo, que ele não transcreve; a lista boa vem de
  `supportedLocales`.
- `AppleSpeechTranscriber.phrases` junta palavras em trechos **antes** do
  agrupador, que junta pedaços com espaço — palavra solta em japonês viraria
  "今日 は".
- **Há reconhecedores cujo tempo é o da emissão do token, não o da palavra**
  (medido no Parakeet Unified: palavras ~0,4 s atrasadas, ponto final emitido
  só na frase seguinte). `TokenPhrases.group` ignora o tempo da pontuação e
  `SpeechEnergy.fit` encosta o trecho na voz. As duas peças ficam porque
  qualquer RNNT novo cai no mesmo problema; o v3 tem durações do TDT e não
  passa pelo `fit`.
- `TokenPhrases.group` existe porque o `buildWordTimings` do FluidAudio agrupa
  pelo "▁", que japonês quase não tem.
- **A primeira inferência do Parakeet pode estourar o tempo no Neural Engine**
  (`ANE op async execution has timed out`) e derrubar a transcrição inteira.
  `AneRetry.once` tenta de novo com o decodificador zerado. Uma tentativa só;
  cancelamento não é retentado.

### Testados e removidos

| Motor | Por quê |
|---|---|
| Whisper large-v3 (1,55 B) | dobro do tempo (20 s contra 10 s em 90 s de japonês), mesmas palavras, legendas piores em vídeo real |
| `DictationTranscriber` | cobre 54 locales contra 30, mas entrega blocos de 30-40 s **quase sem pontuação** (5 trechos e 14 sinais contra 50 e 73 do `SpeechTranscriber`) — e pontuação é o que fecha legenda. Só medido em inglês |
| Cohere Transcribe 8 bits | sem marcação de tempo, 40 s para 90 s, 7 GB de cache do ANE |
| Nemotron 3.5 | perdeu as seis falas de 1,2 a 2,0 s de um vídeo (14 de 28 trechos contra 21 da Apple); 16 de 39 em japonês |
| Parakeet Unified EN | mesmo texto do v3 em inglês, o mais rápido (181×) e o mais preciso no tempo, mas só inglês — 586 MB por nada |
| Parakeet `tdtJa` | um terço do texto (239 caracteres contra 736 da Apple), com truncamento no meio da palavra. Descartados como causa: agrupamento, limiar de arquivo longo, nível do áudio, `decoderState` e dica de idioma |

### Qwen3-ASR: o único motor fora do processo

Não existe port CoreML utilizável; o que existe é MLX em Python. Ambiente
próprio por `Scripts/qwen-setup.sh`; o app só oferece o motor quando ele
existe.

```
                caracteres   tempo        desvio do início
Apple                  248   0,6s ·172x   -0,42s
Whisper turbo          260   7,0s · 14x   +0,06s
Qwen3-ASR 0.6B         281   5,7s · 17x   +0,03s
```

O ganho não é volume: ele devolve **uma fala por bloco, com pontuação**,
enquanto a Apple emenda pergunta e resposta na mesma linha. `QwenTranscriber`
pede `-f srt` e lê com o `SRTParser`, que ainda conserta os blocos de duração
zero que ele às vezes emite.

**Só em vídeo** (`supportsLive == false`): 17× tempo real não sustenta
re-reconhecer a cada 0,6 s. Escolhido no painel, o ao vivo cai em `forLive`.

O processo precisa de `HF_HOME` dentro da pasta (senão o modelo vai para
`~/.cache`) e `HF_HUB_OFFLINE=1` (senão há consulta ao Hugging Face por
legenda).

**O 0.6B não pontua em inglês**: zero sinais em 161 s, contra 63 do Parakeet,
73 da Apple e 73 do próprio 1.7B. Por isso o inglês saiu de
`QwenTranscriber.languages(for: .small)`. Em japonês o mesmo modelo pontua
normal — é por idioma.

**0.6B ou 1.7B** (`--grande` acrescenta 3,4 GB):

```
                      96 s limpo      97 s com música     540 s
0.6B   caracteres            281                  271      1661
       tempo               11,4s                15,2s     20,1s · 27×
1.7B   caracteres            286                  264      1673
       tempo               25,6s                37,0s     82,7s ·  7×
```

O volume é o mesmo; o 1.7B compra **nome próprio em áudio difícil** (`ドクター・
ベガ` onde o 0.6B escreveu `独たべが`).

**Os pesos de 4 bits foram medidos e recusados.** São 45% mais rápidos (25,1 s
contra 45,2 s no vídeo de 9 minutos) e transcrevem menos em 3 dos 4 vídeos,
pelo caminho do app: 128/129, 261/265, 1425/1448, 1645/1635 caracteres. Meio
por cento de texto, e texto vale mais que segundos. Num WAV cru o 4 bits
parecia ganhar (1634 contra 1449) — **meça pelo caminho do app**, que é onde a
diferença se inverte. Junto: **8 bits é mais lento que float16** (6,0 s contra
4,9 s) e **`--dtype bfloat16` é mais lento e pior** (21,0 s e 1444 caracteres
contra 19,3 s e 1661).

**O custo é o modelo, não o app**: 20,2 s de geração para 19,3 s de processo
Python. `writeWAV`, o processo e a leitura do `.srt` somam menos de 1 s. O que
mudaria a ordem de grandeza é sair do MLX —
`FluidInference/qwen3-asr-0.6b-coreml` existe, mas o FluidAudio 0.15.7 que o
app já usa **não expõe ASR do Qwen**, só TTS. Seria escrever o laço de
decodificação à mão.

### A lista de termos foi removida

Saiu em 13/09/2026, a pedido. O que ela comprava, com `上村玲香 佐藤雄二 レイカ`:

```
sem contexto:  はじめまして、神村レイカです。
com contexto:  はじめまして、上村レイカです。
```

Quem quiser de volta precisa de três ligações: `--context` (Qwen),
`promptTokens` (Whisper) e `AnalysisContext.contextualStrings` (Apple, nunca
ligado — exige `SpeechAnalyzer(inputSequence:modules:analysisContext:)`).

### Repescagem de fala curta: medida e descartada

Re-reconhecer isolado cada trecho com energia que a 1ª passada deixou sem texto:

```
Parakeet v3 (inglês)        8 sem texto → 2 recuperados
Whisper    (japonês)        5 → 1
Apple      (japonês)        5 → 0
Apple + Whisper (japonês)   5 → 1 ("ん")
Whisper + Parakeet (inglês) 10 → 1 ("Oh.")
```

O que volta é grunhido. E o número antigo ("68% a 95% da fala curta se perde")
vinha de métrica enviesada — contava perdido quando nenhuma peça tinha o
**meio** dentro do trecho. Pelo critério certo são 5 a 10 trechos por vídeo,
quase todos abaixo de 0,5 s.

---

## Tradução

Quatro tradutores — **Apple** (padrão, local), **DeepL**, **Google** (rede) e
**Hunyuan-MT** (local, fora do processo) — mais **Só transcrever**, que não
traduz nada. **Todos valem ao vivo e em vídeo.**

### Ao vivo passou a aceitar qualquer motor

Pedido em 14/09/2026. Antes o caminho ao vivo trocava a escolha pela Apple,
calado, porque uma ida à rede por bloco não cabe num trecho re-reconhecido a
cada 0,6 s. É o mesmo defeito de "Falhou, falhou": **escolha do usuário não se
troca em silêncio**. Quem escolheu DeepL pela qualidade recebia Apple sem saber.

O custo não sumiu, só passou a ser dito antes. `TranslationEngine.liveCostNote`
é o que o painel mostra sob os seletores:

```
Apple, só transcrever   instantâneo, local        (liveCostNote nil)
Google                  ~1 s por bloco
DeepL                   2 a 3 s por bloco, e o desafio anti-robô quando insiste
Gemini                  alguns segundos por bloco, mensagem de chat por vez
Hunyuan                 4,5 GB residentes, disputando GPU com o reconhecedor
```

Duas consequências que não são de interface:

- **Só o motor instantâneo fica carregado** (`isInstantaneous`). O app abre
  carregando os modelos para o primeiro ⌥⌘T não esperar pelo disco; sem essa
  distinção, escolher o Hunyuan uma vez faria toda abertura residir 4,5 GB, e
  escolher o DeepL abriria uma `WKWebView` ociosa. Os outros nascem quando
  alguém manda traduzir.
- **E morrem quando a captura para.** A janela do DeepL e o servidor do Hunyuan
  não se fecham sozinhos, e este app fica aberto o dia todo na barra de menus.
  A Apple fica: não custa nada parada, e soltá-la apagaria o "modelos
  carregados" do painel sem motivo.

Sem tradutor de reserva aqui também: bloco recusado sobe como erro e o painel
mostra a faixa vermelha. Calado, tradutor em silêncio e falante em silêncio são
a mesma tela.

### Só transcrever é um tradutor, não um desvio

`IdentityTranslator` devolve o texto como veio, e `TranslationEngine
.transcriptionOnly` o escolhe. Foi assim, e não com um `if` em cada caminho,
porque são **três** caminhos — painel ao vivo, janela de legendas e item de
menu — e eles já divergiram uma vez quando cada um tinha sua cópia dos passos.

O que muda junto com o motor é o **destino**: sem tradução a legenda sai no
idioma falado. `TranslationEngine.destination` é a regra única, e dela saem a
largura da linha (japonês em 20 caracteres, não 42), o sufixo do arquivo
(`video.ja.srt`, não `.pt.srt`) e o rótulo do painel. O autoteste do item de
menu montava o nome esperado com o idioma **escolhido** e esperava para sempre
por um `.pt.srt` que ninguém ia gravar.

O caso não se chama `none`: `TranslationEngine?` existe (`SubtitleJob
.translation`) e ali `.none` já quer dizer `nil`.

### Testados e removidos

| Testado | Resultado |
|---|---|
| Qwen3-4B (MLX) | erra gênero mesmo com histórico, regra explícita ou raciocínio |
| Qwen3-8B (MLX) | acerta em teste sintético, português pior em vídeo real; **1,02× o tempo do vídeo** |
| NLLB-200-600M | erra moeda (円→"cêntimos"), nome próprio (山梨県→"Yamada"), português europeu |
| MADLAD-400-3B | melhor que o NLLB, ainda abaixo da Apple; 6 GB residentes |
| iTranslate | **resume em vez de traduzir**: 11 de 110 legendas com menos de metade do texto, e inversão de sentido ("Socorro! Vou ser morto pelo Chapéu de Palha" → "ajude-me e eu vou te matar") |

**Armadilha do arnês:** o `transformers` 5.x quebra o MADLAD (não amarra
`shared.weight` a `decoder.embed_tokens.weight`); com `4.44.2` funciona.

### DeepL e Google ganham da Apple em japonês

Dois vídeos japoneses, falas reconhecidas pela Apple (110 e 18), 13/09/2026:

```
                 110 falas   18 falas   caracteres   linhas
Apple               36,4 s      7,0 s         3722   110/110
DeepL               11,0 s      5,0 s         3613   110/110
Google               1,3 s      1,1 s         3475   110/110
```

A linha do DeepL não conta a 1ª carga de página (~11 s).

```
                     gênero    encurta      nome     começa com
                   (8 casos)  mais de 50%  próprio    maiúscula
DeepL                 6/8         0         4/4        109/110
Google                3/8         5         4/4         96/110
Apple                 2/9         2         2/4         49/110
```

**A Apple não está na disputa em japonês.** Não é elegância — é linha sem
sentido onde os outros acertam:

```
あと私のことはいかでいいよ。いか先輩先輩はいらないよ。
   AP  e o que você acha de mim? você não precisa de mim, senhorita.
   DL  Ah, e pode me chamar de "Ika". "Ika-senpai"? Não precisa de "senpai".

店長れいかさんって2人いるんですか？
   AP  você tem duas senhoras rei ka como gerente da loja?
   DL  Gerente, tem duas Reikas aqui?
```

**Gênero o DeepL resolve na maioria, mas não é confiável**: no vídeo que repete
o mesmo diálogo, "Tô ocupada" vira "tô ocupado" na segunda metade. Nenhum
tradutor é determinístico em gênero; o DeepL só erra menos.

**Erro que nasce no reconhecimento atravessa intacto** nos três ("Vizabank" por
Vegapunk, "Ruby" por Luffy). Não é caso de tradutor.

**Registro:** o DeepL escreve brasileiro falado, o Google escreve manual — "Sai
daí um pouco, tá atrapalhando" contra "Saia da frente, você está atrapalhando".
Pesa porque a legenda é quebrada em 2 × 42 caracteres: a versão longa estoura e
o corte come outra coisa.

### O DeepL: uma carga de página, depois limpar-e-colar

`TranslationEngine` escolhe quem traduz nos modos de vídeo. A primeira carga
fixa o par de idiomas pelo formato de link do site, `#<origem>/<destino>/<texto>`;
cada linha vira um `<p>`, e daí sai a contagem preservada. Do segundo bloco em
diante é limpar e colar:

- o botão do site esvazia o campo — `translator-source-clear-button`;
- o texto entra por **evento de cola**, `ClipboardEvent('paste')` com um
  `DataTransfer`. **`execCommand('insertText')` não serve** — o editor o ignora
  e nenhuma requisição sai.

Medido: 2,2 s e 3,0 s por ciclo, contra ~8 s de carga completa. E o ganho maior
não é esse: **recarregar a cada bloco é o que parece robô** — com armazenamento
`nonPersistent` cada carga chega sem cookie, e depois de algumas vinha o
desafio da Cloudflare. Colar mantém uma sessão só.

Quando a colagem não responde o driver recarrega **uma vez**; se ainda falhar,
o bloco derruba a tradução — não há tradutor de reserva, ver "Falhou, falhou".
Qualquer erro zera `loadedPair`.

**O botão de volume é o "estou traduzindo" do site.** Medido a cada 80 ms:

```
t+0ms      3 parágrafos · volume presente  ← a tradução ANTERIOR
t+617ms    1 parágrafo "\n" · volume ausente ← traduzindo
t+1129ms   3 parágrafos · volume presente  ← a tradução nova
```

`[data-testid="translator-speaker-target"]` some enquanto traduz e volta quando
termina — mais firme que classe de CSS. Sem ele, uma leitura nos ~600 ms de
janela escreve a legenda do bloco **anterior** no bloco atual, com timecode
válido e arquivo sem erro. `DeepLWeb.aceitavel` fecha por três caminhos: volume
de volta, ter visto o site trabalhando desde o envio, e o texto ser diferente
do que o bloco anterior deixou. Passados 8 s a regra afrouxa, senão um site que
mude o botão trava a geração.

**A espera é sinal, não relógio.** Três esperas fixas saíram:

- **25 s esperando a contagem certa** → texto **parado** por 3 s (12 leituras
  iguais). Medido: 26 a 38 s antes, 2,3 a 11 s agora.
- **Requisição em voo como condição absoluta** → há requisição que não termina;
  passados 8 s quem manda é o texto parado.
- **300 ms de sono depois de limpar** → confere que o campo esvaziou e que a
  cola entrou, e recarrega na hora quando não entrou.

O desafio anti-robô ganhou **25 s antes de desistir**: ele quase sempre passa
sozinho, e desistir no primeiro quadro mandava para a Apple um bloco que ia
sair dali.

**Carregar o site antes do primeiro bloco foi testado e desfeito**: +11 s no
vídeo curto e +25 s no de 9 minutos, em toda geração, para adiantar algo que
aparece de vez em quando.

Quatro armadilhas, cada uma uma rodada:

- **Trocar só o fragmento não recarrega nada** (SPA). A carga leva
  `?bloco=<n>`. A identidade da página é o **texto do campo de origem**: sem
  conferi-lo a leitura pega o bloco anterior.
- **Enquanto a tradução não chega, o site mostra a origem no lado do destino.**
  Sem requisição em voo e texto parado, isso passava por "pronto" — o `.srt`
  saiu com sete das onze falas em japonês. `mesmoTexto` recusa esse estado.
- **A renderização vem depois da resposta**: um bloco de 11 falas era lido com
  4 e repartido sem necessidade. Por isso `esperar` exige a contagem esperada
  nos primeiros 25 s.
- **Sem cookie nenhum o aviso do site é caixa modal** que não casa com o
  `data-testid` do aviso curto. A sonda esconde por papel (`[role="dialog"]`
  com "cookie") depois de tentar o botão de recusar — esconder, não aceitar.

**A janela não existe mais.** Ela era obrigatória por medo do estrangulamento
de temporizador que o sistema aplica a `WKWebView` fora da tela. Medido em
14/09/2026, pelo `--selftest-job` do app assinado, no vídeo de 9 minutos — 4
blocos, logo com o caminho de limpar-e-colar exercitado:

```
com janela    141 legendas · 44 s · nenhuma falha
sem janela    143 legendas · 45 s · nenhuma falha
```

O mesmo empate em `tradutor-verify traduzir` com 90 linhas em três blocos
(18,8 s contra 18,0 s), e também com a janela transparente (`alphaValue = 0`)
ou fora da tela. O que dispara a tradução não depende de temporizador
estrangulável. `TRADUTOR_DEEPL_JANELA=1` traz a janela de volta para depurar —
e `isReleasedWhenClosed = false` fica lá, para quem a usar.

**O desafio anti-robô continua passando sozinho**, e é isso que permite não ter
janela: ninguém precisa clicar no "confirme que é humano". Automatizar o clique
não está em questão.

**Custo, medido do começo ao `.srt`:**

```
                 96 s (11 falas)   540 s (75 legendas)
Apple                    7 s              32 s
DeepL                   10 s              18 s
```

Os dois custam quase o mesmo por motivos opostos: **a Apple cobra por string**
e **o DeepL cobra por carga de página**, que leva 1400 caracteres de uma vez.
`TranslationEngine.costPerSecondOfVideo` faz a conta por motor.

**O que limita o DeepL é o desafio anti-robô, não a velocidade**: uma execução
barrada levou **195 s** no vídeo de 96 s. Esse número já ficou registrado aqui
como se fosse o custo do motor; é o custo de ser barrado.

**Mais texto por ida piora.** Com lote 120 o site parou de preservar linhas:

```
 40 por lote:  "devolveu 41 para 40", "19 para 20"   → repartia um nível
120 por lote:  "devolveu 1 para 103"                 → um parágrafo só
```

Um parágrafo só cai na repartição binária (103 → 51 → 25 → 12 → 6 → 3), cada
nível uma página: 23 s viraram 162 s. Contagem de linhas vale mais que
contexto.

O que continua valendo contra: teto de 1400 caracteres por colagem
(`DeepLWeb.characterLimit`); **uso automatizado contraria os termos do site**;
o HTML muda quando eles quiserem (`tradutor-verify deepl` cobre só o que é
nosso); e o macOS pede permissão de rede local por causa do WebKit — responder
"Não Permitir" não atrapalha.

### O Google entrou pelo JSON, não pela página

`clients5.google.com/translate_a/t?client=dict-chrome-ex` devolve JSON; sem
janela, sem cookie, sem Cloudflare. O texto sai da máquina e não há API
pública — automatizar contraria os termos, como no DeepL.

**O site do Google funde linhas; este endereço não.** No site, três casos nos
dois vídeos deram 53 linhas para 55 — sempre onde o reconhecimento partiu uma
frase no meio. Uma linha a menos e toda legenda dali em diante recebe o texto
da anterior: corrupção silenciosa. Aqui cada fala vai como um parâmetro `q` e
volta como um item do vetor, e não existe texto corrido para fundir:

```
ヨークの命が惜しければ、海岸の船を全部避 / けろ。
   site   1 linha  "…mova todos os navios para o mar."
   aqui   2 linhas "Se a vida de York estiver em risco, evite todos os
                    navios da costa." / "Kello."
```

O preço está na segunda: **contexto nenhum entre as falas**, e o pedaço órfão
vira bobagem. O DeepL resolve o mesmo corte em duas metades coerentes. É a
troca — alinhamento garantido, contexto zero.

Limites:

- **Teto em bytes de URL, não em falas**: 110 `q` dão 13,7 KB e passam, 220 dão
  400 Bad Request, 880 dão 413. Japonês escapado custa 9 bytes por caractere,
  então `urlBudget` conta bytes e fica em 8000.
- **Sem `User-Agent` de navegador o Google recusa** com "your computer may be
  sending automated queries" antes de olhar a consulta.
- **Determinístico**: três execuções sobre as 110 falas, nenhuma linha mudou.
- `pt` já é o brasileiro; `zh` precisa ser `zh-CN`.

### Gemini: motor de chat travestido de motor de tradução

`GeminiWeb.swift`. Mesma família do DeepL (`WKWebView`, `.nonPersistent()`, sem
API paga, sem conta) mas o site é um chat, não um campo de tradução — não há
API de lote nenhuma, então quem faz o lote virar N traduções alinhadas é só o
prompt.

**Sempre sessão anônima**: sem conta dentro do app, o Gemini cai no modelo
mais fraco da web ("Flash-Lite" em vez do "Flash" de quem loga). Medido em
15/09/2026: sozinho esse modelo errava concordância dentro da própria
legenda — "cansad**a**" numa frase que também dizia "vocês dois". Duas regras
no prompt consertaram (`GeminiWeb.instructions`, regras 5 e 6): concordância
de número/gênero obrigatória dentro do mesmo item, e masculino-plural
genérico como padrão quando não há pista de gênero. Com elas, anônimo empatou
com uma conta logada nas mesmas seis falas.

**O prompt nasceu de três rodadas medidas contra o DeepL**, nos mesmos vídeos
do benchmark de gênero (`ja-dificil`, 6 falas, e o vídeo de 40 falas com
palavrão). Sem regra nenhuma: o Gemini oferecia duas traduções por linha
separadas por "/", e inventava contexto que a fala não tinha ("aqui no
restaurante", que não existe no áudio). A regra do formato fixo (`N::tradução`,
uma linha por item, nunca "/") e a proibição explícita de inventar contexto
fecharam isso; depois empatou com o DeepL nas mesmas falas, incluindo o teste
que separa os dois de verdade — resolver "amo você" em vez de "amo isso" numa
resposta de uma palavra sem pronome no original.

**`execCommand('insertText')` funciona aqui — ao contrário do DeepL**, cujo
editor ignora e só aceita colar por `ClipboardEvent('paste')`. Mas **um só**
`execCommand` com o prompt inteiro (2000+ caracteres, dezenas de linhas)
truncava no meio de vez em quando — medido em 15/09/2026, sempre logo depois
de uma carga de página: chegava a inserir 224 dos 2401 caracteres mandados, o
Gemini recebia meia instrução e respondia "entendido, me manda o texto".
Inserir linha por linha, com uma quebra de parágrafo (`execCommand
('insertParagraph')`) entre cada uma — do jeito que alguém digitando faria —
não truncou mais numa dúzia de execuções.

**O sinal de "terminou" não é ícone de volume como no DeepL** (o chat não tem
um). É o botão "Parar resposta": existe enquanto gera, some quando termina.
Cruzado com o número de respostas na conversa (a leitura tem que ser da
resposta **desta** mensagem, não da anterior, que continua na tela até a nova
aparecer) e com leituras estáveis do texto (a resposta chega por streaming).

**Sem rede de segurança, igual DeepL**: bloco que não fechar direito derruba
a tradução com erro na tela. Mas aqui, quando a resposta chega e não bate com
`N::` vezes a contagem esperada, o prompt inteiro e a resposta crua vão para
`/tmp/tradutor-gemini-erro.txt` — só no caminho de erro, uma tradução que dá
certo não toca o arquivo. `TRADUTOR_GEMINI_DEBUG=1` imprime cada leitura de
estado no stderr, mesmo padrão do `ASR_DEBUG`.

Lote de 40, igual DeepL e Google — sem medição própria de teto de
caracteres (o chat não tem a carga-de-página-por-bloco que limita o DeepL),
mas 40 falas (~1200 caracteres) foi o que os testes usaram sem problema.

**A conversa se joga fora sozinha de vez em quando.** Pedido em 15/09/2026:
em sessão longa (ao vivo, ou vídeo com muitos lotes), de vez em quando uma
fala japonesa voltava sem traduzir de verdade — sem quebrar o formato `N::`,
então não cai na rede de segurança do `GeminiWeb.parse`. Suspeita, não
medição: o histórico da conversa crescendo dilui a instrução. `GeminiDriver`
recomeça a conversa do zero a cada 15 lotes ou 10 minutos, o que vier
primeiro — reiniciar é mais simples e mais seguro que confiar numa mensagem
extra "lembrando as regras" no meio de um histórico que só cresce.

**Corrigir erro de reconhecimento, mas sem inventar fato.** Mesmo pedido:
de vez em quando o reconhecedor erra uma palavra solta, e pediram para o
Gemini usar o contexto e ajustar — já que é um modelo de linguagem, não só
um tradutor. Testado em quatro rodadas contra `写真真経撮れるかな` e frases
sintéticas com erro plantado (hora, nome de pessoa, número de telefone):

- **Só pedir "use o contexto" não mudou nada** — sem exemplo concreto no
  prompt, o modelo continuava traduzindo o pedaço quebrado ao pé da letra.
- **Com exemplo, corrigiu — mas inventando.** Pedindo para `ネコ時` (hora do
  "gato") virar uma hora plausível, duas rodadas diferentes devolveram duas
  horas diferentes, nenhuma vinda de lugar nenhum. Uma legenda errada mas
  plausível é **pior** que uma visivelmente quebrada — ninguém desconfia da
  primeira.
- **A versão que ficou proíbe inventar fato específico** (número, hora, data,
  nome, lugar) e só permite suavizar a palavra solta quando ela não carrega
  um desses. Testado em quatro rodadas (hora, nome, telefone, mais o caso
  real de câmera) e mais uma rodada juntando com as regras de gênero — zero
  fatos inventados, e o `写真真経` seguiu virando "tirar uma foto" limpo, sem
  fantasiar um número em nenhum dos casos.

**A causa real do "não traduziu" apareceu testando pelo app de verdade.**
`tradutor-verify traduzir` (o gate isolado) nunca reproduziu a falha — sempre
traduzia certo. Rodando os mesmos vídeos pelo caminho de verdade (`open -n
build/Tradutor.app --args --selftest-job ...`), um vídeo em inglês voltou
**inteiro em inglês** 3 de 3 vezes: `N::` batendo linha por linha, contagem
certa, só que cada tradução era a própria origem devolvida sem traduzir.
Nenhum erro, nenhuma quebra de formato — `GeminiWeb.parse` aceitava porque
a forma estava certa. Rodando o binário direto (sem `open`), a mesma
tradução saiu certa. Suspeita, não confirmada: limite de uso da sessão
anônima que não avisa — o site devolve uma resposta com a forma certa e o
conteúdo errado, em vez de um erro.

`GeminiWeb.pareceIntocado` compara origem e tradução linha a linha (só as
com mais de três palavras, pra não confundir interjeição/nome que
legitimamente fica igual) e desconfia quando a **maioria** ficou idêntica.
Pegando isso, `GeminiDriver` recomeça a conversa e tenta de novo uma vez;
falhando de novo, vira `GeminiWebError.untranslated` (erro de verdade, com
log em `/tmp/tradutor-gemini-erro.txt`) em vez de gravar a legenda em
inglês sem avisar ninguém. Depois do conserto: o mesmo vídeo que falhou 3
de 3 passou 3 de 3. Retestando os outros quatro vídeos com esse build, um
lote esbarrou na mesma falha e a rede pegou — subiu como erro de verdade em
vez de sair calado, e a tentativa seguinte passou. É o comportamento
certo: falha visível, não legenda errada sem aviso.

**Frase virou pergunta sem motivo — outra forma do mesmo defeito.** Relatado
em 15/09/2026: uma fala afirmativa em inglês saiu com ponto de interrogação
em português, sem nada no original pedindo isso. É a regra 9 (não inventar
fato) de novo, agora sobre a **intenção da frase**: a regra 11 do prompt
proíbe mudar afirmação para pergunta (ou o contrário) e manda decidir só
pela pontuação e estrutura da origem, nunca pelo que soaria mais natural.
Testado com 16 frases inglesas armadilhadas — afirmação com jeito de
pergunta retórica, tom de deboche, frase incompleta de efeito — zero
inversões em duas rodadas.

### Hunyuan-MT-7B: o tradutor local fora do processo

Pesos abertos, especializado em tradução, 33 idiomas. `Scripts/hunyuan-setup.sh`
cria o ambiente (≈4,5 GB em 4 bits) e o motor só aparece quando ele existe.

- **O processo fica vivo entre as falas** — um 7B leva dezenas de segundos para
  carregar. A primeira linha da saída é o aviso de que o modelo carregou; sem
  esperá-la, a primeira fala falharia.
- **Uma fala por requisição** — várias juntas devolvem um bloco e a contagem
  deixa de ser garantida.

Medido no vídeo de 9 minutos, mesmo reconhecimento:

```
             tempo    legendas   caracteres
Apple         32 s        73        3 607
DeepL         18 s        78        3 624
Hunyuan       84 s        87        4 314
```

Rápido o bastante (0,18× o vídeo). **Gênero fica no nível da Apple, não no do
DeepL** (`優しい先輩で` → "um colega" contra "uma colega" do DeepL). **E escreve
24% mais**: 4 500 caracteres contra 3 624, o que vira 86 legendas contra 78.

**Ele conversava dentro da legenda**, duas vezes em 87 ("あ" → "Ah… Parece que
houve um erro na trad"). Dois consertos mataram os dois casos: a fala anterior
vai como **turno já respondido** (custa ~13% de tempo, e mostra ao modelo o
formato certo) e **fala de uma palavra não vai para o modelo**
(`shortestForModel`, menos de 4 caracteres sem espaço). Resultado: zero
comentários em 86 legendas. Gênero não melhorou.

**Onde ele ganha da Apple:** compreensão. 三角筋 → "músculos deltoides" (a
Apple escreveu "músculos triângulos").

**Falar com o processo travava o app** — três defeitos no mesmo ponto, vistos
com o app a 100% de CPU por 12 minutos:

- `availableData` **bloqueia** até chegar byte ou o pipe fechar; o prazo e o
  cancelamento só eram olhados entre leituras. Hoje o descritor é `O_NONBLOCK`.
- **Pipe fechado não era distinguido de "ainda não chegou"**: com o servidor
  morto o laço esperava o prazo inteiro. `lerSemBloquear` separa as três
  respostas.
- **`terminate()` é SIGTERM**, e o servidor pode estar dentro de uma chamada do
  Metal que não atende sinal — ficava vivo com 4,5 GB disputando GPU. Agora
  espera 2 s e escala para `SIGKILL`.

### Tamanho de lote

**O custo é por string, não por requisição nem por caractere.**

```
 10 por requisição:  47 068 ms        40 falas inteiras:  11 679 ms (1852 chars)
 40 por requisição:  47 049 ms       204 pedaços:         27 074 ms (1688 chars)
 80 por requisição:  47 359 ms
160 por requisição:  47 312 ms
```

2,3× mais lento com menos caracteres, só por estar picado. Consequências:

- O lote de 40 fica por inércia, não por ganho. Só não descer abaixo de 10.
- **Legenda mais curta custa mais tradução**: identificar locutor foi de 61
  para 102 legendas e a tradução de 34 s para 45 s.
- **A sobreposição de contexto saiu** (`contextOverlap = 0`): reenviava 10
  legendas por lote e string reenviada custa como nova — 44,4 s contra 37,1 s,
  15% do tempo total.
- **A espera sem progresso é real**: o framework devolve o lote inteiro de uma
  vez. `SubtitleFileBuilder.Progress.waiting` avisa que a requisição está no
  ar. Reduzir o lote para 10 daria quatro vezes mais atualizações por ~1% de
  tempo, e foi **descartado**: o contexto do tradutor é o que está na
  requisição, e mexer nele para melhorar a barra troca qualidade por percepção.

### A sobreposição de contexto não fazia o que dizia

`tradutor-verify sobreposicao` planta o caso que a justificava — "Marina… **She**
is the lead engineer" antes da borda do lote, "the engineer" depois:

```
mudaram: 0 das 5 na borda, 0 de 45 no total
gênero feminino acertado na borda: com 10 = 0, com 0 = 0
```

Idêntico, e errado nos dois. `tradutor-verify dialogo` mostra o mesmo com as
frases na **mesma** requisição: o framework da Apple não resolve gênero por
contexto, nem a dez linhas nem a uma. No vídeo real, tirar a sobreposição muda
10 de 107 legendas, metade para melhor e metade para pior. Loteria de 10% por
15% do tempo. O campo continua lá para quem medir com outro tradutor.

### Maiúscula de começo de frase

O tradutor do sistema devolve minúscula na maioria das falas curtas: 15 de 57.

Prefixar cada fala com travessão até o tradutor sobe para 40 de 57 **mas muda
42 das 57**, com regressões de sentido ("sim, **eu** tenho vinte anos" virou
"sim, **ele** tem"). Com o nome do locutor no lugar, outras 15 mudam, metade
para pior, e o gênero continua errado. Os dois foram descartados;
`tradutor-verify prefixo-ab` reproduz.

O que ficou é `SubtitleFileBuilder.capitalizeSentences`: **52 de 57 com
maiúscula e zero mudanças de texto**. Só capitaliza quem começa frase, porque
`enforceLineLimit` corta legenda no meio da frase.

### Retraduzir sem reconhecer de novo

O botão refaz **só** a tradução; o rótulo do cabeçalho diz os motores que
**rodaram** (`Apple → DeepL (site)`), não os dos seletores.

Entre `makeCues` e `translate` não há mais nada no caminho — glossário, lote,
quebra e maiúscula moram dentro do `translate` —, então guardar o rascunho e
chamar `translate` de novo dá o que outra geração daria. O autoteste confere:
**45 de 45 idênticas** com a Apple. E dá o que gerar de novo não dá: o mesmo
corte e os mesmos locutores.

```
                            geração inteira   só a tradução
ja-musica · Whisper              13,5 s           1,7 s
ja-longo  · Apple                49,6 s          39,4 s
en-dialogo · Apple               14,9 s          10,3 s
en-conversa · Parakeet           16,2 s          15,7 s
```

Quatro decisões:

- **O que está na tela não sai enquanto a nova tradução é feita**, nem se ela
  falhar. Por isso `onBatch` fica de fora aqui.
- **Um tradutor vivo por vez**: a janela do DeepL fecha sozinha no fim (20 a
  30 ms depois do último bloco) e o Hunyuan devolve os 4,5 GB. Antes ninguém
  chamava `reset()` e os dois ficavam vivos até o app fechar.
- **Ao importar um `.srt`, a janela pergunta se ele contém o original ou a
  tradução**. Original vira rascunho em `source` e passa só pela tradução,
  preservando os timecodes; tradução é exibida diretamente.
- **A exportação também pergunta a faixa**: original usa o idioma falado no
  nome do arquivo, tradução usa o destino.
- **Igualdade estrita só vale para tradutor determinístico** — o DeepL mudou 5
  de 20 numa terceira passada. E **cancelar e retomar no mesmo instante** deixa
  o lote anterior em voo: 19,6 s contra 10,4 s.

### Falhou, falhou: nenhum tradutor de reserva

Pedido em 14/09/2026. Antes, bloco que o DeepL ou o Google não entregasse caía
para a Apple, e o lote perdido saía no idioma de origem com um aviso de uma
linha na barra. Quem escolheu o DeepL escolheu pela qualidade dele e recebia
outra coisa sem perceber — o aviso não é lido.

Hoje a falha sobe: `DeepLWebTranslator` e `WebAPI.porBlocos` propagam o erro,
`translate` conta os lotes perdidos em `failedBatches`, e `translateDraft`
lança `SubtitleFileError.translationFailed`. A janela de legendas mostra uma
faixa vermelha com a mensagem e um botão **Tentar novamente**.

**Tentar de novo custa só a tradução.** `retryFailed` cai em `retranslate()`
quando o rascunho do reconhecimento está de pé, que é o caso sempre que quem
falhou foi a tradução — reconhecer de novo levaria minutos e daria o mesmo
texto.

Duas exceções, e as duas são roteamento, não falha:

- **Par que o DeepL não cobre** agora também é erro, em vez de ir calado para
  a Apple.
- **Fala de uma palavra no Hunyuan** continua indo para a Apple
  (`shortestForModel`): é o que impede o modelo de conversar dentro da legenda,
  e foi medido — ver a seção dele.

`translationNotice` continua existindo porque `translate` é usado sozinho nos
gates, e porque **resposta com contagem diferente da entrada é descartada
inteira** — o defeito que não devolve erro, e que agora também derruba a
geração.

---

## Quem fala

`SpeakerDiarizer` roda o `DiarizerManager` ou o `OfflineSortformerDiarizer` do
FluidAudio sobre o áudio de 16 kHz. É **outro modelo**, não recurso do
reconhecedor; vale para qualquer motor que marque tempo. Só em vídeo.

O resultado entra **antes** do agrupamento, porque a troca de locutor é
fronteira de legenda. No arquivo a troca ganha travessão; o nome não vai para o
`.srt` porque ocuparia metade da linha. A regra do travessão é **uma só**, em
`SpeakerMark`, usada pelo `SRTWriter` e pela janela — antes a janela mostrava
só a cor e o arquivo saía com travessão, e o travessão muda a largura da linha.
**Trecho sem locutor no meio não é troca de pessoa**: só um locutor conhecido
substitui o anterior (`pruneTinyVoices` produz esses buracos de propósito).

| Escolha | Valor | Por quê |
|---|---|---|
| Modelo padrão | **Sortformer** | 1,4 s contra 3,6 s, 101 de 104 legendas marcadas contra 114 de 123, e repetível |
| `minimumSpeech` | **0,5 s** | o padrão de 1 s descarta a troca curta: 87 faixas e 133 s contra 175 e 201 s |
| `minimumVoiceTime` | **2 s** | `pruneTinyVoices` descarta voz de 1 s e o trecho fica **sem** locutor em vez de com o do vizinho |
| `clusteringThreshold` | **0,70** | varrido de 0,50 a 0,90; único que preserva distinção nos quatro arquivos. Acima de 0,71 o recorte de 96 s colapsa para uma voz |
| `sameVoiceThreshold` | **0,50** | varrido de 0,35 a 0,65; acerta de 0,45 a 0,60, e em 0,65 o vídeo em inglês colapsa duas vozes numa |
| `boundaryLead` | **0,50 s** | ver "as fronteiras chegavam tarde" |
| `chunkOverlap` | **2 s** | sobreposição entre os blocos de 10 s do agrupamento. O padrão do FluidAudio é 0 e a mesma pessoa muda de rótulo entre blocos: acerto de 88→91%, 72→78% e 61→61% nos três gabaritos. 5 s piora o inglês e dobra o tempo |

### Qual modelo é melhor, contra gabarito humano

`Videos Exemplo/*.quem-fala*.txt` tem a marcação à mão. Acerto de identidade
por legenda, pelo mapeamento de maioria:

```
                        sortformer   agrupamento   agrupamento
                                       (0,70)      (melhor limiar)
9 min, 2 pessoas            97%          88%          88%  (0,45 e 0,55)
161 s inglês, 5 pessoas     70%          59%          61%  (0,45)
97 s japonês, 10 pessoas    50%          56%          78%  (0,45)
```

**O Sortformer ganha nos casos normais e perde onde há muita gente** — teto de
quatro vozes da exportação CoreML, e nenhum ajuste nosso resolve. O agrupamento
não tem teto, mas não existe limiar bom para os dois extremos: 0,45 acerta o
vídeo de dez pessoas e devolve doze vozes no de duas.

O padrão fica no Sortformer por três razões medidas: ganha no caso comum, é 2 a
3× mais rápido, e o erro dele (**dividir** uma pessoa em vários rótulos) tem
conserto pela fusão, enquanto o do agrupamento (**fundir** duas numa) não tem.

```
                     vozes   faixas   tempo   depois da fusão
9 min japonês (2 pessoas)
  agrupamento            3     180     3,5 s        3
  sortformer             4     216     1,3 s        2   ✓
97 s japonês
  agrupamento            3      28     0,5 s        3
  sortformer             3      26     0,3 s        3
161 s inglês
  agrupamento            3      43     0,8 s        3
  sortformer             4      33     0,4 s        3
161 s inglês (2)
  agrupamento            2      37     0,6 s        2
  sortformer             4      28     0,3 s        4
```

Duas armadilhas: `numClusters` **não** serve para dizer quantas vozes esperar
(este caminho só olha o limiar), e o número de vozes do agrupamento **oscila
entre execuções** (2 em cinco medições e 3 em uma, no mesmo arquivo). O
Sortformer não acerta a contagem melhor, mas erra sempre igual — e é isso que
permite medir. **"Determinístico" seria forte demais**: a auditoria achou 3
vozes numa execução e 4 na outra no vídeo de 9 minutos. Guarde entrada e saída
em vez de confiar que a segunda execução repete.

### Um identificador por pessoa, não por pedaço de conversa

O Sortformer parte a mesma pessoa em mais de um identificador — quatro numa
conversa de duas. `SpeakerPalette` numera por ordem de aparição, então a mesma
pessoa trocava de cor no meio do vídeo.

`SpeakerDiarizer.mergeSameVoice` extrai um embedding por identificador (até
12 s, ignorando quem não junta 2 s) e funde os que ficam perto. **Encadeamento
simples**: se A se parece com B e B com C, os três ficam juntos — a mesma
pessoa muda de tom ao longo da conversa.

```
                      identificadores   depois da fusão
9 min japonês (2 pessoas)      4               2
97 s japonês                   3               3
161 s inglês                   4               3
161 s inglês (2)               4               4
```

Custa **0,15 s**. Não muda texto, cobertura nem número de travessões; muda a
identidade. **Fundir demais é pior que fundir de menos** — separado sobra uma
cor, fundido some uma pessoa. `TRADUTOR_SEM_FUSAO=1` desliga.

### As fronteiras de voz chegavam tarde

```
vídeo em inglês (5 pessoas)      legendas com duas pessoas   locutor certo
  sem fronteiras de voz                    2 de 43              31 de 43
  fronteiras cruas                        12 de 43              33 de 43
  fronteiras adiantadas 0,50 s             2 de 43              31 de 43

vídeo japonês com música (10 pessoas)
  sem fronteiras de voz                    1 de 19               8 de 18
  fronteiras cruas                         4 de 22              10 de 21
  fronteiras adiantadas 0,50 s             2 de 22              10 de 21
```

**A causa é atraso sistemático**: a troca real em 12,06 s e o corte em 13,06;
21,84 e 23,28; 49,20 e 50,14. Sempre ~1 s tarde, o bastante para a primeira
palavra de quem entra ficar na legenda de quem sai. Varrido contra os três
gabaritos, contando legendas que juntam duas pessoas:

```
adiantamento      cruas  0,25  0,40  0,50  0,60  0,75
9 min, 2 pessoas      6     6     2     1     1     3
inglês, 5 pessoas    12     9     3     2     2     2
japonês, 10 pessoas   4     2     2     2     2     2
```

`boundaryLead` fica em **0,50 s**: empata com 0,60 e ganha nos três; acima
disso o vídeo de duas pessoas, que é o caso comum, volta a piorar.

Duas suspeitas medidas e descartadas: descartar fronteira vinda de faixa curta
(uma a menos em 29, resultado idêntico) e encaixar cada fronteira no vale de
energia mais próximo (idem).

**A medição que justificava as fronteiras era circular** — contava "trechos com
duas vozes" usando a própria diarização como juiz. Com gabarito humano o sinal
inverte. Toda métrica de locutor daqui para frente é contra gabarito.

### Fronteira de voz dentro do trecho

O trecho do reconhecedor é **indivisível** daí para frente: `assign` dá a ele o
locutor que mais o cobre, e a palavra da outra pessoa vai junto com o rótulo
errado.

```
                trechos com duas vozes   voz minoritária
Qwen 0.6B              0 de 211 (0%)              0,0 s
Whisper turbo          1 de  75 (1%)              0,6 s
Apple                 23 de 132 (17%)            17,4 s
Parakeet v3 (inglês)   0 de 320 (0%)              0,0 s
```

O Qwen corta em cada fala; o Parakeet devolve um trecho por palavra. **Só a
Apple sofre**, porque `phrases` monta frases longas. O conserto foi onde o
problema nasce: `phrases` recebe as fronteiras e fecha o trecho quando o
**meio** da palavra muda de lado — comparar contra o início ou o fim não serve,
porque a fronteira erra ±100 ms e o corte caía uma palavra tarde.

```
Apple, mesmo vídeo         sem fronteiras   com fronteiras
trechos com duas vozes      23 de 132 (17%)   1 de 251 (0%)
voz minoritária                    17,4 s           0,3 s
legendas com locutor             81 de 82        98 de 100
```

A abertura que saía como uma legenda só virou quatro, uma por pessoa. O custo é
fragmentar (132 → 251 trechos, 82 → 100 legendas), e vale **só com a
identificação ligada**. Como a diarização só precisa do áudio, ela roda
**antes** do reconhecimento; `GenerationStep` mudou de ordem e há verificação
para não voltar.

**O que a separação não alcança:** interjeição de um segundo colada na fala do
outro. A Apple reconhece `Entendi` como `e` e alinha ao trecho da outra pessoa
— o texto está no lugar errado antes de qualquer corte. Quem se sai melhor é o
Parakeet, com tempo por palavra (1 legenda misturada de 7 contra 3 de 5).

**Limite do arnês:** as vozes do `say` são menos separáveis que gente de
verdade — num diálogo o agrupamento achou **uma** voz só. Serve para medir
corte e alinhamento, não diarização nem captação.

### O travessão está certo; o que erra é o modelo

**0 travessões fora de lugar** em 59 legendas com agrupamento e 61 com
Sortformer. O que muda é o rótulo: o agrupamento funde as duas pessoas na
abertura e aí não há troca para marcar.

### Uma cor por locutor

`SpeakerPalette`: branco, amarelo, ciano e verde, na ordem de quem falou
primeiro — as cores da legenda oculta da TV americana (CEA-608). No `.srt` vai
como `<font color="#RRGGBB">` envolvendo o bloco depois da quebra (uma tag por
linha dobraria o arquivo). Quem não entende mostra a tag, e por isso é
**opção**. O `SRTParser` já limpava tags.

`SpeakerPalette.index(for:)` devolve `nil` para rótulo sem número — pintar de
branco um locutor desconhecido seria inventar identidade.

**Na lista, o primeiro locutor não pode ser branco**: a barra saía em
(255,255,255) sobre fundo (249,249,249). `listSpeakerColor` troca pelo azul de
destaque; sobre o vídeo continua branco.

Na janela os três controles ficam num menu só (ícone de duas pessoas); no
painel ficam **visíveis mesmo desligados**, apagados — escondidos atrás do
interruptor, ninguém os achava. `TRADUTOR_MEASURE_POPOVER=1` desenha o painel
em `/tmp/painel.png`.

---

## Áudio

### Ganho: só para áudio muito baixo, e só em vídeo

`boostQuietAudio` mede o arquivo uma vez e só multiplica com RMS **abaixo de
0,003** (~−50 dBFS, áudio quebrado, não fala baixa). Ganho genérico piora: com
20 dB de atenuação (RMS ~0,01, que a regra deixa passar), o Whisper caiu de 90
para 86 caracteres.

Com 40 dB (RMS ~0,001), onde a regra age:

```
                                    sem ganho      com ganho
ja-longo    · Whisper                29 car.        87 car.
ja-musica   · Whisper           126 e 77 car.     134 e 134
ja-musica   · Apple                 109            116
en-conversa · Qwen 1.7B             345            363
en-conversa · Apple                 347            350
en-dialogo  · Apple                 403            403
```

O ganho não só recupera texto como **estabiliza** o que a retentativa com
temperatura tornava aleatório. A identificação de vozes melhora junto (erro de
faixa contra o nível original: 4,45 s → 0,80 s no ja-musica com Sortformer).
Nível normal e moderadamente baixo passam **intactos**, e silêncio digital não
vira sinal.

### A fala baixa que some é a baixa EM RELAÇÃO ao resto

**Baixar o arquivo inteiro não perde nada**: atenuando 12 a 40 dB, Whisper e
Apple devolvem o mesmo texto — o modelo normaliza a janela. E **os três
limiares do `isRealSpeech` nunca disparam** (zero segmentos filtrados em todos
os vídeos e atenuações).

O que reproduz a queixa é atenuar **metade das janelas de 20 s**, deixando fala
alta e baixa dentro do mesmo trecho. `levelQuietSpeech` iguala o nível em
janelas de 0,5 s, dentro do `decode`, e vale para **todos** os motores de
vídeo:

```
                            sem nivelar   nivelado   (sem atenuar)
vídeo com música  −20 dB           696        720          723
vídeo com música  −30 dB           603        720          723
vídeo de 9 min    −20 dB          4268       4415         4415
vídeo de 9 min    −30 dB          4170       4323         4415
Qwen 0.6B, música −30 dB           727        777            —
```

**Esses números são bytes UTF-8** (`wc -m` sem locale; kanji ocupa três). As
razões valem; a unidade não. Contado de verdade são 242 e 1492 caracteres. Use
`LC_ALL=en_US.UTF-8` ou conte em Swift.

**No Whisper o ganho vem com um segundo efeito:** cinco execuções do vídeo com
música a −30 dB deram 483 · 422 · 626 · 662 · 494 sem nivelar e 728 · 773 ·
734 · 719 · 740 com. No áudio sem atenuação as cinco passaram a dar
**exatamente 703** (antes 729 a 782), e o texto fica mais correto (`海賊王` no
lugar de `海底王`).

Quatro decisões, cada uma com o número que a obrigou:

- **O fundo é medido em quadros de 20 ms**, não na janela de 0,5 s: com metade
  do arquivo em fala baixa, o percentil baixo cai dentro dessa metade e ela
  vira "ruído" (ganho 1, nada recuperado).
- **O piso é relativo ao fundo, nunca absoluto**: com piso fixo em 0,0005 o
  ruído de sala subiu 20× e o detector viu fala onde não havia (196 trechos
  contra 186). Ruído amplificado vira alucinação com timecode.
- **Só amplifica, e com rampa**: degrau de ganho no meio de uma palavra é um
  clique, que é o que o VAD confunde com ataque de fala.
- **Medir só a banda da voz não paga**: passa-alta em 200 Hz antes de medir
  empata em tudo (723 → 714 no vídeo com música).

`TRADUTOR_SEM_NIVELAMENTO=1` desliga.

**O que ganho nenhum resolve:** fala 25 dB abaixo de fundo grave contínuo. Com
rumble em −27 dBFS a Apple cai de 4170 para 2077 caracteres e nivelar não muda
nada. Ali falta supressão de ruído.

### Quem ganhou o quê: a conta por locutor

`tradutor-verify cobertura` separa as faixas por locutor e conta voz, alcance e
caracteres. Com a Apple, atenuando −30 dB nas janelas alternadas:

```
vídeo com música (97 s)        voz (s)   reconhecido (s)      caracteres
                                          sem niv → com     sem niv → com
locutor da 1ª fala (3,20 s)      40,72    24,56 → 35,84        99 → 138
2º locutor        (13,12 s)      17,60    16,74 → 15,90        82 →  81
3º locutor        (72,88 s)       4,40     3,60 →  3,88        22 →  23

vídeo de 9 min (540 s)
locutor da 1ª fala (13,84 s)    139,52   128,40 → 132,64      855 → 880
2º locutor        (16,16 s)      53,84    49,62 → 50,42       354 → 371
3º locutor       (399,04 s)      18,64    17,24 → 17,80       151 → 152
4º locutor       (381,76 s)       2,72     2,72 →  2,72        32 →  33
```

**A recuperação é concentrada em quem estava baixo**: o locutor da primeira
fala vai de 99 para 138 caracteres, que é exatamente o que ele tem sem
atenuação nenhuma. No áudio sem atenuar, a conta fica igual com e sem nivelar.

**"Locutor" aqui é identificador do modelo, não pessoa** — o Sortformer partiu
duas pessoas em quatro identificadores. Quem usar esta tabela para falar de
gênero precisa dessa etapa a mais; o gate imprime um aviso.

**A régua não pode ser tratada junto com o áudio.** `SpeechEnergy.regions`
rodava sobre o áudio já nivelado e o denominador mudava entre as execuções que
se queria comparar (402 s contra 357 s de "voz"). `MeasurementAudio` separa:
`original` é o PCM cru, de onde saem as regiões e a diarização; `samples` é o
tratado, que vai ao reconhecedor. Duas guardas: as faixas de voz são
**congeladas em arquivo** (`--referencia`, com SHA256 do PCM, senão metade da
diferença seria mudança de diarização) e `extractAudio(processing: false)`
existe só para isto.

### Filtro de graves: medido e recusado

Dois biquads em cascata (vDSP), 100 e 180 Hz, sobre rumble sintético:

```
Apple, caracteres              none   hp100   hp180
vídeo com música, rumble −33    198     204     246
vídeo com música, rumble −21    190     197     239
vídeo de 9 min, rumble −39     1416    1329    1459
vídeo de 9 min, rumble −21     1421    1401    1283
```

Ganha num vídeo, some noutro, e no Whisper vira instabilidade (266 · 266 · 266
sem filtro, 210 · 274 · 273 com). Em inglês é neutro em volume e ainda muda o
texto (similaridade 0,958). E o teste era o **mais favorável possível** — ruído
puramente grave e sintético. Nada foi acrescentado.

**`AVAudioUnitEffect` de voice processing não serve**: é para captura ao vivo e
não funciona no modo de renderização offline, que é o que a legenda usa.

### Subtração espectral: medida e reprovada

O fundo do vídeo difícil **é** estacionário (0,06 a 0,12 de diferença entre
terços, abaixo do 0,15 que separaria de ambiente vivo), ou seja, é o caso em
que ela se aplica. Implementada em vDSP:

```
                    falas reconhecidas pela Apple
original                    5
subtração suave             4
subtração média             4
subtração forte             2
```

Quanto mais limpa, menos texto, e a diarização não muda. O reconhecedor moderno
já foi treinado com ruído; a distorção custa mais que o ruído que ela tira.

Duas armadilhas do arnês: **silêncio digital não é fundo** (10,7% das amostras
são zero exato, e estimar pelos quadros mais quietos dava fundo zero) e
**`AVAudioFile` só corrige o cabeçalho quando é liberado** (o RIFF saía
dizendo 4088 bytes e o reconhecedor devolvia nada).

---

## Legenda

### O ponto final japonês não fechava legenda

`makeCues` fechava na pontuação, e a lista era `".!?…"` — sem `。`, `！` e `？`.
Em japonês a legenda só fechava no teto de 7 s, na pausa de 0,8 s ou nos 150
caracteres, e duas falas iam para a mesma legenda.

```
                     legendas   fins de frase presos no MEIO
japonês, antes            61              55 de 99
japonês, depois          102               8 de 99
inglês, antes             48               5 de 52
inglês, depois            47               5 de 52
```

O alinhamento melhorou junto: desvio médio do fim de +1,04 s para +0,56 s. A
lista virou `SentenceSplitter.sentenceEnders`, com irmã para oração
(`clauseEnders`, com `、`) — o mesmo `".!?…"` estava escrito em três lugares,
os três cegos para japonês.

### O teto de tempo cortava a palavra japonesa ao meio

`phrases` fechava o trecho ao passar de 5 s, onde quer que estivesse. Em
japonês os runs são sub-palavra e o corte partia a palavra (`今日` virando
`今 / 日`). Agora o fecho espera **lugar seguro** (espaço, ou pontuação de
frase ou de oração) a partir de 5 s, com teto duro de 7 s.

```
                          trechos     cortes no meio da palavra
ja-longo    sem locutor   132 → 120          18 → 6
ja-longo    com locutor   235 → 232           4 → 1
ja-musica   sem locutor    21 →  20           5 → 3
ja-musica   com locutor    31 →  30           3 → 2
en-conversa ambos          54 →  51           3 → 0
en-dialogo  ambos          44 →  44           0 → 0
```

**O texto sai idêntico, caractere por caractere** — só muda onde o trecho
fecha.

**O teto tem de ser conferido ANTES de acrescentar o run.** Conferindo depois,
o trecho estoura pelo tamanho do run que o cruzou: 0 → 5 trechos acima de 7 s,
o maior com 7,98 s, que vira legenda de 8,23 s. Quem apanhava isso era o
`clamp`, ou seja, **o último segundo de fala ficava sem legenda na tela**, sem
nada reclamar.

**A folga do teto fica como está.** `hardCeiling` (7,0) + `leadIn` (0,25)
passam de `maximumDuration` (7,0), e 4 legendas de 107 saem truncadas em
7,000 s. Baixar o teto para 6,75 **piora**: cortes no meio da palavra vão de 5
para 6 no japonês e de 0 para 1 no inglês. Texto partido é pior que 0,25 s a
menos numa legenda que já está no limite de leitura.

### O silêncio precisa chegar ao agrupador

Gabarito humano apontou fala perdida na legenda 44 do vídeo de 9 minutos. O
texto **não** estava perdido no reconhecimento:

```
221,34–227,34   お疲れ様あれさんお疲れ様です。
```

Duas falas num trecho de 6 s, apesar de silêncio real em 225,0–226,0. A Apple
então colapsou as duas em "obrigado por seu trabalho árduo" e a fala do homem
desapareceu. Reconhecendo o pedaço isolado, ela devolve as duas separadas — é o
contexto grande que cola.

O conserto tem duas metades, e **só as duas juntas funcionam**:

- `SpeechEnergy.pauseBoundaries` vai para o `phrases`, que fecha o trecho no
  silêncio. Sozinho não resolve: os pedaços saem **contíguos** e `makeCues`
  junta de volta.
- `SpeechEnergy.silences` vai para o `makeCues`, que fecha a legenda quando a
  junção cai dentro de um silêncio medido. **Casa por intervalo, não por
  ponto** — o reconhecedor corta onde a palavra cruza a fronteira (225,12 s) e
  o silêncio está em 225,0–226,0.

```
                      legendas com duas pessoas   locutor certo
9 min, 2 pessoas         1 → 1  (139 → 150)         33 → 35
inglês, 5 pessoas        2 → 2  ( 43 →  43)         31 → 31
japonês, 10 pessoas      2 → 3  ( 22 →  23)         10 → 11
```

Neutro na contaminação, melhor na identidade em dois, e recupera fala inteira
que antes sumia — que a métrica não capta, porque o gabarito marcou aquela
legenda com uma pessoa só. Custa 110 → 116 legendas. `SpeechEnergy.subtitlePause`
é 0,8 s; com 0,6 s a contaminação piora. `TRADUTOR_SEM_PAUSAS=1` desliga.

**Nos outros motores é neutro** (fala sem legenda: Whisper 116,3 → 116,3 s;
Qwen 14,4 → 14,4 s; Parakeet 10,7 → 10,6 s) — nenhum deles produz o trecho de
seis segundos com duas pessoas dentro.

**Cortar o trecho no silêncio, a primeira tentativa, foi descartada.** 44 dos
119 trechos da Apple carregam silêncio de 0,6 s ou mais:

```
limiar        trechos   com pausa dentro   caracteres
desligado        119           49             1497
0,6 s            171           40             1495
1,0 s            132           47             1496
1,5 s            120           48             1501
```

O melhor caso corta 9 dos 49 e cobra 44% de fragmentação. O run é indivisível:
a fronteira cai entre runs de qualquer jeito, então fragmenta sem separar o que
estava junto. **A métrica estava errada duas vezes**: media trecho em vez de
legenda, e não enxergava o dano real, que é fala inteira sumindo na tradução.
Foi preciso gabarito humano para ver.

### A legenda que apaga a tela no meio da fala

```
                buracos abaixo de 1 s     tela apagada
Whisper turbo          38 de 106              25,5 s
Apple                  10 de 105               6,4 s
```

**Não é defeito do Whisper nem do agrupamento**: ele pontua cada fala curta e o
agrupador fecha na pontuação, que é o que se quer. Faltava **segurar a legenda
até a seguinte**. `bridgeShortGaps` estende o fim até `minimumGap` (0,08 s,
dois quadros a 24 fps) antes da próxima, quando o buraco é menor que
`maximumGap` (1,0 s). Nunca encurta e nunca passa do teto:

```
                tela apagada em buracos < 1 s     maior legenda
Whisper  antes           25,5 s                      6,85 s
Whisper  depois           4,4 s                      7,00 s
Apple    antes            6,4 s                      7,00 s
Apple    depois           0,9 s                      7,00 s
```

O conserto é em `makeCues`, **antes da tradução** — vale para qualquer tradutor
e qualquer reconhecedor.

### A legenda de três linhas, e por que ela voltava

`enforceLineLimit` repartia **uma vez só** e contava `caracteres ÷ (42 × 2)`,
supondo que toda linha chega aos 42. Não chega: a quebra procura pontuação e
espaço, então 81 caracteres podem precisar de três linhas. Intermitente — 2 de
4 gerações do mesmo vídeo.

Conserto: a conta passou a ser por **linhas** (`linhas ÷ 2`) e o resultado volta
para outra passada, até três (texto sem onde quebrar não pode entrar em laço).

**E a terceira linha voltava pelo travessão**: `enforceLineLimit` media o texto
**sem** ele, e `— ` ocupa duas colunas da primeira linha. `splitOversized` passou
a medir `SpeakerMark.decorate(...)` e a repartir o texto puro — só a primeira
parte leva travessão. Nos quatro vídeos: **3 legendas de três linhas viraram 0**.

### Identidade não pode se perder depois do reconhecimento

```
                   legendas com cor          três linhas   acima de 7 s
antes                193 de 220 (88%)              3             4
depois               235 de 246 (96%)              0             0
```

- **`splitOversized` não copiava `speaker`**: legenda longa identificada virava
  três sem dono.
- **`mergeTinyCues` juntava resposta curta de outra pessoa** — "Você entregou o
  relatório?" e "Sim." viravam uma legenda atribuída a quem perguntou. Agora só
  junta com o mesmo locutor.
- **`SpeakerDiarizer.assign` escolhia a maior faixa isolada**, não a voz que
  mais cobre o trecho: voz A em 0–3 s e 7–10 s soma 6 s e perdia para os 4 s de
  B. Empate fica com quem falou primeiro, para a saída não mudar entre
  execuções.

O preço é fragmentar (107 → 128 legendas, 44 s → 45-47 s de geração).

**A janela de legendas não conferia nada disso**, e é a outra metade do
produto. O autoteste dela mede `displayText` (o texto como a janela mostra,
travessão incluído) e a duração. Duas verificações que dependiam de dado:

- **"Voltar do meio de uma fala"** usava a legenda de índice 3, fixa; em
  legenda curta o instante caía na seguinte. Hoje procura a primeira com mais
  de 1,3 s.
- **"O reconhecimento mostra progresso"** reprovava num arquivo de 40 s: o
  Whisper decodifica em janelas de 30 s e só relata ao fechar uma. Hoje só vale
  acima de 60 s.

### A largura da linha é a do idioma que vai ser lido

`SRTWriter.render` quebrava em 42, fixo — a convenção latina. Japonês e chinês
cabem em 16 a 20 por linha. Gerando **inglês → japonês** em 161 s:

```
                legendas   linhas   maior linha   linhas acima de 20
42 (fixo)            48       49         42            18
20 (por destino)     49       69         20             0
```

`SubtitleFileBuilder.lineWidth(for:)` decide pelo **destino**. Japonês →
português não muda nada. Coreano fica de fora (usa espaço); tailandês não foi
medido.

**O painel ao vivo não entrou nessa conta** — chama `LineBreaker.wrap` com o
padrão de 58. Traduzir ao vivo para japonês tem o mesmo problema em dobro, não
medido.

### O espaço que não existe em japonês

`よかったです。 頑張ろうね。` — 22 espaços indevidos no vídeo de 9 minutos, de
três origens:

- **o texto do run**, que a Apple devolve com espaço antes da pontuação:
  `Tokens.tightenDense` no `close()` do `phrases` (22 → 12);
- **a junção dos trechos** em `makeCues`, que usava `joined(separator: " ")`:
  `Tokens.join` (12 → 5);
- **`mergeTinyCues`**, que colava com `" " + cue.source` (5 → 0).

Efeito na tradução, isolado do ruído do reconhecedor (mesmo texto, com e sem):

```
linhas com espaço removido                   22 de 104
traduções que mudaram                        18
traduções que mudaram SEM ter espaço          0   ← sem contágio de lote
começam com maiúscula, nas 22 afetadas    com: 0   sem: 14

よかったです。頑張ろうね。
   com espaço:  "foi bom. vamos fazer isso."
   sem espaço:  "Ainda bem. Vamos nos esforçar."
```

**Inglês fica byte a byte igual por construção**: `tightenDense` só age entre
dois caracteres densos e só com **um** espaço.

### Os números latinos que não precisavam mudar

Três constantes suspeitas de serem estreitas para japonês **nunca chegam a
atuar**:

```
SubtitleFileBuilder.maximumCharacters = 150   legenda mais longa: 55 ja, 112 en
PhraseAccumulator.maximumCharacters   =  75   frase mais longa:   42 ja,  70 en
SentenceSplitter.minimumCharacters    =  12   frases japonesas afetadas: 0
```

O mínimo de 12 parecia o mais perigoso (a legenda japonesa tem mediana de 12),
mas ele só gruda frases **dentro de uma frase fechada**, e depois que `。` passou
a fechar frase cada uma chega sozinha. **Não mexer sem uma medição que mostre
elas atuando** — trocar número que não atua é trocar comportamento no escuro.

### Nada de mascarar palavrão

Legenda é transcrição. Auditado motor por motor: só a **Apple** tem como
censurar (`SpeechTranscriber.TranscriptionOption.etiquetteReplacements`), e
`AppleSpeechTranscriber.transcriptionOptions` fica **vazio** —
`tradutor-verify motores` falha se alguém acrescentar algo. WhisperKit,
FluidAudio e o pacote do Qwen não têm lista de palavras, e a tradução da Apple
voltou sem máscara em teste.

O único filtro de texto é `Hallucinations`. Frase de cortesia isolada é
**suspeita, não prova de alucinação**: apagar só pelo texto também apagava
`おやすみなさい` e "Thank you for watching" realmente falados.

`Transcriber.transcribeForSubtitles` é o caminho compartilhado do app e dos
gates: confirma os candidatos no recorte do áudio (±0,5 s), com a Apple já
instalada, antes de descartá-los. Só inglês/japonês, só arquivo. Sem idioma
instalado ou se a conferência falhar, conserva o descarte anterior; nenhum
modelo é baixado. Tempos fora do arquivo não viram recortes vazios — passar
zero amostras ao `SpeechAnalyzer` pode deixá-lo esperando sem fim.

Medido em 14/09/2026: três trechos verdadeiros antes apagados foram
confirmados; dez ocorrências inventadas nas saídas dos vídeos continuaram
rejeitadas. O Whisper mantém os candidatos na saída bruta, mas não os conta
para aceitar uma passada pobre. `transcribeForSubtitles` também retorna vazio
para silêncio digital: três segundos de zeros geravam "Thank you.". Nenhum
limiar de volume foi acrescentado.

### Whisper: não encerrar a janela antes de emitir conteúdo

`suppressBlank = true` só em `transcribeOnce` (arquivo). O filtro nativo
impede espaço/EOT como primeiro token; as retentativas e limiares continuam.
No vídeo difícil, as falas de 7–20 s apareceram em **2/3 execuções contra 0/3**;
a Apple e o Qwen 1.7B reconheceram o mesmo diálogo. Não é garantia de recuperar
sempre: a terceira execução ainda perdeu a abertura. Dois vídeos ingleses e
o japonês curto tiveram texto idêntico com/sem a opção. Silêncio/ruído tiveram
a mesma saída bruta; o bloqueio de zeros é no caminho compartilhado acima.

Rejeitados nesta rodada: processamento sequencial do Whisper (trocou nomes e
idioma), afrouxar o filtro de confiança (não demonstrou recuperação útil), e
relaxar o agrupamento SRT do Qwen (a tradução final ficou idêntica após o
agrupamento do app). Medições e scripts: `scratchpad/qualidade-2026-09-14`.

---

## Armadilhas do sistema

- **A permissão é de Gravação de Tela e Áudio do Sistema.** Negada, não devolve
  erro: o tap abre, o callback dispara na cadência certa, e todos os quadros
  vêm zerados. `CGPreflightScreenCaptureAccess()` **não** é indicador
  confiável — cobre só uma das duas listas.
- **Binário de terminal nunca consegue essa permissão** (o TCC segue o processo
  pai). Só um `.app` assinado, aberto com `open`.
- **Recompilar pode derrubar a permissão** (assinatura ad-hoc muda a cada
  build). Remova o app das duas listas com − e adicione de novo.
- **O aggregate device precisa de sub-dispositivo**: com a lista vazia ele roda
  no clock certo e entrega silêncio — sintoma idêntico ao de permissão negada.
- **`isExclusive` decide inclusão ou exclusão**:
  `initStereoGlobalTapButExcludeProcesses` liga `exclusive` internamente;
  fixá-lo em `false` transformava o tap global em inclusivo de lista vazia.
- **Chrome não toca áudio no processo principal** (vive em
  `com.google.Chrome.helper`). Processos são agrupados por bundle ID do dono.
- **`VideoPlayer` do SwiftUI aborta neste app** (`getSuperclassMetadata` em
  `_AVKit_SwiftUI`). Use `AVPlayerView` via `NSViewRepresentable`.
- **A primeira faixa de áudio não é necessariamente a do idioma.** A faixa é
  escolhida pelo `languageCode`/`extendedLanguageTag` contra o idioma de
  origem, normalizados por `Locale.Language` (resolve "jpn", "ja-JP" e "ja"
  sem tabela). Faixa nenhuma declarando o idioma, a primeira vale.
- **`AVPlayer` escolhe o demuxer pela extensão**: arquivo sem extensão não
  toca, mesmo sendo mp4 válido. Um link temporário `.mp4` resolve.
- **Linha "em branco" com espaços não separava blocos no `.srt` lido**: o
  parser cortava em `\n\n`, e `\n  \n` não é isso — os dois blocos viravam um.
  O app não grava assim; editores gravam.
- **Player novo nasce em volume 1 e sem mudo**: `swapPlayer` já aplicava a
  escolha do usuário, `open` não. E o fim da reprodução não chegava à
  interface — quem avisa é `AVPlayerItemDidPlayToEndTime`.
- **O Whisper alucina no silêncio** (ご視聴ありがとうございました sozinha no
  meio do vídeo). As métricas do modelo não pegam; só o texto denuncia.
- **`DragGesture` entrega deslocamento acumulado, não o passo.** Somá-lo à
  largura atual a cada `onChanged` faz o arrasto acelerar sozinho (12 px
  deslocavam 22). Some ao valor de onde o arrasto partiu. A barra de progresso
  não tem o problema porque usa `value.location`.
- **Legendas podem sair além do fim do vídeo** (uma começando aos 18:04 num
  vídeo de 18:01). `clamp` corta — e o teto de 7 s **vale depois de juntar**
  também: `clamp` roda antes de `mergeTinyCues`, e juntar voltava a passar do
  teto (9,481 s).

---

## Modelos em disco

`~/Library/Application Support/Tradutor/models/` — fora do backup, baixados no
primeiro uso:

```
1,2 GB  whisper/     (turbo)
469 MB  parakeet-tdt-0.6b-v3/    só se escolhido no seletor
 13 MB  speaker-diarization/     vozes: segmentação e embedding
243 MB  sortformer/              vozes: modelo ponta a ponta
```

Fora de `models/`, na mesma pasta:

```
2,2 GB  qwen/       venv Python + Qwen3-ASR 0.6B (Scripts/qwen-setup.sh)
                    +3,4 GB com --grande (o 1.7B)
4,5 GB  hunyuan/    venv Python + Hunyuan-MT-7B em 4 bits
```

**Depois do primeiro download, carregar não usa rede.** Cada reconhecedor
confere o disco antes de chamar a biblioteca:

- Whisper: `WhisperKit.download` consultava o Hugging Face a cada carga (6 s, e
  sem internet falhava). O tokenizador vem de `tokenizerFolder` — sem ele o
  WhisperKit procura em `~/Documents/huggingface` e depois na rede.
- Parakeet: o FluidAudio já pula o download quando acha os arquivos.
- Sortformer: `initializeFromHuggingFace` **não** encaminha a pasta e cai no
  `~/Library/Application Support/FluidAudio`. Quem aceita a pasta é
  `OfflineSortformerModels.loadFromHuggingFace(cacheDirectory:)`, e os modelos
  entram por `diarizer.initialize(models:)`.

### Nada de cache além dos modelos

`CacheCleanup.run()` roda ao abrir, antes de carregar modelo. Antes dela o app
acumulava 3,6 GB em `~/Library/Caches/app.tradutor.instantaneo` e 88 pastas
temporárias.

- **Compilação para o Neural Engine** (`com.apple.e5rt.e5bundlecache`, ~230 MB):
  o Core ML guarda por hash, sem dizer de qual modelo. Trocou o conjunto?
  Incremente `CacheCleanup.modelSetVersion` — a pasta é refeita uma vez (a
  primeira carga leva ~2 min). Pastas de versões antigas do macOS são apagadas
  sempre.
- **Cache HTTP**: `URLCache.shared` zerado, `Cache.db` apagado.
- **Temporários** `tradutor-*` com mais de 1 h: apagados.

Fora do app e **não** tocados por ele: `~/Documents/huggingface` (padrão do
WhisperKit) e `~/Library/Application Support/FluidAudio`.

---

## Estilo

- Comentários em português, explicando **por que**, não o que. Comentário que
  registra uma medição ou um bug caro se preserva.
- Todo bug corrigido ganha uma verificação que falha se ele voltar.
- **Teste nunca escreve em dado do usuário.** O gate da lista de termos já
  destruiu a lista real uma vez: restaurava num `defer` que `exit()` nunca
  executa. Quem guarda dado do usuário aceita um diretório no construtor.
- Antes de trocar um número que tem comentário de medição, meça de novo.

### Importação e exportação de SRT (17/09/2026)

Importar **original** só carrega e guarda o rascunho. O botão de tradução é
a única ação que o traduz. Importar **tradução** carrega apenas essa faixa.
Exportação nunca substitui uma faixa ausente pela outra: original usa
`builder.draft`, antes dos cortes da tradução; tradução usa o resultado.
Os idiomas do conteúdo são guardados independentemente dos seletores.

`--selftest-srt` verifica os dois caminhos sem vídeo, modelo ou rede, antes
da inicialização normal do app; relatório `/tmp/tradutor-srt.txt`. O gate
`legendas` verifica também japonês e ida e volta exata dos milissegundos.
