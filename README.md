# Tradutor Instantâneo

App macOS que faz duas coisas com áudio que já está no seu Mac:

- **legenda traduzida em tempo real** por cima de qualquer aplicativo tocando som;
- **arquivo `.srt`** a partir de um vídeo, com janela para assistir e revisar
  antes de exportar.

O reconhecimento é sempre local. A tradução também, a menos que você escolha
DeepL ou Google, que mandam o texto para o site deles — o app avisa no seletor.
Apple Silicon, macOS 15+ (o reconhecimento da Apple pede macOS 26). Medido num
MacBook Air M5 de 16 GB.

---

## Tempo real

Escolha o aplicativo que está tocando som, o idioma dele e o de destino. Um
painel flutuante aparece com três zonas:

| Zona | Conteúdo |
|---|---|
| Amarela | traduções anteriores, esmaecendo — só ela rola |
| Azul | a tradução mais recente |
| Vermelha | o que está sendo captado agora, **sem traduzir** |

A zona vermelha é o que faz o resto funcionar: o texto parcial do reconhecedor
muda a cada instante, e traduzir esse parcial faria a legenda piscar. O parcial
aparece cru, e só o trecho fechado atravessa a tradução — uma vez escrito, nunca
muda.

Painel de tamanho fixo, escolhido arrastando as bordas e lembrado entre
execuções; *Restaurar tamanho do painel* resolve se ele sumir. `⌥⌘T` liga e
desliga.

**Por que o áudio não é cortado em pedaços.** Cortar parte palavras e nenhuma
metade sobrevive: "reported" saía como "Reaper's" no fim de um bloco e "ported"
no começo do seguinte. O trecho é transcrito inteiro, repetidamente, e vai para
a tela o prefixo em que duas passadas concordam (*LocalAgreement-2*, do
`whisper-streaming`). O detector de voz usa dois limiares — abrir um trecho
exige energia bem acima do ruído, continuar exige bem menos —, senão a voz que
baixa no fim da frase fechava o trecho no meio da fala.

## Legendas de vídeo

Dois caminhos, mesma geração:

- **Assistir com legenda…** abre a janela: escolher o vídeo, gerar, assistir,
  navegar de fala em fala e exportar o `.srt`.
- **Só gerar o .srt de um vídeo…** grava o arquivo ao lado do vídeo, com o
  idioma no nome (`filme.pt.srt`) — a convenção pela qual os players o acham.

Na janela: clicar numa legenda leva o vídeo ao instante em que ela é falada; a
legenda no ar fica destacada e a lista rola sozinha; controles de ±10 s e de
fala em fala; a linha do tempo marca onde há diálogo; velocidade de 0,75× a
1,5×; espaço reproduz, `←`/`→` andam 5 s, `⌘←`/`⌘→` andam de legenda em legenda.
**Carregar .srt** abre uma legenda pronta — o leitor aceita CRLF, bloco sem
número, ponto no lugar da vírgula, `<i>` e arquivos em Latin-1.

As legendas aparecem lote a lote. Regerar limpa o que havia. Cancelar descarta o
resultado e impede a etapa seguinte — o reconhecimento é uma chamada única e
longa, que não dá para matar no meio.

### Como a legenda é montada

```
vídeo ──▶ faixa do idioma escolhido ──▶ áudio 16 kHz ──▶ nivela fala baixa
      ──▶ quem fala, quando pedido (fronteiras de voz)
      ──▶ reconhecimento com marcação de tempo
      ──▶ agrupa em frases (150 chars, pausa > 0,8 s, teto 7 s)
      ──▶ traduz em lotes
      ──▶ reparte em legendas de 2 linhas × 42 chars (20 se o destino é CJK)
      ──▶ .srt
```

