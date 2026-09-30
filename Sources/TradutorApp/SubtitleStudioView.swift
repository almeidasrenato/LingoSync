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
        .background(Color.canvas)
        .buttonStyle(PastelButtonStyle())
        .tint(.brandInk)
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
                    .font(.controlStrong)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.videoName)
                    .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                Button(action: pickVideo) { Label(L("Abrir vídeo", "Open video"), systemImage: "folder") }
                Button(action: loadSRT) { Label(L("Importar SRT", "Import SRT"), systemImage: "square.and.arrow.down") }
                    .disabled(isWorking)
                Button(action: exportSRT) { Label(L("Exportar SRT", "Export SRT"), systemImage: "square.and.arrow.up") }
                    .disabled(model.cues.isEmpty)
                Button { showsGenerationOptions.toggle() } label: {
                    Label(L("Opções", "Options"), systemImage: showsGenerationOptions ? "chevron.up" : "slider.horizontal.3")
                }
                .accessibilityValue(showsGenerationOptions ? L("Expandidas", "Expanded") : L("Recolhidas", "Collapsed"))
                .help(L("Idiomas, modelos e tradução. Clique para expandir ou recolher.", "Languages, models and translation. Click to expand or collapse."))
                // A fonte do texto à vista, não dentro de "Opções": o cabeçalho
                // abre recolhido, e escolha escondida ninguém acha — a lição dos
                // controles de locutor.
                PillSegmented(title: L("Fonte do texto", "Text source"), selection: $model.textSource,
                              options: SubtitleStudioModel.TextSource.allCases, label: \.displayName)
                .fixedSize()
                .disabled(isWorking)
                .help(L("De onde vem o texto: da fala, reconhecendo o áudio, ou da imagem, ", "Where the text comes from: speech, by recognizing the audio, or the image, ")
                      + L("lendo a legenda que já está desenhada no vídeo", "by reading the subtitle already burned into the video"))
                if readsImage, model.player != nil {
                    Button { model.drawsImageArea.toggle() } label: {
                        Label(L("Área", "Area"), systemImage: model.imageArea == nil ? "rectangle.dashed" : "rectangle.inset.filled")
                    }
                    .disabled(isWorking)
                    // Esc desliga o desenho pelo próprio botão: o vídeo não
                    // tem foco de teclado para receber a tecla.
                    .keyboardShortcut(model.drawsImageArea ? KeyboardShortcut.cancelAction : nil)
                    .help(model.drawsImageArea
                          ? L("Arraste sobre o vídeo em volta da legenda. Esc cancela.", "Drag over the video around the subtitle. Esc cancels.")
                          : L("Desenhar onde a legenda aparece. Sem área, lê a faixa de baixo do vídeo.", "Draw where the subtitle appears. Without an area, the bottom strip of the video is read."))
                    if model.imageArea != nil {
                        Button { model.imageArea = nil } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .disabled(isWorking)
                        .accessibilityLabel(L("Área padrão", "Default area"))
                        .help(L("Voltar à área padrão: a faixa de baixo do vídeo", "Back to the default area: the bottom strip of the video"))
                    }
                }
                Button {
                    showsGenerationOptions = false
                    model.generate()
                } label: {
                    Label(readsImage ? L("Ler legenda", "Read subtitles") : L("Gerar legenda", "Generate"),
                          systemImage: readsImage ? "text.viewfinder" : "text.badge.plus")
                }
                .buttonStyle(PastelButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canGenerate)
                Button { model.showsVideo.toggle() } label: {
                    Image(systemName: model.showsVideo ? "sidebar.right" : "rectangle")
                }
                .accessibilityLabel(model.showsVideo ? L("Ocultar vídeo", "Hide video") : L("Mostrar vídeo", "Show video"))
                .help(model.showsVideo ? L("Ocultar vídeo (V)", "Hide video (V)") : L("Mostrar vídeo (V)", "Show video (V)"))
            }
            .controlSize(.regular)

            if showsGenerationOptions {
                Divider()
                HStack(alignment: .bottom, spacing: 14) {
                    if readsImage {
                        // O idioma do texto na tela, que não é o falado — e a
                        // lista é a do leitor de texto, não a do reconhecimento.
                        VStack(alignment: .leading, spacing: 5) {
                            toolbarCaption(L("Idioma do texto", "Text language"))
                            ImageLanguagePicker(selection: $model.imageLanguage, width: 124)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            toolbarCaption(L("Reconhecimento", "Recognition"))
                            EnginePicker(selection: $model.recognitionEngine)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            toolbarCaption(L("Idioma original", "Spoken language"))
                            SourceLanguagePicker(selection: $model.sourceLanguage,
                                                 engine: model.recognitionEngine, width: 124)
                        }
                    }
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.inkSoft)
                        .padding(.bottom, 8)
                    VStack(alignment: .leading, spacing: 5) {
                        toolbarCaption(L("Traduzir para", "Translate to"))
                        PillPicker(title: L("Idioma da tradução", "Translation language"), selection: $model.targetLanguage,
                                   options: Language.allCases, label: \.displayName, width: 124)
                        .disabled(model.translationEngine == .transcriptionOnly)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        toolbarCaption(L("Tradução", "Translation"))
                        TranslationEnginePicker(selection: $model.translationEngine)
                    }
                    if !readsImage, model.recognitionEngine.supportsDiarization {
                        Menu {
                            Toggle(L("Identificar quem fala", "Identify speakers"), isOn: $model.diarizeSpeakers)
                            Picker(L("Modelo de vozes", "Voice model"), selection: $model.speakerModel) {
                                ForEach(SpeakerDiarizer.Model.allCases) { Text($0.displayName).tag($0) }
                            }
                            .disabled(!model.diarizeSpeakers)
                            Toggle(L("Uma cor por locutor", "One color per speaker"), isOn: $model.colorBySpeaker)
                                .disabled(!model.diarizeSpeakers)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: model.diarizeSpeakers ? "person.2.wave.2.fill" : "person.2.wave.2")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.brandInk)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(Color.brandInk)
                                    .frame(width: 18, height: 18)
                                    .background(Color.brandSoft, in: Circle())
                            }
                            .padding(.leading, 10)
                            .padding(.trailing, 5)
                            .frame(height: 28)
                            .background(Color.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel(L("Identificação de locutores", "Speaker identification"))
                        .help(L("Identificação, modelo e cores dos locutores", "Speaker identification, model and colors"))
                    }
                    Spacer(minLength: 8)
                    if model.duration > 0, !isWorking, !readsImage {
                        Label(TranslatorFactory.estimate(forVideoOf: model.duration, using: model.translationEngine),
                              systemImage: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.inkSoft)
                    }
                    Button {
                        showsGenerationOptions = false
                        model.retranslate()
                    } label: {
                        Label(L("Traduzir", "Translate"), systemImage: "character.bubble")
                    }
                    .disabled(!model.canRetranslate)
                    .help(readsImage
                          ? L("Traduz o texto lido da imagem, sem ler o vídeo de novo e sem mudar os tempos", "Translates the text read from the image, without reading the video again or moving any timing")
                          : L("Traduz o original com o tradutor escolhido, sem reconhecer o áudio novamente", "Translates the original with the chosen translator, without recognizing the audio again"))
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
        .padding(4)
        .cardSurface()
    }

    private func toolbarCaption(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(Color.inkSoft)
    }

    private var cueListHeader: some View {
        HStack(spacing: 6) {
            Text(L("Legendas", "Subtitles"))
                .font(.heading)
                .foregroundStyle(Color.ink)
            if !model.cues.isEmpty {
                Text("\(model.cues.count)")
                    .font(.meta.weight(.medium).monospacedDigit())
                    .foregroundStyle(Color.brandInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.brandSoft, in: Capsule())
            }
            // Quem fez o que está na tela. Os motores que rodaram, não os
            // dos seletores: trocar o seletor não muda a legenda que já saiu,
            // e o Parakeet vira Whisper em idioma que ele não cobre.
            if let origem = model.origin {
                // Lido da imagem e ainda sem tradução, não há seta para nada.
                Text(origem.translation.isEmpty
                     ? origem.recognition : "\(origem.recognition) → \(origem.translation)")
                    .font(.meta)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help((origem.recognition == BurnedSubtitle.engineName
                           ? L("Lido da imagem", "Read from the image") : L("Reconhecido por \(origem.recognition)", "Recognized by \(origem.recognition)"))
                          + (origem.translation.isEmpty ? "" : L(", traduzido por \(origem.translation)", ", translated by \(origem.translation)")))
            }
            Spacer()
            if model.isPartial {
                Text(L("parcial", "partial"))
                    .font(.meta.weight(.medium))
                    .foregroundStyle(.orange)
            } else if model.loadedFromFile {
                Label(L("de arquivo", "from file"), systemImage: "doc")
                    .font(.meta)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(Color.inkSoft)
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
                            Text(L("traduzindo o resto…", "translating the rest…"))
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
        .cardSurface()
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
        return SpeakerPalette.index(for: cue.speaker) == 0 ? Color.brandInk : color
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
                          ? AnyShapeStyle(listSpeakerColor(cue) ?? Color.brandInk)
                          : AnyShapeStyle(isPast
                                          ? (listSpeakerColor(cue)?.opacity(0.5)
                                             ?? Color.secondary.opacity(0.28))
                                          : (listSpeakerColor(cue)?.opacity(0.35) ?? Color.clear)))
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(SRTWriter.timecode(cue.start).dropFirst(3).prefix(5))
                            .font(.meta.monospacedDigit())
                            .foregroundStyle(isActive ? AnyShapeStyle(Color.brandInk) : AnyShapeStyle(.tertiary))
                        if isActive {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.brandInk)
                        }
                        Spacer(minLength: 0)
                        Text("\(position + 1)")
                            .font(.meta.monospacedDigit())
                            .foregroundStyle(.quaternary)
                    }

                    Text(model.displayText(at: position))
                        .font(isActive ? .controlStrong : .control)
                        .foregroundStyle(isActive
                                         ? AnyShapeStyle(.primary)
                                         : AnyShapeStyle(Color.inkSoft))
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
                            .foregroundStyle(Color.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 9)
            .background(
                isActive ? Color.brandSoft : .clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Ir para \(SRTWriter.timecode(cue.start).prefix(8))", "Go to \(SRTWriter.timecode(cue.start).prefix(8))"))
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
                Button(L("Tentar novamente", "Try again")) { model.retryFailed() }
                    .controlSize(.small)
                    .disabled(!model.canGenerate)
                    .help(model.canRetranslate
                          ? L("Refaz só a tradução, sem reconhecer o áudio nem ler o vídeo de novo", "Redoes only the translation, without recognizing the audio or reading the video again")
                          : (readsImage ? L("Lê a legenda de novo", "Reads the subtitles again") : L("Gera a legenda de novo", "Generates the subtitles again")))
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var emptyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.stage {
            case .empty:
                Text(L("Escolha um vídeo para começar.", "Choose a video to start."))
            case .ready:
                Text(readsImage ? L("Vídeo carregado. Clique em Ler legenda.", "Video loaded. Click Read subtitles.")
                                : L("Vídeo carregado. Clique em Gerar legenda.", "Video loaded. Click Generate."))
            case .working:
                EmptyView()          // o painel de progresso cuida disso
            case .failed:
                // A faixa acima da lista já diz o que houve, e traz o botão.
                EmptyView()
            case .cancelled:
                Text(readsImage ? L("Leitura cancelada.", "Reading cancelled.") : L("Geração cancelada.", "Generation cancelled."))
            case .done:
                Text(L("Nenhuma legenda gerada.", "No subtitles generated."))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.inkSoft)
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
            .help(L("Arraste para redimensionar o vídeo", "Drag to resize the video"))
    }

    // MARK: Progresso

    @ViewBuilder
    private var progressPanel: some View {
        if case let .working(step) = model.stage {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(step.kind.displayName)
                        .font(.captionStrong)
                    Spacer()
                    Text("\(Int(step.overall * 100))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.inkSoft)
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
                        Text(step.waiting ? L("\(step.detail) · aguardando", "\(step.detail) · waiting") : step.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.inkSoft)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(step.kind == .readingImage
                          ? L("Na primeira vez o sistema prepara o leitor de texto, e isso leva alguns segundos", "The first time, the system prepares the text reader, which takes a few seconds")
                          : step.waiting
                          ? L("O tradutor do sistema responde o lote inteiro de uma vez, sem passos no meio", "The system translator answers the whole batch at once, with no steps in between")
                          : step.detail)
                }

                // Os quatro passos em miniatura: dizem onde o trabalho está
                // sem precisar ler nada. A leitura da imagem é passo único.
                if step.kind != .readingImage { HStack(spacing: 3) {
                    ForEach(Self.stepOrder, id: \.self) { kind in
                        Capsule()
                            .fill(
                                kind == step.kind ? Color.brandInk
                                    : (step.kind.share.lowerBound > kind.share.lowerBound
                                       ? Color.brandInk.opacity(0.35)
                                       : Color.secondary.opacity(0.18))
                            )
                            .frame(height: 3)
                    }
                } }

                HStack {
                    Text(Self.clock(model.elapsed))
                        .font(.system(size: 10).monospacedDigit())
                    Spacer()
                    if let remaining = model.estimatedRemaining {
                        Text(L("faltam ~\(Self.clock(remaining))", "~\(Self.clock(remaining)) left"))
                            .font(.system(size: 10).monospacedDigit())
                    }
                }
                .foregroundStyle(.tertiary)

                Button(role: .destructive) {
                    model.cancelGeneration()
                } label: {
                    Label(L("Cancelar", "Cancel"), systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
            .padding(10)
            .cardSurface()
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
                controlButton("gobackward.10", L("Voltar 10 s", "Back 10 s")) { model.skip(by: -10) }
                controlButton(
                    model.isPlaying ? "pause.fill" : "play.fill",
                    model.isPlaying ? L("Pausar", "Pause") : L("Reproduzir", "Play"),
                    prominent: true
                ) { model.togglePlay() }
                controlButton("goforward.10", L("Avançar 10 s", "Forward 10 s")) { model.skip(by: 10) }
            }

            // Controle separado, pedido à parte: anda de fala em fala, não de
            // tempo em tempo. Cai sempre no instante em que a legenda começa.
            HStack(spacing: 6) {
                controlButton("backward.end.alt.fill", L("Legenda anterior", "Previous subtitle")) {
                    model.jumpToPreviousCue()
                }
                Text(L("legenda", "subtitle"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.inkSoft)
                    .frame(maxWidth: .infinity)
                controlButton("forward.end.alt.fill", L("Próxima legenda", "Next subtitle")) {
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
                .help(model.isMuted ? L("Tirar do mudo", "Unmute") : L("Silenciar", "Mute"))

                Slider(value: $model.volume, in: 0...1)
                    .controlSize(.mini)
                    .frame(maxWidth: .infinity)
                    .help(L("Volume", "Volume"))
            }
            .foregroundStyle(Color.inkSoft)
            .disabled(model.player == nil)

            HStack(spacing: 8) {
                Text(SRTWriter.timecode(model.currentTime).prefix(8))
                    .font(.system(size: 10).monospacedDigit())
                Text("/")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                Text(SRTWriter.timecode(model.duration).prefix(8))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)

                Spacer()

                PillPicker(title: L("Velocidade", "Speed"), selection: $model.rate,
                           options: [Float(0.75), 1.0, 1.25, 1.5],
                           label: { $0 == 1 ? "1×" : "\($0.formatted(.number.locale(Interface.shared.language.locale)))×" },
                           width: 74)
                .controlSize(.small)
                .help(L("Velocidade de reprodução", "Playback speed"))

                if let active = model.activeIndex {
                    Text("\(active + 1)/\(model.cues.count)")
                        .font(.system(size: 10).monospacedDigit())
                } else if !model.cues.isEmpty {
                    Text("—/\(model.cues.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(Color.inkSoft)
        }
        .padding(10)
        .padding(2)
        .cardSurface()
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
                    with: .color(Color.hairline)
                )

                // Onde há fala: mostra de relance a distribuição do diálogo.
                if duration > 0 {
                    for cue in model.cues {
                        let x = cue.start / duration * size.width
                        let w = max(1.5, (cue.end - cue.start) / duration * size.width)
                        context.fill(
                            Path(roundedRect: CGRect(x: x, y: midY - 2.5, width: w, height: 5),
                                 cornerRadius: 2.5),
                            with: .color(Color.brandInk.opacity(0.3))
                        )
                    }
                }

                let played = CGRect(x: 0, y: midY - 2.5,
                                    width: max(2, progress * size.width), height: 5)
                context.fill(
                    Path(roundedRect: played, cornerRadius: 2.5),
                    with: .color(Color.brandInk)
                )

                let knobX = max(5, min(size.width - 5, progress * size.width))
                context.fill(
                    Path(ellipseIn: CGRect(x: knobX - 5, y: midY - 5, width: 10, height: 10)),
                    with: .color(Color.brandInk)
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
                .font(.system(size: prominent ? 17 : 13, weight: .semibold))
        }
        .buttonStyle(CircleButtonStyle(prominent: prominent))
        .accessibilityLabel(help)
        .help(help)
        .disabled(model.player == nil)
    }

    // MARK: Vídeo

    private var videoArea: some View {
        GeometryReader { geometry in
            videoStack(width: geometry.size.width)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func videoStack(width: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if let player = model.player {
                PlayerSurface(player: player)
                    .onTapGesture { model.togglePlay() }
                if readsImage { ImageAreaOverlay(model: model, player: player) }
            } else {
                Rectangle()
                    // Mais escuro que o fundo nos dois temas: no escuro,
                    // o cinza do vídeo vazio sumia contra a janela.
                    .fill(Color(hex: 0x121411))
                    .overlay(
                        Text(L("Nenhum vídeo carregado", "No video loaded"))
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
            .help(L("Diminuir a legenda  (−)", "Smaller subtitles  (−)"))

            Button { model.subtitleScale = SubtitleStudioModel.defaultSubtitleScale } label: {
                Text("\(Int((model.subtitleScale * 100).rounded()))%")
                    .font(.meta.monospacedDigit())
                    .frame(width: 36, height: 22)
                    .contentShape(Rectangle())
            }
            .help(L("Voltar ao tamanho padrão (\(Int(SubtitleStudioModel.defaultSubtitleScale * 100))%)", "Back to default size (\(Int(SubtitleStudioModel.defaultSubtitleScale * 100))%)"))

            Button { model.resizeSubtitles(by: 1) } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .disabled(model.subtitleScale >= range.upperBound)
            .help(L("Aumentar a legenda  (+)", "Bigger subtitles  (+)"))
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
        panel.title = L("Abrir legenda", "Open subtitles")
        panel.prompt = L("Abrir", "Open")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.message = L("Arquivo .srt", ".srt file")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let track = chooseSubtitleTrack(
            title: L("O que este SRT contém?", "What does this SRT contain?"),
            message: L("Importar substitui apenas a faixa escolhida e mantém a outra. Original e tradução aparecem juntos pelos tempos do vídeo. Não inicia tradução automática.", "Importing replaces only the chosen track and keeps the other. Original and translation show together by the video's timing. It does not start translating.")
        ) else { return }
        model.loadSubtitles(from: url, as: track)
    }

    private func exportSRT() {
        guard !model.cues.isEmpty else { return }

        guard let track = chooseSubtitleTrack(
            title: L("O que deseja exportar?", "What do you want to export?"),
            message: L("Escolha entre as falas no idioma original e a tradução.", "Choose between the lines in the original language and the translation."),
            originalAvailable: model.canExport(.original),
            translationAvailable: model.canExport(.translation)
        ) else { return }

        let panel = NSSavePanel()
        panel.title = L("Exportar legenda", "Export subtitles")
        panel.prompt = L("Exportar", "Export")
        // Legenda ou texto corrido; o menu de formato do painel troca a
        // extensão, e é por ela que `export` decide.
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText, .plainText]
        panel.showsContentTypes = true
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
        alert.addButton(withTitle: L("Cancelar", "Cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .original
        case .alertSecondButtonReturn: return .translation
        default: return nil
        }
    }

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.title = L("Escolha o vídeo", "Choose the video")
        panel.prompt = L("Abrir", "Open")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // Mesmo critério da geração de SRT: quem julga o formato é a extração,
        // olhando os bytes, não a extensão do nome.
        panel.allowsOtherFileTypes = true
        panel.message = L("Vídeo ou áudio. Arquivos sem extensão no nome também servem.", "Video or audio. Files without an extension work too.")

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
