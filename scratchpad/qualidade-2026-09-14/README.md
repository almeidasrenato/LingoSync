# Qualidade de transcrição — 14/09/2026

## Mantido no app

1. **Whisper: `suppressBlank = true` somente em arquivo.** Impede espaço/EOT
   como primeiro token da janela, usando o filtro nativo do WhisperKit.
   Mantidos modelo turbo, limiares, VAD e até três tentativas; tempo real intacto.
2. **Frases suspeitas conferidas no áudio antes de apagar.**
   `transcribeForSubtitles` unifica o pós-processamento do app e dos gates.
   Em inglês/japonês, a Apple já instalada confere apenas os candidatos, com
   margem de 0,5 s. Sem modelo instalado ou em caso de erro, mantém o descarte
   anterior. Sem download, rede ou dependência nova. Tempos inválidos/depois
   do arquivo são descartados sem enviar áudio vazio à Apple.
3. **Silêncio digital não vai para reconhecimento.** Sem limiar de energia:
   somente áudio vazio ou inteiramente composto por zeros. Antes o Whisper
   devolvia “Thank you.” para três segundos de zeros.

## Evidência

Whisper medido com os cinco vídeos completos de `Videos Exemplo`, extração e
nivelamento do próprio app. Saídas brutas preservadas, incluindo tentativas,
probabilidades, palavras e tempos. Nos casos variáveis houve três execuções
por condição, alternando a ordem nas repetições. Cada execução ainda pode
fazer até três passadas conforme o alcance, como o app.

| Controle | Padrão anterior × suppressBlank |
|---|---|
| Inglês, conversa | Texto idêntico, 1.718 caracteres |
| Inglês, diálogo | Texto idêntico, 1.246 caracteres |
| Japonês, vídeo curto com música | Texto idêntico, 251 caracteres |
| Japonês, vídeo longo | 1.415/1.481/1.487 → 1.499/1.507/1.519 caracteres |
| Japonês, vídeo difícil | 67/82/54 → 166/146/90 caracteres |

**Contar caracteres não prova qualidade.** O achado relevante no vídeo difícil
é o diálogo entre aproximadamente 7 e 20 segundos: ausente nas três execuções
anteriores, presente em duas de três com suppressBlank. Inclui:

- 大丈夫ですか? / すいません、大丈夫です
- ちょっと疲れが見えるようなので
- 僕たち一旦退出するので
- お二人しばらくお待ちください

Apple e Qwen 1.7B reconhecem esse mesmo diálogo no áudio completo. São
confirmações auxiliares, não gabarito humano nem medição de CER/WER. Persistem
variação, nomes errados e omissões; a mudança não recuperou a abertura em toda
execução. Silêncio e ruído deram as mesmas saídas brutas nas duas condições.
Ruído japonês ainda pode gerar “はい”; não foi acrescentado filtro de volume.

A confirmação de frases preservou os **três trechos realmente falados que
antes eram apagados**, em falas sintéticas com roteiro conhecido (boa-noite
japonês e agradecimento inglês, isolado e com contexto). Continuou rejeitando
as **dez ocorrências suspeitas** nas saídas comparadas dos vídeos reais.
São ocorrências entre variantes, não dez vídeos nem dez frases únicas.

## Rejeitado

- Processamento sequencial do Whisper: mudou nomes e chegou a transcrever
  uma fala japonesa em inglês. Mantido o corte por VAD.
- Afrouxar os filtros de confiança: a inspeção das saídas brutas não mostrou
  recuperação útil consistente. Limiares mantidos.
- Relaxar os limites do SRT intermediário do Qwen (7 s, 150 caracteres,
  sem limite prático de palavras): no japonês curto e no inglês, os resultados
  finais traduzidos foram **idênticos**, após o agrupamento do app. O teste
  usou as mesmas saídas do 1.7B, sem nova inferência para cada condição.

## Reproduzir

Depois de `swift build -c release`:

```sh
python3 scratchpad/qualidade-2026-09-14/run.py measure /tmp/medicao ja-dificil vad
python3 scratchpad/qualidade-2026-09-14/run.py measure /tmp/medicao ja-dificil blank
python3 scratchpad/qualidade-2026-09-14/run.py confirm /tmp/medicao /tmp/confirmacao.json
.build/release/tradutor-verify motores
python3 scratchpad/qualidade-2026-09-14/prepare.py
python3 scratchpad/qualidade-2026-09-14/run.py measure /tmp/falas synthetic vad
python3 scratchpad/qualidade-2026-09-14/run.py confirm /tmp/falas /tmp/falas-confirmadas.json
python3 scratchpad/qualidade-2026-09-14/run.py endtoend
```

Sem nome do vídeo, `measure` percorre os cinco e testa vad/serial/blank.
`resultados/` guarda os JSONs brutos e o resumo das repetições. Os `.f32` não
foram copiados para o repositório: são gerados novamente a partir dos vídeos.
Os medidores são experimentos isolados, não fazem parte do executável do app.
A otimização de desempenho do Qwen não foi alterada nesta rodada.

## Validação final

- Build release e bundle `build/Tradutor.app` concluídos.
- Gates `motores`, `frases`, `tempos`, `quebra` e `legendas`: passaram.
- Seis gerações completas pelo `SubtitleFileBuilder.generate`: despedida
  japonesa e agradecimento inglês, com Whisper, Apple e Qwen 1.7B; todos
  preservaram a fala e traduziram para “Boa noite”/“Obrigado por assistir”.
- Geração em silêncio digital: `noSpeech`, sem legenda inventada.
- Autoteste da janela real com o vídeo japonês curto e Whisper: passou,
  incluindo limites de linhas/duração, navegação, retradução e importação.
- Os avisos existentes do compilador em diarização/hotkey não foram alterados.
- Autoteste de geração pelo menu: passou com japonês e o reconhecedor salvo
  (Qwen 0.6B), sem mudar preferências. Esse autoteste usa a seleção gravada;
  a tentativa inicial com inglês foi corretamente recusada pelo 0.6B.