Vídeo com mais de uma faixa — dublagem, comentário, um idioma por faixa — é lido
na faixa que **declara o idioma escolhido**, não na primeira. Antes do
reconhecimento o áudio passa por um nivelamento em janelas de meio segundo: quem
fala baixo no meio de quem fala alto sobe até perto do resto. Vale para todos os
motores; áudio parelho passa intacto e ruído de fundo não é amplificado.

Cada legenda entra 0,25 s antes da fala — o reconhecedor marca o início entre
0,15 s e 0,8 s tarde —, sem invadir a anterior. Nenhuma fica mais de 7 s na tela
nem começa depois do fim do vídeo. E nenhuma apaga a tela no meio da fala:
buraco menor que 1 s entre duas legendas é preenchido, deixando dois quadros de
respiro.

O Whisper alucina no silêncio — em japonês, ご視聴ありがとうございました sozinha
no meio do vídeo. As métricas do próprio modelo não a pegam; só o texto denuncia,
e há uma lista dessas frases.

**Arquivos sem extensão** não são recusados: quem julga são os bytes. Se o
arquivo não abrir direto, ele é reapresentado por um link temporário `.mp4`,
porque o AVFoundation escolhe o demuxer pela extensão. Se ainda assim não abrir,
o erro diz qual formato é e quais são aceitos.

## Reconhecimento

O seletor oferece cinco famílias; o idioma de origem limita o que aparece.

| Motor | Cobertura | Onde vive |
|---|---|---|
| Apple (padrão) | de, en, es, fr, it, ja, ko, pt, zh | modelos do sistema, pelo + ao lado do idioma |
| Parakeet TDT v3 | os idiomas europeus, ~120× tempo real | pasta do app |
| Whisper turbo | todos os idiomas do app | pasta do app |
| Qwen3-ASR 0.6B | 13 idiomas, melhor em japonês (sem inglês) | ambiente próprio, só em vídeo |
| Qwen3-ASR 1.7B | o mesmo, mais preciso e 4× mais lento | idem, com `--grande` |

O Qwen3-ASR é o único que não roda dentro do app: não há port CoreML dele, só
MLX com Python.

```bash
Scripts/qwen-setup.sh            # ambiente + 0.6B (2,2 GB)
Scripts/qwen-setup.sh --grande   # também o 1.7B (3,4 GB a mais)
Scripts/qwen-setup.sh --remove
```

Em 96 s de japonês limpo ele devolve 281 caracteres contra 260 do Whisper e 248
da Apple — mas o que muda a legenda é o formato: **uma fala por bloco, com
pontuação**, em vez de pergunta e resposta na mesma linha. Custa 17× tempo real
contra 172× da Apple, e por isso vale **só para vídeo**; no tempo real o app
volta sozinho para a Apple.

O Whisper roda com `firstTokenLogProbThreshold` em −3,0, não no −1,5 padrão.
Abaixo desse limiar ele re-decodifica com temperatura crescente, e temperatura
acima de zero sorteia o token: o mesmo arquivo dava de 9 a 34 trechos entre
execuções, e uma em cada três perdia os primeiros 32 s. Com −3,0 a cobertura
subiu de 44% para 70%. Em áudio difícil ele ainda varia, e aí a transcrição é
repetida até três vezes, ficando com a passada que alcançou mais fala.

### Quem fala

*Identificar quem fala*, nos modos de vídeo, roda um segundo modelo sobre o
mesmo áudio e usa o resultado para **separar as legendas por locutor** — a troca
de voz vira fronteira de legenda e ganha travessão no `.srt`.

Dois modelos: **Sortformer** (padrão) marca 101 das 104 legendas em 1,4 s no
vídeo de 9 minutos e repete quase igual entre execuções; **Agrupamento de
vozes** marca 114 de 123 em 3,6 s e oscila mais. Nenhum é determinístico.
Pontuados contra marcação humana, o Sortformer ganha nos casos normais (97% e
70%) e perde onde há muita gente (50% num vídeo de dez pessoas), por causa do
teto de quatro vozes da exportação CoreML.

