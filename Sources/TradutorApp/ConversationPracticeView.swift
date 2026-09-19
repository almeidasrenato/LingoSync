import AudioCapture
import SwiftUI
import TradutorCore

/// A janela de prática de conversa.
struct ConversationPracticeView: View {
    @Bindable var model: ConversationPracticeModel
    /// Glossário do hover, preenchido conforme o ponteiro passa. Fica na view
    /// porque é estado de tela: some quando a janela fecha.
    @State private var glossary: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 480)
        .onAppear { model.refreshSources() }
    }

    // MARK: - Cabeçalho

    private var header: some View {
        HStack(spacing: 10) {
            PulsingDiamond(active: model.isProfessorSpeaking)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.isProfessorSpeaking ? "o professor está falando" : "prática de conversa")
                    .font(.system(size: 12, weight: .medium))
                Text("\(model.sourceLanguage.displayName) → \(model.targetLanguage.displayName)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isRunning {
                Button("Parar") { model.stop() }
            } else {
                Button("Começar") { Task { await model.start() } }
                    .disabled(model.professorProcess == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - A conversa

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.turns.isEmpty { emptyState }
                    ForEach(model.turns) { turn in
                        TurnBubble(
                            turn: turn,
                            isLatestProfessor: turn.id == model.lastProfessorTurn?.id,
                            glossary: $glossary,
                            gloss: { await model.gloss(for: $0) },
                            onToggleHidden: { model.toggleHidden(turn) }
                        )
                        .id(turn.id)
                    }
                    if !model.professorPartial.isEmpty {
                        PartialBubble(text: model.professorPartial, speaker: .professor)
                    }
                }
                .padding(14)
            }
            .onChange(of: model.turns.count) {
                guard let last = model.turns.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.state {
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            case let .loading(what):
                Label(what, systemImage: "hourglass").foregroundStyle(.secondary)
            default:
                Text("Escolha de onde vem a voz do professor e comece.")
                    .foregroundStyle(.secondary)
                // O tap do Core Audio é por processo, não por aba: escolher o
                // navegador captura todo o áudio dele.
                Text("Escolher um navegador capta o áudio dele inteiro, "
                     + "incluindo outras abas.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
    }

    // MARK: - Rodapé

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isRunning {
                HStack(spacing: 8) {
                    Image(systemName: model.isStudentSpeaking ? "waveform" : "mic")
                        .foregroundStyle(model.isStudentSpeaking ? .green : .secondary)
                        .symbolEffect(.variableColor, isActive: model.isStudentSpeaking)
                    Text(model.isStudentSpeaking
                         ? "transcrevendo sua resposta…"
                         : "sua vez — fale quando quiser")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if !model.studentPartial.isEmpty {
                        Text(model.studentPartial)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.primary.opacity(0.6))
                    }
                }
            } else {
                controls
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var controls: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Professor").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $model.professorProcess) {
                    Text("Escolha a fonte").tag(AudioProcess?.none)
                    ForEach(model.availableProcesses) { process in
                        Text(process.isPlaying ? "● \(process.name)" : process.name)
                            .tag(AudioProcess?.some(process))
                    }
                }
                .labelsHidden()
                Button {
                    model.refreshSources()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Atualizar a lista de aplicativos e de microfones")
            }
            GridRow {
                Text("Você").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $model.microphoneDevice) {
                    ForEach(model.availableInputs) { device in
                        Text(device.name).tag(AudioInputDevice?.some(device))
                    }
                }
                .labelsHidden()
                .gridCellColumns(2)
            }
            GridRow {
                Text("Hover").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $model.hoverEngine) {
                    ForEach(ConversationPracticeModel.hoverEngines, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .labelsHidden()
                .gridCellColumns(2)
                .help("Quem traduz a palavra sob o ponteiro. Local, sem ida à rede.")
            }
        }
        .font(.system(size: 11))
    }
}

// MARK: - Losango

/// O losango do cabeçalho, pulsando enquanto o professor fala.
private struct PulsingDiamond: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        Rectangle()
            .fill(active ? Color.accentColor : Color.secondary.opacity(0.35))
            .frame(width: 18, height: 18)
            .rotationEffect(.degrees(45))
            .scaleEffect(active && pulse ? 1.25 : 1.0)
            .animation(
                active
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onChange(of: active) { _, novo in pulse = novo }
            .frame(width: 30, height: 30)
    }
}

