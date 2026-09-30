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
        // O motor de tradução do Pipeline é preferência gravada: a do
        // usuário volta no fim, antes do `exit`.
        let motorDoUsuario = pipeline.translationEngine
        pipeline.translationEngine = .apple
        pipeline.sourceLanguage = .japanese
        pipeline.targetLanguage = .english
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
        // Uma reunião de verdade, para o print servir de divulgação.
        for (source, text) in [
            ("来週の打ち合わせ、火曜日で大丈夫ですか？", "Does Tuesday work for next week's meeting?"),
            ("はい、午後なら空いています。", "Yes, I'm free in the afternoon."),
            ("資料は前日までに送りますね。", "I'll send the materials the day before."),
        ] {
            pipeline.subtitles.commit(SubtitleBlock(source: source, translated: text))
        }
        pipeline.subtitles.setPartial("それと、会議室の予約も")
        // Preferências do painel num domínio à parte: teste não escreve no
        // do usuário.
        let painel = UserDefaults(suiteName: "tradutor-layout-preview")!
        painel.removePersistentDomain(forName: "tradutor-layout-preview")
        for width: CGFloat in [380, 620] {
            await render(OverlayView(pipeline: pipeline, onClose: {}).defaultAppStorage(painel),
                         "live-\(Int(width))", width: width, height: 300, dark: true)
        }
        // Texto corrido: um ditado em inglês, só transcrevendo, com uma
        // pausa longa que abre parágrafo.
        pipeline.translationEngine = .transcriptionOnly
        pipeline.sourceLanguage = .english
        pipeline.subtitles.clear()
        let inicio = Date()
        for (offset, text) in [
            (0.0, "Okay, quick recap of today's call."),
            (3.0, "We agreed to ship the beta on Friday."),
            (7.0, "Marina will handle the release notes, and I'll update the onboarding screens."),
            (25.0, "Next week we'll review the feedback from the first users."),
        ] {
            pipeline.subtitles.commit(SubtitleBlock(
                source: text, translated: text, at: inicio.addingTimeInterval(offset)))
        }
        pipeline.subtitles.setPartial("and decide what goes into version two")
        painel.set(true, forKey: "painelEmTextoCorrido")
        await render(OverlayView(pipeline: pipeline, onClose: {}).defaultAppStorage(painel),
                     "live-texto-620", width: 620, height: 300, dark: true)
        painel.removePersistentDomain(forName: "tradutor-layout-preview")
        pipeline.translationEngine = motorDoUsuario
        model.stop()
        try? report.write(to: folder.appendingPathComponent("layout.txt"), atomically: true, encoding: .utf8)
        print(report)
        exit(0)
    }
}