**Uma cor por locutor**, opcional: branco, amarelo, ciano e verde, as cores da
legenda oculta de TV. Vale na janela e, se você quiser, no `.srt`, onde entra
como `<font color="#…">` — entendido por VLC, mpv e a maioria dos players.

## Tradução

Quatro motores nos modos de vídeo; ao vivo é **sempre a Apple**, porque um
trecho re-reconhecido a cada 0,6 s não comporta ida à rede nem modelo de 7B.

| Motor | Onde roda | Por quê |
|---|---|---|
| **Apple** (padrão) | local | instantâneo, nada sai da máquina |
| **DeepL (site)** | rede | o melhor em japonês — gênero, nome próprio, registro |
| **Google (site)** | rede | o mais rápido, e chega perto do DeepL |
| **Hunyuan-MT 7B** | local, fora do processo | entende melhor que a Apple sem mandar texto para fora |

Medido em 110 falas japonesas: Apple 36 s, DeepL 11 s, Google 1,3 s. Em
qualidade, gênero acertado em 8 casos: DeepL 6, Google 3, Apple 2. Nome próprio:
DeepL e Google 4 de 4, Apple 2 de 4.

O **DeepL** usa o site gratuito numa janela visível; **uso automatizado contraria
os termos de uso deles**, e o mesmo vale para o endereço que o **Google** usa.
Bloco que o site recusa cai para a Apple, e a janela diz quantos foram.

O Google é mais rápido porque manda cada fala numa requisição própria — o que
garante o alinhamento e, em troca, tira todo o contexto entre falas: frase
partida pelo reconhecimento vira duas traduções independentes.

O **Hunyuan-MT** (4,5 GB, `Scripts/hunyuan-setup.sh`) só aparece com o ambiente
instalado. Escreve 24% mais que o DeepL e acerta gênero no nível da Apple, não
no do DeepL. Custa 0,18× o tempo do vídeo.

**Retraduzir** refaz só a tradução, com o tradutor escolhido agora, sem ouvir o
áudio de novo — e dá o que gerar de novo não dá: o mesmo corte e os mesmos
locutores. O cabeçalho da lista diz os motores que rodaram (`Apple → DeepL
(site)`). O que está na tela não sai enquanto a nova tradução é feita, nem se
ela for cancelada. Legenda aberta de um `.srt` não dá para retraduzir: o arquivo
não traz o texto original.

O custo da Apple é **por string**: acima de dez por requisição o número de idas
não muda nada, e o mesmo texto picado custa mais — 40 falas inteiras levam
11,7 s, e os mesmos 1,7 mil caracteres em 204 pedaços levam 27,1 s. Por isso
identificar quem fala, que divide legendas, custa tempo de tradução.

Modelos locais de tradução (Qwen3-4B e 8B via MLX, NLLB-200, MADLAD-400) e o
iTranslate foram testados e removidos — erravam gênero, moeda, nome próprio, ou
resumiam a fala. Os detalhes estão no `CLAUDE.md`.

## Construir

Não precisa de Xcode; Command Line Tools bastam.

```bash
swift build -c release
Scripts/bundle.sh TradutorApp "Tradutor" Resources/app-Info.plist release
Scripts/bundle.sh tradutor-probe "Tradutor Probe" Resources/probe-app-Info.plist release
open build/Tradutor.app
```

Na primeira execução o app pede a permissão e baixa o Whisper turbo e o Parakeet
v3 (~1,7 GB) para `~/Library/Application Support/Tradutor/models/`. Identificar
quem fala acrescenta 256 MB na mesma pasta. Os modelos ficam fora do `.app` de
propósito: gigabytes dentro do pacote tornariam a assinatura lenta e a
distribuição impraticável. Depois do primeiro download, carregar não usa rede.

Carregar o Parakeet leva ~13 s, então começa na abertura do app; parar a
tradução não descarrega nada, e trocar entre idiomas do mesmo modelo não
recarrega. O ponto verde no painel diz quando está tudo quente.

