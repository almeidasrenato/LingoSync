# Plano: ler a legenda queimada na imagem

Estado: **implementado em 22/09/2026**, na branch `legenda-na-imagem` (sem
commit). Ver "Resultado da implementação" logo abaixo; o resto do arquivo é o
plano como foi escrito, mantido como registro. O que o plano chamava de
hipótese foi medido pelo caminho do app, e o `CLAUDE.md` ganhou a seção
"Legenda desenhada no vídeo".

## Resultado da implementação

Código: `Sources/TradutorCore/BurnedSubtitle.swift` (leitor, filtros,
montagem, instante), a ação e a fonte do texto em `SubtitleStudioModel`, o
`Fala | Imagem` e o `ImageLanguagePicker` na janela, `tradutor-verify imagem`
e `--selftest-imagem`. Nada novo no `Package.swift`.

```
                              legendas   texto literal   quadro exato     velocidade
vídeo 2, inglês, 96 s             27        27 de 27     54 de 54 pontas     16×
9 min, japonês, 540 s             81        19 de 20    159 de 162            9×
```

Quatro mudanças sobre o plano, cada uma forçada por medição:

1. **Linhas visuais.** `え？　同じです。` vem do Vision em duas caixas; ordenar
   por altura alternava a ordem (`・同じです。え？`) e criava legenda falsa, e a
   metade `はい。` de `はい。　ありがとうございます。` saía pelo filtro de centro.
   Caixas na mesma altura e do mesmo tamanho viram uma linha.
2. **Centro 0,05 por linha visual, tirando a ponta mais afastada**, não 0,1 por
   caixa: a placa de cardápio aparece em 0,27–0,30 conforme o enquadramento, e
   na altura da fala entra na linha visual dela.
3. **O instante pelos pixels de letra que a outra amostra não repete**, não
   pela caixa inteira da sonda. A caixa inteira deixava o corte de cena mandar
   (5 de 54 pontas 3 quadros atrasadas no vídeo 2); a letra inteira deixava a
   fala nova, no mesmo lugar, segurar a velha (±6 e 7 quadros no de 9 min).
4. **Faixa 0,76–1,0**: pega a caixa escura do vídeo de 9 min até a borda; a
   marca d'água do vídeo 2 que entra junto sai pelo centro.

Critérios de "Como saber que acabou":

| # | Critério | Resultado |
|---|---|---|
| 1 | build sem erro nem aviso novo | ok |
| 2 | `tradutor-verify imagem` sem vídeo | ok, 39 verificações |
| 3 | vídeo 2: 27 literais, sem marca d'água | ok, 27 de 27 |
| 4 | 9 min: só a linha japonesa nas 20 | 19 de 20 — `れいか先輩・・・。` sai `れいか先輩・・` |
| 5 | instante: ≥ 90% exato, nenhum a mais de 1 quadro fora de fade | 100% e 98%; 1 ponta de 216 a 2 quadros (caixa semitransparente, não fade) |
| 6 | 9 min ≥ 7× | 9,2× no gate, 9,3× pela janela |
| 7 | janela: `Fala \| Imagem` à vista, idioma próprio, setas | ok (`--selftest-imagem` 13/13 no vídeo 2; `/tmp/tradutor-imagem.png`) |
| 8 | traduzir não move tempo; cabeçalho `Imagem` | ok |
| 9 | zero legendas é erro; nenhum passo de áudio | ok |
| 10 | nada no `Package.swift`; teste não escreve em `Videos Exemplo/` | ok — os gabaritos foram escritos à mão |
| 11 | `CLAUDE.md` só com número medido | ok |

Regressão: os 16 gates rápidos do `tradutor-verify`, `--selftest-srt` (27),
`--selftest-janelas` (8), `--selftest-layout` e `--selftest-studio` pela fala
(93 ok) passaram depois da mudança.

Reproduzir pelo app, em vez da sonda:

```bash
swift build -c release --product tradutor-verify
cd "Videos Exemplo"
../.build/release/tradutor-verify imagem
../.build/release/tradutor-verify imagem "video exemplo 2 (Conversa mais complexa).mp4" en \
    --gabarito "video exemplo 2 (Conversa mais complexa).legenda-na-imagem.txt" --oraculo
../.build/release/tradutor-verify imagem "video exemplo conversa de pessoas.mp4" ja \
    --gabarito "video exemplo conversa de pessoas.legenda-na-imagem.txt" --oraculo
```

---

Código de referência: árvore em `57e4c82`. Se andou, confira os símbolos antes
de editar — não o número da linha.

Leia antes: `CLAUDE.md` (o registro de medição; não desfaça decisão de lá sem
medir de novo) e este arquivo inteiro. O modo atual mora em
`Sources/TradutorApp/SubtitleStudioModel.swift` e `SubtitleStudioView.swift`;
a legenda pronta é `Cue` em `Sources/TradutorCore/SubtitleFile.swift`.

