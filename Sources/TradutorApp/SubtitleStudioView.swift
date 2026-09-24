import AVFoundation
import AVKit
import SwiftUI
import TradutorCore
import UniformTypeIdentifiers

/// Superfície de vídeo.
///
/// Usa `AVPlayerView` do AppKit em vez do `VideoPlayer` do SwiftUI. O
/// `VideoPlayer` aborta ao instanciar seu metadata genérico neste app —
/// `getSuperclassMetadata` em `_AVKit_SwiftUI`, morte imediata assim que um
/// vídeo era escolhido. O `AVPlayerView` é a mesma coisa por baixo, sem a
/// camada genérica que quebra.
struct PlayerSurface: NSViewRepresentable {

    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        // Os controles são os da janela; os nativos duplicariam tudo e ainda
        // cobririam a legenda.
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Avalia o conteúdo no corpo de uma view própria.
///
/// Com `@Observable`, quem lê uma propriedade é redesenhado quando ela muda.
/// O tempo atual muda dez vezes por segundo e era lido no corpo da janela
/// inteira, então a lista de legendas era refeita junto a cada décimo de
/// segundo — a navegação engasgava. Lido aqui dentro, só este pedaço redesenha.
private struct Isolated<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: Content { content() }
}

/// Janela de legendas: escolher o vídeo, gerar a legenda, assistir com ela e
/// navegar clicando nas falas.
struct SubtitleStudioView: View {

    @Bindable var model: SubtitleStudioModel
    @State var showsGenerationOptions = false

    /// A largura da lista quando o arrasto do divisor começou.
    ///
    /// `DragGesture` entrega `translation` **acumulada** desde o início do
    /// gesto, não o passo desde o último evento. Somando-a à largura atual a
    /// cada evento, arrastar 12 px deslocava 22 e o efeito acelerava: o
    /// divisor ia ao limite quase imediatamente. O que se soma é a largura de
    /// onde o arrasto partiu.
    @State private var larguraAoComecarArrasto: CGFloat?

    /// Largura útil da linha inteira, para o divisor não parar antes da borda.
    /// O limite em si é do modelo, onde dá para conferir sem desenhar nada.
    @State private var larguraDaLinha: CGFloat = 0

