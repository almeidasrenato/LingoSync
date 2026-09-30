import AppKit
import SwiftUI
import TradutorCore
import UniformTypeIdentifiers

/// Transcrever um arquivo e ler na tela, sem ir buscar o `.txt` no Finder.
///
/// Pedido em 30/09/2026: "tenho um áudio e não consigo escutar agora". Os
/// itens "Só gerar o .srt" e "Só extrair o texto" gravam ao lado do arquivo
/// e avisam; aqui o texto aparece na janela, como no painel ao vivo, e só
/// vai para o disco quando alguém exporta.
///
/// A geração é a mesma `SubtitleFileBuilder.generate` dos outros dois
/// caminhos. A fala reconhecida entra na tela antes da tradução (`onBatch`),
/// e cada lote traduzido substitui o rascunho — é o mais perto do ao vivo
/// que o caminho de arquivo tem sem mexer nos reconhecedores.
@MainActor
@Observable
final class FileTranscriptionModel {

    enum Stage: Equatable {
        case empty, working, done, cancelled
        case failed(String)
    }

    var sourceLanguage: Language
    var targetLanguage: Language
    var recognitionEngine: RecognitionEngine
    var translationEngine: TranslationEngine

    private(set) var stage: Stage = .empty
    private(set) var file: URL?
    private(set) var cues: [Cue] = []
    private(set) var stepLabel = ""
    private(set) var fraction = 0.0
    private(set) var notice: String?
    /// Os motores que rodaram, não os dos seletores: trocar o seletor depois
    /// não pode reescrever o que a tela diz ter feito.
    private(set) var origin = ""
    /// O idioma em que o texto da tela está escrito.
    private(set) var writtenIn: Language?

    /// Legendas com tempo, ou texto corrido. Guardado: quem abre para ler
    /// costuma querer sempre o mesmo.
    enum Layout: Identifiable { case lines, prose; var id: Self { self } }
    var layout: Layout = UserDefaults.standard.bool(forKey: "transcricaoEmTextoCorrido") ? .prose : .lines {
        didSet { UserDefaults.standard.set(layout == .prose, forKey: "transcricaoEmTextoCorrido") }
    }
    var showsProse: Bool { layout == .prose }

    private var task: Task<Void, Never>?
    private var builder: SubtitleFileBuilder?

    init(pipeline: Pipeline) {
        sourceLanguage = pipeline.sourceLanguage
        targetLanguage = pipeline.targetLanguage
        recognitionEngine = pipeline.recognitionEngine
        translationEngine = pipeline.translationEngine
    }

    var isWorking: Bool { stage == .working }
    var translates: Bool { translationEngine != .transcriptionOnly }

    /// O que a linha mostra: a tradução quando já chegou, a fala antes.
    static func display(_ cue: Cue) -> String {
        cue.translated.isEmpty ? cue.source : cue.translated
    }

