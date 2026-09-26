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
    var onRefresh: () -> Void
    var onToggle: () -> Void
    var onResetPanel: () -> Void
    var onMakeSubtitles: () -> Void
    var onOpenStudio: () -> Void
    var onNewStudio: () -> Void

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
                    Text("Tradutor Instantâneo")
                        .font(.display)
                        .foregroundStyle(Color.ink)
                    Text("Áudio ao vivo e legendas de vídeo")
                        .font(.caption)
                        .foregroundStyle(Color.inkSoft)
                }
            }
            .padding(.bottom, 2)

            card("Idiomas e modelos", icon: "character.bubble", tint: .sage) { languages }
            card("Ao vivo", icon: "waveform", tint: .clay) { liveControls }
            card("Vídeos", icon: "film", tint: .sand) { videoControls }

            HStack {
                if !pipeline.modelDiskUsage.isEmpty {
                    Label(pipeline.modelDiskUsage, systemImage: "internaldrive")
                        .monospacedDigit()
                        .help("Espaço ocupado pelos modelos em disco")
                }
                Spacer()
                Button("Encerrar") { NSApp.terminate(nil) }
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
                caption("Reconhecimento")
                Spacer()
                EnginePicker(selection: $pipeline.recognitionEngine, width: 158)
                    .controlSize(.small)
                    .disabled(pipeline.isRunning)
            }

            HStack {
                caption("Tradução")
                Spacer()
                TranslationEnginePicker(selection: $pipeline.translationEngine, width: 158)
                    .controlSize(.small)
                    .disabled(pipeline.isRunning)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    caption("Ouvir em")
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
                    caption("Traduzir para")
                    PillPicker(title: "Traduzir para", selection: $pipeline.targetLanguage,
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
            return "\(pipeline.recognitionEngine.displayName) só vale para vídeos · "
                + "ao vivo usa \(pipeline.recognitionEngine.forLive.displayName)"
        }
        return switch TranscriberKind(for: pipeline.sourceLanguage, engine: pipeline.recognitionEngine) {
        case .apple: "Reconhecimento do macOS · idiomas instalados no sistema"
        case .parakeet: "Parakeet v3 · reconhecimento rápido"
        case .whisper: "Whisper turbo · cobertura ampla, mais lento"
        case .qwen: "Qwen3-ASR 0.6B · melhor em japonês, 27× tempo real"
        case .qwenLarge: "Qwen3-ASR 1.7B · o mais preciso, 7× tempo real"
        }
    }

    /// Nota sob os seletores, so quando ha o que dizer.
    private var translationNote: String? {
        let engine = pipeline.translationEngine
        guard engine != .apple else { return nil }
        if engine == .transcriptionOnly {
            return "Só o texto reconhecido, em \(pipeline.sourceLanguage.displayName)"
                + " · vale ao vivo e nos vídeos"
        }
        // Ao vivo agora passa qualquer motor. O que custa precisa dizer
        // quanto custa aqui, senão o usuário descobre pelo atraso na tela.
        if let custo = engine.liveCostNote {
            let cobertura = engine.supports(pipeline.sourceLanguage, pipeline.targetLanguage)
                ? "" : " · não cobre este par de idiomas"
            return "\(engine.displayName) ao vivo: \(custo)"
                + (engine.leavesTheMachine ? " · o texto sai da máquina" : "")
                + cobertura
        }
        return nil
    }

    // MARK: Ao vivo

    private var liveControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    caption("Capturar o áudio de")
                    Spacer()
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.brandInk)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Atualizar a lista")
                    .help("Atualizar a lista de aplicativos e de microfones")
                }

                // Quem esta tocando som aparece marcado: e quase sempre
                // o que o usuario quer, e evita escolher o app errado.
                PillPicker(title: "Capturar o áudio de", selection: $pipeline.selectedProcess,
                           options: [nil] + pipeline.availableProcesses.map(Optional.some),
                           label: { process in
                               guard let process else { return "Escolha a fonte" }
                               return process.isPlaying ? "● \(process.name)" : process.name
                           },
                           width: .infinity)
                    .disabled(pipeline.isRunning)

                // Qual microfone só é pergunta depois que "Microfone" é a
                // resposta da primeira. Padrão do sistema na frente, e é ele
                // que continua valendo quando o usuário troca de fone no meio
                // da reunião — um ID gravado ficaria apontando para o anterior.
                if pipeline.selectedProcess?.isMicrophone == true {
                    PillPicker(title: "Microfone", selection: $pipeline.selectedInputDevice,
                               options: [nil] + pipeline.availableInputs.map(Optional.some),
                               label: { device in
                                   device?.name ?? "Padrão do sistema"
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
                         ? "\(selected.name) · \(selected.pids.count) processos"
                         : "\(selected.name) · 1 processo")
                        .font(.meta)
                        .foregroundStyle(Color.inkSoft)
                }
            }

            Button(action: onToggle) {
                Label(pipeline.isRunning ? "Parar tradução" : "Iniciar tradução",
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
                Text(pipeline.isWarm ? "modelos carregados" : "carregando modelos…")
                    .font(.meta)
                    .foregroundStyle(Color.inkSoft)
                    .help(pipeline.engineNames)
                Spacer()
                Text("atalho")
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
            Button("Restaurar tamanho do painel", action: onResetPanel)
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(Color.brandInk)
                .help("Arraste as bordas do painel para escolher o tamanho; ele é lembrado.")
        }
    }

    // MARK: Vídeos

    private var videoControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            // O principal primeiro: gera, grava o .srt e ainda deixa assistir.
            Button {
                onOpenStudio()
            } label: {
                Label("Assistir com legenda…", systemImage: "play.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .help("Gera a legenda e reproduz o vídeo com ela, com navegação por "
                  + "fala — pelo áudio ou lendo a legenda que já está desenhada no "
                  + "vídeo. Se já houver uma janela aberta, traz ela de volta.")

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
                Label("Abrir outra janela", systemImage: "plus.rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .help("Abre mais uma janela de legendas, para outro vídeo")

            Button {
                onMakeSubtitles()
            } label: {
                Label("Só gerar o .srt de um vídeo…", systemImage: "text.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .disabled(pipeline.isRunning)
            .help("Transcreve e traduz um arquivo, gerando um .srt com os tempos")

            // Aparece quando o reconhecimento escolhido tem como marcar quem
            // fala. Vale só aqui: o ao vivo não tem o áudio inteiro.
            if pipeline.recognitionEngine.supportsDiarization {
                Toggle("Identificar quem fala", isOn: $pipeline.diarizeSpeakers)
                    .font(.control)
                    .help("Separa as legendas por locutor e marca a troca com travessão. "
                          + "Acrescenta um passo à geração.")

                // Visíveis mesmo desligadas, e apagadas.
                //
                // Estavam escondidas atrás do interruptor, e o resultado foi
                // ninguém as achar: quem não liga a identificação não
                // descobre que existe escolha de modelo nem de cor.
                Group {
                    HStack(spacing: 6) {
                        caption("Por")
                        PillPicker(title: "Modelo de vozes", selection: $pipeline.speakerModel,
                                   options: SpeakerDiarizer.Model.allCases, label: \.displayName,
                                   width: .infinity)
                        .controlSize(.small)
                        .help("Sortformer é um modelo só, ponta a ponta: mais rápido, marca mais legendas e devolve sempre o mesmo resultado. Agrupamento de vozes segmenta, extrai a voz e agrupa — acha menos vozes em conversa de duas pessoas.")
                    }
                    .padding(.leading, 18)

                    Toggle("Uma cor por locutor", isOn: $pipeline.colorBySpeaker)
                        .font(.control)
                        // O rótulo da caixa não apaga sozinho quando está
                        // desligada: sem isto ela parecia disponível.
                        .foregroundStyle(pipeline.diarizeSpeakers ? Color.ink : Color.inkSoft.opacity(0.6))
                        .padding(.leading, 18)
                        .help("Na janela de legendas e no .srt exportado, cada voz ganha "
                              + "uma cor (branco, amarelo, ciano, verde)")
                }
                .disabled(!pipeline.diarizeSpeakers)
            }

            Text("Assista e revise na janela de legendas, ou gere apenas o arquivo SRT.")
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
