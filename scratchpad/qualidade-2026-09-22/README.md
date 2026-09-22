# Auditoria de captura e legendas — 22/09/2026

Base: `cc64e3b`, main limpa antes das medições. Branch criada depois do baseline:
`codex/qualidade-captura-legendas`. Sistema medido: macOS 27.0 (26A428).
Referências consultadas: AGENTS.md, auditoria de 14/09 e medição do Qwen de 17/09.

## Resultado mantido

| Verificação | Antes | Depois |
|---|---:|---:|
| Agradecimento realmente falado, duas vozes PT × três motores | 0/6 preservados | 6/6 preservados |
| WER nessas seis falas conhecidas | 100% | 0% |
| Frase ausente: outra fala, silêncio, ruído e cliques | 4/4 rejeitados | 4/4 rejeitados |
| Pontuação original perdida ao repartir 27 transcrições congeladas | 30 sinais | 0 |
| Texto original preservado integralmente, exceto espaços na borda | — | 27/27 |
| SRT exibido/exportado e tempos nos mesmos 27 replays | referência | iguais |

1. `Hallucinations.filter` confirma também em português uma frase candidata
   que o filtro antes apagava sem conferir. Reutiliza o reconhecedor Apple já
   instalado, sem download nem rede. Quando a Apple não está disponível,
   permanece o comportamento anterior. Só frases já suspeitas pagam a conferência.
2. `splitSource` conserva os delimitadores. Vírgulas, perguntas e exclamações
   deixavam de existir no original dividido; o japonês recebia espaços artificiais.
   Não muda a tradução, a duração nem o reconhecedor.
3. O autoteste da janela verifica a limpeza síncrona antes de aguardar: com
   a Apple, 400 ms já bastavam para aparecer o NOVO original, causando dois
   falsos negativos. Nenhum comportamento da interface foi alterado por isso.

**Gemini não foi alterado.** Seus testes usam o tradutor já existente.
Pesos, precisão, alinhador Qwen, limiares Whisper e captura física não mudaram.

## Amostra e método

- Cinco vídeos reais de `Videos Exemplo`: japonês difícil, japonês com música,
  japonês longo e duas conversas em inglês.
- Diálogo PT-BR de 32 s, dez falas conhecidas, vozes Luciana e Rocko. Variante
  idêntica com uma voz 24 dB mais baixa. Não havia vídeo real em português entre
  os exemplos: os resultados PT são sintéticos, não prova de desempenho com
  sotaques, microfone, reverberação ou conversação espontânea.
- Dois agradecimentos isolados e quatro controles negativos adicionais.
- 27 reconhecimentos antes e 27 depois: Apple, Whisper turbo e Qwen3-ASR **1.7B**.
  Extração e preparação do app executadas uma vez; os mesmos bytes Float32
  alimentam ambas as condições. Manifestos SHA-256 em `results/*/audio-sha256.json`.
- 27 replays do mesmo rascunho, sem reconhecimento nem tradução de rede, isolam
  a correção de pontuação. Comparação permite apenas 1e-9 s de arredondamento
  JSON e exige SRT final byte a byte igual.
- Dez replays do segmentador ao vivo, em quadros exatos de 20 ms, Apple/Whisper.
  Qwen não oferece captura ao vivo e não foi apresentado como se oferecesse.
- Nove traduções Gemini: entradas de cada reconhecedor em JA/EN/PT, destinos
  PT/PT/EN. Novas chamadas dos autotestes da janela são validação de integração.

JSONs brutos e logs ficam localmente em `results/`; mídia e esses resultados
não entram no Git. `metrics.json` e `comparison.json` guardam os agregados.
`compare.py` é a verificação executável das promessas da correção.

## Português: palavras, pontuação e sentido

| Motor | WER estrito | WER com números equivalentes | Pergunta do roteiro | Exclamações |
|---|---:|---:|---:|---:|
| Apple | 17,46% | 1,59% | 1/1 | 0/3 |
| Whisper | 22,22% | 3,17% | 1/1 | 0/3 |
| Qwen 1.7B | 3,17% | 0% | 0/1 | 0/3 |

Esses números se repetiram no diálogo com a voz baixa e depois das correções.
WER estrito conta `123,50` contra o valor por extenso como erro. A segunda coluna
normaliza apenas as formas numéricas do roteiro e `sextafeira`; não corrige
palavras erradas. Pontuação é avaliada separadamente, pois WER não a mede.