---

## O que mudou em relação ao rascunho

O rascunho acertava a moldura — mesma janela, estado de original importado,
tradução só no clique, nenhum motor de fala — e errava o miolo. Medido:

1. **O detector barato não funciona em vídeo real.** O desenho era "diferença
   da faixa em todo quadro; lê uma vez quando ela assenta". No vídeo 2, com a
   legenda parada, a diferença passa de 17,8 em 1% dos quadros (o anime se
   mexe atrás da legenda); nas trocas reais a mediana é 12,1 e 10% ficam
   abaixo de 5,9. A troca é menor que o ruído do fundo: em cena com movimento
   a faixa nunca assenta e a legenda passa sem ser lida. Uma máscara de
   "traço claro com contorno escuro" também falha — o traço preto do anime é
   contorno escuro. **Quem detecta a troca passa a ser o próprio OCR**,
   amostrado a cada 0,25 s. Os pixels só acham o quadro exato.
2. **`32BGRA` custa 3,7×**: ~700 quadros/s contra ~2650 em `420v`. A faixa sai
   do plano de luma.
3. **Uma leitura por legenda não é o mais preciso.** O OCR tremula numa amostra
   isolada (`iS`, `Everyone..`). O texto da legenda passa a ser o **mais
   frequente entre as amostras** — de graça, porque as amostras já existem.
4. **`Videos Exemplo/` tem legenda queimada** — o rascunho dizia que não. São o
   material de teste principal.
5. **O ffmpeg desta máquina não tem `drawtext` nem `subtitles`** (9.0.2 do
   Homebrew, sem libass nem freetype). O passo 2 do rascunho quebrava na
   primeira linha. Vídeo sintético, se for preciso, sai de Swift.
6. **O idioma é o do texto na tela, não o falado.** No vídeo 2 a fala é
   japonesa e a legenda é inglesa. Com a dica errada (`ja`), 249 de 386
   leituras mudam, com erro de verdade (`Yes, lam!`, `stil alive in theret`).
   Hoje a janela herda o idioma falado do painel; neste modo não pode.
7. **O seletor de idioma da janela é filtrado pelo motor de fala**
   (`SourceLanguagePicker(engine:)`) e troca a escolha sozinho. Esconder o
   seletor de motor, como o rascunho propunha, não basta.
8. **A faixa pega marca d'água e placa.** Marca d'água na mesma altura da
   legenda no vídeo 2; placa de cardápio no de 9 minutos. Sem filtro, a faixa
   nunca fica vazia e as legendas não fecham.
9. **Detalhes de código que o rascunho não viu**: `recognitionName` é
   `private(set)` e `retranslate()` refaz o cabeçalho a partir dele; o
   `AVAssetReader` **depende sim** da extensão (`extractAudio` já tenta o
   apelido `.mp4`); o `.srt` importado junta as linhas com `Tokens.join`, não
   guarda a quebra do arquivo.
10. **Interface**: em vez de item novo no menu abrindo a janela "em modo", a
    escolha **Fala | Imagem** visível no cabeçalho da própria janela. Ver
    "Interface".

O rascunho original está em `resultados/rascunho-original-do-grok.md`, só
para consulta. Não siga aquele.

---

## O pedido

Um modo parecido com **Assistir com legenda**, mas o texto vem da legenda
desenhada no vídeo, não do áudio. Cada legenda vira `Cue` no instante em que
aparece e no instante em que some. Traduzir é opcional, com os tradutores que
já existem. Os comandos de vídeo e de andar de legenda em legenda são os
mesmos. Rápido e preciso.

Decidido pelo usuário: **o idioma do texto na tela é escolhido por ele.** Não
há detecção automática.

O que **não** é este modo:

- **Captura de tela de outro aplicativo.** O tempo seria o do relógio da tela,
  não o do arquivo; ← e → não levariam aquele vídeo até a fala; e exigiria
  Gravação de Tela.
- **Reconhecimento de fala.** Nada de `SubtitleFileBuilder.generate`, áudio,
  Whisper, Parakeet, Apple Speech ou Qwen. Sem texto, a falha sobe; não cai no
  áudio calado — é o defeito de "Falhou, falhou".
- **Faixa de legenda em texto dentro do arquivo** (`mov_text`, tx3g). Isso não
  é imagem.

---

## Material de teste — já está no disco

| Vídeo | O que tem |
|---|---|
| `video exemplo 2 (Conversa mais complexa).mp4` | 96,5 s, 1080p, 23,976 q/s. **Fala japonesa, legenda queimada em inglês**, branca com contorno, sobre anime em movimento. Marca d'água `©Eiichiro Oda/Shueisha, Toei Animation` no canto inferior direito, **na altura da legenda**. Tela final `Crunchyroll®` dentro da faixa de 86,8 s até o fim. |
| `video exemplo conversa de pessoas.mp4` | 540 s, 1080p, 29,97 q/s. Faixa escura com **furigana, japonês, romaji e inglês** na mesma legenda. Placa de cardápio escrita à mão no canto inferior esquerdo nos primeiros ~9 s, dentro da faixa. |

