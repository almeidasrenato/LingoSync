# Validação de candidatos na transcrição (27/09/2026)

Três candidatos, nesta ordem: 1 (anime-whisper), 3 (pyannote community-1),
2 (separação de voz). Nada entra no app sem ganho medido. Ambientes, modelos
e saídas ficam aqui (`venv/`, `hf/`, `fakehome/` e `resultados/` fora do git).
Nada escrito em `~/Library/Application Support/Tradutor/`; ele só é lido.

## Réguas

- **TED** (16 min, 1 pessoa): legenda oficial japonesa, `tradutor-verify
  referencia` — CER sem pontuação nem espaço (NFKC + minúsculas, então meia
  largura × largura inteira **não** conta), CER pela leitura, fronteiras.
- **9 min** (japonês, 2 pessoas): a legenda japonesa desenhada no vídeo, lida
  por `tradutor-verify imagem` (19 de 20 literais contra o gabarito à mão) e
  convertida em `.srt` (`resultados/reguas/9min-ocr.srt`, 81 legendas). **Ela
  não legenda toda fala** (81 legendas contra ~140 do app): o CER do vídeo
  inteiro dá 147% só de "a mais". `recorta.py` fica com as legendas da
  hipótese que têm metade da duração dentro de uma legenda da referência; é
  esse o número da tabela.
- **Anime** (97 s, música, 10 pessoas): **não há legenda japonesa feita por
  gente**. Duas réguas fracas, ditas como tais:
  - CER contra `video exemplo 2 (Conversa mais complexa).ja.srt`, que é saída
    de um motor, não gabarito — mede concordância, não acerto;
  - `entidades.py`: os 17 nomes e termos que a legenda inglesa desenhada no
    vídeo diz que são falados (ルフィ ×5, 五老星 ×2, 麦わら ×2, ベガパンク,
    ヨーク, 海賊王…), contados na grafia canônica da obra.

---

## Item 1 — anime-whisper × Qwen3-ASR 1.7B

### Como foi medido pelo caminho do app

O app chama `qwen/venv/bin/python -c <launcher> … -f json -o <pasta> fala.wav`
e lê `{text, segments}`. `fakehome.sh` monta um HOME falso
(`CFFIXED_USER_HOME`, que o `FileManager` respeita) em que esse executável é
`aw_shim.py`; os modelos reais entram por symlink. Então o WAV é o que o app
prepara (nivelamento incluído), e o que vem depois — `punctuated`,
`phrases`, fronteiras de pausa, hesitação, `makeCues`, largura — é o do app.

`aw_shim.py`:

- corta o WAV com `split_audio_into_chunks` do próprio `mlx-qwen3-asr` (30 s
  em ponto de baixa energia — o mesmo corte do Qwen);
- reconhece cada bloco com o anime-whisper (transformers 5.17, MPS, float16,
  parâmetros da model card: `language=Japanese`, `no_repeat_ngram_size=0`,
  `repetition_penalty=1.0`);
- alinha o texto com o **mesmo Qwen3-ForcedAligner-0.6B** que o app usa. O
  anime-whisper não tem marcação de tempo útil: as `alignment_heads` do
  `generation_config` são do large-v3 (camadas até 25) e o decodificador dele
  tem 2 camadas. Com o alinhador igual, **só o texto do reconhecedor muda**
  entre as duas colunas.

```bash
scratchpad/validacao-2026-09/fakehome.sh
scratchpad/validacao-2026-09/item1.sh        # Qwen real, anime-whisper (ngram 0 e 5)
python3 scratchpad/validacao-2026-09/recorta.py <hip.srt> resultados/reguas/9min-ocr.srt > r.srt
./.build/release/tradutor-verify referencia --srt r.srt resultados/reguas/9min-ocr.srt
python3 scratchpad/validacao-2026-09/entidades.py resultados/item1/anime-*.srt
```

### Corte em falas pelo VAD: medido e descartado

O modelo foi treinado em falas isoladas de visual novel, então a primeira
tentativa cortou com o Silero VAD. No vídeo de anime:

```
                         blocos   CER contra o rascunho   termos
Silero, limiar 0,5          16          62,6%               —     0–20 s e 25–44 s sumiram (música)
Silero, limiar 0,2          11          43,0%              5/17
30 s do Qwen                 5          15,2%             11/17
```

O VAD perde fala com música por baixo, que é justamente o caso do anime. Com
o VAD veio também a primeira alucinação (`んっ、ちゅっ、だめっ、んっ、んんっ!`
num trecho de 7 s). Daqui em diante, blocos de 30 s — o regime da model card.

### Resultado