// MARK: - Bolhas

private struct TurnBubble: View {
    let turn: ConversationPracticeModel.Turn
    let isLatestProfessor: Bool
    @Binding var glossary: [String: String]
    let gloss: (String) async -> String?
    let onToggleHidden: () -> Void

    private var isProfessor: Bool { turn.speaker == .professor }

    var body: some View {
        HStack {
            if !isProfessor { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 6) {
                // O original com as palavras vivas: passar o mouse traduz uma.
                HoverableText(text: turn.source, glossary: $glossary, gloss: gloss)
                    .foregroundStyle(isProfessor ? .primary : Color.white)

                if isProfessor, let translated = turn.translated {
                    if turn.translationHidden {
                        Text("tradução escondida")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(translated)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                if isProfessor, turn.translated != nil {
                    Button(action: onToggleHidden) {
                        Image(systemName: turn.translationHidden ? "eye.slash" : "eye")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .help(turn.translationHidden
                          ? "Mostrar a tradução"
                          : "Esconder a tradução e praticar a compreensão")
                }
            }

            if isProfessor { Spacer(minLength: 40) }
        }
    }

    private var background: some ShapeStyle {
        if !isProfessor { return AnyShapeStyle(Color.green.opacity(0.85)) }
        // A última fala do professor é a que está em jogo.
        return AnyShapeStyle(
            isLatestProfessor
                ? Color.primary.opacity(0.14)
                : Color.primary.opacity(0.06)
        )
    }
}

/// O que o reconhecedor ainda está mastigando.
private struct PartialBubble: View {
    let text: String
    let speaker: ConversationPracticeModel.Speaker

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 40)
        }
    }
}

// MARK: - Texto com palavra traduzível

/// Cada palavra é uma view, para o ponteiro poder pousar numa só.
///
/// A tradução aparece no balão do próprio sistema (`.help`), que já sabe se
/// posicionar e desaparecer — um popover na mão seria mais código para um
/// resultado pior. O texto chega depois da consulta, e o balão acompanha.
private struct HoverableText: View {
    let text: String
    @Binding var glossary: [String: String]
    let gloss: (String) async -> String?

    var body: some View {
        // Escrita densa (japonês, chinês) não tem espaço entre palavras, e
        // colocar um estragaria a linha.
        let spacing: CGFloat = text.contains(" ") ? 4 : 0
        FlowLayout(spacing: spacing, lineSpacing: 3) {
            ForEach(Array(Tokens.words(text).enumerated()), id: \.offset) { _, token in
                WordView(token: token, glossary: $glossary, gloss: gloss)
            }
        }
    }

}

private struct WordView: View {
    let token: String
    @Binding var glossary: [String: String]
    let gloss: (String) async -> String?
    @State private var hovering = false

    /// Só a palavra, sem a pontuação que veio junto.
    private var word: String {
        token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    var body: some View {
        Text(token)
            .font(.system(size: 13))
            .underline(hovering && !word.isEmpty, pattern: .dot)
            .help(glossary[word.lowercased()] ?? "")
            .onHover { dentro in
                hovering = dentro
                guard dentro, !word.isEmpty, glossary[word.lowercased()] == nil else { return }
                Task {
                    if let traducao = await gloss(word) {
                        glossary[word.lowercased()] = traducao
                    }
                }
            }
    }
}

/// Quebra de linha para as palavras. `Layout` do sistema, sem dependência.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let largura = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, alturaDaLinha: CGFloat = 0
        for view in subviews {
            let tamanho = view.sizeThatFits(.unspecified)
            if x > 0, x + tamanho.width > largura {
                x = 0
                y += alturaDaLinha + lineSpacing
                alturaDaLinha = 0
            }
            x += tamanho.width + spacing
            alturaDaLinha = max(alturaDaLinha, tamanho.height)
        }
        return CGSize(
            width: largura == .infinity ? x : largura,
            height: y + alturaDaLinha
        )
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, alturaDaLinha: CGFloat = 0
        for view in subviews {
            let tamanho = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + tamanho.width > bounds.maxX {
                x = bounds.minX
                y += alturaDaLinha + lineSpacing
                alturaDaLinha = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += tamanho.width + spacing
            alturaDaLinha = max(alturaDaLinha, tamanho.height)
        }
    }
}