Os outros três não servem: dois não têm legenda na imagem, e
`Video perca de fala japones.mp4` é gravação de tela do próprio app.

Leitura só. Gabarito feito à mão vai **ao lado do vídeo**, como os
`*.quem-fala*.txt` — `Videos Exemplo/` está no `.gitignore` porque é obra de
terceiros, e tudo que sai deles também. Teste automático nunca escreve lá.

---

## Medições de viabilidade

22/09/2026, MacBook Air M5, macOS 27. `sonda.swift`; comandos no fim.

```
Vision .accurate      os 18 idiomas do app (e outros). Consultar em tempo de
                      execução: o app roda desde o macOS 15 e a lista lá pode
                      ser menor.
Vision .fast          só en, fr, it, de, es, pt. Sem japonês: não é alternativa.
1ª leitura do Vision  24,4 s, uma vez (compila no cache do processo); na
                      execução seguinte, 0,25 s.

AVAssetReader, 1080p H.264          420v              32BGRA
  vídeo 2 (96,5 s)             2670 q/s · 111×     726 q/s · 30×
  9 min (540 s)                2627 q/s ·  88×     687 q/s · 23×

OCR da faixa, .accurate, vídeo 2, 386 amostras
  região de interesse no quadro colorido     56 ms mediana (faixa vazia ~27 ms)
  faixa recortada em cinza (plano Y)
     1 em voo                                54–65 ms
     2 em voo                                23–26 ms
     4 em voo                                12–13 ms   texto idêntico ao de 1
  9 min, faixa com 3–4 linhas, 4 em voo      27 ms
```

**Leitura inteira pela sonda** (decodificar, recortar, OCR a cada ~0,25 s com
4 em voo; sem refino nem montagem): vídeo 2 em 5,7 s (17×), 9 minutos em 69 s
(7,8×). Um episódio de 24 minutos daria 1,5 a 3 minutos — extrapolação, não
medida.

Texto do vídeo 2, depois do voto entre as amostras de cada legenda:

```
                                          legendas certas   erro sistemático
região de interesse, quadro colorido          26 de 27      "I'm" lido "Im" 9 de 9
faixa recortada em cinza                      27 de 27      nenhum
usesLanguageCorrection desligado              igual ao ligado (26 de 27 quadros)
dica errada (ja-JP em texto inglês)           249 de 386 amostras mudam
```

8 das 27 foram conferidas contra o quadro; o gabarito do passo 2 fecha a
conta.

Japonês, 9 minutos, 4 quadros: a linha japonesa sai literal nos quatro
(`上村れいかです。`, `今、いそがしいの。`…). O Vision devolve **junto** o
romaji e o inglês, e uma vez o furigana como linha miúda e errada (`いよ` por
`いま`, altura 0,09 contra 0,31 da linha principal). A placa de cardápio vira
lixo (`柒￥80 | 滿日00`) nas ~40 amostras em que aparece.

Faixa larga (0,76–1,0) no vídeo 2: a marca d'água entra em quase toda amostra
e gruda na fala (`clear all the ships from the shore! | ©Eiichiro Oda/…`).
Centro horizontal da marca 0,88; das falas, 0,48 a 0,51 nos dois vídeos.
Altura da marca 0,4 da linha da fala.

O detector do rascunho, vídeo 2, faixa 0,78–0,96, OCR a 4 Hz como referência:

```
                               legenda parada        faixa vazia     trocas reais
diferença média da faixa       p50 0,17 · p99 17,8   p99 74,8        mín 1,7 · p10 5,9 · mediana 12,1
células "claro com contorno"   mediana 382           mediana 119
troca de células               p99 291                               mediana 302
```

Refino ingênuo do instante (OCR a cada 12 quadros; quadro da troca = primeiro
em que mais da metade dos pixels que diferem entre as duas amostras, dentro
das caixas do OCR, já está mais perto da amostra nova), contra o oráculo —
OCR em todo quadro da janela da troca, 297 leituras:

```
46 trocas   quadro exato 30 (65%) · a 1 quadro 2 · a 2 quadros 3 · a 3 ou mais 11
```

Os 11 têm explicação: saída com fade (o OCR deixa de ler uns 3 quadros antes
do meio do fade, que é onde o pixel vira); legenda → vazio → legenda dentro de
um único intervalo (o refino achou o fim da primeira, o oráculo o começo da
segunda); e dissolução entre duas legendas.

