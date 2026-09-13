# Tradutor Instantâneo

App macOS que faz duas coisas com áudio que já está no seu Mac:

- **legenda traduzida em tempo real** por cima de qualquer aplicativo que esteja
  tocando som;
- **arquivo `.srt`** a partir de um vídeo, com uma janela para assistir e
  revisar antes de exportar.

Tudo roda local: nenhuma chamada de API, nenhuma chave, nenhum áudio saindo da
máquina. Requer Apple Silicon e macOS 15+ (o reconhecimento da Apple pede
macOS 26). Medido num MacBook Air M5 de 16 GB.

## Tempo real

Você escolhe o aplicativo que está tocando som, o idioma dele e o idioma de
destino. Um painel flutuante aparece com três zonas:

| Zona | Conteúdo |
|---|---|
| Amarela | traduções anteriores, esmaecendo — só ela rola |
| Azul | a tradução mais recente |
| Vermelha | o que está sendo captado agora, **sem traduzir** |

A zona vermelha é o que faz o resto funcionar. O texto parcial do reconhecedor
muda a cada instante; traduzir esse parcial faria a legenda piscar. Então o
parcial aparece cru, e só o trecho já fechado atravessa a tradução — uma vez
escrito, nunca muda.

O painel tem tamanho fixo, escolhido arrastando as bordas e lembrado entre
execuções; se ele sumir da tela, *Restaurar tamanho do painel* resolve.
Atalho global `⌥⌘T` liga e desliga.

### Por que o áudio não é cortado em pedaços

Cortar áudio parte palavras ao meio e nenhuma metade sobrevive: "reported" saía
como "Reaper's" no fim de um bloco e "ported" no começo do seguinte. Cortar no
ponto de menor energia ajudou, não resolveu.

Então o trecho não é cortado: é transcrito inteiro, repetidamente, e vai para a
tela o prefixo em que duas passadas consecutivas concordam
(*LocalAgreement-2*, a política do `whisper-streaming`). O que ainda oscila fica
na zona vermelha, onde mudar é esperado.

O detector de voz usa dois limiares: abrir um trecho exige energia bem acima do
ruído, continuar um já aberto exige bem menos. Com um limiar só, a voz que baixa
no fim da frase fechava o trecho no meio da fala.

## Legendas de vídeo

Dois caminhos, mesma geração:

- **Assistir com legenda…** abre a janela de legendas: escolher o vídeo, gerar,
  assistir com a legenda no ar, navegar de fala em fala e exportar o `.srt`.
- **Só gerar o .srt de um vídeo…** gera e grava o arquivo ao lado do vídeo, com
  o idioma no nome (`filme.pt.srt`) — a convenção pela qual os players acham a
  legenda sozinhos.

Na janela: clicar numa legenda leva o vídeo ao instante em que ela é falada
(tolerância zero, senão o player pula para o quadro-chave mais próximo); a
legenda no ar fica destacada e a lista rola sozinha; um par de controles anda no
tempo (±10 s) e outro anda de fala em fala; a linha do tempo marca onde há
diálogo; velocidade de 0,75× a 1,5×; espaço reproduz, `←`/`→` andam 5 s,
`⌘←`/`⌘→` andam de legenda em legenda. **Carregar .srt** abre uma legenda
pronta — o leitor aceita CRLF, bloco sem número, ponto no lugar da vírgula,
`<i>` e arquivos em Latin-1.

As legendas aparecem conforme saem, lote a lote. Regerar limpa o que havia
antes. Cancelar descarta o resultado e impede que qualquer etapa seguinte
comece — o reconhecimento é uma chamada única e longa, que não dá para matar no
meio. **Retraduzir** refaz só a tradução, com outro tradutor, sem ouvir o áudio
de novo — ver "Retraduzir sem reconhecer de novo".

### Como a legenda é montada

```
vídeo ──▶ áudio 16 kHz ──▶ quem fala, quando pedido (fronteiras de voz)
                       ──▶ reconhecimento com marcação de tempo
      ──▶ agrupa em frases (150 chars, pausa > 0,8 s, teto 7 s)
      ──▶ glossário substitui termos no original
      ──▶ traduz em lotes (40 na Apple e no DeepL, 20 no Hunyuan)
      ──▶ reparte em legendas de 2 linhas × 42 chars
      ──▶ .srt
```

