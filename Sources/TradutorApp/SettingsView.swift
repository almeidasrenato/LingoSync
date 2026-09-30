import AppKit
import AudioCapture
import SwiftUI
import TradutorCore

/// O menu do app, na barra de menus.
///
/// Organizado pelo que o usuário quer fazer, não pela ordem em que as coisas
/// foram criadas: os idiomas valem para tudo e ficam em cima; depois o que é
/// da tradução ao vivo; depois o que é de vídeo. Antes o botão de restaurar
/// o painel ao vivo morava abaixo dos itens de vídeo, e o seletor do Whisper
/// para vídeo morava entre eles.
struct SettingsView: View {

    @Bindable var pipeline: Pipeline
    var updates: UpdateChecker
    var onRefresh: () -> Void
    var onToggle: () -> Void
    var onResetPanel: () -> Void
    var onMakeSubtitles: () -> Void
    var onMakeText: () -> Void
    var onOpenStudio: () -> Void
    var onNewStudio: () -> Void

    @Bindable private var interface = Interface.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                // O balão do ícone do app, em cor chapada. O degradê
                // azul-violeta saiu junto com o violeta da paleta.
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.onBrand)
                    .frame(width: 40, height: 40)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("LingoSync")
                        .font(.display)
                        .foregroundStyle(Color.ink)
                        .fixedSize()
                    Text(L("Áudio ao vivo e legendas de vídeo", "Live audio and video subtitles"))
                        .font(.caption)
                        .foregroundStyle(Color.inkSoft)
                }
                Spacer(minLength: 8)
                // Só existe quando há versão nova: um botão "procurar
                // atualização" sempre à vista seria ruído no menu que se abre
                // dez vezes por dia.
                if let release = updates.available {
                    Button {
                        updates.install()
                    } label: {
                        Label(updates.downloading ? L("Baixando…", "Downloading…") : L("Atualizar", "Update"),
                              systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(PastelButtonStyle(prominent: true))
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(updates.downloading)
                    .help(L("Versão \(release.version) disponível (esta é a \(updates.currentVersion)). "
                            + "Baixa o .dmg e o abre; arraste o app para Aplicativos.",
                            "Version \(release.version) is available (this is \(updates.currentVersion)). "
                            + "Downloads the .dmg and opens it; drag the app into Applications."))
                }
            }
            .padding(.bottom, 2)

            card(L("Idiomas e modelos", "Languages and models"), icon: "character.bubble", tint: .sage) { languages }
            card(L("Ao vivo", "Live"), icon: "waveform", tint: .clay) { liveControls }
            card(L("Vídeos", "Videos"), icon: "film", tint: .sand) { videoControls }

            HStack {
                if !pipeline.modelDiskUsage.isEmpty {
                    Label(pipeline.modelDiskUsage, systemImage: "internaldrive")
                        .monospacedDigit()
                        .help(L("Espaço ocupado pelos modelos em disco", "Disk space used by the models"))
                }
                Spacer()
                // O idioma do app, no rodapé: escolhe-se uma vez, e cada nome
                // vem escrito no próprio idioma, para quem não lê o atual.
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .accessibilityHidden(true)
                    PillPicker(title: L("Idioma do app", "App language"),
                               selection: $interface.language,
                               options: InterfaceLanguage.allCases, label: \.displayName)
                        .controlSize(.small)
                }
                .help(L("Idioma do app", "App language"))
                Link(destination: AppUpdate.repository) {
                    Label("GitHub", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help(L("Abre o repositório do app, com as versões e o código",
                        "Opens the app's repository, with releases and source code"))
                .foregroundStyle(Color.inkSoft)
                Text("·")
                Button(L("Encerrar", "Quit")) { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.inkSoft)
            }
            .font(.caption)
            .foregroundStyle(Color.inkSoft)
            .padding(.horizontal, 4)
        }
        .padding(14)
        .frame(width: 372)
        .background(Color.canvas)
        .buttonStyle(PastelButtonStyle())
        .tint(.brandInk)
    }

    private func card<Content: View>(
        _ title: String, icon: String, tint: Color.Tint, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                IconTile(symbol: icon, tint: tint)
                Text(title)
                    .font(.heading)
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface()
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.inkSoft)
    }

    // MARK: Idiomas — valem para o ao vivo e para os vídeos

    private var languages: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                caption(L("Reconhecimento", "Recognition"))
                Spacer()
                EnginePicker(selection: $pipeline.recognitionEngine, width: 158)
                    .controlSize(.small)
                    .disabled(pipeline.isRunning)
            }

            HStack {
                caption(L("Tradução", "Translation"))
                Spacer()
                TranslationEnginePicker(selection: $pipeline.translationEngine, width: 158)
                    .controlSize(.small)
                    .disabled(pipeline.isRunning)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    caption(L("Ouvir em", "Listen in"))
                    SourceLanguagePicker(
                        selection: $pipeline.sourceLanguage,
                        engine: pipeline.recognitionEngine,
                        width: 112
                    )
                    .disabled(pipeline.isRunning)
                }

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.inkSoft)
                    .padding(.top, 16)

                VStack(alignment: .leading, spacing: 5) {
                    caption(L("Traduzir para", "Translate to"))
                    PillPicker(title: L("Traduzir para", "Translate to"), selection: $pipeline.targetLanguage,
                               options: Language.allCases, label: \.displayName, width: 124)
                    // Sem tradução o destino não é usado por ninguém —
                    // apagado diz isso; escondido faria a linha saltar.
                    .disabled(pipeline.isRunning
                              || pipeline.translationEngine == .transcriptionOnly)
                }
            }

            // O motor de reconhecimento muda com o idioma, e a diferenca de
            // latencia e grande o suficiente para valer dizer ao usuario.
            Text(engineNote)
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
                .padding(.top, 2)

            // O mesmo para a traducao: um motor que nao cobre o par escolhido,
            // ou que nao serve ao vivo, precisa dizer isso aqui — senao o
            // usuario descobre no meio de uma geracao de dez minutos.
            if let translationNote {
                Text(translationNote)
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let erro = AppleSpeechLanguages.shared.lastError {
                Text(erro)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var engineNote: String {
        // Um motor que não serve ao vivo precisa dizer isso aqui: o painel é
        // o mesmo para os dois caminhos.
        if !pipeline.recognitionEngine.supportsLive {
            let video = pipeline.recognitionEngine.displayName
            let live = pipeline.recognitionEngine.forLive.displayName
            return L("\(video) só vale para vídeos · ao vivo usa \(live)",
                     "\(video) works on videos only · live uses \(live)")
        }
        return switch TranscriberKind(for: pipeline.sourceLanguage, engine: pipeline.recognitionEngine) {
        case .apple: L("Reconhecimento do macOS · idiomas instalados no sistema",
                       "macOS recognition · languages installed on the system")
        case .parakeet: L("Parakeet v3 · reconhecimento rápido", "Parakeet v3 · fast recognition")
        case .whisper: L("Whisper turbo · cobertura ampla, mais lento", "Whisper turbo · broad coverage, slower")
        case .qwen: L("Qwen3-ASR 0.6B · melhor em japonês, 27× tempo real",
                      "Qwen3-ASR 0.6B · best for Japanese, 27× real time")
        case .qwenLarge: L("Qwen3-ASR 1.7B · o mais preciso, 7× tempo real",
                           "Qwen3-ASR 1.7B · most accurate, 7× real time")
        }
    }

    /// Nota sob os seletores, so quando ha o que dizer.
    private var translationNote: String? {
        let engine = pipeline.translationEngine
        guard engine != .apple else { return nil }
        if engine == .transcriptionOnly {
            let idioma = pipeline.sourceLanguage.displayName
            return L("Só o texto reconhecido, em \(idioma) · vale ao vivo e nos vídeos",
                     "Only the recognized text, in \(idioma) · live and on videos")
        }
        // Ao vivo agora passa qualquer motor. O que custa precisa dizer
        // quanto custa aqui, senão o usuário descobre pelo atraso na tela.
        if let custo = engine.liveCostNote {
            let cobertura = engine.supports(pipeline.sourceLanguage, pipeline.targetLanguage)
                ? "" : L(" · não cobre este par de idiomas", " · does not cover this language pair")
            return L("\(engine.displayName) ao vivo: \(custo)", "\(engine.displayName) live: \(custo)")
                + (engine.leavesTheMachine ? L(" · o texto sai da máquina", " · text leaves your Mac") : "")
                + cobertura
        }
        return nil
    }

    // MARK: Ao vivo

    private var liveControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    caption(L("Capturar o áudio de", "Capture audio from"))
                    Spacer()
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.brandInk)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L("Atualizar a lista", "Refresh the list"))
                    .help(L("Atualizar a lista de aplicativos e de microfones", "Refresh the list of apps and microphones"))
                }

                // Quem esta tocando som aparece marcado: e quase sempre
                // o que o usuario quer, e evita escolher o app errado.
                PillPicker(title: L("Capturar o áudio de", "Capture audio from"), selection: $pipeline.selectedProcess,
                           options: [nil] + pipeline.availableProcesses.map(Optional.some),
                           label: { process in
                               guard let process else { return L("Escolha a fonte", "Choose a source") }
                               return process.isPlaying ? "● \(process.name)" : process.name
                           },
                           width: .infinity)
                    .disabled(pipeline.isRunning)

                // Qual microfone só é pergunta depois que "Microfone" é a
                // resposta da primeira. Padrão do sistema na frente, e é ele
                // que continua valendo quando o usuário troca de fone no meio
                // da reunião — um ID gravado ficaria apontando para o anterior.
                if pipeline.selectedProcess?.isMicrophone == true {
                    PillPicker(title: L("Microfone", "Microphone"), selection: $pipeline.selectedInputDevice,
                               options: [nil] + pipeline.availableInputs.map(Optional.some),
                               label: { device in
                                   device?.name ?? L("Padrão do sistema", "System default")
                                       + (AudioInputList.systemDefault.map { " (\($0.name))" } ?? "")
                               },
                               width: .infinity)
                        .disabled(pipeline.isRunning)
                }

                if let selected = pipeline.selectedProcess,
                   !selected.isSystemWide, !selected.isMicrophone {
                    // Confirmacao visivel de que a escolha pegou, e de quantos
                    // processos ela cobre — o Chrome, por exemplo, toca audio
                    // num helper, nao no processo principal.
                    Text(selected.pids.count > 1
                         ? L("\(selected.name) · \(selected.pids.count) processos",
                             "\(selected.name) · \(selected.pids.count) processes")
                         : L("\(selected.name) · 1 processo", "\(selected.name) · 1 process"))
                        .font(.meta)
                        .foregroundStyle(Color.inkSoft)
                }
            }

            Button(action: onToggle) {
                Label(pipeline.isRunning ? L("Parar tradução", "Stop translating")
                                         : L("Iniciar tradução", "Start translating"),
                      systemImage: pipeline.isRunning ? "stop.fill" : "waveform")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PastelButtonStyle(prominent: true))
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(pipeline.selectedProcess == nil && !pipeline.isRunning)
            .frame(maxWidth: .infinity)

            HStack(spacing: 5) {
                Circle()
                    .fill(pipeline.isWarm ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(pipeline.isWarm ? L("modelos carregados", "models loaded")
                                     : L("carregando modelos…", "loading models…"))
                    .font(.meta)
                    .foregroundStyle(Color.inkSoft)
                    .help(pipeline.engineNames)
                Spacer()
                Text(L("atalho", "shortcut"))
                    .font(.meta)
                    .foregroundStyle(Color.inkSoft)
                Text(GlobalHotKey.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // O painel nao tem barra de titulo, entao se for arrastado para
            // fora da tela ou encolhido demais nao ha como recupera-lo a nao
            // ser por aqui.
            Button(L("Restaurar tamanho do painel", "Reset panel size"), action: onResetPanel)
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(Color.brandInk)
                .help(L("Arraste as bordas do painel para escolher o tamanho; ele é lembrado.",
                        "Drag the panel edges to resize it; the size is remembered."))
        }
    }

    // MARK: Vídeos

    private var videoControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            // O principal primeiro: gera, grava o .srt e ainda deixa assistir.
            Button {
                onOpenStudio()
            } label: {
                Label(L("Assistir com legenda…", "Watch with subtitles…"), systemImage: "play.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .help(L("Gera a legenda e reproduz o vídeo com ela, com navegação por "
                    + "fala — pelo áudio ou lendo a legenda que já está desenhada no "
                    + "vídeo. Se já houver uma janela aberta, traz ela de volta.",
                    "Generates subtitles and plays the video with them, line by line — "
                    + "from the audio or by reading subtitles already burned into the "
                    + "video. If a window is already open, brings it back."))

            // Visível sempre, inclusive sem janela nenhuma aberta. Escondida
            // atrás de uma condição, ninguém a acharia — é a mesma lição dos
            // controles de locutor no painel.
            //
            // E com moldura, não `.borderless` como o "Restaurar tamanho do
            // painel": ali o texto solto funciona porque está sozinho, aqui
            // ficava espremido entre dois botões cheios e era lido como
            // legenda de um deles. `.small` mantém a diferença de peso.
            Button {
                onNewStudio()
            } label: {
                Label(L("Abrir outra janela", "Open another window"), systemImage: "plus.rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .help(L("Abre mais uma janela de legendas, para outro vídeo", "Opens another subtitle window, for another video"))

            Button {
                onMakeSubtitles()
            } label: {
                Label(L("Só gerar o .srt de um vídeo…", "Just make an .srt…"), systemImage: "text.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .disabled(pipeline.isRunning)
            .help(L("Transcreve e traduz um arquivo, gerando um .srt com os tempos",
                    "Transcribes and translates a file into a timed .srt"))

            // Irmão do de cima, e não opção dentro dele: quem quer o texto de
            // um áudio não está pensando em legenda. Segue o tradutor
            // escolhido — com "Só transcrever" sai a fala como foi dita.
            Button {
                onMakeText()
            } label: {
                Label(L("Só extrair o texto (.txt)…", "Just extract the text (.txt)…"), systemImage: "text.alignleft")
                    .frame(maxWidth: .infinity)
            }
            .disabled(pipeline.isRunning)
            .help(L("Transcreve um vídeo ou áudio num .txt corrido, sem tempos nem "
                    + "cortes de legenda. Traduz se houver tradutor escolhido.",
                    "Transcribes a video or audio file into running .txt, with no "
                    + "timecodes or subtitle breaks. Translates if a translator is chosen."))

            // Aparece quando o reconhecimento escolhido tem como marcar quem
            // fala. Vale só aqui: o ao vivo não tem o áudio inteiro.
            if pipeline.recognitionEngine.supportsDiarization {
                Toggle(L("Identificar quem fala", "Identify speakers"), isOn: $pipeline.diarizeSpeakers)
                    .font(.control)
                    .help(L("Separa as legendas por locutor e marca a troca com travessão. "
                            + "Acrescenta um passo à geração.",
                            "Splits subtitles by speaker and marks each change with a dash. "
                            + "Adds a step to generation."))

                // Visíveis mesmo desligadas, e apagadas.
                //
                // Estavam escondidas atrás do interruptor, e o resultado foi
                // ninguém as achar: quem não liga a identificação não
                // descobre que existe escolha de modelo nem de cor.
                Group {
                    HStack(spacing: 6) {
                        caption(L("Por", "With"))
                        PillPicker(title: L("Modelo de vozes", "Voice model"), selection: $pipeline.speakerModel,
                                   options: SpeakerDiarizer.Model.allCases, label: \.displayName,
                                   width: .infinity)
                        .controlSize(.small)
                        .help(L("Sortformer é um modelo só, ponta a ponta: mais rápido, marca mais legendas e devolve sempre o mesmo resultado. Agrupamento de vozes segmenta, extrai a voz e agrupa — acha menos vozes em conversa de duas pessoas.",
                                "Sortformer is a single end-to-end model: faster, labels more subtitles and always returns the same result. Voice clustering segments, extracts voices and groups them — it finds fewer voices in two-person conversations."))
                    }
                    .padding(.leading, 18)

                    Toggle(L("Uma cor por locutor", "One color per speaker"), isOn: $pipeline.colorBySpeaker)
                        .font(.control)
                        // O rótulo da caixa não apaga sozinho quando está
                        // desligada: sem isto ela parecia disponível.
                        .foregroundStyle(pipeline.diarizeSpeakers ? Color.ink : Color.inkSoft.opacity(0.6))
                        .padding(.leading, 18)
                        .help(L("Na janela de legendas e no .srt exportado, cada voz ganha "
                                + "uma cor (branco, amarelo, ciano, verde)",
                                "In the subtitle window and the exported .srt, each voice gets "
                                + "a color (white, yellow, cyan, green)"))
                }
                .disabled(!pipeline.diarizeSpeakers)
            }

            Text(L("Assista e revise na janela de legendas, ou gere apenas o .srt ou o texto.",
                   "Watch and review in the subtitle window, or just make the .srt or the text."))
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A versão nova no GitHub, se houver. Ver `AppUpdate`.
@MainActor
@Observable
final class UpdateChecker {
    /// Público para o autoteste de layout poder mostrar o botão.
    var available: AppUpdate.Release?
    private(set) var downloading = false
    private var lastCheck: Date?

    let currentVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// Na abertura do menu, no máximo a cada 6 h: o menu abre muitas vezes
    /// por dia, e a resposta muda uma vez por release. Sem rede, calado —
    /// não ter como saber não é defeito para mostrar.
    func checkIfDue() {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 3600 { return }
        lastCheck = Date()
        Task {
            guard let release = try? await AppUpdate.latest(),
                  AppUpdate.isNewer(release.version, than: currentVersion) else { return }
            available = release
        }
    }

    /// Baixa o `.dmg` para Downloads e o abre. Sem `.dmg`, ou se o download
    /// falhar, abre a página da release: o usuário chega lá de qualquer jeito.
    func install() {
        guard let release = available, !downloading else { return }
        guard let dmg = release.diskImage else {
            NSWorkspace.shared.open(release.page)
            return
        }
        downloading = true
        Task {
            defer { downloading = false }
            do {
                let (temp, response) = try await URLSession.shared.download(from: dmg)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                let destination = downloads.appendingPathComponent(
                    "LingoSync-\(release.version).dmg")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temp, to: destination)
                NSWorkspace.shared.open(destination)
            } catch {
                NSWorkspace.shared.open(release.page)
            }
        }
    }
}