Pular o OCR quando a faixa não mudou desde a amostra anterior: 25 a 29% das
janelas de 0,25 s no vídeo 2.

---

## O desenho

```
arquivo ──▶ AVAssetReader, 420v, em ordem, sem seek
             ├─ todo quadro: copia a faixa do plano Y para um anel
             │  (os quadros desde a última amostra) e solta o buffer
             └─ a cada 0,25 s de PTS: a faixa em cinza vai para o Vision
                (até 4 leituras em voo, resultado recolocado na ordem do PTS)
                  └─▶ amostra: linhas com texto e caixa
                        └─▶ filtros de linha ─▶ texto da amostra
                              └─▶ montador: mesma legenda ou outra?
                                    └─▶ troca: refino no anel ─▶ quadro exato
                                          └─▶ Cue(start, end, source)
                                                └─▶ janela; traduzir no clique
```

### Por que o OCR é o detector

Porque ele separa o que a diferença de pixels não separa (tabela acima), e
porque agora cabe no tempo: com 4 leituras em voo, cada amostra custa 12 a
27 ms. OCR em todo quadro seria 6× isso sem ganho — fica só como oráculo do
gate.

### Amostragem

- **Em tempo, não em quadros: a cada 0,25 s de PTS.** Hipótese: legenda mais
  curta que isso pode passar entre duas amostras. O gate precisa de uma
  legenda curta (≤ 0,4 s); se nenhum vídeo real tiver, é o caso que justifica
  o sintético.
- **A faixa vai ao Vision como `CGImage` cinza feita do plano Y recortado**
  (sonda: `paralelo`), não como região de interesse no quadro colorido. Acerta
  mais (27 de 27 contra 26 de 27) e o buffer do decodificador é solto na hora.
- **Até 4 leituras em voo**, com o decodificador esperando vaga antes de
  mandar a próxima — senão ele corre na frente e o anel cresce sem limite.
- Pular a leitura com a faixa parada fica **só se a meta de velocidade pedir**.
  O critério tem de ser "nenhum pixel mudou além do ruído" (contagem de pixels
  com diferença grande), nunca a média da faixa: `Clank.` entrando mudou a
  média em só 1,7.

### Filtros de linha

Cada um nasceu de um caso medido, e só estes:

| Filtro | Caso |
|---|---|
| Linha fora do centro horizontal sai. Hipótese de limiar: centro a mais de 0,1 de 0,5 | Marca d'água (0,88) no vídeo 2; placa no canto esquerdo no de 9 minutos. Falas entre 0,48 e 0,51 |
| Linha cuja maioria das letras não é da escrita do idioma escolhido sai | Com japonês escolhido, o de 9 minutos fica só com a linha japonesa; com inglês, sai a japonesa. Romaji e inglês são ambos latinos e **não se separam** por escrita: aí decide a faixa |
| Depois do filtro de escrita, linha com menos da metade da altura da maior sai. Hipótese de limiar | Furigana: 0,09 contra 0,31. As linhas latinas do de 9 minutos ficam entre 0,55 e 0,87 da maior |

As linhas que sobram vão de cima para baixo e são juntadas com `Tokens.join`,
como o `SRTParser` faz com o `.srt` importado — espaço no latino, nada no CJK.
A janela requebra pela largura do idioma. Não guardar o `\n` do leitor.

Tela final e logotipo centrados dentro da faixa (`Crunchyroll®`) viram
legenda: é texto na tela. Documentar, não filtrar.

### Mesma legenda ou outra

- **Comparação tolerante**: caixa baixa, sem espaço nem pontuação, distância de
  edição normalizada ≤ 0,25 é a mesma legenda (sonda: `same()` em `refine`).
- **Amostra isolada entre duas iguais é tremor**: `A A' A` é uma legenda só,
  mesmo que `A'` passe do limiar (`me!` contra `mel` dá 0,33).
- **O texto da legenda é o mais frequente entre as amostras dela**, cru.
  Empate: o da primeira amostra.
- **O mesmo texto depois de um vazio é outra legenda.** Sumiu e voltou: dois
  blocos. Fundir atravessaria o buraco e mentiria o tempo.
- Legenda vista numa amostra só, entre vazios ou entre legendas diferentes,
  fica: pode ser fala curta de verdade.

### O instante

Definição travada:

- **`start`** = PTS do primeiro quadro em que a legenda já está na tela.
- **`end`** = PTS do primeiro quadro em que ela já não está. **Exclusivo** —
  o mesmo contrato de `SubtitleStudioModel.index(at:)`, onde
  `seconds >= cue.end` já é a próxima.
- **Fade**: o quadro da troca é o do meio do fade, onde o pixel vira. O OCR
  deixa de ler antes disso e não serve de definição.