Cada legenda entra 0,25 s antes da fala — o reconhecedor marca o início entre
0,15 s e 0,8 s tarde, e antecipar é prática corrente de legendagem. O recuo
nunca invade a legenda anterior. Nenhuma legenda começa depois do fim do vídeo
nem fica mais de 7 s na tela: o vídeo de 18 min produziu uma começando aos 18:04
num vídeo de 18:01, durando 20 s.

O Whisper alucina no silêncio — em japonês, ご視聴ありがとうございました
aparece sozinha no meio do vídeo. As métricas do próprio modelo
(`noSpeechProb`, `avgLogprob`, razão de compressão) não a pegam: para ele é uma
predição confiante. Só o texto denuncia, e há uma lista dessas frases.

### Arquivos sem extensão no nome

O seletor não filtra por tipo: um mp4 chamado só `gravacao` seria recusado por
um detalhe que não diz nada sobre o conteúdo. Quem julga são os bytes — se o
arquivo não abrir direto, ele é reapresentado ao sistema por um link temporário
`.mp4`, porque o AVFoundation escolhe o demuxer pela extensão. Se ainda assim
não abrir, o erro diz qual formato é (lendo a assinatura do container) e quais
são aceitos.

## Reconhecimento

O seletor oferece cinco famílias; o idioma de origem limita o que aparece.

| Motor | Cobertura | Onde vive |
|---|---|---|
| Apple (padrão) | de, en, es, fr, it, ja, ko, pt, zh | modelos do sistema, instalados pelo + ao lado do idioma |
| Parakeet TDT v3 | os idiomas europeus, a ~120× tempo real | pasta do app |
| Whisper turbo | todos os idiomas do app | pasta do app |
| Qwen3-ASR 0.6B | 13 idiomas, melhor em japonês (sem inglês) | ambiente próprio, só nos modos de vídeo |
| Qwen3-ASR 1.7B | o mesmo, mais preciso e 4× mais lento | idem, com `--grande` no setup |

O seletor de idioma mostra só o que o reconhecimento escolhido cobre.

O Qwen3-ASR é o único que não roda dentro do app: não há port CoreML dele, só
MLX com Python. Instala-se à parte, e até então não aparece no seletor:

```bash
Scripts/qwen-setup.sh            # cria o ambiente e baixa o 0.6B (2,2 GB)
Scripts/qwen-setup.sh --grande   # baixa também o 1.7B (3,4 GB a mais)
Scripts/qwen-setup.sh --remove   # apaga tudo
```

A lista de termos passa a valer também para o reconhecimento com esses motores
e com o Whisper: os termos vão no prompt do modelo, e nome próprio que saía
errado passa a sair certo.

Em 96 s de japonês limpo ele devolve 281 caracteres contra 260 do Whisper e
248 da Apple — mas o que muda a legenda é o formato: **uma fala por bloco, com
pontuação**, em vez de pergunta e resposta na mesma linha. Custa 17× tempo real
contra 172× da Apple, e por isso vale **só para vídeos**; no tempo real o app
volta sozinho para a Apple.

### Quem fala

A opção *Identificar quem fala*, nos modos de vídeo, roda um segundo modelo
sobre o mesmo áudio (o diarizador do FluidAudio) e usa o resultado para
**separar as legendas por locutor** — a troca de voz passa a ser fronteira de
legenda, e no `.srt` ela ganha travessão, como é a convenção para diálogo.

Há dois modelos à escolha: **Sortformer** (padrão) é um modelo só, ponta a
ponta — no vídeo de 9 minutos marca 101 das 104 legendas em 1,4 s, e repete
quase igual entre execuções; **Agrupamento de vozes** segmenta, extrai a voz e
agrupa em execução, marca 114 de 123 em 3,6 s e oscila mais. Nenhum dos dois é
determinístico: medido, o Sortformer deu 3 vozes numa execução e 4 na outra no
mesmo arquivo.

E há **uma cor por locutor**, opcional: branco, amarelo, ciano e verde, as
cores da legenda oculta de TV. Vale na janela e, se você quiser, no `.srt`
exportado, onde entra como `<font color="#…">` — entendido pelo VLC, mpv e a
maioria dos players.

Medição única, 90 s de japonês limpo: Apple leva 5,2 s do vídeo ao `.srt`,
Whisper turbo 14 s. Qualidade em áudio difícil não foi medida.

O Whisper roda com `firstTokenLogProbThreshold` em −3,0, não no −1,5 padrão do
WhisperKit. Abaixo desse limiar ele re-decodifica a janela com temperatura
crescente, e temperatura acima de zero sorteia o token: o mesmo arquivo dava de
9 a 34 trechos entre execuções, e uma em cada três perdia os primeiros 32 s do
diálogo. Com −3,0 nenhuma retentativa dispara, e a cobertura desse vídeo subiu
de 44% para 70%.

