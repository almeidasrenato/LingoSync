# Layout e Gemini — 17/09/2026

`main` está em `098efa5`, com SRT e Qwen 1.7B corrigidos. O build principal
foi salvo em `build/Tradutor.app` antes das mudanças desta branch,
`codex/layout-gemini`. Não há remoto Git configurado; os commits são locais.

## Layout

Menu organizado em idiomas/modelos, ao vivo e vídeos. Janela de legendas
separa arquivos dos controles de geração; importar, exportar e traduzir têm
rótulos. Painel ao vivo tem duas linhas de controles, inclusive em 380 px.
Contraste, tamanhos de texto e rótulos de acessibilidade foram melhorados.

`--selftest-layout` renderiza os modos claro/escuro, janela vazia/preenchida e
painel de 380/620 px em `/tmp/tradutor-layout`. Conferidos visualmente.
Menu: 372 × 728; estúdio: 1080 × 700; painel: 380/620 × 300.

## Gemini

- Mantém prompt, modelo do site, tamanho de lote, espera de streaming e
  parâmetros de captura/reconhecimento.
- Agrupa as mesmas operações Quill de inserir linha/parágrafo numa chamada
  ao WebKit. Após 100 ms, verifica todas as linhas do editor; divergência
  repete a inserção serial e confere novamente. Prompt incompleto não sai.
- Rejeita índices duplicados/fora da faixa, traduções vazias e itens ausentes;
  aceita CRLF. Detecta maioria de linhas longas CJK devolvidas sem tradução,
  preservando a tolerância a nomes e interjeições. Continua sendo heurística:
  não verifica semanticamente cada frase nem acusa uma fala isolada.
- Lê texto do DOM preservando parágrafos e `<br>`. `innerText` era afetado
  pelos spans animados: houve `Elaveioaqui ontem.` numa execução via `open`.
  O diagnóstico do DOM confirmou spans pendentes/animados e `innerText`
  divergente de `textContent`. Um teste WebKit reproduz a perda de espaços
  ocultos por CSS; a leitura nova preserva todos eles.

### Medições

Dois lotes sintéticos de seis falas, japonês/inglês → português, na mesma
sessão anônima. Tempos não representam promessa de velocidade do serviço.

| Envio | Inserção lote 1 / 2 | Total lote 1 / 2 |
|---|---|---|
| Antigo, sem conferir editor | 487 / 230 ms | 5,917 / 3,318 s |
| Serial, conferindo editor | 405 / 351 ms | 5,850 / 3,159 s |
| Agrupado, conferindo editor | 300 / 249 ms | 5,324 / 3,035 s |

Uma execução por variante: indício de ganho pequeno na inserção (~100 ms
na comparação com a mesma validação), não um benchmark estatístico.
O custo dominante continua sendo o Gemini/rede. Não reduzimos instruções
nem antecipamos a leitura para ganhar tempo.

No pacote final aberto via Launch Services (`open -n`), os lotes de 6, 6 e
40 itens levaram 6,047 / 3,138 / 4,231 s. O lote de 40 repete as seis frases
inglesas: valida capacidade e alinhamento, não diversidade linguística.
Revisão das 52 saídas: sem omissões, palavras coladas, mudança de horário,
troca de afirmação/pergunta ou erro de concordância no material testado.
Isso não garante a qualidade de todas as traduções futuras do site.

### Reprodução

```sh
rtk proxy swift build -c release
rtk proxy .build/release/TradutorApp --selftest-gemini
rtk proxy .build/release/TradutorApp --selftest-srt
rtk proxy env TRADUTOR_GEMINI_DEBUG=1 .build/release/TradutorApp --selftest-gemini --online --batch40
```

`TRADUTOR_GEMINI_INSERCAO_SERIAL=1` compara a inserção anterior com a mesma
verificação de integridade. Testes online enviam somente as falas sintéticas
de `GeminiCheck.swift` ao site. Não carregam modelos nem iniciam captura.

Validação final: build release, 14 verificações Gemini locais (incluindo
WebKit), 16 de SRT, três lotes online e assinatura dos dois bundles passaram.
O build de prévia é `build/Tradutor Layout.app`; o principal foi preservado.

Não foram alteradas as legendas de exemplo do usuário nem encerrada sua
instância da aplicação. Somente os processos dos autotestes terminaram.