    private func limitar(_ largura: CGFloat) -> CGFloat {
        SubtitleStudioModel.clampListWidth(largura, available: larguraDaLinha)
    }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 10) {
                    cueListHeader
                    failureBanner
                    cueList
                    if isWorking { Isolated { progressPanel } }
                    Isolated { transport }
                }
                .frame(width: model.showsVideo ? model.listWidth : nil)
                .frame(maxWidth: model.showsVideo ? nil : .infinity)

                if model.showsVideo {
                    divider
                    videoArea
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { largura in
                larguraDaLinha = largura
                // Encolher a janela com a lista larga deixava o vídeo com
                // alguns pixels: o teto novo vale na hora.
                let ajustada = limitar(model.listWidth)
                if ajustada != model.listWidth { model.listWidth = ajustada }
            }
        }
        .padding(14)
        // Largura mínima com folga para o seletor de reconhecimento e o +.
        .frame(minWidth: 1080, minHeight: 640)
        .background(
            // Atalhos: espaço reproduz, setas andam de legenda em legenda —
            // que é como se lê uma conversa —, e ⌘← e ⌘→ andam 5 s no tempo,
            // para quando o que se procura está no meio de uma fala longa.
            Group {
                Button("") { model.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { model.jumpToPreviousCue() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { model.jumpToNextCue() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { model.skip(by: -5) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("") { model.skip(by: 5) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("") { model.toggleMute() }
                    .keyboardShortcut("m", modifiers: [])
                Button("") { model.showsVideo.toggle() }
                    .keyboardShortcut("v", modifiers: [])
                Button("") { model.volume = min(1, model.volume + 0.1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { model.volume = max(0, model.volume - 0.1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button("") { model.resizeSubtitles(by: -1) }
                    .keyboardShortcut("-", modifiers: [])
                Button("") { model.resizeSubtitles(by: 1) }
                    .keyboardShortcut("=", modifiers: [])
                Button("") { model.resizeSubtitles(by: 1) }
                    .keyboardShortcut("+", modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        )
    }

    // MARK: Topo

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(model.videoName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.videoName)
                    .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                Button(action: pickVideo) { Label("Abrir vídeo", systemImage: "folder") }
                Button(action: loadSRT) { Label("Importar SRT", systemImage: "square.and.arrow.down") }
                    .disabled(isWorking)
                Button(action: exportSRT) { Label("Exportar SRT", systemImage: "square.and.arrow.up") }
                    .disabled(model.cues.isEmpty)
                Button { showsGenerationOptions.toggle() } label: {
                    Label("Opções", systemImage: showsGenerationOptions ? "chevron.up" : "slider.horizontal.3")
                }
                .accessibilityValue(showsGenerationOptions ? "Expandidas" : "Recolhidas")
                .help("Idiomas, modelos e tradução. Clique para expandir ou recolher.")
                // A fonte do texto à vista, não dentro de "Opções": o cabeçalho
                // abre recolhido, e escolha escondida ninguém acha — a lição dos
                // controles de locutor.
                Picker("Fonte do texto", selection: $model.textSource) {
                    ForEach(SubtitleStudioModel.TextSource.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(isWorking)
                .help("De onde vem o texto: da fala, reconhecendo o áudio, ou da imagem, "
                      + "lendo a legenda que já está desenhada no vídeo")
                if readsImage, model.player != nil {
                    Button { model.drawsImageArea.toggle() } label: {
                        Label("Área", systemImage: model.imageArea == nil ? "rectangle.dashed" : "rectangle.inset.filled")
                    }
                    .disabled(isWorking)
                    // Esc desliga o desenho pelo próprio botão: o vídeo não
                    // tem foco de teclado para receber a tecla.
                    .keyboardShortcut(model.drawsImageArea ? KeyboardShortcut.cancelAction : nil)
                    .help(model.drawsImageArea
                          ? "Arraste sobre o vídeo em volta da legenda. Esc cancela."
                          : "Desenhar onde a legenda aparece. Sem área, lê a faixa de baixo do vídeo.")
                    if model.imageArea != nil {
                        Button { model.imageArea = nil } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .disabled(isWorking)
                        .accessibilityLabel("Área padrão")
                        .help("Voltar à área padrão: a faixa de baixo do vídeo")
                    }
                }
                Button {
                    showsGenerationOptions = false
                    model.generate()
                } label: {
                    Label(readsImage ? "Ler legenda" : "Gerar legenda",
                          systemImage: readsImage ? "text.viewfinder" : "text.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canGenerate)
                Button { model.showsVideo.toggle() } label: {
                    Image(systemName: model.showsVideo ? "sidebar.right" : "rectangle")
                }
                .accessibilityLabel(model.showsVideo ? "Ocultar vídeo" : "Mostrar vídeo")
                .help(model.showsVideo ? "Ocultar vídeo (V)" : "Mostrar vídeo (V)")
            }
            .controlSize(.regular)

            if showsGenerationOptions {
                Divider()
                HStack(alignment: .bottom, spacing: 14) {
                    if readsImage {
                        // O idioma do texto na tela, que não é o falado — e a
                        // lista é a do leitor de texto, não a do reconhecimento.
                        VStack(alignment: .leading, spacing: 5) {
                            toolbarCaption("Idioma do texto")
                            ImageLanguagePicker(selection: $model.imageLanguage, width: 108)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            toolbarCaption("Reconhecimento")
                            EnginePicker(selection: $model.recognitionEngine)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            toolbarCaption("Idioma original")
                            SourceLanguagePicker(selection: $model.sourceLanguage,
                                                 engine: model.recognitionEngine, width: 108)
                        }
                    }
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                    VStack(alignment: .leading, spacing: 5) {
                        toolbarCaption("Traduzir para")
                        Picker("Idioma da tradução", selection: $model.targetLanguage) {
                            ForEach(Language.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 108)
                        .disabled(model.translationEngine == .transcriptionOnly)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        toolbarCaption("Tradução")
                        TranslationEnginePicker(selection: $model.translationEngine)
                    }
                    if !readsImage, model.recognitionEngine.supportsDiarization {
                        Menu {
                            Toggle("Identificar quem fala", isOn: $model.diarizeSpeakers)
                            Picker("Modelo de vozes", selection: $model.speakerModel) {
                                ForEach(SpeakerDiarizer.Model.allCases) { Text($0.displayName).tag($0) }
                            }
                            .disabled(!model.diarizeSpeakers)
                            Toggle("Uma cor por locutor", isOn: $model.colorBySpeaker)
                                .disabled(!model.diarizeSpeakers)
                        } label: {
                            Image(systemName: model.diarizeSpeakers ? "person.2.wave.2.fill" : "person.2.wave.2")
                        }
                        .fixedSize()
                        .accessibilityLabel("Identificação de locutores")
                        .help("Identificação, modelo e cores dos locutores")
                    }
                    Spacer(minLength: 8)
                    if model.duration > 0, !isWorking, !readsImage {
                        Label(TranslatorFactory.estimate(forVideoOf: model.duration, using: model.translationEngine),
                              systemImage: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        showsGenerationOptions = false
                        model.retranslate()
                    } label: {
                        Label("Traduzir", systemImage: "character.bubble")
                    }
                    .disabled(!model.canRetranslate)
                    .help(readsImage
                          ? "Traduz o texto lido da imagem, sem ler o vídeo de novo e sem mudar os tempos"
                          : "Traduz o original com o tradutor escolhido, sem reconhecer o áudio novamente")
                }
                .disabled(isWorking)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let aviso = model.notice, !isWorking {
                Label(aviso, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private func toolbarCaption(_ title: String) -> some View {
        Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
    }

    private var cueListHeader: some View {
        HStack(spacing: 6) {
            Text("Legendas")
                .font(.system(size: 11, weight: .semibold))
            if !model.cues.isEmpty {
                Text("\(model.cues.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
            // Quem fez o que está na tela. Os motores que rodaram, não os
            // dos seletores: trocar o seletor não muda a legenda que já saiu,
            // e o Parakeet vira Whisper em idioma que ele não cobre.
            if let origem = model.origin {
                // Lido da imagem e ainda sem tradução, não há seta para nada.
                Text(origem.translation.isEmpty
                     ? origem.recognition : "\(origem.recognition) → \(origem.translation)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help((origem.recognition == BurnedSubtitle.engineName
                           ? "Lido da imagem" : "Reconhecido por \(origem.recognition)")
                          + (origem.translation.isEmpty ? "" : ", traduzido por \(origem.translation)"))
            }
            Spacer()
            if model.isPartial {
                Text("parcial")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
            } else if model.loadedFromFile {
                Label("de arquivo", systemImage: "doc")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Lista de legendas

    private var cueList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.cues.enumerated()), id: \.element.index) { position, cue in
                        cueRow(cue, position: position)
                            .id(cue.index)
                    }
                    if model.cues.isEmpty { emptyList }
                    if model.isPartial {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("traduzindo o resto…")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 6)
                    }
                }
                .padding(8)
            }
            // Acompanha o vídeo sozinho: sem isto a legenda atual sai de vista
            // em poucos segundos e a lista deixa de servir para localizar.
            .onChange(of: model.activeIndex) { _, new in
                guard let new, model.cues.indices.contains(new) else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(model.cues[new].index, anchor: .center)
                }
            }
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .frame(maxHeight: .infinity)
    }

    /// A cor do locutor, quando o usuário pediu cor.
    ///
    /// As mesmas quatro da legenda oculta de TV que vão para o `.srt`, então
    /// a janela e o arquivo mostram a mesma pessoa da mesma cor.
    private func speakerColor(_ cue: Cue) -> Color? {
        guard model.diarizeSpeakers, model.colorBySpeaker,
              let index = SpeakerPalette.index(for: cue.speaker)
        else { return nil }
        let rgb = SpeakerPalette.components[index]
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// A mesma cor, mas legível sobre a lista.
    ///
    /// O primeiro locutor é branco — é a convenção sobre vídeo e é o que vai
    /// para o `.srt`. Só que a lista tem fundo claro, e branco ali é
    /// invisível: conferido no PNG, a barra do Locutor 1 saía em
    /// (255,255,255) sobre (249,249,249). Na lista ele usa a cor de destaque
    /// do sistema; no vídeo continua branco.
    private func listSpeakerColor(_ cue: Cue) -> Color? {
        guard let color = speakerColor(cue) else { return nil }
        return SpeakerPalette.index(for: cue.speaker) == 0 ? Color.accentColor : color
    }

    private func cueRow(_ cue: Cue, position: Int) -> some View {
        let isActive = model.activeIndex == position
        let isPast = (model.activeIndex ?? Int.max) > position

        return Button {
            model.jump(to: position)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                // Barra de cor: diz de relance onde a reprodução está. Cheia
                // na legenda no ar, apagada no que já passou, vazia no que
                // ainda vem.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isActive
                          ? AnyShapeStyle(listSpeakerColor(cue) ?? Color.accentColor)
                          : AnyShapeStyle(isPast
                                          ? (listSpeakerColor(cue)?.opacity(0.5)
                                             ?? Color.secondary.opacity(0.28))
                                          : (listSpeakerColor(cue)?.opacity(0.35) ?? Color.clear)))
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(SRTWriter.timecode(cue.start).dropFirst(3).prefix(5))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        if isActive {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(Color.accentColor)
                        }
                        Spacer(minLength: 0)
                        Text("\(position + 1)")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.quaternary)
                    }

                    Text(model.displayText(at: position))
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive
                                         ? AnyShapeStyle(.primary)
                                         : AnyShapeStyle(.secondary))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    // O original em todas as falas, não só na que está no ar:
                    // é ele que se quer conferir contra a tradução, e ter de
                    // reproduzir a legenda para ver o original tirava a lista
                    // de serviço. Apagado, para a tradução continuar sendo o
                    // que se lê primeiro.
                    if !cue.source.isEmpty, !cue.translated.isEmpty, cue.source != cue.translated {
                        Text(cue.source)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 9)
            .background(
                isActive ? Color.accentColor.opacity(0.13) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ir para \(SRTWriter.timecode(cue.start).prefix(8))")
    }

    /// A falha, dita em voz alta, com o botão de tentar de novo.
    ///
    /// Faixa própria em vez do aviso de uma linha da barra de cima: quando a
    /// tradução caía para outro motor, o aviso passava despercebido e a
    /// legenda saía com duas qualidades dentro. Hoje a tradução falha inteira
    /// — não há tradutor de reserva — e isto é o que aparece no lugar.
    @ViewBuilder
    private var failureBanner: some View {
        if let message = model.failureMessage {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Tentar novamente") { model.retryFailed() }
                    .controlSize(.small)
                    .disabled(!model.canGenerate)
                    .help(model.canRetranslate
                          ? "Refaz só a tradução, sem reconhecer o áudio nem ler o vídeo de novo"
                          : (readsImage ? "Lê a legenda de novo" : "Gera a legenda de novo"))
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(.red.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private var emptyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.stage {
            case .empty:
                Text("Escolha um vídeo para começar.")
            case .ready:
                Text(readsImage ? "Vídeo carregado. Clique em Ler legenda."
                                : "Vídeo carregado. Clique em Gerar legenda.")
            case .working:
                EmptyView()          // o painel de progresso cuida disso
            case .failed:
                // A faixa acima da lista já diz o que houve, e traz o botão.
                EmptyView()
            case .cancelled:
                Text(readsImage ? "Leitura cancelada." : "Geração cancelada.")
            case .done:
                Text("Nenhuma legenda gerada.")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(6)
    }

    /// Divisor arrastável entre a lista e o vídeo.
    ///
    /// Aumentar o vídeo aumenta a legenda junto, porque ela é desenhada sobre
    /// ele e o corpo da fonte acompanha a largura.
    private var divider: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 12)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.quaternary)
                    .frame(width: 3, height: 34)
            )
            .contentShape(Rectangle())
            // Cursor pelo sistema, não por `NSCursor.push`/`pop` na mão: os
            // dois não se equilibram quando o ponteiro sai do divisor no meio
            // do arrasto — que é o que acontece em todo arrasto rápido — e a
            // seta ficava presa em redimensionar, ou voltava a ser seta com o
            // arrasto ainda em curso.
            .pointerStyle(.columnResize)
            .gesture(
                // `minimumDistance: 0`: com os 10 px do padrão, o primeiro
                // evento já chega com 10 px de deslocamento acumulado e o
                // divisor pulava esse tanto antes de começar a acompanhar o
                // ponteiro.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let base = larguraAoComecarArrasto ?? model.listWidth
                        if larguraAoComecarArrasto == nil { larguraAoComecarArrasto = base }
                        model.listWidth = limitar(base + value.translation.width)
                    }
                    .onEnded { _ in larguraAoComecarArrasto = nil }
            )
            // Duplo clique volta ao tamanho de fábrica: é o que um divisor de
            // painel faz em todo lugar, e sai mais barato que caçar o valor.
            .onTapGesture(count: 2) { model.listWidth = SubtitleStudioModel.defaultListWidth }
            .help("Arraste para redimensionar o vídeo")
    }

    // MARK: Progresso

    @ViewBuilder
    private var progressPanel: some View {
        if case let .working(step) = model.stage {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(step.kind.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(Int(step.overall * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: step.overall)

                // Enquanto a requisição está no ar não há progresso para
                // relatar: o tradutor devolve o lote inteiro de uma vez. A
                // barra fica onde está — o que muda é o giro ao lado do
                // rótulo, que diz que não travou.
                if !step.detail.isEmpty || step.waiting {
                    HStack(spacing: 5) {
                        if step.waiting {
                            ProgressView().controlSize(.mini)
                        }
                        Text(step.waiting ? "\(step.detail) · aguardando" : step.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(step.kind == .readingImage
                          ? "Na primeira vez o sistema prepara o leitor de texto, e isso leva alguns segundos"
                          : step.waiting
                          ? "O tradutor do sistema responde o lote inteiro de uma vez, sem passos no meio"
                          : step.detail)
                }

                // Os quatro passos em miniatura: dizem onde o trabalho está
                // sem precisar ler nada. A leitura da imagem é passo único.
                if step.kind != .readingImage { HStack(spacing: 3) {
                    ForEach(Self.stepOrder, id: \.self) { kind in
                        Capsule()
                            .fill(
                                kind == step.kind ? Color.accentColor
                                    : (step.kind.share.lowerBound > kind.share.lowerBound
                                       ? Color.accentColor.opacity(0.35)
                                       : Color.secondary.opacity(0.18))
                            )
                            .frame(height: 3)
                    }
                } }

                HStack {
                    Text(Self.clock(model.elapsed))
                        .font(.system(size: 10, design: .monospaced))
                    Spacer()
                    if let remaining = model.estimatedRemaining {
                        Text("faltam ~\(Self.clock(remaining))")
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
                .foregroundStyle(.tertiary)

                Button(role: .destructive) {
                    model.cancelGeneration()
                } label: {
                    Label("Cancelar", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1)
            )
        }
    }

    /// Sem "Gravando o arquivo": a janela não grava, só exporta. E sem a
    /// leitura da imagem, que não é passo da geração pela fala.
    private static let stepOrder = GenerationStep.allCases.filter { $0 != .saving && $0 != .readingImage }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Controles

    private var transport: some View {
        VStack(spacing: 9) {
            // Barra de posição, com as legendas marcadas: dá para ver onde há
            // fala e onde há silêncio antes de arrastar.
            timeline

            HStack(spacing: 6) {
                controlButton("gobackward.10", "Voltar 10 s") { model.skip(by: -10) }
                controlButton(
                    model.isPlaying ? "pause.fill" : "play.fill",
                    model.isPlaying ? "Pausar" : "Reproduzir",
                    prominent: true
                ) { model.togglePlay() }
                controlButton("goforward.10", "Avançar 10 s") { model.skip(by: 10) }
            }

            // Controle separado, pedido à parte: anda de fala em fala, não de
            // tempo em tempo. Cai sempre no instante em que a legenda começa.
            HStack(spacing: 6) {
                controlButton("backward.end.alt.fill", "Legenda anterior") {
                    model.jumpToPreviousCue()
                }
                Text("legenda")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                controlButton("forward.end.alt.fill", "Próxima legenda") {
                    model.jumpToNextCue()
                }
            }
            .disabled(model.cues.isEmpty)

            HStack(spacing: 6) {
                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: volumeSymbol)
                        .font(.system(size: 11))
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(model.isMuted ? "Tirar do mudo" : "Silenciar")

                Slider(value: $model.volume, in: 0...1)
                    .controlSize(.mini)
                    .frame(maxWidth: .infinity)
                    .help("Volume")
            }
            .foregroundStyle(.secondary)
            .disabled(model.player == nil)

            HStack(spacing: 8) {
                Text(SRTWriter.timecode(model.currentTime).prefix(8))
                    .font(.system(size: 10, design: .monospaced))
                Text("/")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                Text(SRTWriter.timecode(model.duration).prefix(8))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Spacer()

                Picker("", selection: $model.rate) {
                    Text("0,75×").tag(Float(0.75))
                    Text("1×").tag(Float(1.0))
                    Text("1,25×").tag(Float(1.25))
                    Text("1,5×").tag(Float(1.5))
                }
                .labelsHidden()
                .frame(width: 72)
                .controlSize(.small)
                .help("Velocidade de reprodução")

                if let active = model.activeIndex {
                    Text("\(active + 1)/\(model.cues.count)")
                        .font(.system(size: 10, design: .monospaced))
                } else if !model.cues.isEmpty {
                    Text("—/\(model.cues.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    /// Barra de posição com as legendas desenhadas como marcas.
    ///
    /// Desenhada em `Canvas`, não com uma view por legenda. Num vídeo de
    /// dezoito minutos são 160 marcas, e 160 views recriadas dez vezes por
    /// segundo — que é a frequência do observador de tempo — deixavam a
    /// interface pesada justamente enquanto a geração já estava consumindo a
    /// máquina. O `Canvas` desenha tudo num passe só, sem identidade de view
    /// por item.
    private var timeline: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = model.duration
            let progress = model.progress

            Canvas { context, size in
                let midY = size.height / 2
                let track = CGRect(x: 0, y: midY - 2.5, width: size.width, height: 5)
                context.fill(
                    Path(roundedRect: track, cornerRadius: 2.5),
                    with: .color(.secondary.opacity(0.25))
                )

                // Onde há fala: mostra de relance a distribuição do diálogo.
                if duration > 0 {
                    for cue in model.cues {
                        let x = cue.start / duration * size.width
                        let w = max(1.5, (cue.end - cue.start) / duration * size.width)
                        context.fill(
                            Path(roundedRect: CGRect(x: x, y: midY - 2.5, width: w, height: 5),
                                 cornerRadius: 2.5),
                            with: .color(.accentColor.opacity(0.3))
                        )
                    }
                }

                let played = CGRect(x: 0, y: midY - 2.5,
                                    width: max(2, progress * size.width), height: 5)
                context.fill(
                    Path(roundedRect: played, cornerRadius: 2.5),
                    with: .color(.accentColor)
                )

                let knobX = max(5, min(size.width - 5, progress * size.width))
                context.fill(
                    Path(ellipseIn: CGRect(x: knobX - 5, y: midY - 5, width: 10, height: 10)),
                    with: .color(.accentColor)
                )
            }
            .frame(height: 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.seek(toProgress: Double(value.location.x / width), exact: false)
                    }
                    .onEnded { value in
                        model.seek(toProgress: Double(value.location.x / width))
                    }
            )
        }
        .frame(height: 12)
        .disabled(model.player == nil)
    }

    private var volumeSymbol: String {
        if model.isMuted || model.volume == 0 { return "speaker.slash.fill" }
        if model.volume < 0.34 { return "speaker.wave.1.fill" }
        if model.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func controlButton(
        _ symbol: String,
        _ help: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 16 : 13))
                .frame(width: prominent ? 40 : 32, height: 26)
        }
        .buttonStyle(.bordered)
        .help(help)
        .disabled(model.player == nil)
    }

    // MARK: Vídeo

    private var videoArea: some View {
        GeometryReader { geometry in
            videoStack(width: geometry.size.width)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private func videoStack(width: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if let player = model.player {
                PlayerSurface(player: player)
                    .onTapGesture { model.togglePlay() }
                if readsImage { ImageAreaOverlay(model: model, player: player) }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.85))
                    .overlay(
                        Text("Nenhum vídeo carregado")
                            .foregroundStyle(.white.opacity(0.4))
                            .font(.system(size: 13))
                    )
            }

            if let active = model.activeIndex, model.cues.indices.contains(active) {
                subtitleOverlay(at: active, width: width)
                    .padding(.bottom, max(24, width * 0.06))
                    .padding(.horizontal, 24)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.player != nil { subtitleSizeControl }
        }
    }

    /// Menor e maior, com o tamanho atual no meio — clicar nele volta a 100%.
    private var subtitleSizeControl: some View {
        let range = SubtitleStudioModel.subtitleScaleRange
        return HStack(spacing: 0) {
            Button { model.resizeSubtitles(by: -1) } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .disabled(model.subtitleScale <= range.lowerBound)
            .help("Diminuir a legenda  (−)")

            Button { model.subtitleScale = SubtitleStudioModel.defaultSubtitleScale } label: {
                Text("\(Int((model.subtitleScale * 100).rounded()))%")
                    .font(.system(size: 9.5, design: .monospaced))
                    .frame(width: 36, height: 22)
                    .contentShape(Rectangle())
            }
            .help("Voltar ao tamanho padrão (\(Int(SubtitleStudioModel.defaultSubtitleScale * 100))%)")

            Button { model.resizeSubtitles(by: 1) } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .disabled(model.subtitleScale >= range.upperBound)
            .help("Aumentar a legenda  (+)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.9))
        .background(.black.opacity(0.5), in: Capsule())
        .padding(10)
    }

    private func subtitleOverlay(at index: Int, width: CGFloat) -> some View {
        let cue = model.cues[index]
        // A legenda cresce com o vídeo: num painel estreito 21 pt cobre metade
        // da imagem, e num largo some. A escala do usuário vem por cima, fora
        // do teto de 34 pt — senão "aumentar" num vídeo largo não faria nada.
        let corpo = min(34, max(14, width * 0.026)) * model.subtitleScale
        return VStack(spacing: 4) {
            ForEach(model.displayLines(at: index), id: \.self) { line in
                Text(line)
                    .font(.system(size: corpo, weight: .semibold))
                    // Branco continua sendo a cor do primeiro locutor e a de
                    // quem não pediu cor.
                    .foregroundStyle(speakerColor(cue) ?? .white)
                    // Sombra dupla: legenda tem que ler sobre qualquer quadro,
                    // claro ou escuro.
                    .shadow(color: .black.opacity(0.95), radius: 2, y: 1)
                    .shadow(color: .black.opacity(0.6), radius: 6)
            }
            if !cue.source.isEmpty, !cue.translated.isEmpty, cue.source != cue.translated {
                Text(cue.source)
                    .font(.system(size: max(9, corpo * 0.5)))
                    .foregroundStyle(.white.opacity(0.62))
                    .shadow(color: .black.opacity(0.9), radius: 2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 9))
        .animation(.easeOut(duration: 0.15), value: cue.index)
    }

    // MARK: Auxiliares

    private var isWorking: Bool { model.isWorking }

    private var readsImage: Bool { model.textSource == .image }

    private func loadSRT() {
        let panel = NSOpenPanel()
        panel.title = "Abrir legenda"
        panel.prompt = "Abrir"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.message = "Arquivo .srt"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let track = chooseSubtitleTrack(
            title: "O que este SRT contém?",
            message: "Importar substitui apenas a faixa escolhida e mantém a outra. Original e tradução aparecem juntos pelos tempos do vídeo. Não inicia tradução automática."
        ) else { return }
        model.loadSubtitles(from: url, as: track)
    }

    private func exportSRT() {
        guard !model.cues.isEmpty else { return }

        guard let track = chooseSubtitleTrack(
            title: "O que deseja exportar?",
            message: "Escolha entre as falas no idioma original e a tradução.",
            originalAvailable: model.canExport(.original),
            translationAvailable: model.canExport(.translation)
        ) else { return }

        let panel = NSSavePanel()
        panel.title = "Exportar legenda"
        panel.prompt = "Exportar"
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = model.suggestedSRTName(for: track)
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(to: url, track: track)
    }

    private func chooseSubtitleTrack(
        title: String, message: String, originalAvailable: Bool = true,
        translationAvailable: Bool = true
    ) -> SubtitleStudioModel.SubtitleTrack? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let original = alert.addButton(
            withTitle: SubtitleStudioModel.SubtitleTrack.original.displayName)
        original.isEnabled = originalAvailable
        let translation = alert.addButton(withTitle: SubtitleStudioModel.SubtitleTrack.translation.displayName)
        translation.isEnabled = translationAvailable
        alert.addButton(withTitle: "Cancelar")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .original
        case .alertSecondButtonReturn: return .translation
        default: return nil
        }
    }

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.title = "Escolha o vídeo"
        panel.prompt = "Abrir"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // Mesmo critério da geração de SRT: quem julga o formato é a extração,
        // olhando os bytes, não a extensão do nome.
        panel.allowsOtherFileTypes = true
        panel.message = "Vídeo ou áudio. Arquivos sem extensão no nome também servem."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.open(url)
    }
}

/// A área onde a legenda desenhada é lida, sobre o vídeo, e o arrasto que a
/// desenha.
///
/// O retângulo é o do **quadro**, não o da view: o player mostra em
/// `.resizeAspect`, com tarja preta em volta, e a área é normalizada ao
/// quadro — senão a mesma área leria lugares diferentes conforme a janela.
private struct ImageAreaOverlay: View {
    @Bindable var model: SubtitleStudioModel
    let player: AVPlayer
    @State private var dragging: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let size = player.currentItem?.presentationSize ?? .zero
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let video = size.width > 0 && size.height > 0
                ? AVMakeRect(aspectRatio: size, insideRect: bounds) : bounds
            ZStack(alignment: .topLeading) {
                if model.drawsImageArea {
                    Color.black.opacity(0.25)
                    // A faixa padrão, apagada, para quem desenha ver o que
                    // estaria trocando.
                    frame(BurnedSubtitle.defaultArea, in: video)
                        .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                if let area = dragging ?? model.imageArea.map({ denormalized($0, in: video) }) {
                    Rectangle()
                        .path(in: area)
                        .stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
            .contentShape(Rectangle())
            .allowsHitTesting(model.drawsImageArea)
            .gesture(
                // `startLocation` e `location`, não o deslocamento somado —
                // a armadilha do divisor.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = CGRect(p1: clamp(value.startLocation, to: video),
                                          p2: clamp(value.location, to: video))
                    }
                    .onEnded { value in
                        let drawn = CGRect(p1: clamp(value.startLocation, to: video),
                                           p2: clamp(value.location, to: video))
                        dragging = nil
                        model.drawsImageArea = false
                        // Clique sem arrasto não apaga a área que já havia.
                        guard drawn.width >= video.width * 0.02, drawn.height >= video.height * 0.02 else { return }
                        model.imageArea = CGRect(
                            x: (drawn.minX - video.minX) / video.width,
                            y: (drawn.minY - video.minY) / video.height,
                            width: drawn.width / video.width,
                            height: drawn.height / video.height)
                    }
            )
            .pointerStyle(model.drawsImageArea ? .rectSelection : nil)
        }
    }

    private func frame(_ area: CGRect, in video: CGRect) -> Path {
        Rectangle().path(in: denormalized(area, in: video))
    }

    private func denormalized(_ area: CGRect, in video: CGRect) -> CGRect {
        CGRect(x: video.minX + area.minX * video.width, y: video.minY + area.minY * video.height,
               width: area.width * video.width, height: area.height * video.height)
    }

    private func clamp(_ point: CGPoint, to video: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, video.minX), video.maxX), y: min(max(point.y, video.minY), video.maxY))
    }
}

private extension CGRect {
    init(p1: CGPoint, p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }
}