Reconhecedores de RNNT marcam o tempo da **emissão**, não o da palavra — as palavras
saíam ~0,4 s depois de soar e a pontuação só era emitida na frase seguinte. O
tempo da pontuação é ignorado e cada trecho é encostado na energia do áudio;
depois disso, início 0,00 s e fim +0,03 s contra a régua.

## Tradução

Três motores nos modos de vídeo; ao vivo é sempre a Apple, porque um trecho
re-reconhecido a cada 0,6 s não comporta carga de página nem modelo de 7B.

| Motor | Onde roda | Por quê |
|---|---|---|
| **Apple** (padrão) | local | instantâneo, nada sai da máquina |
| **DeepL (site)** | rede | ganha da Apple em japonês — gênero, nome próprio, registro |
| **Hunyuan-MT 7B** | local, fora do processo | entende melhor que a Apple sem mandar texto para fora |

O padrão é a Apple: o framework `Translation` do sistema, local e sem custo, em
lotes de 40 legendas por requisição.

O **DeepL** usa o site gratuito, numa janela visível — o texto sai da máquina, e
uso automatizado contrária os termos de uso deles. Bloco que o site recusa cai
para a Apple, e a janela diz quantos foram. A janela fecha sozinha quando a
tradução termina.

O **Hunyuan-MT** (4,5 GB, `Scripts/hunyuan-setup.sh`) só aparece no seletor com
o ambiente instalado. Escreve 24% mais que o DeepL, o que vira mais legendas, e
acerta gênero no nível da Apple — não no do DeepL. Custa 0,18× o tempo do vídeo.

### Retraduzir sem reconhecer de novo

O botão de retraduzir, na janela de legendas, refaz **só** a tradução com o
tradutor escolhido agora. O cabeçalho da lista diz o que produziu o que está na
tela — `Apple → DeepL (site)`, os motores que rodaram.

O resultado é o mesmo de gerar tudo de novo: entre o reconhecimento e a
tradução não há mais nada no caminho. E dá uma coisa que gerar de novo não dá —
o mesmo corte e os mesmos locutores, porque o áudio não é ouvido outra vez.
O que está na tela não sai enquanto a tradução nova é feita, nem se ela for
cancelada.

Legenda aberta de um `.srt` não dá para retraduzir: o arquivo não traz o texto
original.

Havia 10 legendas de sobreposição entre lotes, para nenhuma ficar na borda sem
vizinhança. Saiu: medido com o caso plantado — uma pessoa apresentada com
gênero antes da borda e referida depois dela —, reenviar as 10 anteriores **não
muda nada**, e o tradutor erra o gênero das duas formas. Custava 15% do tempo.

O custo dele é **por string**: acima de dez por requisição, o número de idas e
voltas não muda nada, e o mesmo texto picado em mais pedaços custa mais —
medido, 40 falas inteiras levam 11,7 s e os mesmos 1,7 mil caracteres em 204
pedaços levam 27,1 s. Por isso legenda mais curta sai mais caro, e identificar
quem fala (que divide legendas) custa tempo de tradução.

Custo total, com reconhecimento: **0,07× a 0,12× o tempo do vídeo**, conforme a
legenda fique mais ou menos picada.

Modelos locais de tradução (Qwen3-4B e 8B via MLX, NLLB-200, MADLAD-400) foram
testados e removidos: erravam gênero, moeda ou nome próprio, e o 8B custava
1,02× o tempo do vídeo. Os detalhes das comparações estão no `CLAUDE.md`.

### Lista de termos

Os erros que sobram são substantivos concretos, não gramática. O glossário
substitui o termo **no original, antes de traduzir** — medido, uma palavra
estrangeira no meio do japonês atravessa intacta e ainda dá ao tradutor uma
palavra com que concordar.

Com o Whisper e o Qwen a lista **também** vai para o reconhecedor: o que nasce
errado no reconhecimento passou a ter conserto. Medido — com `上村玲香` na
lista, `神村レイカです` virou `上村レイカです`. Nos outros motores o limite
continua.

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
quem fala acrescenta o Sortformer (243 MB) e o diarizador de agrupamento
(13 MB), na mesma pasta. Os modelos ficam fora do `.app` de propósito:
gigabytes dentro do pacote tornariam a assinatura lenta e a distribuição
impraticável. Depois do primeiro download, carregar não usa rede.

