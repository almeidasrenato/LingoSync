import AppKit
import AudioCapture
import SwiftUI
import TradutorCore

/// Relatorio de autoteste: acumula linhas, grava a cada escrita e conta as
/// falhas.
///
/// Eram cinco copias de `write` e quatro de `expect` soltas dentro dos
/// autotestes, identicas menos pelo caminho do arquivo. Gravar a cada linha
/// e de proposito: o autoteste termina em `exit()`, e o que ja passou
/// precisa estar no disco quando ele terminar.
final class SelfTestReport {
    private let path: String
    private var lines: [String]
    private(set) var failures = 0

    init(_ path: String, _ title: String) {
        self.path = path
        lines = ["\(title)  \(Date().formatted(date: .abbreviated, time: .standard))"]
    }

    func write(_ text: String) {
        lines.append(text)
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    func expect(_ condition: Bool, _ label: String) {
        write(condition ? "  ok    \(label)" : "  FALHA \(label)")
        if !condition { failures += 1 }
    }
}

/// App de barra de menus, sem icone no Dock (LSUIElement no Info.plist).
///
/// O painel de traducao so existe enquanto a traducao esta ativa: desligou,
/// some. E por isso que ele e criado e destruido no toggle, e nao escondido.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private let pipeline = Pipeline()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    /// Criado uma vez e reaproveitado. Trocar o controller a cada abertura
    /// fazia o popover usar um tamanho velho e sobrar espaco abaixo do icone.
    private var popoverHost: NSHostingController<SettingsView>!
    private var panel: OverlayPanel?
    private var hotKey: GlobalHotKey?
    private var subtitleJob: SubtitleJob?
    /// As janelas de legendas abertas, cada uma com o seu modelo.
    ///
    /// O dicionario e quem retem as duas coisas: a janela nao e `released`
    /// ao fechar, e o modelo so vive enquanto a view existir. `windowWillClose`
    /// tira a chave e o par inteiro cai junto.
    private var studios: [NSWindow: SubtitleStudioModel] = [:]
    /// Sempre crescente, so para numerar o titulo. Reaproveitar o numero de
    /// uma janela fechada daria duas "Legendas 2" ao mesmo tempo.
    private var studioCounter = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest-gemini") {
            Task { await GeminiCheck.run() }
            return
        }
        if CommandLine.arguments.contains("--selftest-layout") {
            Task { await LayoutPreview.run() }
            return
        }
        if CommandLine.arguments.contains("--selftest-srt") {
            Task { await SubtitleIOCheck.run() }
            return
        }
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "captions.bubble", accessibilityDescription: "Tradutor"
        )
        statusItem.button?.toolTip = "Tradutor Instantâneo"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover = NSPopover()
        popover.behavior = .transient

        pipeline.refreshProcesses()
        popoverHost = NSHostingController(rootView: makeSettingsView())
        // Sem isto o popover fica com a altura fixa que for definida em
        // contentSize, independente do conteudo — e o painel aparece
        // descolado do icone, com uma faixa vazia embaixo.
        popoverHost.sizingOptions = [.preferredContentSize]
        popover.contentViewController = popoverHost

        hotKey = GlobalHotKey { [weak self] in
            self?.toggleTranslation()
        }

        // Carrega os modelos em segundo plano assim que o app abre. Sao
        // segundos de disco que ninguem deveria esperar depois de apertar
        // o atalho.
        //
        // A faxina vem antes, e síncrona: ela solta a compilação velha dos
        // modelos, e tem que terminar antes de qualquer coisa carregar
        // modelo — inclusive os testes abaixo, que começam a gerar na hora.
        // Rodando em paralelo, ela apagava a compilação recém-gravada. É
        // barata: a parte cara (apagar) vai para segundo plano.
        CacheCleanup.run()
        Task { [pipeline] in await pipeline.preload() }

        // Verificacao do tamanho do popover sem precisar de clique.
        if ProcessInfo.processInfo.environment["TRADUTOR_MEASURE_POPOVER"] != nil {
            measurePopoverAndExit()
        }

        // Teste ponta a ponta do app real, sem depender de clique nem de
        // atalho:  open build/Tradutor.app --args --selftest-live
        if CommandLine.arguments.contains("--selftest-live") {
            runLiveSelfTest()
        }

        // Exercita o item de menu "Gerar legenda de um video" sem ninguem
        // clicar:  open build/Tradutor.app --args --selftest-job <video> ja pt
        if let index = CommandLine.arguments.firstIndex(of: "--selftest-job"),
           CommandLine.arguments.count > index + 1 {
            let arguments = CommandLine.arguments
            runSubtitleJobSelfTest(
                path: arguments[index + 1],
                source: arguments.count > index + 2
                    ? Language(rawValue: arguments[index + 2]) ?? .japanese : .japanese,
                target: arguments.count > index + 3
                    ? Language(rawValue: arguments[index + 3]) ?? .portuguese : .portuguese
            )
        }

        // Confere que o microfone capta de verdade:
        //   open -n build/Tradutor.app --args --selftest-microfone [segundos]
        if let index = CommandLine.arguments.firstIndex(of: "--selftest-microfone") {
            let segundos = CommandLine.arguments.count > index + 1
                ? Double(CommandLine.arguments[index + 1]) ?? 3 : 3
            runMicrophoneSelfTest(seconds: segundos)
        }

        // Confere que mais de uma janela de legendas coexiste, sem video
        // nenhum:  open -n build/Tradutor.app --args --selftest-janelas
        if CommandLine.arguments.contains("--selftest-janelas") {
            runStudioWindowsSelfTest()
        }

        // Exercita a janela de legendas sem ninguem clicar:
        //   open build/Tradutor.app --args --selftest-studio <video> ja pt
        if let index = CommandLine.arguments.firstIndex(of: "--selftest-studio"),
           CommandLine.arguments.count > index + 1 {
            let arguments = CommandLine.arguments
            runStudioSelfTest(
                path: arguments[index + 1],
                source: arguments.count > index + 2
                    ? Language(rawValue: arguments[index + 2]) ?? .japanese : .japanese,
                target: arguments.count > index + 3
                    ? Language(rawValue: arguments[index + 3]) ?? .portuguese : .portuguese
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // O tap sobrevive ao processo se nao for destruido; sair sem passar
        // por aqui deixa o audio do sistema preso ate reiniciar.
        pipeline.stop()
    }

    // MARK: - Interface

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            pipeline.refreshProcesses()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func makeSettingsView() -> SettingsView {
        SettingsView(
            pipeline: pipeline,
            onRefresh: { [weak self] in
                self?.pipeline.refreshProcesses()
            },
            onToggle: { [weak self] in self?.toggleTranslation() },
            onResetPanel: { [weak self] in self?.panel?.resetToDefaultSize() },
            onMakeSubtitles: { [weak self] in self?.makeSubtitles() },
            onOpenStudio: { [weak self] in self?.openStudio() },
            onNewStudio: { [weak self] in self?.openStudio(nova: true) }
        )
    }

    /// Janela de legendas: escolher video, gerar, assistir e navegar.
    ///
    /// Mais de uma pode ficar aberta — dois videos ao mesmo tempo, ou um
    /// segundo vídeo sem perder a legenda do primeiro, que custou minutos.
    ///
    /// Sem `nova`, o item do menu **levanta as que ja existem** em vez de
    /// abrir mais uma. O app e `.accessory`: sem Dock, sem Cmd-Tab e sem menu
    /// Janela, este e o unico caminho de volta para uma janela enterrada
    /// atras de outras.
    private func openStudio(nova: Bool = false) {
        popover.performClose(nil)

        if !nova, !studios.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            // Na ordem do app, de tras para a frente: a que ja estava na
            // frente termina na frente, em vez de uma qualquer roubar o foco.
            for window in NSApp.orderedWindows.reversed() where studios[window] != nil {
                window.makeKeyAndOrderFront(nil)
            }
            return
        }

        let model = SubtitleStudioModel()
        model.sourceLanguage = pipeline.sourceLanguage
        model.targetLanguage = pipeline.targetLanguage
        model.recognitionEngine = pipeline.recognitionEngine
        model.translationEngine = pipeline.translationEngine
        model.diarizeSpeakers = pipeline.diarizeSpeakers
        model.speakerModel = pipeline.speakerModel
        model.colorBySpeaker = pipeline.colorBySpeaker

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        studioCounter += 1
        window.title = studioCounter == 1 ? "Legendas" : "Legendas \(studioCounter)"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: SubtitleStudioView(model: model)
        )
        window.delegate = self

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        studios[window] = model
    }

    private func makeSubtitles() {
        popover.performClose(nil)
        let job = SubtitleJob(pipeline: pipeline)
        subtitleJob = job          // o trabalho precisa sobreviver ao escopo
        job.run()
    }

    // MARK: - Traducao

    private func toggleTranslation() {
        if pipeline.isRunning {
            stopTranslation()
        } else {
            startTranslation()
        }
    }

    private func startTranslation() {
        pipeline.refreshProcesses()
        // Sem escolha explicita nao se captura nada. O fallback silencioso
        // para "o primeiro que estiver tocando" fazia o app gravar um
        // aplicativo diferente do que o usuario acreditava ter escolhido.
        guard let target = pipeline.selectedProcess else {
            notify(
                "Escolha o que capturar",
                """
                Abra o menu do Tradutor e selecione o aplicativo, ou                 "Todo o áudio do sistema".
                """
            )
            togglePopover()
            return
        }

        popover.performClose(nil)
        showPanel()
        Task { await pipeline.start(on: target) }
        statusItem.button?.image = NSImage(
            systemSymbolName: "captions.bubble.fill", accessibilityDescription: "Traduzindo"
        )
    }

    private func stopTranslation() {
        pipeline.stop()
        hidePanel()
        statusItem.button?.image = NSImage(
            systemSymbolName: "captions.bubble", accessibilityDescription: "Tradutor"
        )
    }

    private func showPanel() {
        guard panel == nil else { return }
        let panel = OverlayPanel(pipeline: pipeline) { [weak self] in
            self?.stopTranslation()
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Confere que o painel acompanha a altura do conteudo em vez de usar um
    /// tamanho fixo — a causa da faixa vazia abaixo do icone.
    private func measurePopoverAndExit() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            guard let button = statusItem.button else { exit(1) }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let fitting = self.popoverHost.view.fittingSize
                let content = self.popover.contentSize
                let text = """
                altura que o conteudo pede : \(Int(fitting.height))
                altura que o popover usa   : \(Int(content.height))
                largura                    : \(Int(content.width))
                diferenca (faixa vazia)    : \(Int(content.height - fitting.height))
                """
                try? text.write(toFile: "/tmp/tradutor-popover.txt", atomically: true, encoding: .utf8)

                // Uma imagem do painel, desenhada pelo próprio app: é o
                // único jeito de conferir o que aparece ali sem depender de
                // alguém olhar, e foi assim que se descobriu que os
                // controles de locutor estavam escondidos.
                let view = self.popoverHost.view
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "/tmp/painel.png"))
                }
                exit(0)
            }
        }
    }

    /// Liga a traducao no primeiro app que estiver tocando som, deixa rodar,
    /// e grava o que apareceu nas tres zonas. E o unico jeito de exercitar o
    /// caminho real — tap, VAD, reconhecimento, traducao e loja — sem uma
    /// pessoa clicando.
    private func runLiveSelfTest() {
        let relatorio = SelfTestReport("/tmp/tradutor-live.txt", "teste ao vivo")
        let write = relatorio.write

        // Idiomas opcionais na linha de comando: --selftest-live ja pt
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--selftest-live") {
            if arguments.count > index + 1,
               let source = Language(rawValue: arguments[index + 1]) {
                pipeline.sourceLanguage = source
            }
            if arguments.count > index + 2,
               let target = Language(rawValue: arguments[index + 2]) {
                pipeline.targetLanguage = target
            }
        }

        Task { @MainActor in
            write("idiomas: \(pipeline.sourceLanguage.rawValue) -> \(pipeline.targetLanguage.rawValue)")
            write("motor esperado: \(pipeline.sourceLanguage.hasParakeetSupport ? "Parakeet" : "Whisper")")
            write("aguardando os modelos carregarem...")
            let loadStart = Date()
            while !pipeline.isWarm, Date().timeIntervalSince(loadStart) < 180 {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard pipeline.isWarm else {
                if case let .failed(message) = pipeline.state {
                    write("FALHA ao carregar: \(message)")
                } else if case let .loading(label, fraction) = pipeline.state {
                    write("FALHA: parou em \"\(label)\" (\(Int(fraction * 100))%)")
                } else {
                    write("FALHA: modelos nao carregaram em 180 s, estado \(pipeline.state)")
                }
                exit(1)
            }
            write("modelos prontos em \(Int(Date().timeIntervalSince(loadStart)))s")
            write("motores: \(pipeline.engineNames)")

            pipeline.refreshProcesses()
            guard let target = pipeline.availableProcesses.first(where: {
                $0.isPlaying && !$0.isSystemWide
            }) else {
                write("FALHA: nenhum app tocando som")
                exit(1)
            }
            write("alvo: \(target.name)  pids \(target.pids.map(String.init).joined(separator: ", "))")
            pipeline.selectedProcess = target

            // A regressao relatada: a escolha do usuario sumia sozinha. Ela
            // tem que sobreviver a um refresh, inclusive quando o estado de
            // reproducao dos aplicativos muda no meio.
            pipeline.refreshProcesses()
            guard pipeline.selectedProcess == target else {
                write("FALHA: a selecao foi perdida ao atualizar a lista")
                exit(1)
            }
            write("selecao sobrevive ao refresh da lista")

            showPanel()
            await pipeline.start(on: target)

            if case let .failed(message) = pipeline.state {
                write("FALHA ao iniciar: \(message)")
                exit(1)
            }
            let sizeAtStart = panel?.frame.size ?? .zero
            write("painel ao iniciar: \(Int(sizeAtStart.width))x\(Int(sizeAtStart.height))")
            write("capturando por 20 s...\n")

            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
            }

            let sizeAtEnd = panel?.frame.size ?? .zero

            write("--- texto cru por segmento ---")
            for (index, raw) in pipeline.rawTranscripts.enumerated() {
                write("  \(index + 1): \(raw)")
            }
            if pipeline.droppedSegments > 0 {
                write("  segmentos descartados por fila cheia: \(pipeline.droppedSegments)")
            }

            let store = pipeline.subtitles
            write("--- zona amarela (historico) ---")
            for block in store.history {
                write("  \(block.source)")
                write("  -> \(block.translated)")
            }
            write("--- zona azul (atual) ---")
            if let current = store.current {
                write("  \(current.source)")
                write("  -> \(current.translated)")
            } else {
                write("  (vazia)")
            }
            write("--- zona vermelha (parcial) ---")
            write("  \(store.partial.isEmpty ? "(vazia)" : store.partial)")
            write("")
            write("latencia do ultimo bloco: \(pipeline.lastTranscribeMs) ms + \(pipeline.lastTranslateMs) ms = \(pipeline.lastTranscribeMs + pipeline.lastTranslateMs) ms")

            let blocks = store.history.count + (store.current == nil ? 0 : 1)
            write("blocos traduzidos: \(blocks)")

            // O painel tem que ser de tamanho fixo: se ele crescesse a cada
            // bloco, o texto pularia de posicao enquanto esta sendo lido.
            write("painel ao terminar: \(Int(sizeAtEnd.width))x\(Int(sizeAtEnd.height))")
            let stable = sizeAtStart == sizeAtEnd
            write(stable
                  ? "tamanho estavel apos \(blocks) blocos"
                  : "FALHA: painel mudou de tamanho com o conteudo")

            pipeline.stop()
            let passed = blocks > 0 && stable
            write(passed ? "\nPASSOU" : "\nFALHA")
            exit(passed ? 0 : 1)
        }
    }

    /// Roda o item de menu de geracao de legenda de ponta a ponta.
    ///
    /// Arquivo separado da janela: compartilham o nucleo, mas interface,
    /// progresso e cancelamento sao de cada um. Testar um nao testa o outro.
    /// Caminho relativo do autoteste, resolvido.
    ///
    /// `open` não passa o diretório de trabalho (o app nasce em `/`), então
    /// relativo vale a partir da pasta que contém o `.app` — o projeto monta
    /// em `build/Tradutor.app`, ou seja, a raiz do projeto.
    private func resolvedTestPath(_ path: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        let raiz = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidato = raiz.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: candidato.path) ? candidato.path : path
    }

    private func runSubtitleJobSelfTest(path rawPath: String, source: Language, target: Language) {
        let path = resolvedTestPath(rawPath)
        let relatorio = SelfTestReport("/tmp/tradutor-job.txt", "gerar legenda de um video")
        let write = relatorio.write
        let expect = relatorio.expect


        Task { @MainActor in
            pipeline.sourceLanguage = source
            pipeline.targetLanguage = target
            write("video: \(URL(fileURLWithPath: path).lastPathComponent)")
            write("idiomas: \(source.rawValue) -> \(target.rawValue)")
            write("motor: \(TranscriberFactory.make(for: source, engine: pipeline.recognitionEngine).engineName)")
            // `--tradutor <nome>` sobrepoe em memoria: o autoteste nao grava
            // preferencia do usuario.
            let motorDeTraducao: TranslationEngine = {
                if let flag = CommandLine.arguments.firstIndex(of: "--tradutor"),
                   CommandLine.arguments.count > flag + 1,
                   let motor = TranslationEngine(rawValue: CommandLine.arguments[flag + 1]) {
                    return motor
                }
                return pipeline.translationEngine
            }()
            write("tradutor: \(motorDeTraducao.displayName)")

            // O sufixo e o idioma ESCRITO, nao o escolhido: com "so
            // transcrever" a legenda sai em japones e o teste esperava um
            // `.pt.srt` que ninguem ia gravar.
            let escrito = motorDeTraducao.destination(from: source, to: target)
            let destino = URL(fileURLWithPath: path)
                .deletingPathExtension()
                .appendingPathExtension("\(escrito.rawValue).srt")
            try? FileManager.default.removeItem(at: destino)

            let inicio = Date()
            let job = SubtitleJob(pipeline: pipeline)
            job.translation = motorDeTraducao
            // Sem alerta: o modal segura o laço principal e o relatório ficava
            // parado em "gerando…" com o .srt já gravado.
            job.silent = true
            subtitleJob = job
            job.run(URL(fileURLWithPath: path))
            write("gerando...")

            // A janela de conclusao e modal; o teste espera o arquivo.
            let limite = Date().addingTimeInterval(1800)
            while Date() < limite,
                  job.failure == nil,
                  !FileManager.default.fileExists(atPath: destino.path) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let erro = job.failure { write("  FALHA \(erro)") }
            if let aviso = job.notice { write("aviso: \(aviso)") }

            let segundos = Int(Date().timeIntervalSince(inicio))
            expect(FileManager.default.fileExists(atPath: destino.path),
                   "grava o .srt ao lado do video (\(segundos)s)")

            guard let texto = try? String(contentsOf: destino, encoding: .utf8) else {
                write("FALHA: nao consegui ler o arquivo gravado")
                exit(1)
            }
            let blocos = SRTParser.parse(texto)
            write("legendas: \(blocos.count)")
            expect(!blocos.isEmpty, "o arquivo tem legendas")
            expect(texto.contains(" --> "), "formato SubRip")
            expect(blocos.allSatisfy { $0.end > $0.start },
                   "nenhuma legenda termina antes de comecar")

            var ordenadas = true
            for i in 1..<max(blocos.count, 1) where blocos[i].start < blocos[i - 1].end {
                ordenadas = false
            }
            expect(ordenadas, "legendas em ordem e sem sobreposicao")
            // Pela largura do destino, nao por 42 fixo: com destino japones a
            // legenda sai em 20 e conferir contra 42 nao acusaria nada.
            let largura = SubtitleFileBuilder.lineWidth(for: escrito)
            expect(blocos.allSatisfy {
                LineBreaker.wrap($0.translated, maximum: largura).count <= 2
            }, "nenhuma legenda passa de duas linhas")
            expect(blocos.allSatisfy { $0.end - $0.start >= 0.6 },
                   "nenhuma legenda pisca")
            expect(!blocos.contains { $0.translated.contains("assistir enquanto") },
                   "sem alucinacao colada em fala real")

            write("")
            write("primeiras legendas:")
            for bloco in blocos.prefix(4) {
                write("  \(SRTWriter.timecode(bloco.start)) → \(SRTWriter.timecode(bloco.end))")
                write("    \(bloco.translated)")
            }

            write("")
            write(relatorio.failures == 0 ? "PASSOU" : "\(relatorio.failures) falhas")
            exit(relatorio.failures == 0 ? 0 : 1)
        }
    }

    /// Confere que mais de uma janela de legendas existe ao mesmo tempo, que
    /// cada uma tem o seu modelo, e que fechar uma nao leva as outras.
    ///
    /// Nao carrega video nem modelo: roda em milissegundos.
    private func runStudioWindowsSelfTest() {
        let relatorio = SelfTestReport("/tmp/tradutor-janelas.txt", "teste das janelas de legendas")
        let write = relatorio.write
        let expect = relatorio.expect

        Task { @MainActor in
            openStudio()
            expect(studios.count == 1, "a primeira abre")

            // Sem `nova`, o item do menu levanta o que ja existe. Abrindo mais
            // uma aqui, quem tivesse a janela enterrada atras de outras ficaria
            // sem caminho de volta: o app nao tem Dock nem menu Janela.
            openStudio()
            expect(studios.count == 1, "reabrir nao cria outra")

            openStudio(nova: true)
            openStudio(nova: true)
            expect(studios.count == 3, "abrir outra cria outra")

            let titulos = Set(studios.keys.map(\.title))
            expect(titulos.count == 3,
                   "cada janela tem seu titulo (\(titulos.sorted().joined(separator: ", ")))")
            expect(Set(studios.values.map(ObjectIdentifier.init)).count == 3,
                   "cada janela tem seu modelo")

            // Fechar uma nao pode levar as outras junto.
            let primeira = studios.keys.first!
            let restantes = Set(studios.keys).subtracting([primeira])
            primeira.close()
            expect(studios.count == 2, "fechar uma deixa as outras")
            expect(Set(studios.keys) == restantes, "sobram as que nao foram fechadas")

            for window in Array(studios.keys) { window.close() }
            expect(studios.isEmpty, "fechar todas esvazia")

            write("")
            write(relatorio.failures == 0 ? "PASSOU" : "\(relatorio.failures) falhas")
            exit(relatorio.failures == 0 ? 0 : 1)
        }
    }

    /// Roda o caminho da janela de legendas de ponta a ponta: abre o video,
    /// gera, e exercita a navegacao por fala.
    /// Capta do microfone e diz o que chegou.
    ///
    /// Existe porque permissão de microfone falha do mesmo jeito que a de
    /// gravação de tela: negada, o `AVAudioEngine` roda, o tap dispara na
    /// cadência certa e **todos os quadros vêm zerados**. Sem medir o nível não
    /// há como distinguir isso de uma sala silenciosa.
    private func runMicrophoneSelfTest(seconds: Double) {
        let relatorio = SelfTestReport("/tmp/tradutor-microfone.txt", "microfone")
        let write = relatorio.write
        let expect = relatorio.expect

        Task { @MainActor in
            let entradas = AudioInputList.all()
            write("entradas: \(entradas.map(\.name).joined(separator: ", "))")
            write("padrão: \(AudioInputList.systemDefault?.name ?? "nenhum")")
            expect(!entradas.isEmpty, "a máquina tem pelo menos uma entrada")

            guard await MicrophoneTap.requestAccess() else {
                write("FALHA: acesso ao microfone negado")
                exit(1)
            }

            // Sem dispositivo: o padrão do sistema, que é o padrão do app.
            let tap = MicrophoneTap()
            let ring = RingBuffer()
            do {
                try tap.start { samples in ring.write(samples) }
            } catch {
                write("FALHA ao abrir: \(error.localizedDescription)")
                exit(1)
            }
            write("taxa: \(Int(tap.sampleRate ?? 0)) Hz")

            try? await Task.sleep(for: .seconds(seconds))
            tap.stop()

            var buffer = [Float](repeating: 0, count: 1 << 20)
            var total = 0
            var pico: Float = 0
            var soma: Double = 0
            while true {
                let lidas = ring.read(into: &buffer, maximum: buffer.count)
                if lidas == 0 { break }
                for index in 0..<lidas {
                    let valor = abs(buffer[index])
                    if valor > pico { pico = valor }
                    soma += Double(valor) * Double(valor)
                    total += 1
                }
            }
            let rms = total > 0 ? (soma / Double(total)).squareRoot() : 0
            write(String(format: "amostras: %d · pico %.5f · RMS %.5f", total, pico, rms))

            let esperadas = Int((tap.sampleRate ?? 48_000) * seconds * 0.5)
            expect(total > esperadas, "chegou áudio suficiente (\(total) amostras)")
            // Zero exato em todos os quadros é a assinatura da permissão
            // negada, não de silêncio: mesmo sala quieta tem ruído de fundo.
            expect(pico > 0, "os quadros não vêm zerados — a permissão está de pé")
            if pico > 0, rms < 0.0005 {
                write("  aviso: nível muito baixo (\(String(format: "%.5f", rms))) — fale perto do microfone")
            }

            write(relatorio.failures == 0 ? "\nPASSOU" : "\n\(relatorio.failures) falha(s)")
            exit(relatorio.failures == 0 ? 0 : 1)
        }
    }

    private func runStudioSelfTest(path rawPath: String, source: Language, target: Language) {
        let path = resolvedTestPath(rawPath)
        let relatorio = SelfTestReport("/tmp/tradutor-studio.txt", "teste da janela de legendas")
        let write = relatorio.write
        let expect = relatorio.expect


        Task { @MainActor in
            let model = SubtitleStudioModel()
            model.sourceLanguage = source
            model.targetLanguage = target
            // O padrão é o reconhecimento da Apple; `--motor <nome>` escolhe
            // outro: parakeet, whisper.
            if let flag = CommandLine.arguments.firstIndex(of: "--motor"),
               CommandLine.arguments.count > flag + 1,
               let motor = RecognitionEngine(rawValue: CommandLine.arguments[flag + 1]) {
                model.recognitionEngine = motor
            }
            // `--tradutor <nome>` escolhe quem traduz: apple, deepl.
            if let flag = CommandLine.arguments.firstIndex(of: "--tradutor"),
               CommandLine.arguments.count > flag + 1,
               let motor = TranslationEngine(rawValue: CommandLine.arguments[flag + 1]) {
                model.translationEngine = motor
            }
            // `--locutores` liga a identificação de quem fala, que é opção
            // do usuário e não padrão.
            model.diarizeSpeakers = CommandLine.arguments.contains("--locutores")
            // `--cores` liga a cor por locutor; `--modelo <nome>` troca quem
            // identifica as vozes.
            model.colorBySpeaker = CommandLine.arguments.contains("--cores")
            if let flag = CommandLine.arguments.firstIndex(of: "--modelo"),
               CommandLine.arguments.count > flag + 1,
               let escolhido = SpeakerDiarizer.Model(rawValue: CommandLine.arguments[flag + 1]) {
                model.speakerModel = escolhido
            }
            if model.diarizeSpeakers {
                write("locutores por: \(model.speakerModel.displayName)"
                      + (model.colorBySpeaker ? ", com cor" : ", sem cor"))
            }
            let kind = TranscriberKind(for: source, engine: model.recognitionEngine)
            write("reconhecimento: \(kind)")
            // Os que reportam progresso durante o reconhecimento. O Parakeet
            // termina 90 s de áudio antes de haver o que amostrar.
            let usaWhisper = [.whisper, .apple].contains(kind)

            // A janela e aberta DE VERDADE: o crash ao escolher um video
            // acontecia na renderizacao da superficie de video, e um teste que
            // so mexe no modelo nunca o alcancaria.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 660),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Legendas (teste)"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SubtitleStudioView(model: model)
            )
            window.orderFrontRegardless()
            studios[window] = model
            write("janela aberta")

            model.open(URL(fileURLWithPath: path))
            // Da tempo de a superficie de video ser instanciada e desenhada,
            // e de o apelido .mp4 entrar no lugar quando o nome nao tem
            // extensao.
            for _ in 0..<25 {
                try? await Task.sleep(for: .milliseconds(100))
                window.contentView?.needsDisplay = true
            }
            write("superficie de video renderizada sem abortar")

            // Arquivo sem extensao tem que TOCAR, nao so extrair audio.
            let tocavel = model.player?.currentItem?.asset
            var duracaoDoItem: Double = 0
            if let asset = tocavel {
                duracaoDoItem = (try? await asset.load(.duration).seconds) ?? 0
            }
            expect(duracaoDoItem > 1,
                   String(format: "o player carrega a midia (%.1fs)", duracaoDoItem))
            write("video: \(model.videoName)")
            expect(model.player != nil, "o player e criado ao abrir o video")

            // A duracao chega de forma assincrona.
            for _ in 0..<40 where model.duration == 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            write(String(format: "duracao: %.1fs", model.duration))
            expect(model.duration > 1, "a duracao do video e lida")
            expect(model.canGenerate, "da para gerar depois de escolher o video")

            // O .srt que uma geração antiga deixou ao lado do vídeo, para o
            // teste de "gerar não grava" valer.
            let srtAoLado = URL(fileURLWithPath: path).deletingPathExtension()
                .appendingPathExtension("\(target.rawValue).srt")
            try? FileManager.default.removeItem(at: srtAoLado)

            model.generate()
            write("gerando...")

            // Verdadeiro se a interface chegou a anunciar que estava
            // esperando a resposta do tradutor.
            nonisolated(unsafe) var viuEspera = false

            // Registra cada mudanca de etapa com o tempo, para saber onde o
            // trabalho fica preso em vez de so ver "travou".
            Task { @MainActor in
                var ultimo = ""
                let inicio = Date()
                while true {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard case let .working(passo) = model.stage else {
                        if case .done = model.stage { return }
                        if case .failed = model.stage { return }
                        continue
                    }
                    // A espera pela resposta do tradutor tem de aparecer:
                    // sem isso a barra fica parada e parece travamento.
                    if passo.waiting { viuEspera = true }
                    let atual = passo.kind.rawValue + (passo.waiting ? " (aguardando)" : "")
                    if atual != ultimo {
                        write(String(format: "  [%5.1fs] %@ %@",
                                     Date().timeIntervalSince(inicio), atual, passo.detail))
                        ultimo = atual
                    }
                }
            }
            // Captura no meio do trabalho, para o painel de progresso
            // aparecer na imagem.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                if let content = window.contentView,
                   let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "/tmp/studio-progresso.png"))
                    }
                }
            }
            let deadline = Date().addingTimeInterval(2400)
            // A barra ficava parada o reconhecimento inteiro — minutos num
            // video longo. Guarda o maior progresso visto dentro do passo.
            var progressoReconhecendo = 0.0
            while Date() < deadline {
                if case let .working(passo) = model.stage, passo.kind == .transcribing {
                    progressoReconhecendo = max(progressoReconhecendo, passo.withinStep)
                }
                if case .done = model.stage { break }
                if case let .failed(message) = model.stage {
                    write("FALHA na geracao: \(message)")
                    exit(1)
                }
                // Curto: o reconhecimento da Apple faz 90 s de áudio em menos
                // de 300 ms, e uma amostragem mais lenta nunca o via.
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard case .done = model.stage else {
                write("FALHA: geracao nao terminou em 10 min")
                exit(1)
            }

            write(String(format: "geracao em %.1fs", model.elapsed))
            write("legendas: \(model.cues.count)")
            expect(!model.cues.isEmpty, "a geracao produz legendas")
            expect(viuEspera, "a interface anuncia a espera pela resposta do tradutor")
            if model.diarizeSpeakers {
                let comLocutor = model.cues.filter { $0.speaker != nil }
                write("locutores: \(Set(comLocutor.compactMap(\.speaker)).sorted().joined(separator: ", "))")
                expect(!comLocutor.isEmpty,
                       "com locutores ligado, as legendas ganham quem fala (\(comLocutor.count) de \(model.cues.count))")
            }
            let originalCheck = FileManager.default.temporaryDirectory
                .appendingPathComponent("original-gerado-\(UUID().uuidString).srt")
            model.export(to: originalCheck, track: .original)
            let originalWritten = (try? String(contentsOf: originalCheck, encoding: .utf8)) ?? ""
            let originalLayout = SubtitleFileBuilder()
            originalLayout.charactersPerLine = SubtitleFileBuilder.lineWidth(for: source)
            let originalFormatted = originalLayout.enforceLineLimit(model.originalCues)
            expect(originalWritten == SRTWriter.render(
                originalFormatted, colorBySpeaker: model.diarizeSpeakers && model.colorBySpeaker,
                charactersPerLine: SubtitleFileBuilder.lineWidth(for: source)),
                "exportacao original usa todas as falas anteriores ao corte da traducao")
            try? FileManager.default.removeItem(at: originalCheck)

            // O que a janela mostra e o que o arquivo leva: travessao incluido.
            // O autoteste do item de menu ja conferia as duas linhas; este
            // nao, e era aqui que a terceira linha passava — 4 dos 24 backups
            // da auditoria de 12/09/2026 tinham legenda de tres linhas.
            let maiorEmLinhas = model.cues.indices
                .map { model.displayLines(at: $0).count }.max() ?? 0
            expect(maiorEmLinhas <= 2,
                   "nenhuma legenda da janela passa de duas linhas (maior: \(maiorEmLinhas))")

            // A janela e o arquivo quebram a linha no MESMO lugar: sao dois
            // caminhos (`displayText` + `LineBreaker` contra
            // `SRTWriter.render`) e ja divergiram pelo travessao e pela
            // largura por idioma. A largura do arquivo vem da regra, nao da
            // propriedade do modelo, para o teste reprovar tambem quando as
            // duas deixarem de concordar.
            let doArquivo = SRTWriter.render(
                model.cues,
                charactersPerLine: SubtitleFileBuilder.lineWidth(for: model.writtenLanguage)
            )
            .components(separatedBy: "\n\n")
            .filter { $0.contains("-->") }
            .map { $0.components(separatedBy: "\n").dropFirst(2).joined(separator: "\n") }
            // Pela mesma funcao que desenha a janela — nao uma copia da regra
            // aqui, que e o que deixava um 42 fixo na view passar batido.
            let daJanela = model.cues.indices.map {
                model.displayLines(at: $0).joined(separator: "\n")
            }
            let divergentes = zip(daJanela, doArquivo).filter { $0 != $1 }.count
            expect(divergentes == 0,
                   "a janela quebra a linha igual ao arquivo (\(divergentes) divergem de \(min(daJanela.count, doArquivo.count)))")
            let maisLonga = model.cues.map { $0.end - $0.start }.max() ?? 0
            expect(maisLonga <= 7.01,
                   String(format: "nenhuma legenda fica mais que 7s na tela (maior: %.2fs)",
                          maisLonga))

            // Vídeo curto não tem como mostrar progresso, e reprovar por isso
            // é reprovar por dado.
            //
            // O Whisper decodifica em janelas de 30 s e só relata ao fechar
            // uma; num arquivo de 40 s o reconhecimento inteiro leva 1,5 s e
            // termina antes de o laço amostrar qualquer fração. A verificação
            // existe para pegar a barra parada em vídeo longo — que era o
            // defeito — então é lá que ela vale.
            if usaWhisper, duracaoDoItem > 60 {
                expect(progressoReconhecendo > 0,
                       String(format: "o reconhecimento mostra progresso (chegou a %.0f%%)",
                              progressoReconhecendo * 100))
            } else if usaWhisper {
                write(String(format: "  (pulado: video de %.0fs, curto demais para relatar progresso)",
                             duracaoDoItem))
            }

            // Copia de seguranca, para restaurar depois do teste de cancelar.
            let destinoParaTeste = FileManager.default.temporaryDirectory
                .appendingPathComponent("backup-\(UUID().uuidString).srt")
            try? SRTWriter.render(model.cues).write(
                to: destinoParaTeste, atomically: true, encoding: .utf8)
            // A janela só grava ao exportar. Antes cada geração deixava um
            // .srt ao lado do vídeo sem ninguém pedir.
            expect(model.savedSRT == nil, "gerar nao grava .srt sozinho")
            expect(!FileManager.default.fileExists(atPath: srtAoLado.path),
                   "nenhum .srt aparece ao lado do video sem exportar")

            if model.diarizeSpeakers {
                // Exporta AQUI, com as legendas recém-geradas.
                //
                // A exportação do fim do teste vem depois de carregar um .srt
                // e de regerar: ali as legendas já vieram de arquivo e não
                // têm locutor, então a cor não teria de onde sair — foi
                // exatamente esse engano que fez o teste falhar antes.
                let comCor = FileManager.default.temporaryDirectory
                    .appendingPathComponent("colorida-\(UUID().uuidString).srt")
                model.export(to: comCor)
                let texto = (try? String(contentsOf: comCor, encoding: .utf8)) ?? ""
                let travessoes = texto.components(separatedBy: "— ").count - 1
                let tags = texto.components(separatedBy: "<font color=").count - 1
                write("no arquivo: \(travessoes) travessoes, \(tags) legendas coloridas")
                expect(travessoes > 0, "a troca de locutor marca travessao no arquivo")
                if model.colorBySpeaker {
                    expect(tags > 0, "o .srt exportado leva a cor de cada locutor")
                    expect(texto.components(separatedBy: "</font>").count - 1 == tags,
                           "cada cor fecha a sua tag")
                    expect(SRTParser.parse(texto).count == model.cues.count,
                           "o .srt colorido volta a ser lido com as mesmas legendas")
                } else {
                    expect(tags == 0, "sem pedir cor, nenhuma tag entra no arquivo")
                }
                try? FileManager.default.removeItem(at: comCor)

                // Um PNG aqui, com as legendas recém-geradas: o do fim do
                // teste é desenhado depois de carregar um .srt, quando as
                // legendas já perderam o locutor e a cor não aparece.
                model.jump(to: min(1, model.cues.count - 1))
                try? await Task.sleep(for: .milliseconds(400))
                if let content = window.contentView,
                   let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "/tmp/studio-locutores.png"))
                    write("layout com locutores em /tmp/studio-locutores.png")
                }
            }

            // Clicar numa legenda leva o video ao momento dela.
            let alvo = min(4, model.cues.count - 1)
            model.jump(to: alvo)
            let cue = model.cues[alvo]
            expect(abs(model.currentTime - cue.start) < 0.2,
                   String(format: "clicar na legenda %d leva o video a %.2fs (foi para %.2fs)",
                          alvo + 1, cue.start, model.currentTime))
            expect(model.activeIndex == alvo, "a legenda clicada fica marcada como atual")

            // Avancar de fala em fala cai sempre no inicio da seguinte.
            model.jump(to: 0)
            var visitados: [Int] = [0]
            for _ in 0..<min(5, model.cues.count - 1) {
                model.jumpToNextCue()
                visitados.append(model.activeIndex ?? -1)
            }
            expect(visitados == Array(0...(visitados.count - 1)),
                   "avancar percorre as legendas em sequencia (\(visitados))")
            expect(model.cues.indices.contains(model.activeIndex ?? -1),
                   "sempre ha uma legenda ativa depois de avancar")

            // Voltar do meio de uma legenda vai para o comeco dela.
            //
            // A regra do app so vale passado um segundo do inicio da legenda
            // atual, entao o teste precisa de uma que dure mais que isso. Era
            // a de indice 3, fixa, e com legendas curtas o instante procurado
            // caia na legenda SEGUINTE — o teste reprovava por dado, nao por
            // defeito. Apareceu com o Parakeet, que devolve legendas curtas.
            if let alvoLongo = model.cues.first(where: { $0.end - $0.start > 1.3 }) {
                model.seek(to: alvoLongo.start + min(
                    (alvoLongo.end - alvoLongo.start) / 2 + 1.0,
                    (alvoLongo.end - alvoLongo.start) - 0.1
                ))
                model.jumpToPreviousCue()
                expect(abs(model.currentTime - alvoLongo.start) < 0.2,
                       "voltar do meio de uma fala vai para o comeco dela")
            } else {
                write("  (pulado: nenhuma legenda dura mais que 1,3s)")
            }

            // No silencio entre duas legendas nao ha legenda ativa.
            if model.cues.count > 2 {
                let gap = model.cues[1]
                let next = model.cues[2]
                if next.start - gap.end > 1.0 {
                    model.seek(to: gap.end + (next.start - gap.end) / 2)
                    expect(model.activeIndex == nil,
                           "no silencio entre falas nenhuma legenda fica marcada")
                } else {
                    write("  (pulado: nao ha silencio entre as duas primeiras)")
                }
            }

            // Retraduzir: refaz so a traducao, sem reconhecer de novo.
            //
            // Tres promessas para conferir, e a primeira e a que custa caro
            // se falhar: o que esta na tela nao pode sumir enquanto a
            // traducao nova e feita, nem se ela for cancelada.
            write("")
            write("retraduzir")
            let textoAntes = model.cues.map(\.translated)
            let origemAntes = model.origin
            expect(origemAntes != nil, "a janela registra o que reconheceu e o que traduziu")
            expect(origemAntes?.recognition.isEmpty == false,
                   "o motor de reconhecimento aparece (\(origemAntes?.recognition ?? "-"))")
            expect(origemAntes?.translation.isEmpty == false,
                   "o tradutor aparece (\(origemAntes?.translation ?? "-"))")
            expect(model.canRetranslate, "com legenda gerada, da para retraduzir")

            // Com o mesmo tradutor, tem que dar o mesmo texto que a geracao
            // inteira deu. E a promessa que justifica o botao: o rascunho e o
            // mesmo, e entre ele e a traducao nao ha mais nada no caminho.
            //
            // Esta vem antes do teste de cancelamento de proposito — cancelar
            // e retomar no mesmo instante deixa o lote anterior ainda em voo,
            // e o tempo medido deixaria de ser o de uma retraducao limpa.
            model.retranslate()
            let prazoRetraducao = Date().addingTimeInterval(300)
            var vazioDurante = false
            while Date() < prazoRetraducao {
                if model.cues.isEmpty { vazioDurante = true }
                if case .done = model.stage { break }
                if case let .failed(erro) = model.stage {
                    write("FALHA ao retraduzir: \(erro)")
                    exit(1)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            expect(!vazioDurante, "a lista nunca fica vazia durante a retraducao")
            write("retraducao em \(String(format: "%.1f", model.elapsed))s")
            expect(model.cues.count == textoAntes.count,
                   "retraduzir devolve a mesma quantidade de legendas "
                   + "(\(model.cues.count) de \(textoAntes.count))")
            // Igualdade estrita so vale para tradutor deterministico. O DeepL
            // e um site e nao repete: medido, uma terceira passada mudou 5 de
            // 20 legendas do mesmo texto. Onde o motor varia, o que se exige e
            // que nenhuma legenda volte vazia.
            if model.translationEngine == .apple {
                expect(model.cues.map(\.translated) == textoAntes,
                       "com o mesmo tradutor, o texto e o mesmo da geracao inteira")
            } else {
                let iguais = zip(model.cues.map(\.translated), textoAntes).filter { $0 == $1 }.count
                write("  \(iguais) de \(textoAntes.count) legendas iguais "
                      + "(\(model.translationEngine.displayName) nao e deterministico)")
                expect(model.cues.allSatisfy { !$0.translated.isEmpty },
                       "nenhuma legenda volta vazia da retraducao")
            }
            expect(model.savedSRT == nil,
                   "retraduzir invalida o .srt que havia sido exportado")
            expect(model.origin?.translation == origemAntes?.translation,
                   "o rotulo continua dizendo quem traduziu")
            expect(model.origin?.recognition == origemAntes?.recognition,
                   "e quem reconheceu nao mudou: o audio nao foi ouvido de novo")

            // --- o que a janela faz quando algo falha ---
            //
            // Nenhum tradutor de reserva entra no lugar de quem falhou (ver
            // `SubtitleFileError.translationFailed`): a falha aparece na tela
            // e o botao refaz. Com o rascunho de pe, refazer custa so a
            // traducao, nao o reconhecimento.
            let legendasAntesDaFalha = model.cues
            model.loadSubtitles(from: URL(fileURLWithPath:
                "/tmp/nao-existe-\(UUID().uuidString).srt"))
            expect(model.failureMessage != nil,
                   "a falha chega a interface com mensagem: \(model.failureMessage ?? "nenhuma")")
            expect(model.canRetranslate,
                   "com rascunho de pe, tentar de novo refaz so a traducao")
            expect(model.cues.count == legendasAntesDaFalha.count,
                   "a falha nao apaga o que ja estava na tela")
            // A faixa vermelha e o botao so existem na tela: um PNG e a unica
            // forma de conferir que eles aparecem.
            try? await Task.sleep(for: .milliseconds(300))
            if let content = window.contentView,
               let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "/tmp/studio-falha.png"))
                write("faixa de falha em /tmp/studio-falha.png")
            }

            // `--retraduzir <motor>` troca de tradutor de verdade, que e para
            // isso que o botao existe. Fica atras de uma bandeira porque o
            // DeepL manda texto para a rede, e nenhum autoteste deve fazer
            // isso sem alguem ter pedido.
            if let flag = CommandLine.arguments.firstIndex(of: "--retraduzir"),
               CommandLine.arguments.count > flag + 1,
               let outro = TranslationEngine(rawValue: CommandLine.arguments[flag + 1]) {
                write("")
                write("trocando o tradutor para \(outro.displayName)")
                let primeira = model.cues.first?.start
                let ultima = model.cues.last?.end
                model.translationEngine = outro
                model.retranslate()
                let prazoTroca = Date().addingTimeInterval(600)
                while Date() < prazoTroca {
                    if case .done = model.stage { break }
                    if case let .failed(erro) = model.stage {
                        write("FALHA ao trocar de tradutor: \(erro)")
                        exit(1)
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
                write("troca em \(String(format: "%.1f", model.elapsed))s")
                // A quantidade PODE mudar, e muda: `enforceLineLimit` reparte
                // pela tradução, e tradutor que escreve mais gera mais partes
                // — o Hunyuan escreve 24% mais que o DeepL. Medido aqui: 21
                // legendas com o Hunyuan viraram 20 com a Apple. O que não
                // pode mudar é a linha do tempo, que vem do rascunho.
                write("  \(textoAntes.count) legendas viraram \(model.cues.count)")
                expect(abs((model.cues.first?.start ?? -1) - (primeira ?? -2)) < 0.01,
                       "a primeira legenda continua no mesmo instante")
                expect(abs((model.cues.last?.end ?? -1) - (ultima ?? -2)) < 0.01,
                       "e a ultima termina no mesmo instante")
                expect(model.cues.allSatisfy { !$0.translated.isEmpty },
                       "nenhuma legenda volta vazia do outro tradutor")
                expect(model.origin?.translation.isEmpty == false,
                       "o rotulo passa a dizer \(model.origin?.translation ?? "-")")
                let mudou = zip(model.cues.map(\.translated), textoAntes).filter { $0 != $1 }.count
                write("  \(mudou) de \(textoAntes.count) legendas mudaram de texto")
                expect(model.origin?.recognition == origemAntes?.recognition,
                       "e o reconhecimento continua sendo o mesmo")
                if let aviso = model.notice { write("  aviso: \(aviso)") }
            }

            // Cancelar no meio nao pode custar a traducao que ja estava boa —
            // e e por isso que as legendas parciais nao chegam a tela aqui.
            //
            // A comparacao e contra o que esta na tela AGORA, nao contra o
            // texto do comeco: com `--retraduzir` o de agora e de outro
            // tradutor, e o teste reprovava por comparar com o baseline velho.
            let textoNaTela = model.cues.map(\.translated)
            model.retranslate()
            var sumiuNoMeio = false
            for _ in 0..<6 {
                if model.cues.isEmpty { sumiuNoMeio = true }
                try? await Task.sleep(for: .milliseconds(60))
            }
            model.cancelGeneration()
            try? await Task.sleep(for: .milliseconds(500))
            expect(!sumiuNoMeio, "a legenda anterior continua na tela enquanto retraduz")
            expect(model.cues.map(\.translated) == textoNaTela,
                   "cancelar a retraducao nao custa a traducao que ja estava boa")
            expect(model.canRetranslate, "e da para tentar de novo depois de cancelar")

            // Carregar um .srt pronto em vez de gerar.
            let srtTemporario = FileManager.default.temporaryDirectory
                .appendingPathComponent("carregada-\(UUID().uuidString).srt")
            try? SRTWriter.render(model.cues).write(
                to: srtTemporario, atomically: true, encoding: .utf8)
            let quantasAntes = model.cues.count
            model.loadSubtitles(from: srtTemporario)
            expect(model.translatedCues.count == quantasAntes, "carregar .srt traz as mesmas legendas")
            expect(model.canRetranslate,
                   "importar traducao preserva o original para retraduzir")
            expect(model.loadedFromFile, "marca que a legenda veio de arquivo")
            model.jump(to: 2)
            expect(model.activeIndex == 2, "navegacao funciona com legenda carregada")
            try? FileManager.default.removeItem(at: srtTemporario)

            // Importar só carrega; traduzir exige uma ação separada.
            let originalImport = FileManager.default.temporaryDirectory
                .appendingPathComponent("original-\(UUID().uuidString).srt")
            let importedText = ("Hello from SRT. " + String(repeating: "This timing must remain unchanged. ", count: 4))
                .trimmingCharacters(in: .whitespaces)
            let originalSRT = "1\n00:00:01,250 --> 00:00:03,750\n\(importedText)\n"
            try? originalSRT.write(to: originalImport, atomically: true, encoding: .utf8)
            let motorAntesDoImport = model.translationEngine
            model.translationEngine = .transcriptionOnly
            model.loadSubtitles(from: originalImport, as: .original)
            expect(model.stage == .done && !model.isWorking,
                   "importar original nao inicia traducao")
            expect(model.originalCues.first?.source == importedText,
                   "original importado substitui apenas a faixa original")
            model.retranslate()
            let prazoImport = Date().addingTimeInterval(5)
            while model.isWorking && Date() < prazoImport {
                try? await Task.sleep(for: .milliseconds(20))
            }
            expect(model.stage == .done, "importar SRT original termina a traducao")
            expect(model.cues.first?.source == importedText,
                   "o texto original do SRT fica preservado")
            expect(model.cues.first?.translated == importedText,
                   "a traducao usa somente o texto importado")
            expect(model.cues.count == 1,
                   "traduzir o SRT não cria novas legendas")
            expect(abs((model.cues.first?.start ?? 0) - 1.25) < 0.001
                   && abs((model.cues.first?.end ?? 0) - 3.75) < 0.001,
                   "importar SRT original preserva os timecodes")
            expect(model.canRetranslate, "SRT original fica disponivel para retraduzir")

            let originalExport = FileManager.default.temporaryDirectory
                .appendingPathComponent("original-export-\(UUID().uuidString).srt")
            model.export(to: originalExport, track: .original)
            let originalExportText = (try? String(contentsOf: originalExport, encoding: .utf8)) ?? ""
            expect(originalExportText.contains("Hello from SRT."),
                   "exportacao original escreve o idioma falado")
            expect(model.suggestedSRTName(for: .original).hasSuffix(".\(model.sourceLanguage.rawValue).srt"),
                   "nome da exportacao original usa o idioma falado")
            try? FileManager.default.removeItem(at: originalExport)
            model.translationEngine = motorAntesDoImport
            try? FileManager.default.removeItem(at: originalImport)

            // Regerar tem que limpar o que estava la.
            model.generate()
            try? await Task.sleep(for: .milliseconds(400))
            expect(model.cues.isEmpty, "regerar limpa as legendas antigas")
            expect(model.activeIndex == nil, "regerar limpa a legenda marcada")
            expect(model.isWorking, "regerar entra em trabalho")

            // E cancelar tem que parar de verdade.
            model.cancelGeneration()
            try? await Task.sleep(for: .milliseconds(300))
            expect(model.stage == .cancelled, "cancelar deixa o estado em cancelado")
            expect(!model.isWorking, "cancelar encerra o trabalho")
            expect(model.canGenerate, "da para gerar de novo depois de cancelar")

            // Devolve as legendas para o resto do teste.
            model.loadSubtitles(from: destinoParaTeste)
            try? FileManager.default.removeItem(at: destinoParaTeste)

            // --- volume e mudo ---
            model.volume = 0.4
            expect(abs((model.player?.volume ?? 0) - 0.4) < 0.001,
                   "o volume chega ao player")
            model.toggleMute()
            expect(model.isMuted && model.player?.isMuted == true, "mudo liga")
            model.volume = 0.8
            expect(!model.isMuted, "mexer no volume tira do mudo")
            model.volume = 1.0

            // --- tamanho da legenda ---
            // A escala e preferencia do usuario, gravada em UserDefaults:
            // restaura na mesma passada, sem `defer` (que `exit()` pula).
            expect(SubtitleStudioModel.defaultSubtitleScale == 0.6, "a legenda comeca em 60%")

            // --- escolha do reconhecimento ---
            expect(TranscriberKind(for: .portuguese, engine: .parakeet) == .parakeet,
                   "Parakeet escolhido roda no portugues, que ele cobre")
            expect(TranscriberKind(for: .japanese, engine: .parakeet) == .whisper,
                   "Parakeet com idioma que ele nao cobre cai no Whisper")
            expect(TranscriberKind(for: .japanese, engine: .whisper) == .whisper,
                   "Whisper escolhido vale para japones")
            expect(RecognitionEngine.parakeet.supportedLanguages?.contains(.japanese) == false,
                   "o seletor nao oferece japones no Parakeet")
            expect(RecognitionEngine.whisper.supportedLanguages == nil,
                   "o Whisper nao limita idioma")
            expect(TranscriberKind(for: .japanese, engine: .apple) == .apple,
                   "Apple escolhida vale para qualquer idioma")
            let catalogo = AppleSpeechLanguages.shared
            await catalogo.refresh()
            write("Apple: instalados \(catalogo.installed.map(\.rawValue)), instalaveis \(catalogo.installable.map(\.rawValue))")
            expect(catalogo.supported.contains(.japanese), "a Apple oferece japones")
            expect(!catalogo.supported.contains(.arabic), "a Apple nao oferece arabe")
            expect(Set(catalogo.installed).isSubset(of: Set(catalogo.supported)),
                   "instalado e sempre um dos oferecidos")
            let escalaDoUsuario = model.subtitleScale
            model.subtitleScale = 1
            model.resizeSubtitles(by: 1)
            expect(abs(model.subtitleScale - 1.1) < 0.001, "aumentar a legenda sobe 10%")
            model.resizeSubtitles(by: -2)
            expect(abs(model.subtitleScale - 0.9) < 0.001, "diminuir a legenda desce 10%")
            model.resizeSubtitles(by: -100)
            expect(model.subtitleScale == SubtitleStudioModel.subtitleScaleRange.lowerBound,
                   "a legenda tem tamanho minimo")
            model.resizeSubtitles(by: 100)
            expect(model.subtitleScale == SubtitleStudioModel.subtitleScaleRange.upperBound,
                   "a legenda tem tamanho maximo")
            model.subtitleScale = escalaDoUsuario

            // --- arrastar a barra: busca rapida, depois exata ---
            // Metade do vídeo, não 30 s fixos: num vídeo de 18 s o tempo era
            // corretamente limitado ao fim e o teste acusava falha.
            let meioDoVideo = model.duration / 2
            model.seek(to: meioDoVideo, exact: false)
            expect(abs(model.currentTime - meioDoVideo) < 0.01, "arrastar a barra move o tempo na hora")
            model.seek(to: model.cues[1].start + 0.02)
            try? await Task.sleep(for: .milliseconds(300))
            expect(model.activeIndex == 1, "soltar a barra cai exatamente na legenda")

            // --- ocultar o video ---
            expect(model.showsVideo, "o video comeca visivel")
            model.showsVideo = false
            try? await Task.sleep(for: .milliseconds(200))
            window.contentView?.needsDisplay = true
            expect(!model.showsVideo, "o video pode ser ocultado")
            model.showsVideo = true

            // --- clicar numa legenda com o video pausado ---
            model.seek(to: 0)
            expect(!model.isPlaying, "o teste roda com o video pausado")
            let antes = model.currentTime
            let alvoPausado = min(6, model.cues.count - 1)
            model.jump(to: alvoPausado)
            try? await Task.sleep(for: .milliseconds(400))
            expect(model.currentTime != antes,
                   "clicar numa legenda move o video mesmo pausado")
            expect(model.activeIndex == alvoPausado,
                   "a legenda clicada vira a ativa mesmo pausado")
            let quadro = model.player?.currentTime().seconds ?? -1
            expect(abs(quadro - model.cues[alvoPausado].start) < 0.3,
                   String(format: "o quadro exibido acompanha (%.2fs vs %.2fs)",
                          quadro, model.cues[alvoPausado].start))

            // --- tamanho da area do video ---
            let larguraInicial = model.listWidth
            model.listWidth = 480
            expect(model.listWidth == 480, "a coluna de legendas redimensiona")
            model.listWidth = larguraInicial

            // O limite do divisor sai da largura da janela, nao de um teto
            // fixo: com 560 fixo o divisor travava no meio de uma janela larga
            // e, na estreita, encolher a janela deixava o video com alguns
            // pixels.
            let limite = SubtitleStudioModel.self
            expect(limite.clampListWidth(2000, available: 1600)
                   == 1600 - limite.minimumVideoWidth,
                   "numa janela larga o divisor vai ate onde o video ainda cabe")
            expect(limite.clampListWidth(900, available: 1000) <= 1000 - limite.minimumVideoWidth,
                   "encolher a janela encolhe a lista junto")
            expect(limite.clampListWidth(10, available: 1600) == limite.minimumListWidth,
                   "a lista nunca some")
            expect(limite.defaultListWidth > 320,
                   "a lista abre mais larga que os 320 antigos (\(limite.defaultListWidth))")

            // --- clicar no video alterna reproducao ---
            expect(!model.isPlaying, "comeca pausado")
            model.togglePlay()
            expect(model.isPlaying, "o clique no video inicia a reproducao")
            model.togglePlay()
            expect(!model.isPlaying, "o clique de novo pausa")

            // Exportar para um caminho escolhido.
            let destino = FileManager.default.temporaryDirectory
                .appendingPathComponent("exportada-\(UUID().uuidString).srt")
            model.export(to: destino)
            expect(model.savedSRT == destino, "exportar registra onde a legenda foi gravada")
            expect(FileManager.default.fileExists(atPath: destino.path),
                   "exportar grava o arquivo no destino escolhido")
            let conteudo = (try? String(contentsOf: destino, encoding: .utf8)) ?? ""
            expect(conteudo.contains(" --> "), "o arquivo exportado tem formato SubRip")
            expect(conteudo.split(separator: "\n\n").count == model.cues.count,
                   "o exportado tem uma entrada por legenda")
            expect(model.suggestedSRTName.hasSuffix(".\(model.writtenLanguage.rawValue).srt"),
                   "o nome sugerido traz o idioma (\(model.suggestedSRTName))")
            try? FileManager.default.removeItem(at: destino)

            // O proprio app se desenha num PNG. Nao precisa de permissao de
            // gravacao de tela, e mostra o layout de verdade.
            if let content = window.contentView,
               let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/studio.png"))
                    write("layout gravado em /tmp/studio.png (\(Int(content.bounds.width))x\(Int(content.bounds.height)))")
                }
            }

            write("")
            write("primeiras legendas:")
            for cue in model.cues.prefix(5) {
                write("  \(SRTWriter.timecode(cue.start)) → \(SRTWriter.timecode(cue.end))")
                write("    \(cue.source)")
                write("    \(cue.translated)")
            }

            model.stop()
            write("")
            write(relatorio.failures == 0 ? "PASSOU" : "\(relatorio.failures) falhas")
            exit(relatorio.failures == 0 ? 0 : 1)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let model = studios.removeValue(forKey: window) else { return }
        // Solta o player e o observador de tempo junto com a janela.
        model.stop()
    }

    private func notify(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.runModal()
    }
}

// O topo de main.swift roda fora do MainActor, mas tudo aqui e AppKit.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    // O delegate precisa sobreviver ao escopo: NSApplication nao o retem.
    objc_setAssociatedObject(application, "tradutor.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    application.run()
}
