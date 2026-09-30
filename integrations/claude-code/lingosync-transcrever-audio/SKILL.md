---
name: lingosync-transcrever-audio
description: LingoSync — transcribes audio or video files locally (no API, no network) with the LingoSync (Tradutor Instantâneo) engine, so Claude can read what is said in them. Use whenever the user sends or points to an audio/video file (.m4a, .mp3, .wav, .aac, .ogg, .flac, .mp4, .mov, .mkv, .webm, voice memo, recording, meeting, podcast, "áudio", "gravação", "vídeo") and wants it read, transcribed, summarized, translated, quoted or analyzed. Also use for "o que ele fala neste áudio", "transcreva", "ouça este arquivo".
---

# LingoSync: transcrever áudio e vídeo

Claude não ouve áudio. Esta skill transforma a fala do arquivo em texto com o
mesmo reconhecimento do app LingoSync (Tradutor Instantâneo), tudo local, e aí o texto é
lido normalmente.

## Comando

```bash
~/.claude/skills/lingosync-transcrever-audio/scripts/lingosync-transcrever "<arquivo>" [idioma] [motor] [--saida <arquivo.txt>]
```

- **stdout** é só o texto corrido (parágrafo novo a cada pausa de 10 s ou mais).
  **stderr** tem o progresso e a última linha `N trechos, N caracteres, Ns`.
- `idioma`: código de duas letras da fala — `pt` (padrão), `en`, `es`, `fr`,
  `de`, `it`, `ja`, `ko`, `zh`, `nl`, `pl`, `ru`, `uk`, `ar`, `hi`, `tr`, `vi`, `th`.
- `motor`: `whisper` (padrão) cobre todos os idiomas e é o que mais tolera
  áudio difícil (~30× tempo real). `apple` é o mais rápido (~100×), mas só
  cobre de, en, es, fr, it, ja, ko, pt, zh e depende do idioma instalado no
  macOS — use quando a pressa pesar mais. `parakeet` é opção para idiomas
  europeus.
- Aceita vídeo e áudio de qualquer formato que o macOS abre; a faixa de áudio
  é escolhida pelo idioma.
- Sem pontuação de tempo. Hesitações (`まあ`, `えー`, "um", "uh") saem do texto.

## Como usar

1. **Descubra o idioma** pela conversa (o nome do arquivo, o que o usuário
   disse). Sem pista, use `pt` — o usuário fala português.
2. Rode o comando com `timeout` generoso: arquivos longos no Whisper levam
   minutos (um vídeo de 9 min leva ~30 s no Whisper).
3. **Confira o resultado.** Texto vazio, muito curto para a duração, ou em
   outra língua/sem sentido quase sempre é idioma errado: rode de novo com o
   idioma certo, ou com `apple` para comparar.
4. Para texto longo, grave com `--saida` num arquivo do scratchpad e leia
   dele, em vez de despejar tudo na conversa.
5. Responda o que o usuário pediu (resumo, tradução, citação) a partir do
   texto. Ao citar, lembre que é transcrição automática: nomes próprios podem
   sair errados.

## Se falhar

- `tradutor-verify não compilado`: o script diz o comando. Compile uma vez na
  raiz do repositório (`swift build -c release --product tradutor-verify`; com
  as Command Line Tools do macOS 27, prefixe
  `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`).
- Motor Apple recusando o idioma: o modelo daquele idioma não está instalado
  no macOS — use `whisper`, ou peça ao usuário para instalá-lo pelo botão **+**
  ao lado do idioma no app.
- A primeira execução do Whisper baixa o modelo (~1,2 GB) para
  `~/Library/Application Support/Tradutor/models/`; avise o usuário.