Os dois motores que rodam fora do processo têm pasta própria, criada pelo script
de instalação e só então oferecida no seletor: `qwen/` (2,2 GB, reconhecimento)
e `hunyuan/` (4,5 GB, tradução).

Carregar o Parakeet leva ~13 s, então o carregamento começa na abertura do app;
parar a tradução não descarrega nada, e trocar entre os idiomas que o mesmo
modelo cobre não recarrega. O ponto verde no painel diz quando está tudo quente.

## Verificar

Não há `swift test` — as Command Line Tools não trazem `XCTest`. As verificações
vivem dentro dos binários.

```bash
./.build/release/tradutor-probe selftest    # captura, ring buffer, VAD, agrupamento
./.build/release/tradutor-verify prefixo    # confirmação de prefixo estável
./.build/release/tradutor-verify frases     # corte em frases, sobreposição, tokens
./.build/release/tradutor-verify quebra     # quebra de linha
./.build/release/tradutor-verify tempos     # tempos e limites de legenda
./.build/release/tradutor-verify formatos   # arquivo sem extensão, formato recusado
./.build/release/tradutor-verify legendas   # leitura de .srt
./.build/release/tradutor-verify glossario  # lista de termos
./.build/release/tradutor-verify modelos    # trocar de idioma não pode recarregar
./.build/release/tradutor-verify lotes      # mede tamanho de lote de tradução
./.build/release/tradutor-verify motores   # limiar do Whisper, separação dos motores
./.build/release/tradutor-verify locutores # atribuição de quem fala, sem modelo
./.build/release/tradutor-verify deepl     # blocos, link, leitura atrasada do site
./.build/release/tradutor-verify vivo <audio>  # o que o VAD do tempo real deixa passar
./.build/release/tradutor-verify srt <video> [origem] [destino]
./.build/release/tradutor-verify alinhamento <audio> [motor] [idioma]
```

`tempos` inclui lote de tradução que falha; `quebra` inclui o travessão de
troca de locutor. A lista completa, com os que precisam de áudio, está no
`CLAUDE.md`.

E três testes que exercitam o app inteiro sem ninguém clicar:

```bash
open build/Tradutor.app --args --selftest-live ja pt              # → /tmp/tradutor-live.txt
open build/Tradutor.app --args --selftest-studio video.mp4 ja pt  # → /tmp/tradutor-studio.txt, /tmp/studio.png
open build/Tradutor.app --args --selftest-job video.mp4 ja pt     # → /tmp/tradutor-job.txt
```

O da janela faz 78 verificações e cobre gerar, navegar, exportar e retraduzir.
`--motor <nome>` troca o reconhecimento, `--tradutor <nome>` troca quem traduz,
`--locutores --cores --modelo <clustering|sortformer>` exercitam quem fala, e
`--retraduzir <motor>` troca de tradutor depois de gerar.

## Permissão

O process tap é controlado pela permissão de **Gravação de Tela e Áudio do
Sistema**. Negada, ela não devolve erro: o tap abre, o callback dispara na
cadência certa, e todos os quadros vêm zerados. Se as legendas nunca aparecerem
mas o app parecer funcionar, é isso.

Um binário solto no terminal não consegue pedir essa permissão — ele herda a
identidade do processo pai. Só o `.app` assinado consegue.

**Recompilar pode derrubar a permissão**, porque a assinatura ad-hoc muda a cada
build. Se depois de um `swift build` a captura voltar a dar silêncio, remova o
Tradutor das duas listas com − e adicione de novo.

`Tradutor Probe.app` responde sem envolver o app principal, gravando o relatório
numa janela e em `/tmp`:

```bash
open "build/Tradutor Probe.app"                    # a captura funciona?
open "build/Tradutor Probe.app" --args isolamento  # a seleção é respeitada?
open "build/Tradutor Probe.app" --args geral       # o tap global funciona?
```

## Escolha do aplicativo

A unidade escolhida é o **aplicativo**, não o processo: o Chrome não toca áudio
em `Google Chrome`, e sim em `com.google.Chrome.helper`. Escolher o processo
principal produz silêncio absoluto, sem erro nenhum. Por isso os processos são
agrupados pelo bundle ID do dono e o tap recebe todos de uma vez — o mesmo vale
para qualquer app com renderizador separado.

Há a opção explícita **Todo o áudio do sistema**. Explícita de propósito: antes
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