Refino: entre a última amostra de A e a primeira depois dela, nos quadros do
anel, dentro das caixas do OCR das duas amostras, só nos pixels que diferem
bastante entre elas (a sonda usou diferença de luma > 40): o quadro da troca é
o primeiro em que mais da metade desses pixels já está mais perto da amostra
nova.

**A → vazio → B dentro de um intervalo** tem dois instantes. Refinar o fim de
A e o começo de B separados, cada um com as próprias caixas — foi o erro de
−7 quadros da sonda.

Com 4 leituras em voo, os quadros de um intervalo ficam no anel até o
resultado das duas amostras que o cercam chegar.

### O leitor

`RecognizeTextRequest` — o Vision em Swift, macOS 15+, assíncrono, tipo valor.
É o que a sonda usou.

```text
recognitionLevel        .accurate
recognitionLanguages    o idioma do texto escolhido (zh: zh-Hans e zh-Hant;
                        o Vision chama o vietnamita de vi-VT — casar por
                        Locale.Language, não por string)
usesLanguageCorrection  padrão (medido: não muda nada)
customWords             não — a lista de termos saiu de propósito
```

Nenhum pré-processamento além do cinza, que não é tratamento: é o plano Y
como veio. Aumentar contraste, engrossar contorno ou inverter fica desligado
até existir um quadro em que o Vision erra e o tratamento acerta, sem piorar
os outros — o filtro de graves e a subtração espectral já ensinaram isso no
áudio.

Recusados, sem medição nova: Tesseract, PaddleOCR, EasyOCR (outro processo,
centenas de MB, a família de custo do Qwen), VideoSubFinder (ferramenta, GPL),
ffmpeg em tempo de execução, Vision `.fast` (sem CJK), OCR em todo quadro.

### Velocidade

Meta: **≥ 7× o tempo real no vídeo de 9 minutos pelo caminho do app** (a
sonda deu 7,8× sem refino nem montagem, que são contas de pixel em poucos
quadros). Cancelar: `Task.checkCancellation()` a cada quadro — o laço é nosso,
então aqui dá para não repetir o buraco do reconhecimento longo.

Memória: a faixa de 1080p tem ~370 KB em luma; 0,25 s a 60 q/s são 15
quadros, ~6 MB por intervalo em espera.

---

## O que já existe na janela

Conferido no código em `57e4c82`.

| Já existe | Onde | Neste modo |
|---|---|---|
| `Cue` | `SubtitleFile.swift` | Texto lido em `source`; `translated` vazio; `speaker` nil. |
| Player, lista, divisor; atalhos espaço, ← →, ⌘← ⌘→, `m`, `v`, ↑ ↓, − = | `SubtitleStudioView` | Herdados. Nenhum atalho novo. |
| `jump(to:)` (busca `start + 0,02`), `jumpToNextCue`, `jumpToPreviousCue` | `SubtitleStudioModel` | Funcionam com `cues` preenchido. |
| Original importado | `loadSubtitles(from:as: .original)` | O modelo a copiar: `SubtitleFileBuilder(draft:)`, `originalWasImported = true`, não traduz sozinho. |
| `retranslate()` | `SubtitleStudioModel` | Não tem parâmetro: passa `preserveCueTiming: self.originalWasImported`. A leitura tem de deixar `originalWasImported = true` — renomear para o que o campo quer dizer, tempo preservado, é bem-vindo. Sem isso `enforceLineLimit` reparte e o tempo da imagem se perde. |
| `export(to:track:)` | `SubtitleStudioModel` | Com `originalWasImported`, o original sai sem `enforceLineLimit`: os blocos da imagem intactos. |
| Cabeçalho (`origin`) | `retranslate()` refaz com `builder.recognitionName ?? (loadedFromFile ? "SRT" : "")` | `recognitionName` é `private(set)` e `init(draft:)` não o recebe. Sem mudar isso, depois de traduzir o cabeçalho diz `SRT → …` ou ` → …`. O builder nasce com `"Imagem"`. `loadedFromFile` fica falso. |
| `displayText` / `displayLines` | `SubtitleStudioModel` | Sem tradução mostram `source` na largura do idioma do texto. |
| Idioma do conteúdo | `originalLanguage`, `subtitleLanguage(for:)`, `suggestedSRTName` | `originalLanguage` = idioma do texto na imagem. O vídeo 2 exporta `….en.srt`, não `.ja`. |
| `SourceLanguagePicker(engine:)` | `LanguageControls.swift` | **Não serve como está**: filtra pelo motor de fala (com Apple, só idiomas com modelo de fala instalado) e troca a seleção sozinho em `.task(id: engine)`. Aqui a lista é a do Vision (`supportedRecognitionLanguages` cruzada com `Language`). |
| Apelido `.mp4` | `playableAlias` (público), `mp4Alias` (privado), em `SubtitleFileBuilder` | O leitor de vídeo precisa do mesmo que `extractAudio` faz: tentar direto, depois pelo apelido. `playableAlias` devolve apelido também para arquivo **sem faixa de áudio** — inofensivo, não quer dizer "não toca". |
| `GenerationStep` | `SubtitleFile.swift` | Fatias fixas; reconhecer ocupa 0,18–0,48. A leitura precisa de passo próprio: "Carregando o leitor" (a primeira vez leva ~24 s) e "Lendo a legenda na imagem — X de Y s". Conferir os `switch` exaustivos, `SubtitleJob` incluído. |
| `SRTParser` | `SubtitleFile.swift` | Junta as linhas do bloco com `Tokens.join`. A leitura junta igual. |
| Tradutores, `IdentityTranslator` | `TranslationEngine` | Todos valem. "Só transcrever" copia `source` para `translated` — é o que já acontece com original importado, e a lista já esconde o duplicado. Sem caso especial. |