Apple acrescenta um artigo em “para a sexta-feira”. Whisper acrescenta “E aí”
no final do reconhecimento, mas o agrupamento temporal não o inclui no SRT
desse exemplo. Não foi criado um filtro genérico para apagar essa expressão:
ela pode ser fala verdadeira. Qwen preserva as palavras, porém entrega **zero
sinais de pontuação** no diálogo PT. Esse resultado não autoriza banir o idioma
nem inventar perguntas com heurísticas; exige amostra real adicional.

## Gemini: o reconhecimento limita a tradução

As nove traduções produziram **214 legendas**, zero traduções vazias, zero
sobreposições, zero blocos acima de duas linhas e zero durações acima de 7 s.
Tempos: cerca de 6,0–6,1 s nos exemplos PT/JA curtos e 10,1–10,7 s no inglês.
São observações de uma rodada de um serviço variável, não SLA nem benchmark
isolado de inferência.

Conferência de oito informações do roteiro PT: horário, pergunta sobre relatório,
negação “ainda não”, envio amanhã após almoço, quinze versus cinquenta caixas,
R$123,50, proibição de fechar a janela e viagem condicional na sexta-feira.
Apple/Whisper conservaram 8/8 na tradução; Qwen 7/8: a pergunta sem pontuação
virou “You sent the report”. As demais informações permaneceram presentes,
embora o valor por extenso fosse repartido entre legendas. Isso mede apenas
essas oito informações, não uma nota geral de qualidade do Gemini.

No inglês, a versão Whisper já chega sem a negação de “I don't really know…”
em um trecho e com falas repetidas; a tradução reproduz o problema. No japonês
difícil, nomes e expressões divergentes dos três reconhecedores geram traduções
diferentes. Sem transcrição humana desses vídeos, não foi calculado WER/CER
nem declarada uma tradução como gabarito. Foi observada também a construção
estranha “A então eu farei…” na saída da Apple→Gemini. Nenhuma correção foi
feita no Gemini, conforme solicitado.

## Segmentação, sincronismo e limitações

Todos os SRTs de arquivo ficaram em até duas linhas e 7 s nas duas condições.
Os dados completos incluem duração curta, p95 de caracteres por segundo,
tempo de legenda sem voz e tempo de energia de voz sem legenda.

**Energia é proxy, não gabarito de fala.** Música pode ser marcada como voz;
legendas que permanecem durante uma pausa não são necessariamente incorretas.
Não se deve chamar a redução desse indicador de aumento de acurácia.

No replay ao vivo, os segmentos cobrem todo o tempo marcado como voz nos
exemplos inglês, japonês com música e nos dois diálogos PT. No japonês difícil,
15,39% dessa energia fica fora dos segmentos: ainda é necessário distinguir
ruído de fala audível nessa parcela, antes de baixar limiares.

| Replay PT | Segmentos | Cortes dentro da fala conhecida | WER normalizado Apple / Whisper |
|---|---:|---:|---:|
| Normal | 3 | 2 | 15,87% / 3,17% |
| Uma voz baixa | 5 | 0 | 14,29% / 0% |

No normal, os cortes caem em 11,78 s e 23,26 s. Apple perde partes do valor
monetário e de “Obrigado por avisar”; Whisper preserva melhor o valor. A voz
baixa muda as fronteiras e, por acaso, beneficia alguns trechos: não é evidência
de que atenuar áudio seja uma otimização. Não foram alterados VAD nem teto de
segmento, pois uma mudança global pode partir outras palavras ou atrasar texto.

Esse replay reconhece segmentos fechados. Não reproduz os parciais, a confirmação
de prefixo, a fila do tradutor, Core Audio, Bluetooth ou o atraso do dispositivo.
Logo, **não mede latência completa ao vivo**. O teste da janela real verifica
o outro caminho: player, seleção da legenda, seeks, lacunas, importação e
renderização durante/depois da geração. Relatórios em `results/viewer/`.

Apple e Qwen mantiveram texto e tempos reconhecidos idênticos nos sete exemplos
principais antes/depois. Whisper repetiu exatamente cinco; inglês conversa e
japonês difícil variaram, como já documentado no projeto. Essa oscilação e os
tempos menores/maiores não são ganhos atribuíveis às duas correções.

## Reprodução e validação

Com o release compilado, use `rtk proxy` antes dos comandos abaixo:

