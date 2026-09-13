import AppKit
import Foundation
import TradutorCore
import UniformTypeIdentifiers

/// Gera um arquivo `.srt` a partir de um vídeo escolhido pelo usuário.
///
/// Só a interface é daqui — janela de progresso, cancelamento, aviso no fim.
/// Os passos em si são `SubtitleFileBuilder.generate`, os mesmos da janela de
/// legendas, para os dois não voltarem a gerar legendas diferentes.
@MainActor
final class SubtitleJob: NSObject, NSWindowDelegate {

    private let pipeline: Pipeline
    private var window: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var task: Task<Void, Never>?
    private var cancelButton: NSButton?
    private var cancelled = false

    /// Sem alerta no fim, para o autoteste.
    ///
    /// `NSAlert.runModal` segura o laço principal, e o laço do autoteste roda
    /// no `@MainActor`: com o aviso na tela o relatório ficava parado em
    /// "gerando…" para sempre, mesmo com o `.srt` gravado certo. Aconteceu em
    /// duas de quatro execuções — é corrida, e quanto mais lenta a geração,
    /// mais provável.
    var silent = false

    /// O que deu errado, quando `silent` engoliu o alerta.
    private(set) var failure: String?

    /// O que o tradutor avisou no fim, quando avisou.
    private(set) var notice: String?

    /// Sobrepõe quem traduz, só nesta execução.
    ///
    /// Existe para o autoteste escolher o motor sem gravar preferência: a do
    /// usuário mora em `UserDefaults` e teste não mexe em dado de usuário.
    var translation: TranslationEngine?

    init(pipeline: Pipeline) {
        self.pipeline = pipeline
        super.init()
    }

    /// Fechar a janela de progresso é a mesma coisa que cancelar.
    func windowWillClose(_ notification: Notification) {
        guard !cancelled, task != nil else { return }
        cancelled = true
        task?.cancel()
        task = nil
    }

    /// Abre o seletor e começa. Volta imediatamente.
    func run() {
        let panel = NSOpenPanel()
        panel.title = "Escolha o vídeo ou áudio"
        panel.prompt = "Gerar legenda"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // Sem filtro por tipo, de proposito: arquivo sem extensao no nome —
        // download interrompido, midia renomeada, arquivo vindo de outro
        // sistema — ficaria acinzentado por um detalhe que nao diz nada sobre
        // o conteudo. Quem decide se serve e a extracao, olhando os bytes.
        panel.allowsOtherFileTypes = true
        panel.message = "Vídeo ou áudio. Arquivos sem extensão no nome também servem."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(url)
    }

    /// Começa direto num arquivo, sem passar pelo seletor.
    ///
    /// É por aqui que o teste exercita o caminho inteiro — o seletor de
    /// arquivo é a única parte que precisa de alguém clicando.
    func run(_ url: URL) {
        showProgressWindow(for: url)
        task = Task { await process(url) }
    }

    // MARK: - Trabalho

    /// Interrompe tudo e fecha.
    ///
    /// O reconhecimento é uma chamada única e longa que não dá para matar no
    /// meio; o cancelamento garante que o resultado seja descartado, que
    /// nenhuma etapa seguinte comece e que nada seja gravado em disco.
    @objc private func cancel() {
        cancelled = true
        task?.cancel()
        task = nil
        window?.close()
        window = nil
    }

    /// Verdadeiro quando já não faz sentido continuar.
    private var stopped: Bool { cancelled || Task.isCancelled }

    private func process(_ url: URL) async {
        let builder = SubtitleFileBuilder()
        // A janela do DeepL e o servidor do Hunyuan não se fecham sozinhos, e
        // este app fica aberto o dia todo na barra de menus.
        defer { builder.finish() }
        // A lista de termos é por par de idiomas: 納豆 não vira a mesma coisa
        // em inglês e em português.
        builder.glossary = Glossary(
            source: pipeline.sourceLanguage,
            target: pipeline.targetLanguage
        )
        builder.speakerModel = pipeline.speakerModel

        do {
            let translated = try await builder.generate(
                from: url,
                source: pipeline.sourceLanguage,
                target: pipeline.targetLanguage,
                engine: pipeline.recognitionEngine,
                translation: translation ?? pipeline.translationEngine,
                diarize: pipeline.diarizeSpeakers
            ) { [weak self] step, fraction, detail, waiting in
                Task { @MainActor in
                    // Esperando a resposta do tradutor: o rótulo diz o que
                    // está no ar, e as reticências viram "aguardando".
                    let texto = detail.isEmpty
                        ? "\(step.rawValue)…"
                        : "\(step.rawValue): \(detail)\(waiting ? " (aguardando resposta)" : "")"
                    self?.update(step.overall(fraction), texto)
                }
            }

            if stopped { return }
            update(GenerationStep.saving.overall(0), "\(GenerationStep.saving.rawValue)…")
            let output = url
                .deletingPathExtension()
                .appendingPathExtension("\(pipeline.targetLanguage.rawValue).srt")
            try SRTWriter.render(
                translated, colorBySpeaker: pipeline.diarizeSpeakers && pipeline.colorBySpeaker,
                charactersPerLine: builder.charactersPerLine
            ).write(to: output, atomically: true, encoding: .utf8)

            notice = builder.translationNotice
            finish(savedAt: output, cues: translated.count)
        } catch {
            guard !stopped else { return }
            finish(error: error.localizedDescription)
        }
    }

    // MARK: - Janela

    private func showProgressWindow(for url: URL) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Legenda de \(url.lastPathComponent)"
        window.delegate = self          // fechar a janela também cancela
        window.center()
        window.isReleasedWhenClosed = false

        let status = NSTextField(labelWithString: "preparando…")
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingMiddle
        status.frame = NSRect(x: 20, y: 66, width: 380, height: 20)

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 40, width: 380, height: 16))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1

        let cancel = NSButton(title: "Cancelar", target: self, action: #selector(self.cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"        // Esc também cancela
        cancel.frame = NSRect(x: 310, y: 8, width: 90, height: 26)

        window.contentView?.addSubview(status)
        window.contentView?.addSubview(bar)
        window.contentView?.addSubview(cancel)
        window.makeKeyAndOrderFront(nil)
        self.cancelButton = cancel

        self.window = window
        self.statusLabel = status
        self.progressBar = bar
    }

    /// Só para frente: o progresso chega de outras threads, e uma atualização
    /// atrasada faria a barra recuar.
    private func update(_ fraction: Double, _ label: String) {
        guard !stopped, fraction >= (progressBar?.doubleValue ?? 0) else { return }
        progressBar?.doubleValue = fraction
        statusLabel?.stringValue = label
    }

    private func finish(savedAt url: URL, cues: Int) {
        guard !stopped else { return }
        window?.delegate = nil
        window?.close()
        window = nil

        guard !silent else { return }

        let alert = NSAlert()
        alert.messageText = "Legenda pronta"
        // O aviso do tradutor vai junto: é aqui que a troca do DeepL para a
        // Apple no meio do arquivo deixa de ser invisível.
        alert.informativeText = [
            "\(cues) legendas gravadas em \(url.lastPathComponent).", notice,
        ].compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: "Mostrar no Finder")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func finish(error message: String) {
        guard !stopped else { return }
        window?.delegate = nil
        window?.close()
        window = nil
        failure = message
        guard !silent else { return }

        let alert = NSAlert()
        alert.messageText = "Não foi possível gerar a legenda"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