---

## Interface

**A mesma janela, com a fonte do texto escolhida no cabeçalho compacto**:
`Fala | Imagem`, segmentado, ao lado do botão principal. Em Imagem o botão
vira **Ler legenda**.

Por que não o item novo no menu que o rascunho propunha:

- O cabeçalho abre compacto desde 18/09; escolha dentro de "Opções" fica
  escondida — é a lição dos controles de locutor.
- O mesmo vídeo pode ser lido pelas duas fontes sem reabrir nada, que é como
  se compara.
- `openStudio` levanta as janelas que existem; um segundo item teria de
  decidir se levanta ou abre, e isso é mais uma regra.

Se o usuário quiser o item no menu mesmo, ele é só um atalho que abre a janela
já em Imagem.

Em Imagem:

- **Somem** o seletor de reconhecimento e o menu de locutores.
- **"Idioma original" vira "Idioma do texto"**, com a lista do Vision e valor
  **próprio deste modo**, guardado à parte — nunca o idioma falado herdado do
  painel. No vídeo 2 o herdado seria japonês, e a dica errada estraga 249 de
  386 leituras.
- **Faixa**: uma só, embaixo, com o filtro de centro. Candidatas 0,78–0,96
  (medida no vídeo 2) e 0,76–1,0 (medida no de 9 minutos, onde a caixa escura
  vai até a borda); o passo 2 escolhe uma medindo os dois vídeos com ela.