```sh
python3 scratchpad/qualidade-2026-09-22/prepare.py
python3 scratchpad/qualidade-2026-09-22/prepare-controls.py
python3 scratchpad/qualidade-2026-09-22/run.py meter suite baseline
python3 scratchpad/qualidade-2026-09-22/run.py meter trials gemini
python3 scratchpad/qualidade-2026-09-22/run.py meter trials live
python3 scratchpad/qualidade-2026-09-22/run.py meter trials confirm confirm-baseline
# Aplicar a correção e compilar novamente; manter audio/*.f32 intactos.
python3 scratchpad/qualidade-2026-09-22/run.py meter suite candidate
python3 scratchpad/qualidade-2026-09-22/run.py meter trials layout layout-candidate
python3 scratchpad/qualidade-2026-09-22/run.py meter trials confirm confirm-candidate
python3 scratchpad/qualidade-2026-09-22/compare.py
python3 scratchpad/qualidade-2026-09-22/viewer.py
```

Os runners pulam JSON já existente: para medir de novo, use outra pasta de fase
ou mova os resultados anteriores. Não regenere a mídia entre A e B.
Execute `summary.py` para cada fase e depois `audit.py` para os agregados.

Build release e gates `motores`, `tempos`, `quebra`, `legendas`, `frases`,
`prefixo`: passaram. Bundle separado `build/Tradutor Qualidade.app`, com identidade
e preferências próprias. A aplicação principal aberta (PID 32559) foi preservada.
O autoteste usa cópias temporárias; nenhum SRT dos exemplos é sobrescrito.

Autotestes da janela concluídos: português com Apple, Whisper e Qwen 1.7B,
mais vídeo japonês com música/Qwen, todos com Gemini: **4/4 passaram**.
Incluem legenda correspondente ao quadro pausado, navegação, lacunas sem legenda,
importação das duas faixas, exportação e texto original antes da tradução.
A primeira execução Apple teve apenas os dois falsos negativos de limpeza
descritos acima; o relatório inicial permanece em `results/viewer/pt-apple-initial.txt`.

Encerramento solicitado por cota: 92% consumidos na última consulta. Não há teste
iniciado pendente. Commit fica nesta branch, sem merge na main. A instância
principal foi confirmada ainda aberta após os testes. Para uma próxima rodada:
vídeo real PT com gabarito, medição física ponta a ponta da captura ao vivo e
investigação da pontuação PT do Qwen. São limitações desta amostra, não ganhos
que tenham sido presumidos ou implementados.

## Tempos observados nos arquivos principais

Segundos do reconhecimento/pós-filtro, sem a preparação Swift. No Qwen, incluem
inicialização do processo/modelo Python. O primeiro Whisper teve 75,7 s de carga
adicionais, excluídos desta tabela. Contagem e CPS são do baseline sem tradução.
Não foram feitas repetições estatísticas de desempenho; não inferir aceleração.

| Exemplo | Motor | Antes (s) | Depois (s) | Legendas | p95 caracteres/s |
|---|---|---:|---:|---:|---:|
| en-conversa | apple | 1.31 | 1.26 | 51 | 22.7 |
| en-conversa | qwenLarge | 19.29 | 18.63 | 54 | 21.1 |
| en-conversa | whisper | 12.20 | 10.75 | 49 | 21.0 |
| en-dialogo | apple | 0.95 | 0.95 | 42 | 19.5 |
| en-dialogo | qwenLarge | 14.40 | 14.04 | 43 | 19.4 |
| en-dialogo | whisper | 5.84 | 5.83 | 34 | 19.3 |
| ja-dificil | apple | 0.76 | 0.72 | 6 | 5.5 |
| ja-dificil | qwenLarge | 11.82 | 6.10 | 10 | 6.7 |
| ja-dificil | whisper | 20.80 | 22.05 | 13 | 7.0 |
| ja-longo | apple | 4.44 | 4.60 | 114 | 7.4 |
| ja-longo | qwenLarge | 49.38 | 57.37 | 106 | 7.3 |
| ja-longo | whisper | 20.47 | 20.24 | 109 | 8.8 |
| ja-musica | apple | 0.97 | 0.91 | 18 | 5.8 |
| ja-musica | qwenLarge | 10.62 | 10.10 | 24 | 6.2 |
| ja-musica | whisper | 7.17 | 7.03 | 19 | 5.8 |
| pt-clean | apple | 0.46 | 0.44 | 11 | 13.6 |
| pt-clean | qwenLarge | 7.00 | 7.70 | 7 | 12.7 |
| pt-clean | whisper | 2.13 | 2.13 | 9 | 13.0 |
| pt-quiet | apple | 0.38 | 0.42 | 11 | 13.6 |
| pt-quiet | qwenLarge | 7.35 | 8.32 | 6 | 12.2 |
| pt-quiet | whisper | 2.15 | 2.07 | 9 | 13.0 |
