# Qwen3-ASR 1.7B — ponto de retomada, 17/09/2026

## Estado entregue

- `main`: `08322a1`, correções de importação/exportação de SRT. Inclui `1e6ac0c`.
- Build independente: `build/Tradutor Legendas.app`, assinado e verificado.
- A instância original (PID 2183) e `build/Tradutor.app` foram preservados.
- Não existe remoto Git configurado; a main é local.
- Branch de pesquisa: `codex/qwen-1.7b-performance`.
- Implementação nova: cache livre do MLX limitado a 512 MiB e residência de
  buffers limitada à metade da RAM/teto recomendado do dispositivo, só no 1.7B.
  Mantém os mesmos pesos, precisão float16, áudio, segmentação e alinhador.
  Validação final concluída; build separado `build/Tradutor Qwen.app`.
  `build/Tradutor Legendas.app` e `main` continuam na versão de SRT anterior.
- A branch acrescenta instrumentos de medição: `fonte ... --json <arquivo>`
  grava tempo total, falas com tempos completos e SRT; a variável
  `TRADUTOR_QWEN_GUARDAR_WAV` copia o WAV temporário exatamente como o app o
  entrega ao Qwen. Não sobrescreve arquivo existente.

## O que foi corrigido e testado na main

Importar original só carrega, sem iniciar tradução. O rascunho permite traduzir
por clique. Importar tradução carrega essa faixa e remove o rascunho anterior.
Exportação de original usa o rascunho completo, anterior aos cortes da tradução;
original gerado recebe o limite de duas linhas. Original importado conserva seus
blocos e tempos. Faixa ausente não é substituída por texto no outro idioma.
O idioma do conteúdo não muda quando o usuário altera seletores.
Japonês não ganha espaços ao juntar linhas; ida e volta preserva milissegundos
(e durações positivas menores que 200 ms).

Passaram: `--selftest-srt` (16 verificações), gates `legendas`, `tempos`, `quebra`,
compilação release e verificação de assinatura. O teste completo de studio com
vídeo não foi executado nesta rodada. Sua verificação de exportação original foi
atualizada e compilada. Nenhum teste escreveu nos SRTs de `Videos Exemplo`.

## Ambiente e metodologia

MacBook Air M5, 16 GB; MLX 0.32.2, mlx-qwen3-asr 0.4.0, NumPy 2.5.3,
nagisa 0.3.0. Modelos já instalados; HF_HUB_OFFLINE=1 em todas as execuções.
GPU usada sequencialmente, mantendo o app original aberto.

A primeira comparação passou por `tradutor-verify fonte`, incluindo extração e
tratamento do app. Houve variação de texto/tempos entre execuções do próprio
baseline. Não atribuir automaticamente essa variação à otimização. Sua origem
não foi isolada. A seguir, capturei uma vez o WAV já preparado pelo app e usei
os mesmos bytes em todas as execuções do CLI. Com WAV fixo, as quatro execuções
por vídeo deram SRT, texto e tempos idênticos. Os arquivos brutos ficam em
`frozen/` e `results/`, fora do Git; os scripts ficam versionados.

### Hipótese 1: decodificação especulativa nativa

Opções `--draft-model Qwen/Qwen3-ASR-0.6B --num-draft-tokens 4`.
Primeira medição, incluindo o caminho do app:

| Vídeo | Normal | Especulativa | Resultado |
|---|---:|---:|---|
| Japonês difícil (78 s) | 9,57 s | 11,34 s | 18,4% mais lenta, saída idêntica |
| Japonês com música (97 s) | 12,94 s | 18,29 s | 41,3% mais lenta, tempos diferentes |

Reprovada pelo desempenho. A diferença de tempos da segunda linha foi observada
antes de congelar o WAV, portanto não prova regressão causada pela opção.
A ligação experimental no Swift foi removida. Não acrescentar o modelo menor
como padrão. O script `frozen.py` permite medir a opção diretamente no CLI.

### Hipótese 2: sincronização rápida do MLX

`MLX_METAL_FAST_SYNCH=1`, suportada pelo MLX instalado em Metal 3.2+/macOS 15+,
conforme `mlx/include/mlx/fence.h`. Ordem normal, rápida, rápida, normal; WAV fixo:

| Vídeo | Normal 1 | Rápida 1 | Rápida 2 | Normal 2 |
|---|---:|---:|---:|---:|
| Japonês difícil | 6,53 s | 6,48 s | 7,17 s | 6,99 s |
| Japonês com música | 10,49 s | 12,71 s | 12,32 s | 12,32 s |

SRT idêntico nas quatro execuções de cada vídeo, mas sem ganho consistente.
Não ativada. Os números incluem a inicialização do processo e escrita do SRT.

### Perfil da execução normal

`cProfile` no mesmo japonês com música, WAV fixo: 13,16 s instrumentados;
13,40 s de parede. A saída permaneceu idêntica ao baseline.

- `generate_with_info`: 8,62 s cumulativos; `_sample`: 8,30 s, predominantemente
  esperando a GPU em `scalar_int`/`.item()`. Isso **não** prova que o custo é
  todo sincronização: o item espera também as operações anteriores da GPU.
- Alinhamento: 2,95 s cumulativos, incluindo sua carga.
- Carga dos dois modelos: 1,99 s cumulativos, já incluídos nos itens anteriores.
- O `prefill` da biblioteca já projeta só o último token; KV cache já é
  pré-alocado; atenção já usa o kernel fundido do MLX. Não reimplementar isso.

## Reprodução

Na branch de pesquisa, compilar primeiro (o bundle da main permanece intacto):

```sh
swift build -c release --product tradutor-verify
python3 scratchpad/qwen-performance-2026-09-17/frozen.py ja-dificil ja-musica
QWEN_VARIANTS=profile python3 scratchpad/qwen-performance-2026-09-17/frozen.py ja-musica
```

