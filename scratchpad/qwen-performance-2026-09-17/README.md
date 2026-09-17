# Qwen3-ASR 1.7B — ponto de retomada, 17/09/2026

## Estado entregue

- `main`: `08322a1`, correções de importação/exportação de SRT. Inclui `1e6ac0c`.
- Build independente: `build/Tradutor Legendas.app`, assinado e verificado.
- A instância original (PID 2183) e `build/Tradutor.app` foram preservados.
- Não existe remoto Git configurado; a main é local.
- Branch de pesquisa: `codex/qwen-1.7b-performance`.
- **Nenhuma otimização do Qwen foi aprovada ou ativada.** O padrão continua com
  os mesmos pesos, precisão float16, áudio, segmentação e alinhador.
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
`measure.py` compara normal e sincronização rápida no caminho inteiro do app;
essa comparação não congela o WAV entre execuções.

## Pendente

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
