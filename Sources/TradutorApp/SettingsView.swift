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
        VStack(alignment: .leading, spacing: 14) {
            Text("Tradutor Instantâneo")
                .font(.system(size: 13, weight: .semibold))

            Divider()

            languages

            Divider()

            section("Tradução ao vivo")
            liveControls

            Divider()

            section("Vídeos")
            videoControls

            Divider()

            Button("Encerrar") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 330)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.bottom, -6)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
    }

    // MARK: Idiomas — valem para o ao vivo e para os vídeos

    private var languages: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                caption("Reconhecimento")
                Spacer()
                EnginePicker(selection: $pipeline.recognitionEngine)
                    .controlSize(.small)
                    .disabled(pipeline.isRunning)
            }

            HStack {
                caption("Tradução")
                Spacer()
                TranslationEnginePicker(selection: $pipeline.translationEngine)
                    .controlSize(.small)
                    .disabled(pipeline.isRunning)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    caption("Ouvir em")
                    SourceLanguagePicker(
                        selection: $pipeline.sourceLanguage,
                        engine: pipeline.recognitionEngine
                    )
                    .disabled(pipeline.isRunning)
                }

                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 14)

                VStack(alignment: .leading, spacing: 5) {
                    caption("Traduzir para")
                    Picker("", selection: $pipeline.targetLanguage) {
                        ForEach(Language.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .disabled(pipeline.isRunning)
                }
            }

            // O motor de reconhecimento muda com o idioma, e a diferenca de
            // latencia e grande o suficiente para valer dizer ao usuario.
            Text(engineNote)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)

            // O mesmo para a traducao: um motor que nao cobre o par escolhido,
            // ou que nao serve ao vivo, precisa dizer isso aqui — senao o
            // usuario descobre no meio de uma geracao de dez minutos.
            if let translationNote {
                Text(translationNote)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let erro = AppleSpeechLanguages.shared.lastError {
                Text(erro)
                    .font(.system(size: 9.5))
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
        if !engine.supports(pipeline.sourceLanguage, pipeline.targetLanguage) {
            return "\(engine.displayName) nao cobre "
                + "\(pipeline.sourceLanguage.displayName) → "
                + "\(pipeline.targetLanguage.displayName) · a traducao usa a Apple"
        }
        return "\(engine.displayName) so vale para videos · ao vivo usa Apple"
            + (engine.leavesTheMachine ? " · o texto sai da maquina" : " · local")
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
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Atualizar a lista de aplicativos")
                }

                Picker("", selection: $pipeline.selectedProcess) {
                    Text("Escolha um aplicativo").tag(AudioProcess?.none)
                    ForEach(pipeline.availableProcesses) { process in
                        // Quem esta tocando som aparece marcado: e quase sempre
                        // o que o usuario quer, e evita escolher o app errado.
                        Text(process.isPlaying ? "● \(process.name)" : process.name)
                            .tag(AudioProcess?.some(process))
                    }
                }
                .labelsHidden()
                .disabled(pipeline.isRunning)

                if let selected = pipeline.selectedProcess, !selected.isSystemWide {
                    // Confirmacao visivel de que a escolha pegou, e de quantos
                    // processos ela cobre — o Chrome, por exemplo, toca audio
                    // num helper, nao no processo principal.
                    Text(selected.pids.count > 1
                         ? "\(selected.name) · \(selected.pids.count) processos"
                         : "\(selected.name) · 1 processo")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            Button(pipeline.isRunning ? "Parar tradução" : "Iniciar tradução") {
                onToggle()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(pipeline.selectedProcess == nil && !pipeline.isRunning)
            .frame(maxWidth: .infinity)

            HStack(spacing: 5) {
                Circle()
                    .fill(pipeline.isWarm ? Color.green : Color.orange)
                    .frame(width: 5, height: 5)
                Text(pipeline.isWarm ? "modelos carregados" : "carregando modelos…")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help(pipeline.engineNames)
                Spacer()
                Text("atalho")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(GlobalHotKey.displayName)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }

            // O painel nao tem barra de titulo, entao se for arrastado para
            // fora da tela ou encolhido demais nao ha como recupera-lo a nao
            // ser por aqui.
            Button("Restaurar tamanho do painel", action: onResetPanel)
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .help("Arraste as bordas do painel para escolher o tamanho; ele é lembrado.")
        }
    }

    // MARK: Vídeos

    private var videoControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // O principal primeiro: gera, grava o .srt e ainda deixa assistir.
            Button {
                onOpenStudio()
            } label: {
                Label("Assistir com legenda…", systemImage: "play.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .help("Gera a legenda e reproduz o vídeo com ela, com navegação por "
                  + "fala. Se já houver uma janela aberta, traz ela de volta.")

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
                    .font(.system(size: 11))
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
                        Picker("", selection: $pipeline.speakerModel) {
                            ForEach(SpeakerDiarizer.Model.allCases) { modelo in
                                Text(modelo.displayName).tag(modelo)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .help("Sortformer é um modelo só, ponta a ponta: mais rápido, marca mais legendas e devolve sempre o mesmo resultado. Agrupamento de vozes segmenta, extrai a voz e agrupa — acha menos vozes em conversa de duas pessoas.")
                    }
                    .padding(.leading, 18)

                    Toggle("Uma cor por locutor", isOn: $pipeline.colorBySpeaker)
                        .font(.system(size: 11))
                        .padding(.leading, 18)
                        .help("Na janela de legendas e no .srt exportado, cada voz ganha "
                              + "uma cor (branco, amarelo, ciano, verde)")
                }
                .disabled(!pipeline.diarizeSpeakers)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Os dois geram a mesma legenda, nos idiomas acima, e gravam o .srt ao lado do vídeo.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !pipeline.modelDiskUsage.isEmpty {
                    Text(pipeline.modelDiskUsage)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.quaternary)
                        .help("Espaço ocupado pelos modelos em disco")
                }
            }
        }
    }
}