```
                           CER     leitura   oração P/C   legenda P/C   tempo
anime (97 s)  Qwen 1.7B   13,9%*    8,6%*     69/91        65/78         9,8 s
              anime-w     15,7%*    8,8%*     63/100       67/89        11,1 s
              anime-w ng5 14,8%*    8,8%*     62/95        70/89        14,0 s
9 min, só onde
a imagem tem  Qwen 1.7B   25,9%    12,4%     97/95        87/78        45,3 s
legenda       anime-w     93,8%    80,2%     85/95        78/80        97,3 s
              anime-w ng5 28,1%    13,7%     93/95        87/83        56,2 s
TED (16 min)  Qwen 1.7B    9,0%     4,6%     86/53        70/67       180,1 s
              anime-w     19,3%    13,4%     86/66        70/62       145,1 s
              anime-w ng5 20,5%    15,1%     87/65        70/64       189,9 s
                                             * contra saída de outro motor
termos do anime (17): Qwen 11 · anime-w 11 · anime-w ng5 11
```

Os termos perdidos são outros, não menos: o Qwen erra ヨーク, 凶悪 e duas
ルフィ; o anime-whisper erra ベガパンク (`ヴェガ・パンファンク`), エッグヘッド
(`エグヘッド`) e um 麦わら (`にぎわら`). 五老星 nenhum dos dois acerta
(`五郎瀬`/`五郎政` contra `ご老成`).

**Laço de alucinação no vídeo de 9 min**, que é uma conversa de trabalho
comum: `じゅるるるる…` com ~400 caracteres, `んっ、` ×27 no fim, `すんすん`
(fungada) duas vezes onde não há som disso. É o viés do treino em áudio de
visual novel, que a própria model card anuncia. `no_repeat_ngram_size=5`
(o valor do benchmark do autor) encurta o laço mas não o remove — os três
continuam lá, curtos — e piora o TED (19,3 → 20,5%).

**TED: o dobro do erro, quase todo por omissão** — 615 caracteres faltando
contra 84 do Qwen. O modelo pula pedaços dentro do bloco de 30 s (blocos de
27–28 s com 85–93 caracteres onde a fala tem ~130).

Efeitos à parte, como pedido:

```
                        。     !?    ASCII meia largura   ○
anime   Qwen            17      8          1              0
        anime-w          0     27         28              0
9 min   Qwen           139     25          0              0
        anime-w         98     47         54              0
TED     Qwen           117      0         54              0
        anime-w         63      3         15              0
```

- **Ponto final**: 0 `。` no anime (a model card avisa). Não mexe no CER (a
  régua tira pontuação); aparece nas fronteiras — no anime, 63% de precisão
  de oração contra 69%. No 9 min e no TED ele pontua mais que o esperado:
  sobre fala real, o viés vale menos.
- **○**: nenhum nos três vídeos — não havia palavrão para mascarar. A
  proibição do projeto não foi testada por falta de caso, e continuaria
  exigindo um filtro que desfaça o `○` (impossível: a palavra não existe no
  texto).
- **Meia largura**: neutro no CER (NFKC). Na tela, `!?` e dígitos estreitos
  em legenda japonesa; `SubtitleFileBuilder.lineWidth` conta caractere, então
  a quebra não muda.

### Veredito: não integrar, nem como motor só para anime

- No único vídeo de anime o resultado é **empate** (CER 13,9 × 15,7 contra um
  rascunho de máquina; 11 × 11 termos, errando termos diferentes). Não há
  ganho medido que pague um motor a mais — outro venv com torch
  (~2 GB) + 1,5 GB de pesos.
- Fora do anime é **pior em tudo**: o dobro do CER no TED e laço de
  alucinação obsceno num vídeo de escritório. "Só para anime" dependeria de o
  usuário escolher certo, e o vídeo de 9 min mostra o custo de errar.
- Ressalva: a régua do anime é fraca (97 s, sem gabarito japonês). Se um dia
  houver um episódio com legenda japonesa oficial, este é o experimento a
  refazer — `item1.sh` já roda qualquer vídeo.

---

## Item 3 — pyannote community-1

**Pulado a pedido** em 27/09/2026, antes de pedir o token do Hugging Face.
Nada medido.

---

## Item 2 — separação de voz antes do reconhecimento

### Como foi medido

`separa.py` extrai o áudio em 44,1 kHz estéreo (onde os dois modelos foram
treinados), separa a voz e grava **WAV 16 kHz mono PCM 16 bits**. A linha de
base (`original`) passa pelo mesmo `ffmpeg` sem separar, então a única
diferença entre as colunas é a separação. Os três WAV entram no mesmo
`tradutor-verify gerar … transcricao --locutores --modelo <m>` — caminho do
app inteiro, nivelamento incluído. A linha de base em WAV reproduz os números
do CLAUDE.md feitos a partir do `.mp4` (9 min, Apple + Sortformer: 97%).

