# LingoSync

Tradução e legendas em tempo real no macOS. Captura o áudio de um aplicativo ou
do microfone, transcreve, traduz e mostra na tela — **tudo local, sem API paga,
sem chave, sem conta**. Os tradutores de rede existem, mas são escolha do
usuário, nunca o padrão.

Alvo: Apple Silicon, macOS 15+. Medido num MacBook Air M5, 16 GB.

---

## O que ele faz

**Painel ao vivo** (⌥⌘T) — escolhe de onde vem o som (um aplicativo, todo o
áudio do sistema ou o microfone) e mostra três zonas: o parcial cru do
reconhecedor, a fala já confirmada e a tradução. Não corta o áudio no meio da
palavra: o trecho é re-reconhecido inteiro a cada 0,6 s e só sobe para a tela o
prefixo em que duas passadas concordam.

**Janela de legendas** — abre um vídeo, gera o `.srt` e deixa assistir com a
legenda ao lado, original e tradução na mesma lista. Dá para importar um `.srt`
pronto, retraduzir sem reconhecer de novo, identificar quem fala (com cor por
locutor) e exportar cada faixa separadamente.

**Item de menu** — gera o `.srt` de um vídeo sem abrir janela nenhuma.

## Requisitos

- Apple Silicon, macOS 15 ou mais recente
- Command Line Tools — **Xcode não é necessário**
- macOS 26 para o tradutor da Apple (a API de sessão direta só existe lá)

## Construir

```bash
swift build -c release
Scripts/bundle.sh TradutorApp "Tradutor" Resources/app-Info.plist release
open build/Tradutor.app
```

O app vive na barra de menus (`LSUIElement`), sem ícone no Dock.

Na primeira vez ele pede **Gravação de Tela e Áudio do Sistema** (para capturar
o áudio de outro aplicativo) e **Microfone**. Negada, a captura não dá erro:
entrega quadros zerados. Um binário aberto pelo terminal nunca consegue essas
permissões — só um `.app` assinado, aberto com `open`.

## Motores

Reconhecimento, escolhido no painel e limitado pelo idioma:

| Motor | Cobertura | Observação |
|---|---|---|
| Apple (padrão) | de, en, es, fr, it, ja, ko, pt, zh | `SpeechAnalyzer` do macOS 26 |
| Parakeet TDT v3 | 10 idiomas europeus | ~120× tempo real |
| Whisper turbo | todos | mais lento, mais amplo |
| Qwen3-ASR 0.6B / 1.7B | 13 e 14 idiomas | fora do processo, **só em vídeo** |

Tradução: **Apple** (padrão, local), **DeepL**, **Google**, **Gemini**,
**Hunyuan-MT-7B** (local, fora do processo) e **Só transcrever**. Todos valem
ao vivo e em vídeo; o painel diz o que cada um custa por bloco antes de você
escolher.

> Os tradutores DeepL, Google e Gemini são dirigidos pela página ou por um
> endereço interno. **Uso automatizado contraria os termos desses sites.** São
> opção consciente do usuário, nunca o padrão.

## Modelos em disco

Baixados no primeiro uso, em `~/Library/Application Support/Tradutor/models/`:
Whisper turbo (1,2 GB), Parakeet (469 MB) e os dois modelos de quem-fala
(13 MB e 243 MB). Qwen (2,2 GB) e Hunyuan (4,5 GB) têm instaladores próprios em
`Scripts/` e só aparecem no seletor quando existem. Depois do primeiro
download, carregar não usa rede.

## Verificação

Não há `swift test`: as Command Line Tools não trazem `XCTest`. As verificações
vivem dentro dos binários, e cada defeito consertado deixa um gate que falha se
ele voltar.

```bash
./.build/release/tradutor-verify frases      # corte em frases, sobreposição
./.build/release/tradutor-verify motores     # limiares, retentativa do ANE
./.build/release/tradutor-verify captura     # lista de captura e de microfones
./.build/release/tradutor-verify srt <video> <orig> <dest> <motor> [--locutores]
```

Sem áudio no argumento os gates não carregam modelo e rodam em milissegundos.

Captura, que precisa de `.app` assinado:

```bash
open "build/Tradutor Probe.app"                    # a captura funciona?
open "build/Tradutor Probe.app" --args isolamento  # a seleção é respeitada?
open "build/Tradutor Probe.app" --args duplo       # app e microfone juntos?
open "build/Tradutor Probe.app" --args variantes   # por que o microfone entrega zero?
```

E o app inteiro, de ponta a ponta:

```bash
open -n build/Tradutor.app --args --selftest-live ja pt
open -n build/Tradutor.app --args --selftest-studio video.mp4 ja pt
open -n build/Tradutor.app --args --selftest-microfone 4
```

## Onde está a documentação de verdade

O [CLAUDE.md](CLAUDE.md) é o registro das decisões e das medições que as
sustentam — por que o áudio não é cortado, por que o Whisper repete a passada
quando ela sai pobre, por que a sobreposição de contexto foi removida, quais
motores foram testados e descartados e com que números. Antes de trocar uma
constante que tem comentário de medição, meça de novo.

## Estrutura

```
Sources/
  AudioCapture/     tap, ring buffer, reamostragem, VAD   (sem dependências)
  TradutorCore/     reconhecimento, tradução, legendas
  TradutorApp/      painel flutuante, janela de legendas, barra de menus
  tradutor-probe/   verificação da captura
  tradutor-verify/  verificação do resto
Scripts/bundle.sh   monta o .app sem Xcode
```

Os vídeos de exemplo e os gabaritos de quem-fala ficam fora do repositório: são
obra de terceiros. Os gates que dependem deles leem de `Videos Exemplo/` no
disco de quem mede.
