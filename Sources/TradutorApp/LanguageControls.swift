import SwiftUI
import TradutorCore

/// Quem reconhece a fala. Usado no menu e na janela de legendas.
struct EnginePicker: View {

    @Binding var selection: RecognitionEngine

    var body: some View {
        Picker("Reconhecimento", selection: $selection) {
            ForEach(RecognitionEngine.allCases.filter(\.isAvailable)) { engine in
                Text(engine.displayName).tag(engine)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("""
              Quem reconhece a fala. Parakeet é o mais rápido, mas só cobre os \
              idiomas europeus; Whisper cobre todos. Apple usa o \
              reconhecimento do macOS, com os idiomas instalados no sistema. \
              A lista de idiomas ao lado mostra só o que o escolhido cobre.
              """)
    }
}

/// Quem traduz. Vale para vídeo e para o ao vivo.
struct TranslationEnginePicker: View {

    @Binding var selection: TranslationEngine

    var body: some View {
        Picker("Tradução", selection: $selection) {
            // Só o que existe: o Hunyuan mora num ambiente que o usuário
            // instala à parte, e oferecer o que não está lá daria erro no
            // meio de uma geração.
            ForEach(TranslationEngine.allCases.filter(\.isAvailable)) { engine in
                Text(engine.displayName).tag(engine)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("""
              Quem traduz as legendas de vídeo. Apple é local e instantânea. \
              DeepL abre o site numa janela e traduz por lá — o melhor em \
              japonês, medido. Google é o mais rápido e chega perto dele. \
              Gemini conversa com o chat do site, sempre na sessão anônima — \
              sem conta, sem histórico salvo. Os três de rede mandam o texto \
              para fora da máquina e precisam de internet. Hunyuan-MT é \
              local como a Apple e roda fora do processo, quando instalado. \
              "Só transcrever" pula a tradução e deixa o texto no idioma \
              falado. Todos valem ao vivo também — os de rede custam \
              segundos por bloco, e a nota abaixo diz quanto.
              """)
    }
}

/// Idioma de origem.
///
/// A lista mostra só o que o reconhecimento escolhido cobre: o que está
/// instalado no Mac para a Apple (com o + ao lado para instalar mais um), os
/// idiomas europeus para o Parakeet e todos para o Whisper.
struct SourceLanguagePicker: View {

    @Binding var selection: Language
    let engine: RecognitionEngine
    var width: CGFloat?

    private var catalog: AppleSpeechLanguages { .shared }

    var body: some View {
        HStack(spacing: 4) {
            Picker("Idioma original", selection: $selection) {
                ForEach(options) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .frame(width: width)

            if engine == .apple { installControl }
        }
        .task(id: engine) {
            // Ao trocar de reconhecimento, o idioma tem que ser um que ele
            // cobre — senão a tradução falharia só na hora de começar.
            if engine == .apple { await catalog.refresh() }
            if let first = available.first, !available.contains(selection) {
                selection = first
            }
        }
    }

    /// O que o reconhecimento escolhido cobre de fato.
    private var available: [Language] {
        if engine == .apple { return catalog.installed }
        return engine.supportedLanguages ?? Language.allCases
    }

    private var options: [Language] {
        // O selecionado fica na lista enquanto a troca não acontece: um
        // Picker com seleção fora das opções aparece em branco.
        var list = available
        if !list.contains(selection) { list.append(selection) }
        return list
    }

    @ViewBuilder
    private var installControl: some View {
        if let installing = catalog.installing {
            ProgressView(value: catalog.installProgress)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .help("Instalando \(installing.displayName)… \(Int(catalog.installProgress * 100))%")
        } else {
            Menu {
                Section("Instalar no reconhecimento da Apple") {
                    ForEach(catalog.installable) { language in
                        Button(language.displayName) {
                            Task {
                                if await catalog.install(language) { selection = language }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(catalog.installable.isEmpty)
            .help(catalog.installable.isEmpty
                  ? "Todos os idiomas da Apple já estão instalados"
                  : "Instalar mais um idioma no reconhecimento da Apple")
        }
    }
}
