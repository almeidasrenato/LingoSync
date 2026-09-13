# Tradutor Instantâneo

App macOS que captura o áudio de um aplicativo específico, transcreve e traduz
em tempo real, e também gera legendas `.srt` de arquivos de vídeo.

Tudo roda local. Nada sai da máquina. Sem API paga, sem chave, sem conta.

Alvo: Apple Silicon, macOS 15+. Desenvolvido e medido num **MacBook Air M5, 16 GB**.

---

## Como construir e testar

Não precisa de Xcode — Command Line Tools bastam.

```bash
swift build -c release
Scripts/bundle.sh TradutorApp "Tradutor" Resources/app-Info.plist release
Scripts/bundle.sh tradutor-probe "Tradutor Probe" Resources/probe-app-Info.plist release
open build/Tradutor.app
```

### Verificações

Não há `swift test`: Command Line Tools não trazem `Testing` nem `XCTest`.
As verificações vivem dentro dos próprios binários.

```bash
./.build/release/tradutor-probe selftest      # captura, ring buffer, VAD, agrupamento (39)
./.build/release/tradutor-verify prefixo      # confirmação de prefixo estável
./.build/release/tradutor-verify frases       # corte em frases, sobreposição, tokens
./.build/release/tradutor-verify quebra       # quebra de linha
./.build/release/tradutor-verify tempos       # tempos, limites de legenda, lote que falha
./.build/release/tradutor-verify formatos     # arquivo sem extensão, formato recusado
./.build/release/tradutor-verify legendas     # leitura de .srt
./.build/release/tradutor-verify faixas       # video com duas faixas: escolha pelo idioma
./.build/release/tradutor-verify cobertura    # sem argumento: prova a regua e o cache de vozes
./.build/release/tradutor-verify cobertura <audio> [idioma] [motor] \
      --audio-referencia <wav>                # PCM original: a regua nunca e o audio tratado
      --referencia <json>                     # congela as faixas do Sortformer para o A/B
      --json <saida>                          # relatorio por locutor
./.build/release/tradutor-verify modelos      # trocar de idioma não pode recarregar
./.build/release/tradutor-verify lotes        # tamanho de lote e custo por string
./.build/release/tradutor-verify sobreposicao # se reenviar contexto melhora a tradução
./.build/release/tradutor-verify motores      # limiar do Whisper, motores, retentativa
./.build/release/tradutor-verify locutores    # atribuição de quem fala, sem modelo
./.build/release/tradutor-verify deepl        # tradutores: blocos, link, leitura atrasada
./.build/release/tradutor-verify treslinhas <video>
                                              # varre a saída atrás de legenda de 3 linhas
./.build/release/tradutor-verify vozes <audio> [limiares]
                                              # quantas vozes cada limiar devolve
./.build/release/tradutor-verify fronteiras <video> [idioma] [motor]
                                              # trechos com duas vozes, com e sem o conserto
./.build/release/tradutor-verify vivo <audio> [motor] [idioma]
                                              # o que o VAD do tempo real deixa passar;
                                              # com motor, reconhece segmento a segmento
                                              # com e sem nivelamento
./.build/release/tradutor-verify repescagem <audio> [motor] [idioma] [motor2]
                                              # re-reconhece isolado o que a 1ª passada perdeu
./.build/release/tradutor-verify alinhamento <audio> [motor] [idioma]
                                              # legenda contra onde há voz; com a
                                              # Apple, falha se algum trecho passar
                                              # do teto de 7 s
./.build/release/tradutor-verify fonte <video> [idioma] [motor]
                                              # as falas reconhecidas, uma por linha
./.build/release/tradutor-verify audio <wav> [origem] [destino] [motor]
                                              # VAD do tempo real + reconhecimento + tradução
```

`motores`, `locutores`, `vivo` e os demais sem áudio não carregam modelo —
rodam em milissegundos. `fonte` e `audio` aceitam motor no fim, que é como se
comparam dois reconhecedores no mesmo áudio; `prefixo-ab` compara traduções
com e sem rótulo de locutor.

Há também diálogo sintético de duas vozes, com roteiro conhecido, para medir
corte e alinhamento — `scratchpad/gera.py` (fácil), `gera2.py` (interjeição
colada) e `mapa.py` (compara o `.srt` com o roteiro), em português e inglês:

```bash
python3 scratchpad/gera2.py /tmp/dialogo
./.build/release/tradutor-verify srt /tmp/dialogo/dificil-pt.wav pt en apple --locutores
python3 scratchpad/mapa.py /tmp/dialogo/dificil-pt.json /tmp/dialogo/dificil-pt.en.srt
```

Dois testes exercitam o app inteiro sem ninguém clicar:

```bash
# tempo real: liga no primeiro app tocando som, grava o que chegou às zonas
open build/Tradutor.app --args --selftest-live ja pt        # → /tmp/tradutor-live.txt

# janela de legendas: abre vídeo, gera, navega, exporta, retraduz (78 verificações)
# o padrão é o reconhecimento da Apple; --motor <nome> no fim troca:
#   parakeet, whisper, qwen, qwenLarge
open build/Tradutor.app --args --selftest-studio video.mp4 ja pt  # → /tmp/tradutor-studio.txt
#                                                                    → /tmp/studio.png
# `--locutores`, `--cores` e `--modelo <clustering|sortformer>` exercitam quem
# fala; com locutores ele grava um segundo PNG, /tmp/studio-locutores.png.
# `--retraduzir <apple|deepl|hunyuan>` troca de tradutor depois de gerar e
# confere o que muda. Fica atrás de bandeira porque o DeepL manda texto para a
# rede, e nenhum autoteste deve fazer isso sem alguém ter pedido.
#
# Cuidado ao acrescentar checagem de locutor: a exportação do fim do teste
# vem DEPOIS de carregar um .srt, e legenda lida de arquivo não tem locutor —
# a cor não teria de onde sair. Quem testa locutor exporta junto da geração.

# item de menu "Só gerar o .srt de um vídeo…": gera e audita o .srt
open build/Tradutor.app --args --selftest-job video.mp4 ja pt     # → /tmp/tradutor-job.txt
# `--tradutor <apple|deepl>` troca quem traduz, nos dois autotestes. A escolha
# do usuário mora em UserDefaults e o teste não a toca — ver SubtitleJob.translation.
# Caminho relativo vale a partir da raiz do projeto: `open` não herda o
# diretório de trabalho (o app nasce em `/`), então os autotestes resolvem
# relativo contra a pasta que contém o `.app` — `build/Tradutor.app` → raiz.

# várias janelas de legendas ao mesmo tempo (sem vídeo, milissegundos)
open -n build/Tradutor.app --args --selftest-janelas   # → /tmp/tradutor-janelas.txt
```

**Com o app já aberto, `open` ignora os `--args` em silêncio.** Ele ativa a
instância que existe e o autoteste nunca roda — nenhum erro, nenhum relatório.
É fácil não perceber, porque o app é de barra de menus e não aparece no Dock.
`open -n` abre outra instância e resolve; os autotestes terminam em `exit()`,
então a instância extra não sobra.

**O aviso de conclusão do item de menu não aparece sob autoteste**
(`SubtitleJob.silent`). `NSAlert.runModal` segura o laço principal, e o laço do
autoteste roda no `@MainActor`: com o aviso na tela o relatório ficava parado
em "gerando…" para sempre, com o `.srt` já gravado certo. Acontecia em duas de
quatro execuções — é corrida, e quanto mais lenta a geração, mais provável.

### Mais de uma janela de legendas

`AppDelegate.studios` é um dicionário de janela para modelo, e é ele quem retém
os dois: a janela não é liberada ao fechar, e o modelo só vive enquanto a view
existir. `windowWillClose` tira a chave e o par cai junto, com `stop()` soltando
o player e o observador de tempo daquela janela — e só daquela.

**"Assistir com legenda…" levanta as janelas que já existem; quem abre outra é
o botão "Abrir outra janela", visível sempre — inclusive sem janela nenhuma
aberta, quando ele faz a mesma coisa que o primeiro.** O app é `.accessory`: sem Dock, sem Cmd-Tab e sem menu Janela, o item do popover é o
único caminho de volta para uma janela enterrada atrás de outras. Se ele
passasse a abrir uma janela nova a cada clique, a que tem a legenda já gerada
ficaria inalcançável — e gerar de novo custa minutos. O levantamento segue a
ordem de `NSApp.orderedWindows` de trás para a frente, senão uma janela
qualquer roubava o foco de quem já estava na frente.

O título é numerado por um contador que só cresce (`Legendas`, `Legendas 2`…):
reaproveitar o número de uma janela fechada daria duas "Legendas 2" ao mesmo
tempo, e o título é o que distingue as janelas no Mission Control.

Nada no caminho da geração é compartilhado — `Translator.make` e
`SubtitleFileBuilder` são por instância, e cada modelo tem o seu `AVPlayer`.
O que **não** tem guarda é gerar em duas janelas ao mesmo tempo: são dois
modelos residentes disputando GPU e memória (dois Hunyuan não cabem nos 16 GB),
e duas `WKWebView` no site do DeepL puxam o desafio da Cloudflare, que custa
195 s por vídeo quando aparece. Assistir em várias e gerar numa só é o uso
seguro.

A janela de legendas e o item de menu são **arquivos separados**
(`SubtitleStudioModel` e `SubtitleJob`). A geração é uma função só,
`SubtitleFileBuilder.generate` — cada um tinha sua cópia dos passos, e o
usuário via legenda diferente saindo de cada um. Interface, progresso e
cancelamento continuam separados — testar um não testa o outro. A janela só
grava `.srt` quando o usuário exporta; o item de menu grava ao lado do vídeo,
que é para isso que ele existe.

O studio grava um PNG da janela desenhado pelo próprio app — serve para
conferir layout sem depender de permissão de gravação de tela.

Diagnóstico da captura, com janela de resultado:

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

`AudioCapture` não depende de nada externo **de propósito**: é a camada mais
arriscada e precisa compilar e rodar em segundos para ser depurada sozinha.

### Fluxo em tempo real

```
áudio do app ──▶ Core Audio process tap (todos os processos do app)
             ──▶ 16 kHz mono + detector de voz com dois limiares
             ──▶ trecho em andamento, re-reconhecido a cada 0,6 s
                   ├──▶ prefixo que ainda oscila ──▶ zona vermelha
                   └──▶ prefixo estável (2 passadas concordam)
                          └──▶ fecha na pontuação ──▶ tradução ──▶ zonas azul e amarela
```

### Fluxo de arquivo

```
vídeo ──▶ faixa do idioma escolhido ──▶ áudio 16 kHz ──▶ nivela fala baixa
                       ──▶ quem fala, quando pedido (fronteiras de voz)
                       ──▶ reconhecimento com marcação de tempo
      ──▶ agrupa em frases (150 chars, pausa > 0,8 s, teto 7 s)
      ──▶ traduz em lotes (40 na Apple e no DeepL, 20 no Hunyuan)
      ──▶ reparte a tradução em legendas de 2 linhas × 42 chars
      ──▶ .srt
```

---

## Decisões que vieram de medição

Cada uma custou uma investigação. Não desfaça sem medir de novo.

### Por que o áudio não é cortado em pedaços (tempo real)

Cortar áudio parte palavras ao meio e nenhuma metade é reconhecível:
"reported" saía como "Reaper's" no fim de um bloco e "ported" no começo do
seguinte. Cortar no ponto de menor energia ajudou, não resolveu.

A solução é não cortar: o trecho é transcrito inteiro, repetidamente, e vai
para a tela o prefixo em que duas passadas consecutivas concordam
(*LocalAgreement-2*, a política do `whisper-streaming`).