    var prose: String {
        CaptureExport.prose(cues.map { (Self.display($0), $0.start, $0.end) })
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = L("Escolha o áudio ou vídeo", "Choose an audio or video file")
        panel.prompt = L("Transcrever", "Transcribe")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // Sem filtro por tipo, como no item de menu: quem decide se serve é a
        // extração, olhando os bytes.
        panel.allowsOtherFileTypes = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.transcribe(url) }
        }
    }

    func transcribe(_ url: URL) {
        cancel()
        file = url
        cues = []
        notice = nil
        origin = ""
        fraction = 0
        stepLabel = GenerationStep.extracting.displayName + "…"
        stage = .working
        writtenIn = translationEngine.destination(from: sourceLanguage, to: targetLanguage)
        task = Task { await run(url) }
    }

    func retry() {
        if let file { transcribe(file) }
    }

    func cancel() {
        guard isWorking else { return }
        task?.cancel()
        task = nil
        builder?.finish()
        builder = nil
        stage = .cancelled
    }

    private func run(_ url: URL) async {
        let builder = SubtitleFileBuilder()
        self.builder = builder
        let source = sourceLanguage, target = targetLanguage
        let engine = recognitionEngine, translation = translationEngine
        do {
            let result = try await builder.generate(
                from: url, source: source, target: target,
                engine: engine, translation: translation, diarize: false,
                progress: { [weak self] step, fraction, detail, waiting in
                    Task { @MainActor in self?.advance(step, fraction, detail, waiting) }
                },
                onBatch: { [weak self] partial in
                    Task { @MainActor in
                        guard let self, self.isWorking, self.builder === builder else { return }
                        self.cues = partial
                    }
                })
            guard !Task.isCancelled, self.builder === builder else { return }
            cues = result
            notice = builder.translationNotice
            origin = [builder.recognitionName, translation == .transcriptionOnly ? nil : builder.translationName]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " → ")
            stage = .done
        } catch {
            guard !Task.isCancelled, self.builder === builder else { return }
            stage = .failed(error.localizedDescription)
        }
        builder.finish()
        if self.builder === builder { self.builder = nil }
    }

    /// Só para frente: o progresso chega de outras threads fora de ordem.
    private func advance(_ step: GenerationStep, _ part: Double, _ detail: String, _ waiting: Bool) {
        guard isWorking else { return }
        let overall = step.overall(part)
        guard overall >= fraction else { return }
        fraction = overall
        // O detalhe vai junto: na repetição do Whisper a barra fica cheia, e
        // só "nova passada 2 de 3" diz que a leitura continua.
        stepLabel = waiting
            ? L("\(step.displayName): aguardando resposta", "\(step.displayName): waiting for a reply")
            : detail.isEmpty ? step.displayName + "…" : "\(step.displayName): \(detail)"
    }

    // MARK: Copiar e exportar

    /// Copia o que está na tela, no formato da tela.
    func copy(original: Bool) {
        let field: (Cue) -> String = original ? { $0.source } : { Self.display($0) }
        let text = showsProse
            ? CaptureExport.prose(cues.map { (field($0), $0.start, $0.end) })
            : cues.map(field).filter { !$0.isEmpty }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func export(asSubtitles: Bool) {
        guard let file, let writtenIn else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [asSubtitles ? UTType(filenameExtension: "srt") ?? .plainText : .plainText]
        panel.nameFieldStringValue = file.deletingPathExtension().lastPathComponent
            + ".\(writtenIn.rawValue).\(asSubtitles ? "srt" : "txt")"
        panel.directoryURL = file.deletingLastPathComponent()
        let content = asSubtitles
            ? SRTWriter.render(cues, charactersPerLine: SubtitleFileBuilder.lineWidth(for: writtenIn))
            : prose
        // `begin`, não `runModal`: o modal seguraria o laço principal.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Janela

struct FileTranscriptionView: View {

    @Bindable var model: FileTranscriptionModel
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 14) {
            header
            options
            if model.isWorking { progress }
            banner
            VStack(spacing: 8) {
                if !model.cues.isEmpty { resultActions }
                content
            }
        }
        .padding(18)
        .frame(minWidth: 700, minHeight: 460)
        .background(Color.canvas)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            model.transcribe(url)
            return true
        } isTargeted: { dropping = $0 }
    }

    // MARK: Cabeçalho

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(symbol: "waveform", tint: .sage, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.file?.lastPathComponent ?? L("Transcrever um arquivo", "Transcribe a file"))
                    .font(.heading)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.meta)
                    .foregroundStyle(Color.inkSoft)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if model.file != nil {
                Button {
                    model.chooseFile()
                } label: {
                    Label(L("Outro arquivo…", "Another file…"), systemImage: "folder")
                }
                .buttonStyle(PastelButtonStyle())
                .controlSize(.small)
                .fixedSize()
                .help(L("Escolher outro áudio ou vídeo. Soltar um arquivo na janela também serve.",
                        "Choose another audio or video. Dropping a file on the window works too."))
            }
        }
    }

    private var subtitle: String {
        switch model.stage {
        case .empty: return L("Áudio ou vídeo, lido aqui mesmo. Nada é gravado até você exportar.",
                              "Audio or video, read right here. Nothing is saved until you export.")
        case .working: return L("Transcrevendo…", "Transcribing…")
        case .cancelled: return L("Cancelado", "Cancelled")
        case .failed: return L("Não terminou", "Did not finish")
        case .done:
            let falas = L("\(model.cues.count) falas", "\(model.cues.count) lines")
            return [model.origin, falas, model.cues.last.map { Self.clock($0.end) }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    private var resultActions: some View {
        HStack(spacing: 6) {
            PillSegmented(title: L("Mostrar como", "Show as"),
                          selection: $model.layout,
                          options: [.lines, .prose],
                          label: { $0 == .prose ? L("Texto", "Text") : L("Falas", "Lines") })
            .fixedSize()
            .help(L("Falas com o tempo de cada uma, ou o texto corrido para ler e copiar",
                    "Lines with their times, or running text to read and copy"))
            Spacer(minLength: 8)

            if let spoken = spokenLanguage {
                copyButton(spoken, original: true)
            }
            if model.translates, let written = model.writtenIn, written != spokenLanguage {
                copyButton(written, original: false)
            }

            Menu {
                Button(L("Texto corrido (.txt)…", "Running text (.txt)…")) { model.export(asSubtitles: false) }
                Button(L("Legenda com tempos (.srt)…", "Timed subtitles (.srt)…")) { model.export(asSubtitles: true) }
            } label: {
                Label(L("Exportar", "Export"), systemImage: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(PastelButtonStyle())
            .controlSize(.small)
            .fixedSize()
            .disabled(model.isWorking)
            .help(L("Gravar o que está na tela", "Save what is on screen"))
        }
    }

    /// O idioma da fala da transcrição que está na tela.
    private var spokenLanguage: Language? {
        guard model.file != nil, !model.cues.isEmpty else { return nil }
        return model.translates ? model.sourceLanguage : model.writtenIn
    }

    /// `⧉ PT`: o código diz qual dos dois, sem passar o mouse.
    private func copyButton(_ language: Language, original: Bool) -> some View {
        Button {
            model.copy(original: original)
        } label: {
            Label(language.rawValue.uppercased(), systemImage: "doc.on.doc")
        }
        .buttonStyle(PastelButtonStyle())
        .controlSize(.small)
        .fixedSize()
        .help(L("Copiar tudo em \(language.displayName)", "Copy everything in \(language.displayName)"))
    }

    // MARK: Opções

    private var options: some View {
        HStack(alignment: .bottom, spacing: 10) {
            labeled(L("Reconhecimento", "Recognition")) {
                EnginePicker(selection: $model.recognitionEngine)
            }
            labeled(L("Idioma falado", "Spoken language")) {
                SourceLanguagePicker(selection: $model.sourceLanguage,
                                     engine: model.recognitionEngine, width: 124)
            }
            labeled(L("Tradução", "Translation")) {
                TranslationEnginePicker(selection: $model.translationEngine)
            }
            labeled(L("Traduzir para", "Translate to")) {
                PillPicker(title: L("Idioma da tradução", "Translation language"),
                           selection: $model.targetLanguage,
                           options: Language.allCases, label: \.displayName, width: 124)
                .disabled(!model.translates)
            }
            Spacer(minLength: 0)
            if model.file != nil, !model.isWorking {
                Button {
                    model.retry()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(CircleButtonStyle())
                .accessibilityLabel(L("Transcrever de novo", "Transcribe again"))
                .help(L("Refaz com os motores e idiomas escolhidos agora",
                        "Runs again with the engines and languages chosen now"))
            }
        }
        .disabled(model.isWorking)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
                .lineLimit(1)
                .fixedSize()
            content()
        }
    }

    // MARK: Progresso e avisos

    private var progress: some View {
        HStack(spacing: 10) {
            ProgressView(value: model.fraction)
                .progressViewStyle(.linear)
                .tint(Color.brandInk)
            Text(model.stepLabel)
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
                .lineLimit(1)
                .frame(minWidth: 180, alignment: .leading)
            Button(L("Cancelar", "Cancel")) { model.cancel() }
                .buttonStyle(PastelButtonStyle())
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var banner: some View {
        if case let .failed(message) = model.stage {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("Tentar novamente", "Try again")) { model.retry() }
                    .buttonStyle(PastelButtonStyle())
                    .controlSize(.small)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if let notice = model.notice {
            Text(notice)
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Conteúdo

    private var content: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Group {
            if model.cues.isEmpty {
                emptyState
            } else if model.showsProse {
                proseView
            } else {
                linesView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropping ? Color.brandSoft : Color.card, in: shape)
        .overlay(shape.strokeBorder(dropping ? Color.brandInk : Color.hairline,
                                    lineWidth: dropping ? 2 : 1))
        .animation(.easeOut(duration: 0.15), value: dropping)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            switch model.stage {
            case .working:
                ProgressView().controlSize(.small)
                Text(L("A fala aparece aqui assim que for reconhecida.",
                       "Speech shows up here as soon as it is recognized."))
                    .font(.control)
                    .foregroundStyle(Color.inkSoft)
            default:
                Image(systemName: dropping ? "arrow.down.circle.fill" : "waveform.badge.plus")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.brandInk)
                    .symbolRenderingMode(.hierarchical)
                Text(dropping ? L("Pode soltar", "Drop it") : L("Solte um áudio ou vídeo aqui", "Drop an audio or video file here"))
                    .font(.heading)
                    .foregroundStyle(Color.ink)
                Text(model.stage == .done
                     ? L("Nenhuma fala reconhecida neste arquivo.", "No speech was recognized in this file.")
                     : L("A transcrição aparece nesta janela, com a tradução se houver tradutor escolhido.",
                         "The transcript appears in this window, translated if a translator is chosen."))
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
                Button {
                    model.chooseFile()
                } label: {
                    Label(L("Escolher arquivo…", "Choose file…"), systemImage: "folder")
                }
                .buttonStyle(PastelButtonStyle(prominent: true))
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
                .padding(.top, 4)
            }
        }
        .padding(24)
    }

    private var linesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.cues.indices, id: \.self) { index in
                        line(model.cues[index])
                            .id(index)
                    }
                }
                .padding(.vertical, 8)
            }
            // Como no painel ao vivo: enquanto chega texto, a tela acompanha.
            .onChange(of: model.cues.count) {
                guard model.isWorking, let last = model.cues.indices.last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private func line(_ cue: Cue) -> some View {
        let pending = model.translates && cue.translated.isEmpty
        let shown = FileTranscriptionModel.display(cue)
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(Self.clock(cue.start))
                .font(.meta.monospacedDigit())
                .foregroundStyle(Color.inkSoft)
                .frame(width: 46, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(shown)
                    .font(.system(size: 14))
                    .foregroundStyle(pending ? Color.inkSoft : Color.ink)
                // O original, apagado, em toda fala: conferir tradução contra
                // original é o uso, como na lista da janela de legendas.
                if !pending, model.translates, cue.source != shown {
                    Text(cue.source)
                        .font(.caption)
                        .foregroundStyle(Color.inkSoft)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var proseView: some View {
        ScrollView {
            Text(model.prose)
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(Color.ink)
                .textSelection(.enabled)
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
        }
    }

    /// `1:05` ou `1:02:05`: o relógio de quem ouve, não o timecode do `.srt`.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