## Verificar

Não há `swift test` — as Command Line Tools não trazem `XCTest`. As verificações
vivem dentro dos binários.

```bash
./.build/release/tradutor-probe selftest      # captura, ring buffer, VAD
./.build/release/tradutor-verify prefixo      # confirmação de prefixo estável
./.build/release/tradutor-verify frases       # corte em frases, sobreposição
./.build/release/tradutor-verify quebra       # quebra de linha e travessão
./.build/release/tradutor-verify tempos       # tempos, limites, lote que falha
./.build/release/tradutor-verify formatos     # arquivo sem extensão
./.build/release/tradutor-verify legendas     # leitura de .srt
./.build/release/tradutor-verify faixas       # vídeo com duas faixas
./.build/release/tradutor-verify modelos      # trocar de idioma não recarrega
./.build/release/tradutor-verify lotes        # tamanho de lote de tradução
./.build/release/tradutor-verify motores      # limiares e separação dos motores
./.build/release/tradutor-verify locutores    # atribuição de quem fala
./.build/release/tradutor-verify deepl        # blocos, link, leitura atrasada
./.build/release/tradutor-verify webapi       # Google: repartição, código, escape
./.build/release/tradutor-verify vivo <audio> # o que o VAD do tempo real deixa passar
```

A lista completa, com os que precisam de áudio, está no `CLAUDE.md`. E três
testes que exercitam o app inteiro sem ninguém clicar:

```bash
open build/Tradutor.app --args --selftest-live ja pt              # → /tmp/tradutor-live.txt
open build/Tradutor.app --args --selftest-studio video.mp4 ja pt  # → /tmp/tradutor-studio.txt
open build/Tradutor.app --args --selftest-job video.mp4 ja pt     # → /tmp/tradutor-job.txt
```

O da janela faz 79 verificações e cobre gerar, navegar, exportar e retraduzir.
`--motor <nome>` troca o reconhecimento, `--tradutor <nome>` troca quem traduz,
`--locutores --cores --modelo <clustering|sortformer>` exercitam quem fala, e
`--retraduzir <motor>` troca de tradutor depois de gerar.

## Permissão

O process tap depende da permissão de **Gravação de Tela e Áudio do Sistema**.
Negada, ela não devolve erro: o tap abre, o callback dispara na cadência certa,
e todos os quadros vêm zerados. Se as legendas nunca aparecerem mas o app
parecer funcionar, é isso.

Um binário solto no terminal não consegue pedir essa permissão — ele herda a
identidade do processo pai. Só o `.app` assinado consegue. E **recompilar pode
derrubar a permissão**, porque a assinatura ad-hoc muda a cada build: remova o
Tradutor das duas listas com − e adicione de novo.

```bash
open "build/Tradutor Probe.app"                    # a captura funciona?
open "build/Tradutor Probe.app" --args isolamento  # a seleção é respeitada?
open "build/Tradutor Probe.app" --args geral       # o tap global funciona?
```

## Escolha do aplicativo

A unidade é o **aplicativo**, não o processo: o Chrome não toca áudio em
`Google Chrome`, e sim em `com.google.Chrome.helper`. Escolher o processo
principal produz silêncio absoluto, sem erro nenhum. Por isso os processos são
agrupados pelo bundle ID do dono e o tap recebe todos de uma vez.

Há a opção explícita **Todo o áudio do sistema** — explícita de propósito: antes
o app pegava calado o primeiro processo com som quando nada era escolhido.

## Licenças

Tudo permissivo, uso comercial incluído.

| Componente | Licença |
|---|---|
| WhisperKit / Whisper | MIT |
| FluidAudio | Apache-2.0 |
| Parakeet TDT v3 | CC-BY-4.0 |

## Estrutura

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
arriscada e precisa compilar e rodar em segundos para ser depurada sozinha.