- **Progresso honesto**, com o passo próprio. Cancelar vale.
- **Zero legendas é erro visível**, não lista vazia. Se o filtro de escrita
  tirou tudo mas havia texto, a mensagem diz isso ("encontrei texto, mas não
  em japonês — confira o idioma do texto"); senão, "não encontrei legenda na
  parte de baixo do vídeo".
- Legenda indo para a lista conforme fecha: bom, não obrigatório na primeira
  entrega. Sem isso, cancelar descarta a leitura inteira.
- Traduzir, exportar, importar, ← →: os da janela.

Permissão: nenhuma nova. Ler o arquivo que a pessoa abriu não é Gravação de
Tela.

---

## Tradução

Depois da leitura, o estado é o de um original importado:

1. Builder com o rascunho lido e `recognitionName = "Imagem"`.
2. `originalWasImported = true`: `preserveCueTiming` na tradução e export do
   original sem `enforceLineLimit`.
3. `originalLanguage` = idioma do texto.
4. Traduzir é o botão que existe (`retranslate`). Nada de traduzir sozinho no
   fim da leitura — importar original também não traduz (18/09/2026).
5. Com `preserveCueTiming`, `finalize` só capitaliza. Tradução longa quebra na
   tela e no arquivo **sem** ganhar `start` novo. Não "consertar" chamando
   `enforceLineLimit`: o tempo é o contrato deste modo.
6. `source` sai como foi lido, minúscula e pontuação torta inclusive. Corrigir
   OCR com o tradutor é inventar texto.
7. Falha de tradução sobe como já sobe. Sem tradutor de reserva.

---

## Onde o código mora

| Peça | Lugar |
|---|---|
| Montador puro: filtros de linha, comparação tolerante, voto, montagem de `Cue`, refino sobre bytes de luma | `Sources/TradutorCore/BurnedSubtitle.swift`. As funções que o gate chama não tocam em Vision nem em AVFoundation. |
| Leitor: `AVAssetReader`, anel, Vision com 4 em voo | O mesmo arquivo; separar só se crescer. |
| Ação da janela, irmã de `generate()`, e a fonte do texto | `SubtitleStudioModel` |
| `Fala \| Imagem`, idioma do texto | `SubtitleStudioView`; o seletor de idioma do Vision em `LanguageControls.swift` |
| Gate | `tradutor-verify imagem` (sem vídeo, milissegundos) e `tradutor-verify imagem <video> <idioma> [gabarito]` |
| Autoteste do app | `--selftest-imagem <video> <idioma>` |

Nada no `Package.swift`: Vision e AVFoundation são do sistema. `AudioCapture`
não entra.

---

## Passos, nesta ordem

Quem implementar para no passo que não fechar. Não começar pela janela.

### 1. Montador puro, com gate

`tradutor-verify imagem` sem argumento: milissegundos, sem Vision, sem vídeo.
Entrada fabricada: amostras (PTS, linhas com texto, caixa e altura) e anéis de
luma pequenos. Casos que têm de falhar se alguém quebrar:

- `A A A` → uma legenda, com `start` e `end` do refino;
- `A A' A`, inclusive `me!`/`mel` → uma legenda, texto de A;
- voto: `is` ×4 e `iS` ×2 → `is`;
- `A`, vazio, `A` → duas legendas;
- `A` → `B` sem vazio → fecha e abre no quadro da troca;
- `A` → vazio → `B` dentro de um intervalo → dois instantes, cada um no seu
  quadro;
- faixa vazia o tempo todo → lista vazia, não legenda em branco;
- duas linhas → uma legenda, `Tokens.join` (inglês com espaço, japonês sem);
- escrita: japonês escolhido fica com a linha japonesa; inglês escolhido fica
  com as latinas;
- altura: furigana sai, linha de 0,55 da maior fica;
- centro: linha em 0,88 sai;
- `end` exclusivo: o `end` de A é o PTS do primeiro quadro sem A.

Se o binário não tiver o comando, o gate não existe — não marcar o passo como
feito.

### 2. Leitor nos dois vídeos reais — texto primeiro

`tradutor-verify imagem <video> <idioma>` imprime as legendas lidas com tempo.
Gabarito à mão ao lado do vídeo:
`video exemplo 2 (Conversa mais complexa).legenda-na-imagem.txt` com as 27
falas — a sonda dá o rascunho, mas cada linha é conferida contra o quadro, não
copiada — e as primeiras 20 falas do de 9 minutos (a linha japonesa).

Critério:

- vídeo 2 com **27 de 27** literais (a sonda chegou lá); nenhuma marca d'água;
- 9 minutos, japonês escolhido: a linha japonesa literal nas 20; nada de
  furigana, romaji, inglês ou placa;
- a faixa escolhida (0,78–0,96 ou 0,76–1,0) é a mesma nos dois;
- tempo de parede anotado.

Pare se o vídeo 2 ficar abaixo de 27: o defeito é recorte, coordenada, formato
de pixel ou filtro — não motivo para trocar de leitor.

### 3. O instante exato, contra oráculo

Oráculo: OCR em todo quadro das janelas de troca (como `sonda refine`). O
oráculo não serve para fade, porque deixa de ler antes do meio: essas trocas
se conferem à mão num punhado, olhando os quadros.

Critério: trocas sem fade no quadro exato em pelo menos 90%, nenhuma a mais de
um quadro; trocas com fade dentro do fade. O refino ingênuo da sonda fez 65%.
Registrar a tabela aqui.

### 4. Velocidade

Pelo caminho do app, não pela sonda: 9 minutos em ≥ 7× o tempo real; vídeo 2
anotado. Se não chegar, pular a faixa parada (critério de contagem de pixels)
e medir o ganho — não supor.

### 5. Ligar na janela

Só com 1 a 4 verdes.

- `Fala | Imagem` no cabeçalho compacto, idioma do texto próprio com a lista
  do Vision, passo de progresso, erro de zero legendas com a mensagem de
  escrita.
- Builder com `recognitionName`, `originalWasImported`, `originalLanguage`.
- Autoteste `--selftest-imagem <video> <idioma>`, relatório em `/tmp`: lê o
  vídeo 2 em inglês; confere a contagem e as três primeiras falas; ← e →
  contra os `start` lidos; traduz com "Só transcrever" (passa por
  `retranslate` e `finalize` sem rede) e confere que nenhum `start` ou `end`
  mudou; cabeçalho `Imagem → …` depois de traduzir; exporta o original e
  confere `….en.srt` com os mesmos blocos.
- Bundle separado se a instância do usuário estiver aberta; `open -n`, caminho
  absoluto (ver `CLAUDE.md`).

### 6. Sintético, só se faltar caso

Fade conhecido, a mesma frase duas vezes com vazio no meio, legenda de 0,4 s,
CJK sem faixa escura: se os vídeos reais não cobrirem algum, gerar em Swift —
CoreText desenha o texto com contorno sobre os quadros de um vídeo de
exemplo, `AVAssetWriter` grava. Script em `scratchpad/legenda-na-imagem/`,
vídeo em `/tmp`, nada no Git.

### 7. Registro

Parágrafo no `CLAUDE.md`, no estilo dos outros, com os números do caminho do
app: legendas, acerto literal, precisão do instante, tempo de parede, o que
foi recusado. Atualizar este plano com o que ficou. Sem número, não escrever
que "o Vision é preciso" nem que "varre em N×".

---

## Como saber que acabou

1. `swift build -c release` sem erro nem aviso novo.
2. `tradutor-verify imagem` passa com os casos do passo 1.
3. Vídeo 2: 27 de 27 literais contra o gabarito; nenhuma marca d'água.
4. 9 minutos, japonês: só a linha japonesa, sem placa, nas 20 do gabarito.
5. Instante: tabela contra o oráculo, meta do passo 3 atingida ou o motivo
   registrado.
6. 9 minutos em ≥ 7× o tempo real pelo caminho do app.
7. Na janela: `Fala | Imagem` visível sem abrir "Opções"; idioma do texto
   próprio, não herdado; seletor de motor e locutores somem em Imagem; ←, →,
   espaço, ⌘← e ⌘→ funcionam nas legendas lidas — porque é a janela velha,
   não porque nasceu atalho.
8. Traduzir não move `start` nem `end`; cabeçalho diz `Imagem`, antes e depois
   de traduzir.
9. Zero legendas é erro; nenhum modelo de fala é carregado e nenhum áudio é
   extraído neste caminho.
10. Nada novo no `Package.swift`; nenhum teste escreve em `Videos Exemplo/`.
11. `CLAUDE.md` só ganha parágrafo com número medido.

O que não é critério: "li um anime inteiro e pareceu bom". Sem gabarito, isso
não distingue faixa errada de leitor errado de tempo errado.

---

## Armadilhas

Medidas nesta revisão:

- **O `AVAssetReader` tem de viver o laço inteiro.** Solto antes, o
  `copyNextSampleBuffer` derruba o processo com "cannot copy next sample
  buffer before adding this output to an instance of AVAssetReader".
- **Coordenadas do Vision**: origem embaixo à esquerda, e as caixas vêm
  normalizadas à região de interesse — ou ao recorte, se a faixa for recortada
  — não ao quadro.
- **A confiança do Vision é grossa** (0,3, 0,5, 1,0). Não serve de filtro.
- **A primeira leitura leva ~24 s** e compila em
  `~/Library/Caches/<bundle>/com.apple.e5rt.e5bundlecache`, a pasta que o
  `CacheCleanup` administra. Volta a custar isso quando o macOS atualiza. Não
  incrementar `modelSetVersion` por causa disto: é acréscimo, não troca.
- **Alargar a faixa traz a marca d'água**, que o filtro de centro tira.
- **O ffmpeg daqui não desenha texto.**

Já conhecidas no resto do app:

- `VideoPlayer` do SwiftUI aborta neste app; a janela usa `AVPlayerView`.
- `DragGesture` entrega deslocamento acumulado — se um dia houver retângulo
  arrastado para a faixa.
- `open` com o app aberto ignora `--args`: `open -n`.
- Teste nunca escreve em dado do usuário.
- Comentário em português, dizendo **por que**, onde a próxima pessoa repetiria
  o erro: a origem do Vision, `preserveCueTiming`, o OCR como detector.

---

## Fora da primeira versão

- Captura ao vivo da tela de outro aplicativo.
- Faixa em cima (sem vídeo que a meça) e retângulo arrastado.
- Karaokê, letreiro rolante, letra que troca sílaba a sílaba.
- Duas legendas ao mesmo tempo (em cima e embaixo) como duas faixas.
- Separar romaji de inglês: mesma escrita.
- Filtro de marca d'água por persistência — só se um vídeo mostrar que o
  centro não basta.
- Aviso de faixa de legenda em texto dentro do arquivo.
- Corrigir OCR com o tradutor; identificar quem fala; detectar faixa ou idioma
  sozinho; baixar modelo.

---

## Reproduzir as medições

```bash
swiftc -O -parse-as-library scratchpad/legenda-na-imagem/sonda.swift -o /tmp/sonda
cd "Videos Exemplo"
V2="video exemplo 2 (Conversa mais complexa).mp4"
V9="video exemplo conversa de pessoas.mp4"
/tmp/sonda langs
/tmp/sonda decode "$V2"
/tmp/sonda scan "$V2" en-US 0.78 0.96 6 /tmp/v2.tsv        # diferença, máscara, OCR a 4 Hz
python3 ../scratchpad/legenda-na-imagem/separa.py /tmp/v2.tsv
/tmp/sonda refine "$V2" en-US 0.78 0.96 12                 # refino contra oráculo
EM_VOO=1,2,4 /tmp/sonda paralelo "$V2" en-US 0.78 0.96 6 /tmp/cinza.txt
EM_VOO=4 /tmp/sonda paralelo "$V9" ja-JP 0.76 1.0 7 /tmp/jp.txt
/tmp/sonda ocr "$V9" ja-JP 0.76 1.0 30,90,150,250          # linhas com caixa e altura
```