- **BS-RoFormer**: `audio-separator` 0.47.0, `model_bs_roformer_ep_317_sdr_12.9755.ckpt`,
  parâmetros padrão, torch 2.14 em MPS.
- **Demucs**: 4.1.0, `htdemucs`, faixa `vocals`, `apply_model(split=True,
  overlap=0.25)` em MPS.

```bash
scratchpad/validacao-2026-09/item2.sh     # separa (4 vídeos × 3) e gera (× Apple/Qwen 1.7B × Sortformer/agrupamento)
python3 scratchpad/validacao-2026-09/mede2.py
```

Réguas: as mesmas do item 1 para o japonês. Para o inglês não há gabarito
de texto: mede-se **quanto o texto muda** contra a mesma combinação sem
separação, e **quanto Apple e Qwen discordam** na mesma variante — separação
que ajuda deveria aproximar os dois motores, não afastar.

### Custo da separação

```
                      97 s anime   540 s 9 min   161 s en1   109 s en2
htdemucs                15,7 s        39,9 s       17,4 s      12,1 s     ~0,1× o vídeo
BS-RoFormer            420,6 s      2726,0 s      792,3 s     523,3 s     ~5× o vídeo
```

O BS-RoFormer leva **45 minutos** para o vídeo de 9 minutos, antes de
qualquer reconhecimento. Sozinho, isso já o tiraria do app.

### Texto

```
                        sem separar     htdemucs      BS-RoFormer
anime   Apple   CER*       2,6%           5,2%           9,6%
                termos    11/17          12/17          11/17
        Qwen    CER*      12,6%          17,0%          15,2%
                termos    11/17          11/17          11/17
9 min   Apple   CER       22,3%          23,3%          26,0%
        Qwen    CER       25,6%          25,6%          28,5%
en1     Apple   muda        —             5,6%           4,7%     (319 → 315 / 317 palavras)
        Qwen    muda        —             4,4%           3,1%
        Apple × Qwen      4,1%           7,6%           5,7%
en2     Apple   muda        —             3,4%           4,2%
        Qwen    muda        —             3,8%           3,3%
        Apple × Qwen      5,9%           5,9%           6,3%
                                  * contra o .ja.srt, que é saída da Apple
```

No anime o CER* é concordância com a Apple sem separação, não acerto — por
isso a Apple original dá 2,6%. O que vale ali são os termos: **um a mais**
com htdemucs na Apple (12 × 11), nenhum no Qwen. No 9 min, onde há gabarito,
a separação **piora ou empata** nos dois motores; o BS-RoFormer piora nos
dois (Apple: 68 → 101 caracteres faltando).

No inglês limpo **a separação mexe no texto de 3 a 6% das palavras sem
ganho visível**, e afasta os dois motores um do outro (4,1% → 7,6% no en1).
Fala limpa não precisa de limpeza, e a distorção da separação vira troca de
palavra.

### Quem fala

```
                              sem separar   htdemucs   BS-RoFormer
anime (10)  Apple  Sortformer     47%          47%        40%
                   agrupamento    53%          53%        40%  (1 voz)
            Qwen   Sortformer     47%          40%        33%
                   agrupamento    53%          47%        33%  (1 voz)
9 min (2)   Apple  Sortformer     97%          87%        57%  (1 voz)
                   agrupamento    83%          77%        60%
            Qwen   Sortformer     90%          87%        60%  (1 voz)
                   agrupamento    83%          77%        63%
en2 (5)     Apple  Sortformer     72%          67%        77%
                   agrupamento    40%          42%        42%
            Qwen   Sortformer     70%          67%        74%
                   agrupamento    37%          42%        42%
```

**A separação apaga o que distingue uma voz da outra.** Com o BS-RoFormer o
Sortformer vê **uma voz só** no vídeo de duas pessoas (97% → 57%), e sem
troca de voz some a fronteira de legenda: 145 → 104 legendas, com nove falas
curtas perdidas (`いらっしゃいませ。`, `ちょっと声が小さいよ。`, `すいません`…).
O htdemucs perde menos, mas perde em quase toda linha. A única melhora é o
en2 com BS-RoFormer + Sortformer (+5 e +4 pontos), num gabarito só e com o
custo acima — não paga.

### Veredito: não integrar

É o mesmo resultado da subtração espectral e do filtro de graves, agora com
rede neural: **quanto mais limpa, menos texto, e menos gente**. O htdemucs é
barato, mas empata ou piora o texto (um termo a mais no anime, piora no
9 min) e piora a identificação de quem fala. O BS-RoFormer piora mais e
custa cinco vezes a duração do vídeo. Separação de voz fica fora do app.
