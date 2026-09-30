import AppKit
import SwiftUI
import TradutorCore

/// Renderização de QA sem capturar áudio, carregar modelos ou mudar preferências.
@MainActor
enum LayoutPreview {
    static func run() async {
        let folder = URL(fileURLWithPath: "/tmp/tradutor-layout", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pipeline = Pipeline()
        let model = SubtitleStudioModel()
        model.sourceLanguage = .portuguese
        model.targetLanguage = .english
        model.recognitionEngine = .qwenLarge
        model.translationEngine = .gemini
        var report = ""
        func render<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat?, dark: Bool) async {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor))
                .preferredColorScheme(dark ? .dark : .light))
            let size = NSSize(width: width, height: height ?? host.fittingSize.height)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = host
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(200))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: folder.appendingPathComponent(name + ".png"))
                report += "\(name): \(Int(host.bounds.width)) × \(Int(host.bounds.height))\n"
            }
            window.close()
        }
        // Com uma versão nova à vista, para o botão de atualizar sair no quadro.
        let updates = UpdateChecker()
        updates.available = AppUpdate.Release(
            version: "9.9.9", page: AppUpdate.repository, diskImage: nil)
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            await render(SettingsView(pipeline: pipeline, updates: updates, onRefresh: {}, onToggle: {},
                onResetPanel: {}, onMakeSubtitles: {}, onMakeText: {}, onOpenStudio: {}, onNewStudio: {}),
                "menu-\(mode)", width: 372, height: nil, dark: dark)
            await render(SubtitleStudioView(model: model), "studio-empty-\(mode)",
                         width: 1080, height: 700, dark: dark)
        }
        let fixture = folder.appendingPathComponent("exemplo.srt")
        try? SRTWriter.render([
            Cue(index: 1, start: 0, end: 3, source: "Olá! Vamos conferir as legendas deste vídeo."),
            Cue(index: 2, start: 4, end: 7, source: "Você pode importar o original e traduzir quando quiser."),
            Cue(index: 3, start: 8, end: 12, source: "Os controles de arquivos, idiomas e geração agora têm seu próprio espaço.")
        ]).write(to: fixture, atomically: true, encoding: .utf8)
        model.loadSubtitles(from: fixture, as: .original)
        let translation = folder.appendingPathComponent("translation.srt")
        try? SRTWriter.render([
            Cue(index: 1, start: 0, end: 3, source: "Hello! Let's check the subtitles for this video."),
            Cue(index: 2, start: 4, end: 7, source: "You can import both tracks in either order."),
            Cue(index: 3, start: 8, end: 12, source: "Generation settings can be collapsed to give the video more room.")
        ]).write(to: translation, atomically: true, encoding: .utf8)
        model.loadSubtitles(from: translation, as: .translation)
        for dark in [false, true] {
            await render(SubtitleStudioView(model: model), "studio-filled-\(dark ? "dark" : "light")",
                         width: 1080, height: 700, dark: dark)
            await render(SubtitleStudioView(model: model, showsGenerationOptions: true),
                         "studio-expanded-\(dark ? "dark" : "light")",
                         width: 1080, height: 700, dark: dark)
        }
        for text in ["A conversa fica guardada no histórico.", "Agora os controles estão mais fáceis de encontrar."] {
            pipeline.subtitles.commit(SubtitleBlock(source: "Sample source text.", translated: text))
        }
        // Preferências do painel num domínio à parte: teste não escreve no
        // do usuário.
        let painel = UserDefaults(suiteName: "tradutor-layout-preview")!
        painel.removePersistentDomain(forName: "tradutor-layout-preview")
        for width: CGFloat in [380, 620] {
            await render(OverlayView(pipeline: pipeline, onClose: {}).defaultAppStorage(painel),
                         "live-\(Int(width))", width: width, height: 300, dark: true)
        }
        pipeline.subtitles.setPartial("e isto ainda está sendo captado")
        painel.set(true, forKey: "painelEmTextoCorrido")
        painel.set(0.5, forKey: "opacidadeDoFundoDoPainel")
        await render(OverlayView(pipeline: pipeline, onClose: {}).defaultAppStorage(painel),
                     "live-texto-620", width: 620, height: 300, dark: true)
        painel.removePersistentDomain(forName: "tradutor-layout-preview")
        model.stop()
        try? report.write(to: folder.appendingPathComponent("layout.txt"), atomically: true, encoding: .utf8)
        print(report)
        exit(0)
    }
}