O reconhecedor às vezes **reescreve o passado**. Confirmar por índice sem
checar isso produzia texto embaralhado ("running in been running in
production"). Uma passada que discorda do que já saiu não confirma nada.

### Motores de reconhecimento

`RecognitionEngine` escolhe a família; o seletor de idioma limita ao que cada
uma cobre. Família nova: um caso no enum, um `Transcriber`, e o seletor mostra
sozinho.

| Caso | Cobertura | Observação |
|---|---|---|
| `.apple` (padrão) | de, en, es, fr, it, ja, ko, pt, zh | `SpeechAnalyzer` do macOS 26, modelos do sistema |
| `.parakeet` | os 10 idiomas europeus que o app oferece | Parakeet TDT v3, ~120× tempo real |
| `.whisper` | todos os idiomas do app | Whisper turbo, mais lento e mais amplo |
| `.qwen` | 13 idiomas (sem inglês) | Qwen3-ASR 0.6B, **só nos modos de vídeo**, fora do processo |
| `.qwenLarge` | 14 dos 18 idiomas | o mesmo em 1.7B, com `qwen-setup.sh --grande` |

Parakeet e Whisper eram **um item só** no seletor (`.models`, "Parakeet /
Whisper"), e o idioma decidia qual rodava por baixo. São dois modelos
diferentes, com cobertura e velocidade diferentes, e agora são duas escolhas:
o seletor de idioma mostra só o que cada um cobre. `TranscriberKind` ainda
manda o Parakeet para o Whisper quando o idioma não é coberto — rede de
segurança para preferência gravada antes de o idioma mudar.

O Whisper é sempre o turbo (809 M). O large-v3 completo (1,55 B) foi
**removido**: em 90 s de japonês limpo levava o dobro (20 s contra 10 s) com as
mesmas palavras, e no uso real as legendas saíram piores. Não reintroduzir sem
comparar em vídeo real.

### O limiar que fazia a legenda mudar a cada execução

O WhisperKit re-decodifica a janela com temperatura 0,2 · 0,4 · 0,6 · 0,8 · 1,0
quando a confiança do **primeiro token** fica abaixo de `firstTokenLogProbThreshold`
(padrão −1,5) — e acima de zero o amostrador sorteia o token (`Float.random`,
sem semente). Num vídeo com música ao fundo o mesmo arquivo dava 9, 20, 25 ou
34 trechos, e uma execução em cada três perdia os **primeiros 32 s** do diálogo.

Medido, quatro execuções cada:

```
-1,5 (padrão do WhisperKit): 34 / 25 / 20 / 31 trechos, 7 a 17 retentativas
-3,0 (o que está no código): 30 / 32 / 30 / 32 trechos, nenhuma retentativa
```

A cobertura do `.srt` desse vídeo subiu de 44% para 70%. Em áudio limpo o texto
sai idêntico ao da melhor execução do padrão. **Zerar `temperatureFallbackCount`
também acaba com o sorteio e foi medido: cai para 9 trechos** — as retentativas
aleatórias recuperavam texto de verdade; o certo é não precisar delas.
`tradutor-verify motores` falha se o número voltar.

Detalhes que custaram investigação:

- O botão + ao lado do idioma de origem instala o modelo da Apple pelo
  `AssetInventory`. `SpeechTranscriber.supportedLocale(equivalentTo:)` devolve
  variante até para árabe e russo, que ele não transcreve; a lista boa vem de
  `supportedLocales`.
- `AppleSpeechTranscriber.phrases` junta as palavras em trechos antes do
  agrupador, que junta pedaços com espaço — palavra solta em japonês viraria
  "今日 は".
- **Há reconhecedores cujo tempo é o da emissão do token, não o da palavra.**
  Medido no Parakeet Unified, antes de ele sair: as palavras saíam ~0,4 s
  depois de soar e o ponto final só era emitido quando a frase seguinte
  começava. `TokenPhrases.group` ignora o tempo da pontuação e
  `SpeechEnergy.fit` encosta cada trecho na voz — as duas peças continuam aqui
  porque qualquer família nova de RNNT cai no mesmo problema. O Parakeet v3
  tem durações do TDT e não passa pelo `fit`.
- `TokenPhrases.group` existe porque o `buildWordTimings` do FluidAudio agrupa
  pelo "▁", que japonês quase não tem.
- **Comparar motores contando trechos é enganoso.** O v3 sai do
  `buildWordTimings` com **um trecho por palavra**; Unified e Apple saem com
  trechos de frase. Uma métrica que pergunta "quantos trechos de fala foram
  alcançados" premia quem fatia mais fino: por ela o Unified parecia bem pior
  que o v3, e o texto dos dois é o mesmo (311 contra 320 palavras, frase a
  frase idêntico). Compare por texto — `tradutor-verify fonte <video> <idioma>
  <motor>`.
- **A primeira inferência do Parakeet pode estourar o tempo no Neural
  Engine**: `ANE op async execution has timed out`, e a transcrição inteira
  falhava — o usuário via "nenhuma fala reconhecida" num áudio cheio de fala,
  e numa execução os mesmos 96 s levaram 59 s em vez de 2 s. `AneRetry.once`
  tenta uma segunda vez, com o decodificador zerado (a chamada que falhou
  pode ter parado no meio de uma hipótese). Uma tentativa só, e cancelamento
  não é retentado. `tradutor-verify motores` testa os três casos.

Medido em 161 s de inglês, os três que sobraram transcrevem o **mesmo texto**
(319, 320 e 328 palavras; a diferença é pontuação e onde cada um corta). O que
separa é velocidade e precisão de tempo:

```
                texto      tempo        alinhamento (início / fim)
Parakeet v3     320 pal.   1,8s · 88x   +0,10 / -0,18 s
Apple           319 pal.   1,4s · 116x  -0,42 / +0,08 s
Whisper turbo   328 pal.   5,6s · 29x   -0,65 / +0,43 s
```

Em japonês (96 s com música), Apple e Whisper dão o mesmo texto — 735 e 734
caracteres — com a Apple em 0,6 s contra 3,6 s.

**`DictationTranscriber` foi testado e recusado.** É o outro reconhecedor do
`Speech`, e cobre **54 locales contra 30** do `SpeechTranscriber` — os 18
idiomas do app, contra 9. Seria o fim do "a Apple não cobre russo". Medido em
13/09/2026 nos 161 s de inglês, o único par em que os dois estão instalados
nesta máquina, com o preset `.timeIndexedLongDictation`:

```
                        trechos   pontuação   caracteres   tempo
SpeechTranscriber            50          73         1726    1,4 s
DictationTranscriber          5          14         1461    3,9 s
```

Ele devolve tempo por palavra (296 runs, todos com `audioTimeRange`), mas
entrega o texto em blocos de 30 a 40 s **quase sem pontuação** — e pontuação é
o que fecha legenda (`makeCues`). É o mesmo defeito que tirou o Qwen 0.6B do
inglês. Nos idiomas que a Apple não cobre, o Whisper continua sendo a resposta:
cobre todos e pontua. **Limite da medição:** só em inglês, porque instalar o
modelo de ditado dos outros idiomas custa download; quem for refazer, meça a
pontuação antes de qualquer outra coisa.

**Cohere Transcribe (8 bits) foi testado e removido.** Não marca tempo, era o
mais lento (40 s para 90 s de japonês) e a compilação para o Neural Engine
ocupava 7 GB de cache, 3,3× o modelo.

**Nemotron 3.5 foi testado e removido.** Media pior que o Whisper e que a
Apple nos dois idiomas medidos: no inglês perdeu as seis falas de 1,2 a 2,0 s
de um dos vídeos (14 de 28 trechos, contra 21 da Apple e 23 do Parakeet v3);
no japonês, 16 de 39. Custava 634 MB em disco.

**Parakeet Unified EN foi testado e removido.** Transcrevia o mesmo texto do
Parakeet v3 em inglês (311 contra 320 palavras, frase a frase igual), era o
mais rápido de todos (0,9 s para 161 s, 181× tempo real) e o mais preciso no
tempo (+0,04 / +0,09 s) — mas só fazia inglês, que o v3 já cobre. 586 MB para
nada que já não existisse.

**Parakeet japonês (`tdtJa`) foi testado e removido.** Reconhecia um terço do
que os outros reconhecem: 96 s de japonês limpo deram 239 caracteres, contra
736 da Apple e 752 do Whisper, com truncamento no meio da palavra
("おはようござい"). Descartados como causa, um a um: o agrupamento de tokens
(o `transcribe` cru sai igualmente truncado), o limiar de arquivo longo
(perde também em clipes de 20 s), o nível do áudio (ganho automático não
mudou nada), o `decoderState` (2 camadas, o mesmo do benchmark do FluidAudio)
e a dica de idioma (o FluidAudio a ignora para `tdtJa`). Custava 590 MB.

### Tradução: o padrão é a Apple, e o que foi descartado no caminho

Hoje há três motores — Apple (padrão, local), DeepL (site, rede) e Hunyuan-MT
(local, fora do processo). As seções seguintes medem os dois últimos. Esta
guarda o que **saiu**, para não voltar sem medição nova.

Foram testados e **removidos**:

| Testado | Resultado |
|---|---|
| Qwen3-4B (MLX) | erra gênero mesmo com histórico, regra explícita ou raciocínio |
| Qwen3-8B (MLX) | acerta gênero em teste sintético, português pior em vídeo real; **1,02× o tempo do vídeo** |
| NLLB-200-600M | erra moeda (円→"cêntimos"), nome próprio (山梨県→"Yamada"), português europeu |
| MADLAD-400-3B | melhor que o NLLB, ainda abaixo da Apple; 6 GB residentes |

O tradutor do sistema custa **0,07× a 0,12× o tempo do vídeo** — conforme a
legenda fique mais ou menos picada, ver "Tamanho de lote" — e ganhou de todos
os modelos **locais** no par japonês → português brasileiro. Contra tradutor de
nuvem ele perde, e perde feio — ver a seção seguinte.

Se for reavaliar, o arnês está pronto: `tradutor-verify fonte` extrai as falas,
`tradutor-verify traduzir` roda a Apple, e `scratchpad/compara.py` põe lado a
lado. **Armadilha:** o `transformers` 5.x quebra o MADLAD (não amarra
`shared.weight` a `decoder.embed_tokens.weight`, a saída vira lixo repetido);
com `transformers==4.44.2` funciona.

### DeepL e Google ganham da Apple em japonês, e o preço é a nuvem

Medido em 12/09/2026, à mão, colando as falas nos dois sites gratuitos. Dois
vídeos japoneses, reconhecimento da Apple nos dois: a conversa de 9 min (55
falas) e o anime de 96 s (11 falas). Nenhum código foi escrito — o app continua
só com a Apple.

**A Apple não está na disputa.** Não é questão de elegância: ela entrega linha
sem sentido onde os dois acertam.

```
 8 JA  あと私のことはいかでいいよ。 いか先輩先輩はいらないよ。
    AP  e o que você acha de mim? você não precisa de mim, senhorita.
    DL  Ah, e pode me chamar de "Ika". "Ika-senpai"? Não precisa de "senpai".

24 JA  もっと元気に。            AP  mais saudável.       DL  Com mais ânimo.
34 JA  店長れいかさんって2人いるんですか？
    AP  você tem duas senhoras rei ka como gerente da loja?
    DL  Gerente, tem duas Reikas aqui?
```

**O gênero, que era o defeito nomeado, o DeepL resolve na maioria.** `上村さんも`
→ a Apple escreve "senhor uemura" para a Reika; o DeepL, "a senhora". `優しい先輩で`
→ "ele é um senhor mais velho gentil" contra "uma colega mais velha". Mas
**não é confiável**: o vídeo 1 repete o mesmo diálogo na segunda metade, e ali o
DeepL inverte o que tinha acertado — "Tô ocupada" (fala 19) vira "tô ocupado"
(fala 49). O Google erra em espelho, acertando a 49 e errando a 19. Nenhum dos
dois é determinístico em gênero; o DeepL só erra menos.

#### O que separa os dois é a contagem de linhas

```
                   vídeo 1 (conversa)   vídeo 2 (anime)
DeepL                  55 / 55              11 / 11
Google                 53 / 55              10 / 11
```

O Google funde **sempre no mesmo caso**: onde o reconhecimento partiu uma frase
no meio e ela ficou em duas falas. Foram três casos nos dois vídeos, três
fusões.

```
 3 JA  …海岸の船を全部避
 4 JA  けろ。
    DL  "…tire todos os navios da costa"  /  "daqui."     ← duas linhas
    GO  "…mova todos os navios para o mar."               ← uma linha, a 4 sumiu
```

Isto **desqualifica o Google para gerar `.srt`**, independente de qualidade: uma
linha a menos e toda legenda dali em diante recebe o texto da anterior, com
timecode válido e arquivo sem erro nenhum. Corrupção silenciosa. O DeepL trata
a colagem como linhas e o Google como texto corrido — é comportamento de
produto, não azar de amostra.

#### Nome próprio, e o que nenhum tradutor conserta

```
モンキーディールフィ   AP  "Monkey D. Luffy"   DL  "Monkey D. Luffy"   GO  "Luffy"
エッグヘッド          AP  "os cabeças de ovo"  DL  "Egghead"          GO  "Cabeça de Ovo"
麦わらに殺される       AP  "morto por um palhaço"  DL  "pelo Chapéu de Palha"
ドクタービザバンク     AP  "o banco de vistos médicos"  DL  "O Dr. Vizabank"
```

O DeepL chegou a **reconstruir expressão a partir de palavra errada**: o
reconhecimento ouviu `権力をカバにして`, e é 笠 (かさ) — 権力を笠に着る, "se
escudar no poder". Saiu "usando o poder como escudo". A Apple inverteu quem
manda em quem.

Mas o erro que **nasce no reconhecimento atravessa intacto** nos três:
"Vizabank" por Vegapunk, "Ruby" por Luffy, 世 virando "Yo". Não é caso de
tradutor: nenhum deles tem como saber o que foi dito.

#### Registro

O DeepL escreve brasileiro falado e o Google escreve manual, consistente nos
dois vídeos: "Sai daí um pouco, tá atrapalhando" contra "Saia da frente, você
está atrapalhando"; "Obrigado pelo seu trabalho" contra "Obrigado pelo seu
trabalho árduo" duas vezes na mesma fala. Pesa mais do que pareceria, porque a
legenda é quebrada em 2 linhas × 42 caracteres: a versão longa estoura e o
corte come outra coisa.

#### O DeepL entrou, como opção

`TranslationEngine` escolhe quem traduz nos modos de vídeo; o padrão continua
sendo a Apple, e **ao vivo é sempre a Apple** (`supportsLive`) — uma carga de
página por bloco não cabe num trecho re-reconhecido a cada 0,6 s.

**Uma carga de página por geração, não por bloco.** A primeira fixa o par de
idiomas pelo formato de link do próprio site, `#<origem>/<destino>/<texto>`;
cada linha vira um `<p>`, e é daí que sai a contagem preservada. Do segundo
bloco em diante é **limpar e colar**, sem recarregar:

- o botão do próprio site esvazia o campo — `translator-source-clear-button`;
- o texto entra por **evento de cola**, `ClipboardEvent('paste')` com um
  `DataTransfer`, que é o mesmo caminho de quem aperta ⌘V.

`execCommand('insertText')` **não** serve: o editor do site o ignora e nenhuma
requisição sai. Foi por causa disso que este arquivo já registrou "o texto não
entra digitando" e o código recarregava a página a cada bloco — errado nos dois
sentidos, porque colar funciona.

Medido em 12/09/2026, dois ciclos seguidos de limpar-colar-ler: **2,2 s e
3,0 s**, contagem exata nos dois, contra ~8 s de uma carga completa. E o ganho
que importa não é esse: **recarregar a cada bloco é o que parece robô.** Com
armazenamento `nonPersistent`, cada carga chegava sem cookie nenhum, como
visitante novo — e depois de algumas seguidas vinha o desafio da Cloudflare.
Colar mantém uma sessão só.

Quando a colagem não responde, o driver **recarrega uma vez** e tenta de novo;
se ainda assim falhar, o bloco cai para a Apple com aviso. Qualquer erro zera
`loadedPair`, para a tentativa seguinte começar por uma carga limpa.

#### O botão de volume é o "estou traduzindo" do site

Medido no próprio site em 12/09/2026, trocando o idioma de destino e amostrando
a página a cada 80 ms:

```
t+0ms      3 parágrafos · volume presente  ← a tradução ANTERIOR
t+617ms    1 parágrafo "\n" · volume ausente ← traduzindo
t+1129ms   3 parágrafos · volume presente  ← a tradução nova
```

`[data-testid="translator-speaker-target"]` — o botão de ouvir, ao lado do
campo de destino — **some enquanto o site traduz e volta quando o resultado
está pronto**. É o sinal que o site dá, e é mais firme que classe de CSS.

O que ele resolve tem nome: por ~600 ms depois de o texto novo entrar na
origem, o campo de destino ainda mostra a tradução do **bloco anterior** —
completa, estável, diferente da origem e plausível. Uma leitura nessa janela
escreve a legenda do bloco passado no bloco atual, com timecode válido e
arquivo sem erro nenhum. A requisição em voo protegia por acidente; quando o
site espera para disparar, não há requisição nenhuma e a janela fica aberta.

`DeepLWeb.aceitavel` fecha por três caminhos: o volume de volta, ter visto o
site trabalhando desde o envio, e — para quando a passagem é rápida demais
para a leitura pegar — o texto ser diferente do que o bloco anterior deixou.
Passados 8 s a regra afrouxa: um site que mude o botão, ou dois blocos com a
mesma tradução, não podem travar a geração.

#### A espera deixou de ser relógio e passou a ser sinal

Três esperas fixas saíram, e todas custavam tempo parado com a tradução já na
tela:

- **25 s esperando a contagem certa.** Era isso ou aceitar a primeira leitura
  com contagem diferente; o meio-termo é exigir o texto **parado** por 3 s
  (12 leituras iguais). Medido no vídeo de 9 minutos, entre dois níveis de
  repartição: **26 a 38 s antes, 2,3 a 11 s agora**.
- **Requisição em voo como condição absoluta.** Há requisição que não termina
  (telemetria, conexão longa) e o bloco ficava parado até o tempo esgotar.
  Passados 8 s, quem manda é o texto ficar parado.
- **300 ms de sono depois de limpar o campo.** Agora o app confere que o campo
  esvaziou e que a cola entrou — e quando não entrou, recarrega na hora em vez
  de esperar 90 s por uma tradução que ninguém pediu.

E o desafio anti-robô ganhou **25 s de espera antes de desistir**: ele quase
sempre passa sozinho, e desistir no primeiro quadro mandava para a Apple um
bloco que ia sair daqui. Quando passa, o bloco continua; quando não passa,
cai para a Apple como antes.

**Carregar o site antes do primeiro bloco foi testado e desfeito.** A ideia era
adiantar o desafio para fora da tradução. Custa uma página inteira a mais em
toda geração — medido, +11 s no vídeo curto e +25 s no de 9 minutos — para
adiantar algo que aparece de vez em quando. O desafio é esperado onde ele
aparece.

Quanto custa cada caminho, medido no vídeo de 9 minutos:

```
carga de página   ~11 s por bloco
limpar e colar    2,3 a 8,7 s por bloco
```

Quatro armadilhas, cada uma custou uma rodada:

- **Trocar só o fragmento não recarrega nada.** A página é uma SPA e ignora o
  fragmento novo. A carga leva `?bloco=<n>`, que força carga de verdade. A
  identidade da página, nos dois caminhos, é o **texto do campo de origem**:
  sem conferi-lo a leitura pega o bloco **anterior**, que tem texto válido e
  errado — tanto enquanto a página carrega quanto enquanto a cola não chegou.
- **Enquanto a tradução não chega, o site mostra o texto de origem do lado do
  destino.** Sem requisição em voo e com o texto parado, isso passava por
  "pronto": o `.srt` saiu com sete das onze falas em japonês, plausível e
  errado. `mesmoTexto` recusa o estado em que os dois lados são iguais.
- **A renderização vem depois da resposta.** Requisição terminada, parágrafos
  ainda aparecendo: um bloco de 11 falas era lido com 4, e o repartidor
  entrava sem necessidade. Por isso `esperar` exige a contagem esperada nos
  primeiros 25 s, e só depois aceita contagem diferente.
- **Sem cookie nenhum o aviso do site é uma caixa modal** que não casa com o
  `data-testid` do aviso curto. A sonda esconde por papel (`[role="dialog"]`
  com a palavra "cookie") depois de tentar o botão de recusar — esconder, não
  aceitar; o armazenamento é `nonPersistent` e nada fica em disco.

A janela **precisa estar visível**: `WKWebView` fora da tela tem temporizador
estrangulado, e a página depende de temporizador para disparar a tradução. Ela
também é o que o usuário vê saindo da máquina. `isReleasedWhenClosed = false`,
senão fechá-la no meio da geração derruba o app.

**O custo não é o que parecia.** Medido nos dois vídeos, mesmas opções, do
começo ao `.srt` gravado:

```
                 96 s (11 falas)   540 s (75 legendas)
Apple                    7 s              32 s
DeepL                   10 s              18 s
```

Os dois custam quase o mesmo, por motivos opostos: **a Apple cobra por string**
(ver "Tamanho de lote") e **o DeepL cobra por carga de página**, que leva 1400
caracteres de uma vez. Daí o DeepL sair mais caro no vídeo curto, onde a carga
não se dilui, e mais barato no longo, onde a Apple paga por cada uma das 75
legendas.

**O que limita o DeepL não é velocidade, é o desafio anti-robô.** Uma execução
com desafio da Cloudflare no meio levou **195 s** no vídeo de 96 s — quinze
vezes o normal, porque cada bloco espera o tempo esgotar antes de cair para a
Apple. Foi esse número que por um momento ficou registrado aqui como se fosse
o custo do motor; não é, é o custo de ser barrado.

A estimativa da janela sai de `TranslationEngine.costPerSecondOfVideo`: os dois
ficam perto, mas a conta vem de quem vai fazer o trabalho e não de uma
constante que vale para um motor e é chute para o outro.

Quando um bloco falha — tempo esgotado, limite do site — ele **cai para a
Apple** e a geração continua; o contrário seria perder dez minutos de trabalho
por um bloco. E isso **aparece na tela**: `Translator.completionNotice` sobe
pelo `SubtitleFileBuilder.translationNotice` até a janela de conclusão do item
de menu e a barra da janela de legendas ("3 blocos foram traduzidos pela
Apple"). Sem esse aviso a legenda trocava de qualidade no meio do arquivo sem
explicação — "a senhora Uemura" e "o senhor uemura" no mesmo `.srt`.

**Mais texto por ida piora, e isso está medido.** Mais falas por requisição é
mais contexto — que é de onde o DeepL tira gênero e pronome — e seriam menos
idas ao site. Com o lote em 120 o primeiro bloco passou a levar ~100 falas em
vez de ~40, e o site **parou de preservar as linhas**:

```
 40 por lote:  "devolveu 41 para 40", "19 para 20"   → repartia um nível
120 por lote:  "devolveu 1 para 103"                 → um parágrafo só
```

Um parágrafo só não tem como ser alinhado às legendas, e o bloco cai na
repartição binária — 103 → 51 → 25 → 12 → 6 → 3 —, cada nível uma página. A
geração foi de 23 s para 162 s. O lote voltou a 40: contagem de linhas
preservada vale mais que contexto, porque é dela que depende a legenda cair no
tempo certo.

O que continua valendo contra:

- **Teto de 1500 caracteres por colagem.** `DeepLWeb.characterLimit` é 1400,
  com margem. O vídeo de 9 min dá 2 blocos; um de 18 min, 4 ou 5 seguidos, que
  é o padrão que provoca bloqueio — e bloqueio não devolve erro, devolve vazio.
- **Uso automatizado do tradutor web contraria os termos de uso deles.**
- **Quebra silenciosa:** o site muda o HTML quando quiser. `tradutor-verify
  deepl` cobre o que é nosso (repartição e link); o resto depende de HTML
  alheio e por isso não vira teste.
- **macOS pede permissão de rede local** na primeira execução, por causa do
  WebKit. Responder "Não Permitir" não atrapalha em nada.

As medições de "Tamanho de lote" **não valem** para ele: são do framework da
Apple, que cobra por string. Aqui o custo é por carga de página.

#### Como refazer a medição

```bash
./.build/release/tradutor-verify fonte "<video>" ja apple > /tmp/falas.txt
tail -n +2 /tmp/falas.txt > /tmp/ja.txt          # a 1ª linha é o cabeçalho do motor
./.build/release/tradutor-verify traduzir /tmp/ja.txt ja pt
```

Depois é colar `/tmp/ja.txt` no site em blocos de até 1500 caracteres, cortando
em fim de linha, e conferir **primeiro a contagem**, antes de ler o texto —
`scratchpad/compara.py` põe os arquivos lado a lado e reclama quando a
contagem não bate.

### Hunyuan-MT-7B: o tradutor local fora do processo

O DeepL ganha da Apple em japonês e cobra a premissa do projeto — o texto sai
da máquina. O Hunyuan-MT-7B (Tencent, pesos abertos, especializado em
tradução, 33 idiomas) é o candidato a fazer o mesmo trabalho sem sair daqui.

Mesmo desenho do Qwen3-ASR, pelo mesmo motivo: não existe port CoreML, o que
existe é MLX em Python. `Scripts/hunyuan-setup.sh` cria
`~/Library/Application Support/Tradutor/hunyuan` (≈4,5 GB em 4 bits) e o motor
só aparece no seletor quando esse ambiente existe — `isAvailable` confere o
Python, o servidor e o `config.json` do modelo.

Duas decisões que o desenho impõe:

- **O processo fica vivo entre as falas.** Um 7B leva dezenas de segundos para
  carregar; carregar por fala seria inviável. O servidor lê uma linha JSON e
  devolve uma linha JSON, e a primeira linha da saída é o aviso de que o
  modelo carregou — sem esperar por ela, a primeira fala falharia.
- **Uma fala por requisição.** Mandar várias juntas devolve um bloco de texto,
  e aí a contagem de linhas deixa de ser garantida. É o mesmo problema que
  apareceu no site do DeepL, e lá custou um `.srt` desalinhado.

#### Medido, e ele perde para o DeepL

Vídeo de 9 minutos em japonês, mesmo reconhecimento (Apple), do começo ao
`.srt`:

```
             tempo    legendas   caracteres
Apple         32 s        73        3 607
DeepL         18 s        78        3 624
Hunyuan       84 s        87        4 314
```

Rápido o bastante — 0,18× o tempo do vídeo, muito abaixo do 1,02× que o
Qwen3-8B custava. O problema é o texto.

**Gênero: fica no nível da Apple, não no do DeepL.**

```
上村さんも    Apple "senhor uemura"          DeepL "A Kamimura"        Hunyuan "Sr. Uemura"
優しい先輩で   Apple "ele é um senhor"        DeepL "uma colega"        Hunyuan "um colega"
今忙しいの    Apple "Estou ocupado"          DeepL "Tô ocupada"        Hunyuan "ocupada" / "ocupado"
```

**Ele conversava dentro da legenda, e isso tem conserto.** Duas vezes em 87
legendas o modelo comentou a tarefa em vez de traduzir:

```
あ              →  "Ah… Parece que houve um erro na trad"
じゃあゆうじで   →  "Como é que se chama esse personagem? Acho que era
                    'Yujii'… ou talvez 'Yujikun'. Não tenho certeza."
```

O `without additional explanation` do cartão não segura fala curta e ambígua.
Duas mudanças mataram os dois casos:

- **A fala anterior vai como turno já respondido**, não como texto solto no
  prompt. Dá contexto e, de quebra, mostra ao modelo o formato da resposta
  certa — só a tradução. Custa ~13% de tempo (84 s → 95 s), porque cada
  requisição carrega o turno extra.
- **Fala de uma palavra não vai para o modelo** (`shortestForModel`, menos de
  4 caracteres sem espaço): é nela que ele derrapa, e a Apple resolve "あ" em
  milissegundos sem inventar. A fala curta continua entrando no contexto da
  próxima.

Medido depois: **zero comentários em 86 legendas**, e o caso do "Yujikun"
virou tradução plausível. O que **não** melhorou foi gênero — continua no
nível da Apple — nem o volume, que subiu para 4 500 caracteres.

**E escreve 24% mais.** 4 500 caracteres contra 3 624 do DeepL, o que vira 86
legendas contra 78 — mais corte, mais tempo de leitura, e legenda mais curta
custa mais tempo de tradução (ver "Tamanho de lote").

**Onde ele ganha:** da Apple, em compreensão. 三角筋 vira "músculos deltoides"
(a Apple escreveu "músculos triângulos"), 店長れいかさんって2人 vira "Existem
duas pessoas chamadas Reika que são gerentes da loja?" (a Apple, "Você tem
duas senhoras rei ka como gerente da loja?").

Fica no app como a opção local para quem não quer mandar texto para fora — e a
comparação está aqui para não se repetir a medição. `scratchpad/compara-srt.py`
põe dois `.srt` lado a lado alinhados pelo tempo.

#### Falar com o processo travava o app

Três defeitos no mesmo ponto — a leitura do pipe —, e juntos eles congelavam a
janela. Vistos em 12/09/2026: o app a 100% de CPU por 12 minutos e o servidor
Python vivo ao lado, com o usuário tendo trocado de tradutor durante o trabalho.

- **`availableData` bloqueia a thread até chegar byte ou o pipe fechar.** O
  prazo (300 s na carga, 120 s por fala) só era olhado *entre* leituras, e o
  cancelamento também: carregar um 7B leva dezenas de segundos, e nesse tempo o
  Cancelar não chegava a lugar nenhum. Hoje o descritor é `O_NONBLOCK` e o
  `read` volta na hora, com ou sem dado; quem espera é o laço, que sabe olhar o
  relógio e atender o cancelamento.
- **Pipe fechado não era distinguido de "ainda não chegou".** Com o servidor
  morto, `availableData` devolve vazio para sempre, e o laço esperava o prazo
  inteiro por quem não ia responder mais. `lerSemBloquear` separa as três
  respostas — chegou, ainda não, acabou — e o fim volta na hora.
- **`terminate()` é SIGTERM, e o servidor pode estar dentro de uma chamada do
  Metal que não atende sinal.** O app zerava a referência e seguia achando que
  matou; o processo ficava vivo com 4,5 GB, e o servidor seguinte competia com
  ele pela GPU. Agora espera 2 s e escala para `SIGKILL`.

Verificado depois, nos dois fluxos e nas duas trocas (Hunyuan → Apple e
Hunyuan → DeepL), inclusive cancelando no meio da carga do modelo: **nenhum
processo órfão sobra**.

### Qwen3-ASR: o único motor fora do processo

Não existe port CoreML do Qwen3-ASR. O que existe é MLX, em Python. Ele fica
num ambiente próprio criado por `Scripts/qwen-setup.sh`
(`~/Library/Application Support/Tradutor/qwen`, 2,2 GB com o modelo), e o app
só oferece o motor quando esse ambiente existe — `RecognitionEngine.qwen`
responde `isAvailable` pelo executável em disco.

Por que entrou, medido em 96 s de japonês limpo:

```
                caracteres   tempo        desvio do início
Apple                  248   0,6s ·172x   -0,42s
Whisper turbo          260   7,0s · 14x   +0,06s
Qwen3-ASR 0.6B         281   5,7s · 17x   +0,03s
```

O ganho que importa não é o volume: é que ele devolve **uma fala por bloco,
com pontuação**, enquanto a Apple emenda pergunta e resposta na mesma linha.
`QwenTranscriber` pede `-f srt` ao processo e lê com o `SRTParser` do app — o
próprio modelo já corta onde a legenda quer, e o parser ainda conserta os
blocos de duração zero que ele às vezes emite.

**Só nos modos de vídeo** (`supportsLive == false`): o modelo carrega a cada
chamada, a 17× tempo real, e o tempo real re-reconhece o trecho em andamento
a cada 0,6 s. Quando ele está escolhido no painel, o ao vivo cai em
`forLive` (a Apple) e o painel diz isso na linha sob o seletor.

Duas coisas o processo precisa do ambiente: `HF_HOME` apontando para dentro
da pasta (senão o modelo vai para `~/.cache`) e `HF_HUB_OFFLINE=1` (senão há
uma consulta ao Hugging Face por legenda — o mesmo erro que o WhisperKit
fazia).

#### O 0.6B não pontua em inglês

Medido em 161 s de conversa em inglês: **zero** sinais de pontuação, contra 63
do Parakeet, 73 da Apple e 73 do próprio 1.7B. Sem ponto o agrupador perde a
fronteira de frase e só corta por pausa e por teto de caracteres. Em japonês o
mesmo modelo pontua normal — é por idioma. Por isso o inglês saiu de
`QwenTranscriber.languages(for: .small)`; os outros doze seguem oferecidos
porque não foram medidos.

E ele **não traduz**: Qwen3-ASR é só reconhecimento (o código do pacote diz
"no translation layer"). Quando a legenda sai em inglês, quem traduziu foi o
framework da Apple, como sempre.

#### 0.6B ou 1.7B

`qwen-setup.sh --grande` acrescenta o 1.7B (3,4 GB); sem ele, `.qwenLarge` não
aparece no seletor, porque `isInstalled` confere a pasta do modelo, não só o
executável.

```
                      96 s limpo      97 s com música     540 s
0.6B   caracteres            281                  271      1661
       tempo               11,4s                15,2s     20,1s · 27×
1.7B   caracteres            286                  264      1673
       tempo               25,6s                37,0s     82,7s ·  7×
```

O volume é praticamente o mesmo. O que o 1.7B compra é **nome próprio em áudio
difícil**: onde o 0.6B escreveu `独たべが / パンクは`, o 1.7B escreveu
`ドクター・ベガ / パンクは` — os caracteres certos. Por 4× o tempo.

#### A lista de termos foi removida, e o que ela alcançava está medido

O app teve uma lista de termos do usuário, aplicada ao original antes de
traduzir e passada também ao reconhecimento — `--context` no Qwen,
`promptTokens` no Whisper. Saiu em 13/09/2026, a pedido. O que ela comprava,
medido no vídeo limpo com `上村玲香 佐藤雄二 レイカ` na lista:

```
sem contexto:  はじめまして、神村レイカです。 / 神村さんも？
com contexto:  はじめまして、上村レイカです。 / 上村さんも？
```

Quem quiser esse ganho de volta precisa de uma fonte de termos e de três
ligações: `--context` (Qwen), `promptTokens` (Whisper) e
`AnalysisContext.contextualStrings` (Apple, nunca ligado — exige
`SpeechAnalyzer(inputSequence:modules:analysisContext:)` no lugar de
`SpeechAnalyzer(modules:)`). Sem isso, erro que nasce no reconhecimento não
tem conserto em lugar nenhum do caminho.

### Quem fala

`SpeakerDiarizer` roda o `DiarizerManager` ou o `OfflineSortformerDiarizer` do
FluidAudio sobre o mesmo áudio de 16 kHz. É **outro modelo**, não recurso do
reconhecedor — por isso vale para qualquer motor que marque tempo, que hoje são
todos; `supportsDiarization` existe para um motor futuro sem tempo dizer que
não. Só nos modos de vídeo: ao vivo não há áudio inteiro para agrupar vozes.

O resultado entra **antes** do agrupamento, porque a troca de locutor é
fronteira de legenda — duas pessoas na mesma legenda é o que embaralhava a
leitura no diálogo rápido. No arquivo a troca ganha travessão; o nome não vai
para o `.srt` porque ocuparia metade da linha.

A regra do travessão é **uma só**, em `SpeakerMark`, usada pelo `SRTWriter` e
pela janela de legendas. Duas coisas que ela resolve:

- A janela mostrava só a cor e o arquivo saía com travessão — quem assistia
  para conferir antes de exportar via uma legenda diferente da que ia sair, e o
  travessão muda a largura da linha, que é onde a quebra de 42 caracteres
  decide o corte.
- **Trecho sem locutor no meio não é troca de pessoa.** `previousSpeaker` era
  atualizado com `nil`, e a sequência Locutor 1 → sem dono → Locutor 1 dava
  dois travessões para a mesma pessoa. Como `pruneTinyVoices` produz esses
  buracos de propósito, isso acontecia no uso normal. Hoje só um locutor
  conhecido substitui o anterior.

#### As escolhas, e o número que justifica cada uma

| | Valor | Por quê, medido no vídeo de 9 min |
|---|---|---|
| Modelo padrão | **Sortformer** | 1,4 s contra 3,6 s, 101 de 104 legendas marcadas contra 114 de 123, e **repetível** — 216 faixas iguais em toda execução aqui, enquanto o agrupamento oscilava entre 2 e 3 vozes no mesmo arquivo |
| `minimumSpeech` | **0,5 s** | o padrão de 1 s descarta a troca curta: 87 faixas e 133 s de fala contra 175 faixas e 201 s. Fim a fim, legendas marcadas de 83/133 para 115/125 |
| `minimumVoiceTime` | **2 s** | baixar a fala mínima trouxe uma voz de 1 s numa conversa de duas pessoas. `pruneTinyVoices` a descarta, e o trecho fica **sem** locutor em vez de com o do vizinho |
| `clusteringThreshold` | **0,70** | varrido de 0,50 a 0,90 com `tradutor-verify vozes`; único valor que preserva distinção nos quatro arquivos. Acima de 0,71 o recorte de 96 s colapsa para uma voz |

Duas armadilhas registradas: `numClusters` **não** serve para dizer quantas
vozes esperar (fixá-lo em 2 não muda nada — este caminho só olha o limiar), e o
número de vozes **oscila entre execuções** do agrupamento: 2 em cinco medições
e 3 em uma, no mesmo arquivo. Não há semente. O Sortformer não acerta a
contagem melhor, mas erra sempre igual — e é isso que permite medir.

Sortformer ignora limiar e fala mínima: as faixas saem do próprio modelo,
dentro do teto de quatro vozes da exportação CoreML.

**"Determinístico" era forte demais.** A auditoria de 12/09/2026 repetiu a
identificação nos quatro vídeos e achou variação pequena, mas real: no vídeo
de 9 minutos, 3 vozes numa execução e 4 na outra, 214 faixas contra 215. Nos
clipes curtos as duas execuções bateram. Continua muito mais repetível que o
agrupamento — e continua sendo o padrão pelo mesmo motivo —, mas quem medir
precisa guardar entrada e saída em vez de confiar que a segunda execução
repete a primeira.

#### Um identificador por pessoa, e não por pedaço de conversa

O Sortformer parte a mesma pessoa em mais de um identificador: no vídeo de 9
minutos, que é uma conversa de **duas** pessoas, ele devolveu **quatro** — o
terceiro e o quarto aparecendo depois dos 380 s. Isso não é detalhe de
medição: `SpeakerPalette` numera por ordem de aparição, então a mesma pessoa
troca de cor no meio do vídeo.

O modelo de identificação não diz se dois rótulos são a mesma pessoa. Quem diz
é o **embedding de voz**, que é outro modelo — o mesmo do caminho de
agrupamento, 13 MB, e já em disco. `SpeakerDiarizer.mergeSameVoice` extrai um
embedding por identificador (até 12 s do áudio que ele cobre, ignorando quem
não junta 2 s) e funde os que ficam perto.

Medido nos quatro vídeos de exemplo:

```
                      identificadores   depois da fusão
9 min japonês (2 pessoas)      4               2
97 s japonês                   3               3
161 s inglês                   4               3
161 s inglês (2)               4               4
```

No vídeo de 9 minutos a segunda pessoa volta a ser uma só, e as contas batem:
53,84 + 18,64 + 2,72 = 75,20 s de voz, 393 + 159 + 34 = 586 caracteres. Nos
outros três a fusão age pouco ou nada, que é o comportamento certo quando as
vozes são mesmo diferentes.

**O que ela não muda:** o texto, a cobertura e o número de travessões — 103
trocas de locutor antes e depois, porque os identificadores extras alternavam
com o outro interlocutor, não com o rótulo que absorveu eles. O que muda é a
identidade: a cor da mesma pessoa para de trocar no meio do vídeo, e passa a
existir uma conta por pessoa.

Custa **0,15 s** no vídeo de 9 minutos (2,55 s contra 2,70 s), porque o modelo
é pequeno e são poucos embeddings.

Duas decisões:

- **O limiar é 0,50**, e o número está no comentário de
  `sameVoiceThreshold`: varrido de 0,35 a 0,65, a faixa que acerta o caso
  conhecido vai de 0,45 a 0,60, e em 0,65 o vídeo em inglês colapsa duas vozes
  numa. Fica no meio. Fundir demais é pior que fundir de menos — separado
  sobra uma cor, fundido some uma pessoa.
- **Encadeamento simples:** se A se parece com B e B com C, os três ficam
  juntos. A mesma pessoa muda de tom ao longo da conversa e os pedaços dela
  chegam justamente como uma corrente.

`tradutor-verify locutores` verifica o agrupamento com embeddings dados à mão,
sem carregar modelo nenhum: vozes parecidas se juntam, a diferente fica de
fora, o encadeamento funciona, quem falou primeiro nomeia o grupo, e limiar
apertado não funde nada. `TRADUTOR_SEM_FUSAO=1` desliga.

**A referência de vozes do `cobertura` aparava faixa nenhuma, e se recusava
sozinha.** O Sortformer trabalha em blocos e a última faixa costuma passar do
fim do áudio; a validação da leitura exige o contrário, então o arquivo
gravado era rejeitado na execução seguinte — a guarda disparava contra o dado
que ela mesma tinha acabado de gravar. Hoje a faixa é aparada antes de gravar.

#### Fronteira de voz dentro do trecho

O trecho do reconhecedor é **indivisível** daí para frente: `assign` dá a ele
um locutor — o que mais o cobre — e a palavra da outra pessoa vai junto, com o
rótulo errado. Medido com `tradutor-verify fronteiras`, vídeo de 9 minutos:

```
                trechos com duas vozes   voz minoritária
Qwen 0.6B              0 de 211 (0%)              0,0 s
Whisper turbo          1 de  75 (1%)              0,6 s
Apple                 23 de 132 (17%)            17,4 s
```

O Qwen não sofre porque corta em cada fala, com pontuação. A Apple sofre porque
`AppleSpeechTranscriber.phrases` monta frases longas a partir das palavras.

**O Parakeet também não sofre, e agora está medido** — 161 s de inglês, os dois
modelos de identificação:

```
Parakeet v3, inglês      0 de 320 trechos com duas vozes (0%)
                         idêntico com e sem as fronteiras
```

Ele devolve **um trecho por palavra**, e uma palavra não tem como ser de duas
pessoas. Por isso `speakerBoundaries` continua sendo usado só pelo
`AppleSpeechTranscriber`: nos outros três motores a implementação do protocolo
é vazia de propósito, e a medição diz que não falta nada. O que sobra no
Parakeet são 3 de 44 legendas cujo intervalo encosta na faixa de outra voz —
igual com e sem fronteiras, ou seja, fora do alcance deste conserto.

**O conserto foi onde o problema nasce:** `phrases` recebe as fronteiras de voz
e fecha o trecho quando o **meio** da palavra muda de lado. Comparar contra o
início ou o fim da palavra não serve — a fronteira vem de um modelo por quadro
e erra ±100 ms, então o corte caía uma palavra tarde e o "E" de "Entendi"
ficava no trecho da outra pessoa.

Como a diarização só precisa do áudio, ela passou a rodar **antes** do
reconhecimento. `GenerationStep` mudou de ordem por isso, e há verificação para
a ordem não voltar.

```
Apple, mesmo vídeo         sem fronteiras   com fronteiras
trechos com duas vozes      23 de 132 (17%)   1 de 251 (0%)
voz minoritária                    17,4 s           0,3 s
legendas com locutor             81 de 82        98 de 100
```

A abertura que saía como uma legenda só — `"Bom dia. Bom dia. Você é um
novato? Sim, agora"` — virou quatro, uma por pessoa. O custo é fragmentar: 132
trechos viram 251 e 82 legendas viram 100, e legenda mais curta custa tempo de
tradução (ver "Tamanho de lote"). Vale **só com a identificação ligada**.

#### O que a separação não alcança

Medido com diálogo sintético de duas vozes feito pelo `say`, em português e
inglês, com o roteiro em JSON — o teste sabe quem falou o quê e quando
(`scratchpad/dialogo/`, refeito por `gera.py` e `gera2.py`).

Fala de tamanho normal e bem pontuada sai perfeita: no diálogo fácil, **uma
legenda por fala, 8 de 8**, com travessão em todas — e sem as fronteiras
também, porque ali a pontuação já separava.

**Interjeição de um segundo colada na fala do outro não tem conserto aqui.**
A Apple reconhece `Entendi` como `e` e alinha esse `e` ao trecho da outra
pessoa: o texto está no lugar errado antes de qualquer corte. Nos dois idiomas,
2 de 6 trechos misturados sem fronteiras e 2 de 8 com elas. Quem se sai melhor
nesse caso é o **Parakeet**, que devolve tempo por palavra — 1 legenda
misturada de 7 no diálogo difícil em português, com as interjeições saindo como
legenda própria, contra 3 de 5 da Apple.

**Limite do arnês:** as vozes do `say` são menos separáveis que gente de
verdade — no diálogo fácil em inglês o agrupamento achou **uma** voz só. Serve
para medir corte e alinhamento, não para julgar diarização.

#### O travessão está certo; o que erra é o modelo

`tradutor-verify srt <video> ja pt <motor> --locutores` imprime, legenda por
legenda, o locutor e se o travessão saiu. **0 fora de lugar** em 59 legendas
com o agrupamento e em 61 com o Sortformer — o mecanismo não erra. O que muda é
o rótulo:

```
agrupamento                     sortformer
× Locutor 1  — Bom dia.         × Locutor 1  — Bom dia.
  Locutor 1    Bom dia.         × Locutor 2  — Bom dia.
  Locutor 1    Você é novo…     × Locutor 1  — Você é novo…
```

O agrupamento funde as duas pessoas na abertura, e aí não há troca para marcar.
Se alguém reclamar que "o travessão não aparece", é no modelo que se olha.

#### Uma cor por locutor

`SpeakerPalette` dá a cor, e é a mesma na janela e no arquivo: branco, amarelo,
ciano e verde, na ordem de quem falou primeiro — as cores da legenda oculta da
TV americana (CEA-608), o conjunto que décadas de legenda mostraram legível
sobre qualquer imagem.

No `.srt` vai como `<font color="#RRGGBB">` envolvendo o bloco depois da quebra
(uma tag por linha dobraria o arquivo sem mudar nada na tela). VLC, mpv e a
maioria dos players entendem; quem não entende mostra a tag, e por isso é
**opção**. O `SRTParser` já limpava tags, então a legenda colorida volta a ser
lida sem resíduo — com verificação para isso.

`SpeakerPalette.index(for:)` devolve `nil` para rótulo sem número, e não a
primeira cor: pintar de branco um locutor que não se sabe qual é seria inventar
identidade. Hoje `renumber` sempre entrega "Locutor N", então isso vale para o
dia em que alguém mostrar o identificador cru do modelo.

**Na lista, o primeiro locutor não pode ser branco:** conferido nos pixels do
PNG do teste, a barra saía em (255,255,255) sobre fundo (249,249,249).
`listSpeakerColor` troca o branco pela cor de destaque; sobre o vídeo continua
branco. Verificado depois: barra azul (52,120,246) no Locutor 1, amarela
(244,244,110) no Locutor 2, legenda branca sobre o vídeo.

Na janela de legendas os três controles ficam num **menu só**, no ícone de duas
pessoas da barra. No painel eles ficam **visíveis mesmo desligados**, apagados
até a identificação estar ligada: escondidos atrás do interruptor, ninguém os
achava. `TRADUTOR_MEASURE_POPOVER=1 ./build/Tradutor.app/Contents/MacOS/Tradutor`
desenha o painel em `/tmp/painel.png` — é como se confere o que aparece ali.

### Repescagem de fala curta: medida e descartada

A ideia era re-reconhecer, isolado, cada trecho com energia de fala que a
primeira passada deixou sem texto. `tradutor-verify repescagem <audio>
[motor] [idioma] [motor2]` faz exatamente isso — e o terceiro argumento
tenta a segunda passada com **outro** motor.

Medido nos três vídeos de exemplo:

```
Parakeet v3 (inglês)       8 trechos sem texto → 2 recuperados, 0,5s
Whisper    (japonês)       5 trechos sem texto → 1 recuperado,  0,5s
Apple      (japonês)       5 trechos sem texto → 0
Apple + Whisper (japonês)  5 trechos sem texto → 1 ("ん")
Whisper + Parakeet (inglês) 10 trechos sem texto → 1 ("Oh.")
```

O que volta é grunhido: "Oh.", "Uh", "ん". Não compensa uma etapa a mais no
pipeline.

**E o caminho até aqui corrigiu um número:** a conta de que fala curta se
perdia em 68% a 95% dos casos vinha da mesma métrica enviesada da comparação
entre motores — um trecho de fala era dado como perdido quando nenhuma peça
tinha o **meio** dentro dele. Pelo critério certo (alguma peça se sobrepõe ao
trecho), o que fica sem texto nenhum são 5 a 10 trechos por vídeo, quase
todos abaixo de 0,5 s, muitos de 0,03 s — ruído, não diálogo.

### O que o VAD do tempo real faz com áudio contínuo

`tradutor-verify vivo <audio>` roda o `Segmenter` do caminho ao vivo sobre um
arquivo e compara com onde há voz. Medido nos três vídeos de exemplo:

```
japonês com música   9 segmentos ·  86,9s de 97s · 38/38 trechos de fala alcançados
japonês limpo        9 segmentos ·  95,9s de 96s · 42/42
inglês              14 segmentos · 161,3s de 161s · 64/64
```

Quase tudo vira segmento, e **quase todo segmento fecha por teto de 12 s, não
por silêncio** — 7 de 9, 9 de 9 e 14 de 14. Com música ou ruído de sala a
energia nunca cai o bastante para fechar um trecho.

Consequência: `minimumDuration` (0,4 s) e `framesToOpen` (3 quadros) **nunca
disparam** nesse material — a varredura do gate dá resultado idêntico com
0,15 s e com 1 quadro. Se alguém for atrás de fala curta perdida ao vivo, não
é aqui: o que o tempo real faz é cortar a cada 12 s no ponto mais quieto, e
cada passada de re-reconhecimento processa o bloco inteiro em andamento.

### Tamanho de lote na tradução

**O custo é por string, não por requisição nem por caractere.** A conclusão
antiga — "o custo é a ida e volta" — vinha de medir só até 40 itens; com 160 a
figura muda.

Ida e volta, 160 falas, mesmo texto em lotes diferentes:

```
 10 por requisição:  47 068 ms
 40 por requisição:  47 049 ms
 80 por requisição:  47 359 ms
160 por requisição:  47 312 ms
```

Acima de ~10 por requisição o número de idas **não importa**. O que importa é
em quantos pedaços o texto está. Mesmo conteúdo, mesmo lote de 40:

```
 40 falas inteiras:  11 679 ms   (1852 caracteres)
204 pedaços:         27 074 ms   (1688 caracteres)
```

**2,3× mais lento com menos caracteres**, só por estar picado. Há um custo fixo
por string, e é ele que domina.

Consequências práticas:

- O lote de 40 fica (`AppleTranslator.preferredBatchSize`), mas por inércia, não
  por ganho: 10 ou 160 dariam o mesmo tempo. Só não descer abaixo de 10.
- **Legenda mais curta custa mais tempo de tradução.** Identificar quem fala
  divide legendas — no vídeo de 9 minutos foram de 61 para 102 —, e a tradução
  subiu de 34 s para 45 s. É o preço da separação, e é aqui que ele aparece.
- A **sobreposição de contexto saiu** (`contextOverlap = 0`). Ela reenviava 10
  legendas por lote, e string reenviada custa como string nova: no vídeo de 9
  minutos, 44,4 s de tradução contra 37,1 s sem ela — **15% do tempo total**.
  Ver a próxima seção para o que isso custou em qualidade.

**E daí também a espera sem progresso.** O framework devolve o lote inteiro de
uma vez — não há retorno por legenda —, então entre enviar e receber não
existe nada para relatar. Num vídeo de 9 minutos são 4 requisições de ~16 s: a
barra andava em 4 saltos e parecia travada no meio de cada um.
`SubtitleFileBuilder.Progress.waiting` avisa quando a requisição está no ar; a
janela mostra o giro ao lado de "41–80 de 133", e o item de menu escreve
"(aguardando resposta)". A barra não mente: ela fica onde está, porque é onde o
trabalho está.

Reduzir o lote para 10 daria quatro vezes mais atualizações por ~1% de tempo
(11 906 ms contra 11 715 ms na medição acima) — e foi **descartado de
propósito**: o contexto que o tradutor usa é o que está dentro da requisição,
e mexer nele para melhorar a barra é trocar qualidade de tradução por
percepção.

### A sobreposição de contexto não fazia o que dizia fazer

Ela existia para dar vizinhança à legenda da borda do lote: com lotes
encostados, a primeira de cada lote não tem nada atrás dela.
`tradutor-verify sobreposicao` planta exatamente esse caso — quatro falas
apresentando "Marina… **She** is the lead engineer…" logo antes da borda, e
cinco depois dela referindo a mesma pessoa como "the engineer" e "the lead",
que em inglês não têm gênero:

```
mudaram: 0 das 5 na borda, 0 de 45 no total
gênero feminino acertado na borda: com 10 = 0, com 0 = 0
```

**Idêntico, e errado nos dois** ("o engenheiro"). E o `tradutor-verify dialogo`
mostra o mesmo com as quatro frases na **mesma** requisição: o framework da
Apple não resolve gênero por contexto, nem a dez linhas de distância nem a uma.
A premissa que justificava a sobreposição — "ele usa o contexto da requisição"
— nunca valeu para o caso que importa.

No vídeo real, tirar a sobreposição muda 10 de 107 legendas, e a leitura é
mista: `"— Você deve gritar mais alto."` (com) é melhor que `"— Você está
gritando mais alto de sua barriga"` (sem), e `"— Vamos lá, yuji"` (sem) é
melhor que `"— vamos lá, yuji"` (com). Não é ganho nem perda sistemática: é
loteria de 10% das legendas, por 15% do tempo.

Saiu por isso. O campo continua lá para quem medir de novo com outro tradutor.

### Maiúscula de começo de frase, e o prefixo que não entrou

O tradutor do sistema devolve minúscula na maioria das falas curtas: medido
num vídeo de 270 s, **15 de 57 legendas** começavam com maiúscula.

O caminho tentado primeiro foi prefixar cada fala com travessão até o
tradutor e removê-lo na volta. Funciona — sobe para 40 de 57 — mas **não é de
graça**: 42 das 57 legendas mudaram de texto, e entre elas há regressões de
sentido ("você também, kamimura? sim, **eu** tenho vinte anos" virou "o senhor
kamimura também? sim, **ele** tem vinte anos"). Também foi testado o nome do
locutor no lugar do travessão (`Locutor 1: `): muda outras 15 falas, metade
para melhor e metade para pior, e nem assim o tradutor acerta o gênero — a
identidade escrita na frente dele não é usada. Os dois foram descartados;
`tradutor-verify prefixo-ab` reproduz a comparação.

O que ficou é `SubtitleFileBuilder.capitalizeSentences`, determinístico e sem
tradutor no meio: **52 de 57 legendas com maiúscula e zero mudanças de
texto**. A regra é só capitalizar quem começa frase — a legenda anterior tem
de ter terminado em pontuação, porque `enforceLineLimit` corta legenda no meio
da frase e a segunda metade não leva maiúscula.

### O ponto final japonês não fechava legenda

`makeCues` fecha a legenda quando o trecho termina em pontuação, e a lista
era `".!?…"` — sem `。`, `！` e `？`. Em japonês, portanto, o fim de frase
nunca fechava nada: a legenda só se fechava quando batia no teto de 7 s, na
pausa de 0,8 s entre trechos ou nos 150 caracteres. Duas falas — quase sempre
de duas pessoas — iam para a mesma legenda.

Medido no vídeo de 9 minutos, reconhecimento da Apple, sem identificação de
locutor:

```
                     legendas   fins de frase presos no MEIO de uma legenda
japonês, antes            61                       55 de 99
japonês, depois          102                        8 de 99
inglês, antes             48                        5 de 52
inglês, depois            47                        5 de 52
```

O inglês não muda porque lá o problema não existia — `.` já estava na lista.
E o alinhamento melhorou junto, porque a legenda deixou de atravessar o
silêncio até a fala seguinte: o desvio médio do **fim** caiu de +1,04 s para
+0,56 s.

A lista virou `SentenceSplitter.sentenceEnders`, e há uma irmã para oração
(`clauseEnders`, com `、`), porque o mesmo `".!?…"` estava escrito em três
lugares: aqui, no `SentenceSplitter.split` e no `PhraseAccumulator` do tempo
real — os três cegos para japonês. `tradutor-verify frases` falha se voltar.

### O teto de tempo cortava a palavra japonesa ao meio

`AppleSpeechTranscriber.phrases` fechava o trecho assim que ele passava de
5 s, onde quer que estivesse. Em inglês cada run do sistema é uma palavra
inteira e o corte cai entre palavras; em japonês os runs são **sub-palavra**,
e o corte partia a palavra:

```
新人さんですかはい今 / 日から働くことに…      今日 partido
タメ口でもいいですかはいもち / ろんです。     もちろん partido
優しい先輩で緊張してるそ / うだよね。         そうだよね partido
でも楽しい職場だから心配しない / で。         しないで partido
```

O texto quebrado chega assim ao tradutor. Agora o fecho por tempo espera um
**lugar seguro** — espaço (inglês) ou pontuação de frase ou de oração (os
dois, `、` inclusive) — a partir de 5 s, e há um teto duro de 7 s, que é o
teto da legenda (`SubtitleFileBuilder.maximumDuration`).

Medido com o mesmo reconhecimento nos dois lados (a mesma saída do
`SpeechAnalyzer` agrupada das duas maneiras, então não há ruído de motor):

```
                          trechos     cortes no meio da palavra
ja-longo    sem locutor   132 → 120          18 → 6
ja-longo    com locutor   235 → 232           4 → 1
ja-musica   sem locutor    21 →  20           5 → 3
ja-musica   com locutor    31 →  30           3 → 2
en-conversa ambos          54 →  51           3 → 0
en-dialogo  ambos          44 →  44           0 → 0
```

**O texto sai idêntico, caractere por caractere, nos quatro vídeos** — o
conserto só muda onde o trecho fecha, não o que ele diz.

#### O teto tem de ser conferido ANTES de acrescentar o run

Conferindo depois, o trecho estoura o teto pelo tamanho do run que o cruzou.
Com o teto em 5 s isso cabia na folga; com o teto em 7 s, não:

```
                      trechos acima de 7 s     o maior
ja-longo  sem locutor        0 → 5              7,98 s
ja-musica sem locutor        1 → 4              7,38 s
```

E 7,98 s vira legenda de 8,23 s com a entrada antecipada. Quem apanhava isso
era o `clamp`, que corta a legenda em `maximumDuration` — ou seja, **o último
segundo de fala ficava sem legenda na tela**, sem nada reclamar. Conferindo o
teto antes de acrescentar o run, nenhum trecho passa de 7 s em nenhum dos
quatro vídeos, com e sem locutor — inclusive o que já passava antes do
conserto todo.

`tradutor-verify alinhamento <video> apple <idioma>` falha se voltar.

#### A folga do teto: medida, e o número fica onde está

Três constantes conspiram — `hardCeiling` (7,0), `leadIn` (0,25) e
`maximumDuration` (7,0) — e a soma das duas primeiras passa da terceira. Quem
segura é o `clamp`, que corta a legenda em `maximumDuration`. Medido no vídeo
de 9 minutos: **4 legendas de 107 saem exatamente em 7,000 s**, ou seja,
truncadas; em inglês, nenhuma.

Fechar essa folga baixando o teto para 6,75 s (= 7,0 − 0,25) foi testado e
**piora**:

```
                        cortes no meio da palavra
                        teto 7,00    teto 6,75
ja-longo sem locutor         5           6
en-conversa ambos            0           1
```

O inglês estava zerado e passaria a ter um. Texto partido ao meio é pior que
0,25 s a menos de tela numa legenda que já está no limite de leitura — e o que
o `clamp` corta é a cauda, onde a legenda seguinte quase sempre já começa.

Fica em 7,0, e `tradutor-verify motores` falha se `hardCeiling` passar de
`maximumDuration`. Quem for mexer nos três números mede as duas colunas acima
antes.

### O tempo real confirmava japonês em blocos de três frases

O *LocalAgreement-2* compara a hipótese nova com a anterior e confirma o
prefixo em que as duas concordam. A unidade de comparação era a palavra
separada por espaço — e japonês, chinês e coreano não escrevem espaço entre
palavras. Medido com `tradutor-verify audio` em 75 s de japonês: a hipótese
tinha 224 caracteres e 16 frases, e **8 unidades**, a maior com 44 caracteres
e três frases inteiras. A zona azul só andava quando duas passadas repetiam
um bloco de três frases; o resto ficava na zona vermelha até o segmento
fechar no teto de 12 s.

`Tokens.split` passa a unidade para o **caractere** onde a escrita não separa
palavra com espaço, e `Tokens.join` desfaz pela mesma regra — sem isso
"今日は" voltaria à tela como "今 日 は". Vale para o confirmador de prefixo,
para o acumulador de frases e para o `OverlapTrimmer`, que tinham os três o
mesmo `split(separator: " ")`.

Medido nos 75 s iniciais de cada vídeo, hipótese a hipótese:

```
                  caracteres confirmados      frases entregues
                  antes de o segmento fechar   antes do fim do segmento
ja-longo               51 → 153                      6 → 18
ja-musica              40 →  84                      3 →  8
en-conversa           393 → 393                     16 → 16
en-dialogo            480 → 480                     20 → 20
```

Inglês **idêntico**, como tem de ser: sem caractere denso na frase,
`Tokens.split` devolve exatamente o que `split(separator: " ")` devolvia.

**Coreano usa espaço e não pode entrar nessa regra.** O hangul saiu da faixa
de `isDense` — a primeira versão o incluía e teria colado as palavras. O
`tradutor-verify prefixo` tem o caso, com `"오늘 날씨가 좋습니다."`, mais ida
e volta em chinês, em japonês com nome latino no meio e em inglês com
pontuação de largura inteira.

### Ganho de volume: só para áudio muito baixo, e só nos modos de arquivo

`decode` entregava as amostras como vieram. `boostQuietAudio` mede o arquivo
inteiro uma vez e só multiplica quando o RMS fica **abaixo de 0,003** —
aproximadamente −50 dBFS, que é áudio quebrado, não fala baixa. Não é AGC ao
vivo nem redução de ruído.

O limiar é estreito porque ganho genérico **piora**. Medido com atenuação de
20 dB (RMS ~0,01, que a regra de hoje deixa passar intacto):

```
ja-longo · Whisper · atenuado 20 dB   sem ganho 90 caracteres   com ganho 86
```

Com 40 dB de atenuação (RMS ~0,001), que é onde a regra age, o ganho recupera
texto de verdade:

```
                                    sem ganho      com ganho
ja-longo    · Whisper                29 car.        87 car.
ja-musica   · Whisper           126 e 77 car.     134 e 134  (duas execuções)
ja-musica   · Apple                 109            116
en-conversa · Qwen 1.7B             345            363
en-conversa · Apple                 347            350
en-dialogo  · Apple                 403            403
```

Repare no Whisper com música: sem ganho as duas execuções do mesmo arquivo
deram 126 e 77 caracteres; com ganho, 134 nas duas. O ganho não só recupera
texto como **estabiliza** o que a retentativa com temperatura tornava
aleatório.

A identificação de vozes melhora junto. Comparando as faixas do áudio
atenuado com as do áudio no nível original, quanto menor a diferença melhor:

```
                              sem ganho   com ganho
ja-musica   · sortformer        4,45 s      0,80 s
ja-musica   · agrupamento       2,00 s      0,00 s
ja-longo    · sortformer        2,15 s      0,45 s
en-conversa · sortformer        2,25 s      0,35 s
en-dialogo  · sortformer        8,05 s      5,40 s
```

Nível normal e nível moderadamente baixo passam **intactos** — não há
multiplicação nenhuma, e o silêncio digital também não vira sinal.
`tradutor-verify tempos` cobre os dois lados: que o áudio normal, moderado e
residual sai idêntico, que o ganho preserva tempo, polaridade e forma, e que
um pico isolado limita o ganho antes de haver clipping.

O VAD do tempo real **não** é suspeito para fala baixa, e por isso não
ganhou nada: medido nos 75 s de japonês, ele captura 75,0 s e alcança 37 de
37 trechos de fala, e varrer os limiares não muda nada.

### A fala baixa que some é a baixa EM RELAÇÃO ao resto

A queixa era o Whisper perder fala baixa em japonês. Medido em 13/09/2026, e a
primeira suspeita estava errada nas duas pontas.

**Baixar o arquivo inteiro não perde nada.** Atenuando os dois vídeos
japoneses em 12, 20, 26, 32 e 40 dB, Whisper e Apple devolvem o mesmo texto
que no original — o modelo normaliza a janela que decodifica. E **os três
limiares do `isRealSpeech` nunca disparam**: com `ASR_DEBUG=1`, nos quatro
vídeos e em todas as atenuações, zero segmentos filtrados. Afrouxá-los não
recupera nada, porque não é ali que o texto se perde.

O que reproduz a queixa é atenuar **metade das janelas de 20 s**, deixando
fala alta e fala baixa dentro do mesmo trecho — que é como fala baixa aparece
de verdade. Aí o Whisper perde, e muito.

`levelQuietSpeech` iguala o nível ao longo do arquivo, em janelas de 0,5 s,
e roda logo depois do `boostQuietAudio`, dentro do `decode`: vale para **todos
os motores** dos modos de vídeo, não só para o Whisper. Medido com a Apple,
que repete a mesma saída caractere por caractere:

```
                            sem nivelar   nivelado   (o mesmo áudio sem atenuar)
vídeo com música  −20 dB           696        720          723
vídeo com música  −30 dB           603        720          723
vídeo de 9 min    −20 dB          4268       4415         4415
vídeo de 9 min    −30 dB          4170       4323         4415
Qwen 0.6B, música −30 dB           727        777            —
```

**Estes números são bytes UTF-8, não caracteres.** Saíram de `wc -m` num shell
sem locale UTF-8, onde ele conta bytes — e kanji ocupa três. As razões, que é
o que a tabela quer mostrar, estão certas; a unidade não. Contado de verdade
(pelo próprio Swift, no gate `cobertura`), o vídeo com música tem 242
caracteres e o de 9 minutos 1492. Quem for medir de novo: `LC_ALL=en_US.UTF-8`
antes do `wc -m`, ou conte em Swift.

**No Whisper o ganho é maior, e vem com um segundo:** cinco execuções do mesmo
arquivo, vídeo com música atenuado em −30 dB, deram 483 · 422 · 626 · 662 ·
494 caracteres sem nivelar, e 728 · 773 · 734 · 719 · 740 com. No áudio sem
atenuação nenhuma, as cinco execuções passaram a dar **exatamente 703** —
antes oscilavam entre 729 e 782. Nivelar tira o material da faixa em que a
retentativa com temperatura decide a legenda, e o texto que sai é mais
correto: `海賊王` (rei dos piratas, que é o certo e o que a Apple escreve) no
lugar de `海底王`.

Áudio normal não é mexido, e isso foi conferido nos dois idiomas: inglês sai
com 320 → 323 palavras e similaridade 0,992 (a diferença é "of the house",
fala recuperada), Parakeet e Apple saem idênticos, e o vídeo de 9 minutos
ganha 4415 → 4451 caracteres na Apple.

Quatro decisões, cada uma com o número que a obrigou:

- **O fundo é medido em quadros de 20 ms, não na janela de 0,5 s.** Quando
  metade do arquivo é fala baixa, o percentil baixo das janelas cai dentro
  dessa metade e ela vira "ruído": ganho 1, nada recuperado. O quadro curto
  pega a pausa entre sílabas, que é onde o fundo aparece mesmo num arquivo que
  nunca fica em silêncio. O gate de `tempos` tem esse caso.
- **O piso é relativo ao fundo, nunca absoluto.** Com piso fixo em 0,0005 o
  ruído de sala de um dos vídeos subiu 20× e o detector de energia passou a
  ver fala onde não havia — 196 trechos contra 186, 402 s de "voz" contra
  357 s. Ruído amplificado é pior que fala baixa: vira alucinação com
  timecode.
- **Só amplifica, e com rampa.** Comprimir a fala alta mudaria o que já estava
  bom, e degrau de ganho no meio de uma palavra é um clique — que é
  exatamente o que o detector de voz confunde com ataque de fala.
- **Medir só a banda da voz foi testado e não paga.** Um passa-alta em 200 Hz
  antes de medir deveria ajudar voz aguda sobre fundo grave; medido em banda
  larga contra 1 e 3 polos, empata em tudo (e 723 → 714 no vídeo com música).
  Ficou a medida em banda larga, que é mais simples.

**O que ganho nenhum resolve:** fala 25 dB abaixo de um fundo grave contínuo.
Somando rumble em −27 dBFS ao vídeo de 9 minutos com as janelas atenuadas, a
Apple cai de 4170 para 2077 caracteres e o nivelamento não muda nada (2059 a
2071 nas três variantes tentadas). Ali a voz está dentro do ruído, e o que
falta é supressão de ruído, não volume.

**O sintético do `say` não serve para julgar isto.** Um diálogo de duas vozes
com a feminina atenuada foi montado e descartado como arnês: a própria Apple,
chamada direto pelo `SpeechAnalyzer` sem o app no meio, perde 5 das 10 falas
do arquivo **sem atenuação nenhuma**, enquanto o Whisper pega 9. O CLAUDE.md
já registrava que essas vozes servem para medir corte e alinhamento, não
diarização; captação entra na mesma lista.

`TRADUTOR_SEM_NIVELAMENTO=1` desliga o nivelamento, para refazer qualquer
linha da tabela acima sem recompilar.

#### O tempo real não precisa disto, e agora está medido

O nivelamento vale só para os modos de vídeo, e a pergunta óbvia era levá-lo
para o ao vivo. `tradutor-verify vivo <audio> <motor>` responde: ele alimenta
o `Segmenter` em blocos de 50 ms, como o laço do pipeline faz, e reconhece
cada segmento que fecha — com e sem nivelamento.

```
                        desligado   nivelado
vídeo de 9 min             1602       1608
vídeo de 9 min, −30 dB     1576       1583
vídeo com música, −30 dB    195        196
```

Diferença de 0,2% a 0,4%, que é ruído. Um nivelador com memória de sessão
(ganho por segmento, alvo aprendido dos segmentos anteriores) foi escrito e
medido junto: mesmo resultado, mesmo levantando 87 dos 115 segmentos.

**O motivo é o desenho do caminho ao vivo.** O que o nivelamento resolve é
fala alta e baixa **na mesma janela** — e ao vivo o detector de voz já fecha
um segmento no silêncio antes disso. Cada segmento chega ao motor sozinho, e
aí vale o que já estava medido: baixar um bloco inteiro não tira texto,
porque o modelo normaliza a janela que decodifica. É a mesma conclusão que o
gate `vivo` já dava pelo outro lado ("alcança 37 de 37 trechos de fala").

Nada foi acrescentado ao caminho ao vivo. O nivelador de sessão foi removido;
o que ficou é o gate, para refazer a medição se o desenho do tempo real mudar.

#### Quem ganhou o quê: a conta por locutor

A pergunta que sobrava era se a fala recuperada é de quem estava baixo —
em particular a voz feminina, que era a queixa. `tradutor-verify cobertura`
responde: ele roda a identificação de vozes, separa as faixas por locutor e
conta, para cada um, quanto tempo de voz existe, quanto foi alcançado por
algum trecho reconhecido, e quantos caracteres saíram. Medido com a Apple
(determinística), atenuando −30 dB nas janelas alternadas:

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

**A recuperação é concentrada em quem estava baixo.** No vídeo com música, o
locutor da primeira fala vai de 99 para 138 caracteres — que é exatamente o
que ele tem no áudio sem atenuação nenhuma (138) — enquanto os outros dois
ficam parados. No vídeo de 9 minutos o ganho se espalha, porque a atenuação
alternada não respeita quem fala.

E no áudio **sem atenuação** a conta por locutor fica praticamente igual com e
sem nivelamento (906/393 contra 904/388 no vídeo de 9 min; idêntica no vídeo
com música), que é a outra metade do que se queria provar.

**"Locutor" aqui é identificador do modelo, não pessoa.** O Sortformer
partiu um diálogo de duas pessoas em **quatro** identificadores no vídeo de 9
minutos e em três no de 97 s — o terceiro e o quarto aparecem depois dos
380 s. Então a linha de um identificador é um limite inferior do que aquela
pessoa falou, e somar "o que a mulher ganhou" exige saber quais
identificadores são dela. Quem for usar esta tabela para falar de gênero
precisa dessa etapa a mais; o gate não a faz e imprime um aviso dizendo isso.

#### A régua não pode ser tratada junto com o áudio

A primeira tentativa de medir cobertura se contaminou sozinha:
`SpeechEnergy.regions` rodava sobre o áudio **já nivelado**, então o
denominador mudava entre as duas execuções que se queria comparar — 402 s de
"voz" contra 357 s no mesmo vídeo, e percentuais que não queriam dizer nada.

`MeasurementAudio` separa as duas coisas: `original` é o PCM como saiu do
arquivo, sem ganho e sem nivelamento, e é dele que saem as regiões de fala e
a identificação de vozes; `samples` é o áudio tratado, que vai para o
reconhecedor. `alinhamento` e `cobertura` usam os dois, e o denominador passou
a ser idêntico nas duas pontas — 356,9 s no vídeo de 9 minutos, 53,6 s no de
97 s, com e sem nivelamento.

Duas guardas que vieram junto, porque a medição depende delas:

- **As faixas de voz são congeladas em arquivo** (`--referencia <json>`). O
  Sortformer não repete exatamente a mesma saída entre execuções — o CLAUDE.md
  já registrava 3 vozes numa e 4 noutra —, e sem congelar, metade da diferença
  medida seria mudança de diarização, não fala recuperada. O arquivo guarda o
  SHA256 do PCM original, e é recusado se vier de outro áudio ou com faixa
  invertida.
- **`extractAudio(processing:)`** existe para essa medição: com `false` ele
  devolve o PCM sem `boostQuietAudio` nem `levelQuietSpeech`. Fora dos gates,
  ninguém chama com `false`.

#### Filtro de graves antes do reconhecimento: medido e recusado

O caso que o nivelamento não resolve é fala sob fundo grave contínuo. O
candidato natural é um passa-alta antes do reconhecimento. Medido em
13/09/2026 com dois biquads em cascata (vDSP), em 100 Hz e em 180 Hz, sobre
rumble sintético (senoides de 43, 67 e 91 Hz) somado ao áudio já atenuado:

```
Apple, caracteres              none   hp100   hp180
vídeo com música, limpo         245     244     244
vídeo com música, rumble −39    196     241     245
vídeo com música, rumble −33    198     204     246
vídeo com música, rumble −27    194     198     246
vídeo com música, rumble −21    190     197     239

vídeo de 9 min, limpo          1501    1473    1486
vídeo de 9 min, rumble −39     1416    1329    1459
vídeo de 9 min, rumble −33     1399    1355    1436
vídeo de 9 min, rumble −27     1416    1417    1422
vídeo de 9 min, rumble −21     1421    1401    1283
```

No vídeo com música o passa-alta de 180 Hz recupera quase tudo. No vídeo de 9
minutos ele **piora** no rumble mais forte (1421 → 1283), e o próprio rumble
quase não atrapalha ali. No Whisper, três execuções de cada:

```
                        none              hp180
música, limpo      266 · 266 · 266    266 · 266 · 266
música, rumble −33 280 · 280 · 280    283 · 275 · 294
música, rumble −21 266 · 266 · 266    210 · 274 · 273
```

Ele não perdia nada com o rumble, e com o filtro passou a oscilar — 210 numa
das três. Em inglês o filtro é neutro em volume (1357 → 1358 e 1036 → 1034) e
ainda assim muda o texto (similaridade 0,958 e 0,977).

Ganho que aparece num vídeo, some noutro e vira instabilidade num terceiro não
entra no caminho de todo mundo. E o teste era o **mais favorável possível**
para um passa-alta: ruído puramente grave e sintético. Nada foi acrescentado
ao app; o arnês fica em
`scratchpad/medicoes-cobertura-ruido-2026-09-13/` para quem quiser refazer com
ruído real. Um filtro que se ligue sozinho só quando a energia grave domina é
a próxima ideia, e continua não medida.

**`AVAudioUnitEffect` de voice processing não serve aqui**, e isso é da
documentação da Apple, não medição: ele existe para captura ao vivo e não
funciona no modo de renderização offline, que é o que a geração de legenda usa.

### Cortar o trecho no silêncio: medido e descartado

A pausa que o reconhecedor não expõe parecia a causa da legenda mal cortada em
japonês: medido no vídeo de 9 minutos, **44 dos 119 trechos da Apple (37%)**
carregam um silêncio de 0,6 s ou mais dentro. Em japonês ela é invisível de
propósito — a Apple emite um caractere por run e embute o silêncio na duração
do caractere que abre a fala seguinte, e só `longRunIsPause` (2 s) a percebe.

O conserto tentado foi o mesmo desenho das fronteiras de voz: medir os
silêncios com `SpeechEnergy` e passá-los ao `phrases`, que fecharia o trecho
ali. Medido com a Apple, varrendo o silêncio mínimo:

```
limiar        trechos   com pausa dentro   caracteres
desligado        119           49             1497
0,6 s            171           40             1495
1,0 s            132           47             1496
1,5 s            120           48             1501
```

O melhor caso corta 9 dos 49 casos e cobra **52 trechos a mais** — 44% de
fragmentação, que é tempo de tradução (ver "Tamanho de lote") e legenda mais
picada. No Whisper não muda nada (31 contra 32), porque ele já corta pelo
próprio detector de voz. O texto sai igual e a fala sem legenda também
(97,6 s dos dois lados).

A explicação é que o run é indivisível: a fronteira cai entre runs de qualquer
jeito, então ela fragmenta sem separar o que estava junto. Nada foi mantido.

### O espaço que não existe em japonês

A legenda saía `よかったです。 頑張ろうね。` e `あのれいかさん、何すればいいですか ？`.
Esse espaço não existe em japonês, e ele segue para o tradutor e para o
arquivo. Eram **22 no vídeo de 9 minutos**, e vinham de três lugares
diferentes — cada um precisou da sua regra:

- **o texto do próprio run**, que a Apple devolve com espaço antes da
  pontuação: `Tokens.tightenDense`, chamado no `close()` do
  `AppleSpeechTranscriber.phrases` (22 → 12);
- **a junção dos trechos** em `makeCues`, que usava `joined(separator: " ")`:
  `Tokens.join` (12 → 5);
- **`mergeTinyCues`**, que colava duas legendas curtas com `" " + cue.source`
  (5 → 0).

Nos dois vídeos japoneses o resultado é **zero**.

#### O efeito na tradução, isolado do ruído do reconhecedor

Comparar duas gerações não serve: a Apple não repete o mesmo texto duas vezes
("homing" numa execução, "humming" na outra). O teste que serve é o mesmo
texto, com e sem os espaços, pelo `tradutor-verify traduzir`:

```
linhas com espaço removido                   22 de 104
traduções que mudaram                        18
traduções que mudaram SEM ter espaço          0   ← sem contágio de lote
começam com maiúscula, nas 22 afetadas    com: 0   sem: 14
```

Um exemplo do que muda:

```
よかったです。頑張ろうね。
   com espaço:  "foi bom. vamos fazer isso."
   sem espaço:  "Ainda bem. Vamos nos esforçar."
```

O tradutor do sistema devolve minúscula e frase frouxa quando o japonês chega
malformado. Isto ataca a causa; `capitalizeSentences` continua existindo para
o que sobra.

**Inglês fica byte a byte igual, por construção**: `tightenDense` só age entre
dois caracteres de escrita densa e só quando há **um** espaço, e `Tokens.join`
omite o espaço na mesma condição. `tradutor-verify prefixo` e `frases` cobrem
os dois lados, inclusive `dois  espacos  ficam` e `今 20歳です` — o `2` não é
denso, então aquele espaço fica.

### A largura da linha é a do idioma que vai ser lido

`SRTWriter.render` quebrava em 42 caracteres, fixo. 42 é a convenção latina;
japonês e chinês escrevem caractere de largura cheia e a legenda do meio cabe
em 16 a 20 por linha. Medido gerando **inglês → japonês** num vídeo de 161 s:

```
                legendas   linhas   maior linha   linhas acima de 20
42 (fixo)            48       49         42            18
20 (por destino)     49       69         20             0
```

`SubtitleFileBuilder.lineWidth(for:)` decide pelo **destino**, `translate` a
aplica e `render` a recebe. Japonês → português não muda nada: 136 linhas e
42 de maior nos dois lados.

Coreano fica de fora, como já fica em `Tokens.isDense`: usa espaço entre
palavras. Tailandês não usa, mas tem convenção própria e não foi medido.

**O painel ao vivo não entrou nessa conta.** Ele chama `LineBreaker.wrap` com
o padrão de **58**, não 42, e traduzir ao vivo para japonês tem o mesmo
problema em dobro. Não foi medido.

### Os números latinos que não precisavam mudar

Quatro constantes foram suspeitas de estarem calibradas para o latim e serem
estreitas demais para japonês, que é duas vezes mais denso. Medidas no
material real, **três nunca chegam a atuar**:

```
SubtitleFileBuilder.maximumCharacters = 150   legenda mais longa: 55 ja, 112 en
PhraseAccumulator.maximumCharacters   =  75   frase mais longa:   42 ja,  70 en
SentenceSplitter.minimumCharacters    =  12   frases japonesas afetadas: 0 de 33
                                              e 0 de 17
```

O mínimo de 12 caracteres parecia o mais perigoso — a legenda japonesa tem
mediana de 12 caracteres, então metade delas fica abaixo dele. Só que ele só
gruda frases **dentro de uma mesma frase fechada**, e depois que `。` passou a
fechar frase (ver acima) cada uma chega sozinha. Onde ele ainda age é em
inglês, evitando que `...` vire três blocos — que é para o que foi feito.

A quarta era real, e é a da seção anterior. **Não mexer nas três primeiras sem
uma medição que mostre elas atuando**: trocar número que não atua é trocar
comportamento no escuro.

### Como os três consertos acima foram exercitados ponta a ponta

Matriz de 13/09/2026, 24 execuções dos dois fluxos, guardada em
`Relatorio Auditoria 2026-09-12/conclusao-2026-09-13/matriz-final/`:

```
4 vídeos × janela e item de menu × Apple × com e sem locutores   16
Whisper, Parakeet, Qwen 0.6B e Qwen 1.7B (item de menu)           4
vídeo de 40 s atenuado 40 dB × janela e item de menu × com e sem  4
```

**22 passaram; as 2 reprovações foram a verificação de progresso no vídeo de
40 s**, que é o caso de dado descrito acima. Nenhuma legenda de três linhas,
nenhuma acima de 7 s, nenhum motor caindo para outro em silêncio.

**Com locutores ligados a matriz não pega tudo.** A regressão do teto de 7 s
só aparecia com a identificação **desligada** — que é o padrão do app —,
porque com ela ligada a troca de voz corta o trecho antes de o teto chegar. A
matriz anterior rodava tudo com locutores e passava. Quem medir corte de
trecho roda os dois.

### A legenda que apaga a tela no meio da fala

A queixa: em japonês, com o Whisper, a legenda aparece e some com a pessoa
ainda falando. Medido no vídeo de 9 minutos, contando o buraco entre uma
legenda e a seguinte:

```
                buracos abaixo de 1 s     tela apagada
Whisper turbo          38 de 106              25,5 s
Apple                  10 de 105               6,4 s
```

**Não é defeito do Whisper, e não é o agrupamento.** Onde a Apple devolve dois
trechos contínuos, o Whisper devolve seis curtos com buraco entre eles:

```
Whisper  …402,84 → 405,02 → 406,18 → 407,30 → 408,18 → 408,72 → 409,86…
Apple    403,86–408,54  ·  408,54–411,06
```

Ele pontua cada fala curta, e o agrupador fecha legenda na pontuação — que é
exatamente o que se quer. O que faltava era **segurar a legenda até a
seguinte**, que é prática corrente de legendagem: buraco de meio segundo entre
duas frases da mesma pessoa não é pausa, é a tela piscando.

`bridgeShortGaps` estende o fim de cada legenda até `minimumGap` (0,08 s, dois
quadros a 24 fps) antes da seguinte, quando o buraco é menor que `maximumGap`
(1,0 s). Nunca encurta nada e nunca passa do teto de leitura:

```
                tela apagada em buracos < 1 s     maior legenda
Whisper  antes           25,5 s                      6,85 s
Whisper  depois           4,4 s                      7,00 s
Apple    antes            6,4 s                      7,00 s
Apple    depois           0,9 s                      7,00 s
```

O conserto é em `makeCues`, **antes da tradução** — vale para qualquer
tradutor, inclusive o DeepL, e para qualquer reconhecedor. `tradutor-verify
tempos` cobre os três casos: buraco curto preenchido com respiro, buraco longo
intocado, e preencher sem passar dos 7 s.

### A legenda de três linhas, e por que ela voltava

`enforceLineLimit` reparte a legenda cuja tradução não cabe em duas linhas.
Ela repartia **uma vez só**, e a conta de quantas partes fazer era
`caracteres ÷ (42 × 2)` — ou seja, supunha que toda linha chega aos 42
caracteres. Não chega: a quebra procura pontuação e espaço, então 81
caracteres podem precisar de três linhas.

O caso real, no vídeo de 9 minutos:

```
160 caracteres  →  2 partes de ~80
                   a segunda, "Depois, desculpe, como você faz os músculos
                   triângulos? Eu não entendo muito bem.", saía com 3 linhas
```

E ninguém conferia de novo. A legenda ia para o arquivo com três linhas,
cobrindo o vídeo.

**Intermitente, e por isso escapou:** acontecia em 2 de 4 gerações do mesmo
vídeo, conforme o texto que o tradutor devolvia. O autoteste do item de menu
pegava quando acontecia ("nenhuma legenda passa de duas linhas").

Duas correções: a conta passou a ser por **linhas** (`linhas ÷ 2`, que é o que
de fato decide) e o resultado volta para outra passada, até três, porque texto
sem onde quebrar não pode entrar em laço. `tradutor-verify quebra` roda o caso
de 160 caracteres e falha se alguma parte voltar com três linhas.

`tradutor-verify treslinhas <video>` gera com a Apple e varre a saída inteira;
foi como a causa foi encontrada, e serve para procurar de novo.

#### E a terceira linha voltava pelo travessão

A conta por linhas consertou a repartição, e a legenda de três linhas
continuou saindo — por outro caminho. `enforceLineLimit` media o texto **sem**
o travessão; quem acrescenta `— ` é a renderização, depois, e ele ocupa duas
colunas da primeira linha. Corpo que cabe em duas linhas, mais travessão, são
três.

```
— Se você queimar isso, você
essencialmente vai atrasar o progresso
científico!
```

`splitOversized` passou a medir `SpeakerMark.decorate(...)`, o texto como ele
vai para a tela e para o arquivo, e a repartir o texto puro — só a primeira
parte leva travessão, porque as seguintes são do mesmo locutor. Medido nos
quatro vídeos de exemplo, com Apple e Sortformer: **3 legendas de três linhas
viraram 0**, e o autoteste do item de menu deixou de reprovar em dois deles.

`tradutor-verify quebra` tem o caso mínimo — 14 repetições de "teste", que
cabem em duas linhas e estouram com o travessão.

### Identidade não pode se perder depois do reconhecimento

Três lugares do pós-processamento desfaziam o trabalho da identificação de
vozes. Todos foram medidos nos mesmos quatro vídeos, Apple + Sortformer,
antes e depois:

```
                   legendas com cor          três linhas   acima de 7 s
antes                193 de 220 (88%)              3             4
depois               235 de 246 (96%)              0             0
```

- **`splitOversized` não copiava `speaker`.** Uma legenda longa identificada
  virava três sem dono: sem cor na janela, sem travessão no arquivo. Era a
  segunda origem das lacunas de cor — a primeira, legítima, é o trecho que o
  modelo deixou sem dono.
- **`mergeTinyCues` juntava resposta curta de outra pessoa.** O agrupador
  respeita a troca de locutor; a junção vinha depois e desfazia. "Você
  entregou o relatório?" e "Sim." viravam uma legenda só, atribuída a quem
  perguntou. Agora só junta quando o locutor é o mesmo — com identificação
  desligada, os dois são `nil` e nada muda.
- **`SpeakerDiarizer.assign` escolhia a maior faixa isolada**, não a voz que
  mais cobre o trecho. Voz A em 0–3 s e 7–10 s soma 6 s e perdia para os 4 s
  de B em 3–7 s. Trecho largo com ida e volta dentro é justamente o que a
  Apple produz. Empate fica com quem falou primeiro, para a saída não mudar
  entre execuções.

O preço é fragmentar: no vídeo de 9 minutos, 107 legendas viraram 128 a 130
conforme a execução, e a geração foi de 44 s para 45–47 s (a primeira execução
depois de recompilar deu 69 s — é carga de modelo, não o custo). Nos outros
três vídeos o tempo não mudou. É o mesmo preço já registrado em "Tamanho de
lote": legenda mais curta custa mais tempo de tradução.

Os quatro autotestes do item de menu passam: antes, dois reprovavam em
"nenhuma legenda passa de duas linhas".

**A janela de legendas não conferia nada disso**, e é a outra metade do
produto. O autoteste dela agora mede `displayText` — o texto como a janela
mostra, travessão incluído — e a duração das legendas geradas. Nos quatro
vídeos: 78 verificações, tudo passa; com o código anterior, o mesmo teste
reprova em três linhas e em 9,36 s.

Exercitado depois com Whisper (quatro vídeos) e Parakeet (os dois em inglês),
nos dois fluxos: 12 execuções, tudo passa, nenhuma legenda de três linhas nem
acima de 7 s. Com o Parakeet são 63 verificações — a do progresso do
reconhecimento só vale para o Whisper.

**Uma verificação de navegação dependia do tamanho da legenda.** "Voltar do
meio de uma fala" usava a legenda de índice 3, fixa, e procurava um instante
um segundo depois do início dela; em legenda curta esse instante cai na
legenda **seguinte**, e o teste reprovava por dado, não por defeito. Apareceu
com o Parakeet, que corta mais fino. Hoje o teste procura a primeira legenda
com mais de 1,3 s — a regra do app só vale passado um segundo do início.

**E uma verificação de progresso dependia da duração do vídeo.** "O
reconhecimento mostra progresso" reprovava num arquivo de 40 s: o Whisper
decodifica em janelas de 30 s e só relata ao fechar uma, o reconhecimento
inteiro levava 1,5 s, e o laço do teste terminava sem amostrar fração
nenhuma. As outras 17 verificações da mesma execução passavam. A verificação
existe para pegar a barra parada em **vídeo longo**, que era o defeito, então
hoje ela só vale acima de 60 s e escreve "(pulado)" abaixo disso. Apareceu ao
incluir um vídeo curto e muito baixo na matriz.

### Lote que falha não pode passar por geração completa

`translate` registrava o erro do lote e seguia — certo, porque perder dez
minutos de trabalho por um lote seria pior. Mas em silêncio: aquelas legendas
saem no idioma de origem e o `.srt` fica plausível e errado. O aviso que
existia era o do DeepL (`completionNotice`), que não cobre erro absorvido pelo
builder.

Agora `translate` conta os lotes perdidos e escreve em `translationNotice`, que
já subia até a janela de conclusão e a barra da janela de legendas. Os dois
avisos somam: cair para a Apple e não traduzir são coisas diferentes.

**E resposta com contagem diferente da entrada é descartada inteira.** É o
defeito que não devolve erro: a legenda 5 recebe a tradução da 4, com timecode
válido e arquivo sem nada de errado — a mesma corrupção silenciosa que
desqualificou o Google na comparação de tradutores.

### Retraduzir sem reconhecer de novo

O botão de retraduzir refaz **só** a tradução, com o tradutor escolhido agora, e
o rótulo no cabeçalho da lista diz o que produziu o que está na tela —
`Apple → DeepL (site)`, os motores que **rodaram**, não os dos seletores.

Por que o resultado é o mesmo de gerar de novo: entre `makeCues` e `translate`
não há mais nada no caminho. Glossário, tamanho de lote, quebra de duas linhas
e maiúscula de começo de frase moram todos dentro do `translate`. Então guardar
o rascunho — as legendas antes de traduzir — e chamar `translate` de novo dá
exatamente o que outra geração daria com aquele tradutor. O autoteste da janela
confere isso legenda a legenda, com a Apple: **45 de 45 idênticas**.

E dá uma coisa que gerar de novo **não** dá: o mesmo corte e os mesmos
locutores. O reconhecimento não repete igual — o Sortformer varia entre
execuções e o Whisper tem retentativa com temperatura —, então comparar dois
tradutores regerando compara duas coisas ao mesmo tempo.

O que se economiza é o reconhecimento e a identificação de vozes, e isso varia
muito conforme quem reconhece:

```
                            geração inteira   só a tradução
ja-musica · Whisper              13,5 s           1,7 s
ja-longo  · Apple                49,6 s          39,4 s
en-dialogo · Apple               14,9 s          10,3 s
en-conversa · Parakeet           16,2 s          15,7 s
```

Onde o reconhecimento é caro, a economia é quase tudo. Onde ele já é rápido
(Parakeet faz 161 s de áudio em 1,8 s), o que sobra é a tradução, e ela custa o
que custa.

Quatro decisões que o botão obrigou:

- **O que está na tela não sai enquanto a nova tradução é feita**, nem se ela
  for cancelada ou falhar. Por isso as legendas parciais não chegam à tela aqui
  — `onBatch` fica de fora de propósito. Trocar de tradutor não pode custar a
  legenda que já estava boa.
- **Um tradutor vivo por vez, e encerrado assim que termina.** A janela do
  DeepL fecha sozinha no fim da tradução (medido: 20 a 30 ms depois do último
  bloco) e o servidor do Hunyuan devolve os 4,5 GB na hora. Antes ninguém
  chamava `reset()` nos modos de vídeo e os dois ficavam vivos até o app
  fechar — um app de barra de menus, que fica aberto o dia todo.
- **Legenda aberta de arquivo não dá para retraduzir.** O `SRTParser` põe o
  texto em `translated` e deixa `source` vazio — não há original. O botão fica
  apagado e diz por quê.

E duas armadilhas que o autoteste pegou:

- **Igualdade estrita só vale para tradutor determinístico.** O DeepL é um
  site: numa terceira passada sobre o mesmo texto, 5 de 20 legendas mudaram. A
  verificação estrita roda com a Apple; com os outros, o que se exige é que
  nenhuma legenda volte vazia.
- **Cancelar e retomar no mesmo instante deixa o lote anterior em voo**, e o
  tempo medido deixa de ser o de uma retradução limpa — 19,6 s contra 10,4 s no
  mesmo vídeo. A ordem do teste importa.

---

### Nada de mascarar palavrão

Legenda é transcrição: o que foi dito, sai. Auditado motor por motor:

- **Apple** é o único que tem como censurar —
  `SpeechTranscriber.TranscriptionOption.etiquetteReplacements`, que troca
  palavrão por eufemismo. `AppleSpeechTranscriber.transcriptionOptions` fica
  **vazio**, e `tradutor-verify motores` falha se alguém acrescentar algo.
- **WhisperKit**: nenhuma lista de palavras. `supressTokens` é `[]` por
  padrão (a linha na biblioteca ainda tem um `// TODO` para os tokens de
  não-fala, que são pontuação e símbolos, não palavras).
- **FluidAudio** (Parakeet) e o **pacote do Qwen**: nenhuma menção a filtro —
  o do Qwen diz literalmente "no translation layer", e nada de filtragem.
- **Tradução da Apple**: testado com duas frases carregadas em japonês; voltou
  sem máscara ("Este filme de merda é uma porcaria").

O único filtro de texto do app é `Hallucinations`, e ele só descarta frase de
cortesia isolada ("obrigado por assistir") — nada a ver com vocabulário.

Ele roda em **dois lugares, por motivos diferentes**: dentro do
`WhisperTranscriber`, que também serve ao tempo real, e em
`SubtitleFileBuilder.generate`, logo depois do reconhecimento, valendo para
todos os motores. Antes só existia o primeiro, e Apple, Parakeet e Qwen
passavam direto — justamente o Qwen, que é o recomendado para japonês.

## Armadilhas do sistema

**A permissão é de Gravação de Tela e Áudio do Sistema.** Negada, não devolve
erro: o tap abre, o callback dispara na cadência certa, e todos os quadros vêm
zerados. `CGPreflightScreenCaptureAccess()` **não** é indicador confiável — ele
cobre só uma das duas listas do painel.

**Binário de terminal nunca consegue essa permissão.** O TCC segue o processo
pai. Só um `.app` assinado, aberto com `open`, tem identidade própria.

**Recompilar pode derrubar a permissão.** Assinatura ad-hoc muda a cada build.
Se a captura voltar a dar silêncio: remova o app das duas listas com − e
adicione de novo.

**O aggregate device precisa de sub-dispositivo.** Com a lista vazia ele roda
no clock certo e entrega silêncio — sintoma idêntico ao de permissão negada.

**`isExclusive` decide inclusão ou exclusão.** `initStereoGlobalTapButExcludeProcesses`
liga `exclusive` internamente; fixá-lo em `false` transformava o tap global em
um tap inclusivo de lista vazia.

**Chrome não toca áudio no processo principal.** Vive em
`com.google.Chrome.helper`. Os processos são agrupados por bundle ID do dono.

**`VideoPlayer` do SwiftUI aborta neste app.** `getSuperclassMetadata` em
`_AVKit_SwiftUI`, morte imediata ao escolher um vídeo. Use `AVPlayerView` do
AppKit via `NSViewRepresentable`.

**A primeira faixa de áudio não é necessariamente a do idioma.** `decode`
pegava `tracks.first`, e vídeo com dublagem, comentário do diretor ou um
idioma por faixa não diz qual é a principal: a legenda saía do áudio errado,
com timecode válido e nada reclamando. Hoje a faixa é escolhida pelo
`languageCode`/`extendedLanguageTag` dela contra o idioma de origem — os dois
normalizados por `Locale.Language`, que resolve "jpn", "ja-JP" e "ja" no mesmo
código sem tabela de conversão. Faixa nenhuma declarando o idioma pedido, a
primeira continua valendo. `tradutor-verify faixas` monta um arquivo de duas
faixas e falha se voltar a pegar a primeira.

**`AVPlayer` escolhe o demuxer pela extensão.** Arquivo sem extensão não toca,
mesmo sendo mp4 válido. Um link temporário `.mp4` resolve.

**Linha "em branco" com espaços não separava blocos no `.srt` lido.** O parser
cortava em `\n\n`, e `\n  \n` não é isso: os dois blocos viravam um, com o
número e o timecode do segundo dentro do texto do primeiro. Arquivo aceito,
legenda embaralhada. O app não grava assim; editor de texto e outras
ferramentas gravam.

**Player novo nasce em volume 1 e sem mudo.** `swapPlayer` já aplicava a
escolha do usuário; `open` não, e quem tinha silenciado levava o susto ao abrir
o vídeo seguinte. O fim da reprodução também não chegava à interface —
`isPlaying` ficava verdadeiro com o player parado, e o primeiro clique no botão
não fazia nada visível. Quem avisa é `AVPlayerItemDidPlayToEndTime`.

**O Whisper alucina no silêncio.** Em japonês, ご視聴ありがとうございました
aparece sozinha no meio do vídeo. As métricas do modelo não a pegam — para ele
é predição confiante. Só o texto denuncia (`Hallucinations.swift`).

**`DragGesture` entrega deslocamento acumulado, não o passo.** O
`value.translation` conta desde o início do gesto, e somá-lo à largura atual a
cada `onChanged` faz o arrasto acelerar sozinho: 12 px de movimento
deslocavam 22, e o divisor da janela ia ao limite antes de dar para escolher
uma largura. O que se soma é o valor de onde o arrasto partiu. A barra de
progresso do vídeo não tinha o problema porque usa `value.location`, que é
posição absoluta.

**Legendas podem sair além do fim do vídeo.** No vídeo de 18 min saiu uma
começando aos 18:04 num vídeo de 18:01, durando 20 s. `clamp` corta.

**E o teto de 7 s vale depois de juntar, também.** `clamp` roda antes de
`mergeTinyCues`, e juntar voltava a passar do teto — 9,481 s numa legenda do
vídeo com música. A junção passou a respeitar `maximumDuration`; nos quatro
vídeos, 4 legendas acima de 7 s viraram 0.

---

## Modelos em disco

`~/Library/Application Support/Tradutor/models/` — fora do backup, baixados na
primeira execução:

```
1,2 GB  whisper/     (turbo)
                     os três abaixo só se escolhidos no seletor, no 1º uso:
469 MB  parakeet-tdt-0.6b-v3/
```

**Depois do primeiro download, carregar não usa rede.** Cada reconhecedor
confere o disco antes de chamar a biblioteca:

- Whisper: `WhisperKit.download` consultava o Hugging Face a cada carga (6 s,
  e sem internet falhava). Com o modelo inteiro na pasta, ele é usado direto;
  o tokenizador vem de `tokenizerFolder` — sem ele, o WhisperKit procura em
  `~/Documents/huggingface` e depois na rede.
- Parakeet: o FluidAudio já pula o download quando acha os arquivos.
- Sortformer: `initializeFromHuggingFace` **não** encaminha a pasta e cai no
  `~/Library/Application Support/FluidAudio`. O comentário dizia uma coisa e o
  modelo ia para outra, fora do alcance do `CacheCleanup` e da conta de espaço.
  Quem aceita a pasta é `OfflineSortformerModels.loadFromHuggingFace(cacheDirectory:)`,
  e os modelos entram por `diarizer.initialize(models:)`.

A compilação para o Neural Engine, em `~/Library/Caches/<bundle>`, fica em
~230 MB com todos os motores usados.

Fora de `models/`, na mesma pasta do app:

```
2,2 GB  qwen/         venv Python + modelo, criado por Scripts/qwen-setup.sh
4,5 GB  hunyuan/      venv Python + Hunyuan-MT-7B em 4 bits, por Scripts/hunyuan-setup.sh
  13 MB models/speaker-diarization/   vozes: segmentação e embedding (FluidAudio)
 243 MB models/sortformer/            vozes: modelo ponta a ponta (FluidAudio)
```

### Nada de cache além dos modelos

`CacheCleanup.run()` roda ao abrir, antes de carregar modelo. Antes dela
existir o app acumulava 3,6 GB em `~/Library/Caches/app.tradutor.instantaneo`
e 88 pastas temporárias.

- **Compilação para o Neural Engine** (`com.apple.e5rt.e5bundlecache`): o
  Core ML guarda por hash, sem dizer de qual modelo. Trocou o conjunto de
  modelos? Incremente `CacheCleanup.modelSetVersion` — a pasta é refeita do
  zero uma vez (a primeira carga leva ~2 min). Pastas de versões antigas do
  macOS são apagadas sempre.
- **Cache HTTP dos downloads**: `URLCache.shared` zerado; `Cache.db` apagado.
- **Temporários** `tradutor-*` com mais de 1 h: apagados.
- Tradução não grava nada; o histórico das legendas é só memória.

Fora do app, e **não** tocados por ele: `~/Documents/huggingface` (padrão do
WhisperKit) e `~/Library/Application Support/FluidAudio` (padrão do
FluidAudio). O código atual passa pasta própria às duas bibliotecas.

---

## Estilo

- Comentários em português, explicando **por que**, não o que. Vários comentários
  registram uma medição ou um bug que custou caro — preserve-os.
- Todo bug corrigido ganha uma verificação que falha se ele voltar.
- **Teste nunca escreve em dado do usuário.** O gate da lista de termos já
  destruiu a lista real uma vez: trocava os termos pelos de teste e restaurava
  num `defer` que `exit()` nunca executa. Quem guardar dado do usuário aceita
  um diretório no construtor, e o teste passa uma pasta temporária.
- Antes de trocar um número que tem comentário de medição, meça de novo.