Outras entradas disponíveis: `en-conversa`, `en-dialogo`, `ja-longo`.
`QWEN_VARIANTS=base1,draft4` mede a especulativa sobre WAV fixo.
`measure.py` agora compara normal e otimizado no caminho inteiro do app,
com `TRADUTOR_QWEN_SEM_OTIMIZACAO=1` no controle. Essa comparação não congela o
WAV entre execuções. `frozen.py` é o teste que exige saída inteiramente idêntica.

## Pendências registradas ao encerrar a primeira rodada

1. Localizar um ganho real na decodificação mantendo as operações numéricas e
   todos os tokens. O perfil aponta o custo, não uma solução comprovada.
2. Se investigar reutilização de processo/modelo, medir o benefício em vídeos
   sucessivos e respeitar liberação de memória/cancelamento. Carga é ~2 s neste
   exemplo; não prometer aceleração substancial de vídeo longo por isso.
3. Validar qualquer candidato em inglês, japonês com música, fala difícil e
   vídeo japonês longo; comparar texto completo, tempos e SRT sobre WAV fixo,
   repetir alternando a ordem e confirmar depois pelo caminho do app.
4. Só ativar após ganho consistente, sem regressão de cobertura ou qualidade.
   Não quantizar, reduzir modelo, encurtar janelas/tokens ou retirar alinhador.

As alterações locais preexistentes dos SRTs de exemplo continuam fora dos commits.
As mudanças de Gemini, retentativa de tradução e ícone já existentes foram
preservadas no primeiro commit da versão da main.


## Continuação — memória do MLX

A sobreposição CPU/GPU (`async_runner.py`) conservou a saída e passou nos testes
de tokens/EOS/repetição, mas não trouxe ganho consistente após aquecimento;
não foi integrada. `MLX_METAL_FAST_SYNCH` e a especulativa continuam desativados.

O cache de buffers livres do MLX usa, por padrão, o limite de memória (1,5 vez
o working set recomendado). Na máquina de 16 GB ele pode reter memória demais.
Primeiro medi apenas `set_wired_limit`: redução de 2% a 5%, sem reduzir o pico.
Limitar o cache livre a 512 MiB trouxe o maior benefício. Não é quantização nem
corte de contexto: os buffers ativos do modelo permanecem intactos.

A produção chama o mesmo `mlx_qwen3_asr.cli.main()` pelo Python do venv após
ajustar os dois controles nativos. Não altera a instalação Python, pesos ou
API interna de decodificação. Ao terminar/cancelar o processo, a memória é
liberada. Se o MLX antigo não expõe os controles, ou recusa o ajuste, o mesmo
CLI continua; não há mudança de reconhecedor. O 0.6B mantém sua chamada antiga.

`TRADUTOR_QWEN_SEM_OTIMIZACAO=1` permite repetir o controle sem recompilar.
`check_wired.py` executa o texto real embutido no Swift com APIs simuladas:
limite de 512 MiB, metade da RAM/teto do dispositivo, API antiga, falha no ajuste
e encaminhamento intacto de idioma/modelo/caminho com espaços.

```sh
python3 scratchpad/qwen-performance-2026-09-17/check_wired.py
QWEN_VARIANTS=base11,app1,app2,base12 python3 scratchpad/qwen-performance-2026-09-17/frozen.py ja-dificil en-dialogo ja-longo
python3 scratchpad/qwen-performance-2026-09-17/summary.py
```

As variantes `app*` usam exatamente o launcher embutido em `QwenEngine.swift`.
`bounded*` usou os mesmos controles no arnês exploratório. Todas mantêm o
mesmo arquivo WAV por vídeo. A ordem ABBA intercala duas execuções do candidato
entre duas do controle. Para música e conversa em inglês, a rodada exploratória
teve controle/cache isolado/cache+residência/controle (uma execução combinada).
Os tempos têm variação de carga/temperatura; não extrapolar os percentuais para
todo vídeo. `/usr/bin/time -l` fornece o pico de footprint do processo Python,
incluindo memória Metal; ele não é o RSS. Saídas brutas locais em `frozen/`.

### Resultado final da comparação

SRT e JSON completo (texto, idioma, motivos de parada, trechos, tempos) idênticos
em todas as variantes finais dos cinco vídeos. A comparação aborta se divergir.

| Vídeo | Controle (média) | Otimizado (média) | Redução | Pico de footprint |
|---|---:|---:|---:|---:|
| ja-dificil | 7.11 s | 5.81 s | 18.3% | 11.05 → 7.84 GiB |
| ja-musica | 12.18 s | 9.92 s | 18.6% | 11.16 → 7.85 GiB |
| en-conversa | 21.38 s | 18.17 s | 15.0% | 10.62 → 7.84 GiB |
| en-dialogo | 17.06 s | 14.57 s | 14.6% | 11.15 → 7.86 GiB |
| ja-longo | 63.47 s | 59.03 s | 7.0% | 11.20 → 7.92 GiB |

### Entrega da continuação

- Release compilado; gate `motores` passou; regressão `check_wired.py` passou.
- Integração com binário compilado: `fonte ... ja qwenLarge --json ...`,
  otimização padrão, concluiu reconhecimento e geração do SRT de diagnóstico.
- Novo bundle `build/Tradutor Qwen.app` assinado/verificado; `--selftest-srt`
  passou com 16 verificações. Os dois bundles anteriores foram preservados.
- Sem alteração da main nesta etapa: otimização fica na branch
  `codex/qwen-1.7b-performance` para uso e avaliação do build separado.
- Não restam etapas de implementação desta otimização. Ganhos maiores exigem
  outra investigação; as variantes descartadas não entraram no app.
