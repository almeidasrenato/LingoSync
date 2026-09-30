import AppKit
import SwiftUI
import TradutorCore
import UniformTypeIdentifiers

/// As tres zonas.
///
/// A hierarquia visual e o ponto: o idioma de origem fica pequeno e apagado,
/// servindo so de ancora, e a traducao recebe todo o peso. Cada bloco fica
/// curto de proposito — leitura em tempo real nao sobrevive a paragrafo longo.
///
/// O layout e deliberadamente dividido em duas partes: so o historico rola.
/// A traducao atual e o que esta sendo captado ficam ancorados embaixo, porque
/// sao justamente o que o usuario esta lendo agora — se rolassem junto, sairiam
/// de vista no momento em que mais importam.
struct OverlayView: View {

    @Bindable var pipeline: Pipeline
    var onClose: () -> Void

    /// Opacidade do fundo, não da janela. Era `alphaValue` entre 0,82 e 1,
    /// começando no mínimo: o controle só deixava o painel mais opaco, e o
    /// texto apagava junto com o fundo. Agora o texto fica inteiro e o fundo
    /// vai até 0,35, com sombra na letra quando o vídeo começa a aparecer.
    @AppStorage("opacidadeDoFundoDoPainel") private var backgroundOpacity = 0.9

    /// Texto corrido em vez de legenda: para ditar, ou tirar o texto de um
    /// áudio, e colar em outro lugar.
    @AppStorage("painelEmTextoCorrido") private var proseMode = false

    private var subtitles: SubtitleStore { pipeline.subtitles }
    private let bottomAnchor = "fim-do-historico"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 10)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            switch pipeline.state {
            case let .loading(label, fraction):
                loading(label, fraction)
                    .padding(.horizontal, 22)
                Spacer(minLength: 0)
            case let .failed(message):
                failure(message)
                    .padding(.horizontal, 22)
                Spacer(minLength: 0)
            default:
                Group {
                    if proseMode { prose } else { history }
                }
                .shadow(color: readingShadow, radius: 2, y: 1)
                .frame(minHeight: 0)
                .layoutPriority(-1)
                pinned
                    .shadow(color: readingShadow, radius: 2, y: 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.panelInk.opacity(backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .tint(Color.blueZone)
    }

    /// Com o fundo transparente, legenda clara sobre cena clara some. Só no
    /// texto de leitura: nos controles a sombra borrava o rótulo da pílula.
    private var readingShadow: Color {
        .black.opacity(seeThrough ? 0.8 : 0)
    }

    /// Fundo quase transparente: os controles ganham chão próprio, senão o
    /// véu branco de 7% some sobre cena clara e o botão vira ícone solto.
    private var seeThrough: Bool { backgroundOpacity < 0.75 }
    /// O cinza de apoio some sobre cena clara; com o fundo transparente o
    /// apoio sobe para o tom do texto e a hierarquia fica no tamanho.
    private var muted: Color { seeThrough ? .panelText : .panelMuted }
    private var controlFill: Color { seeThrough ? Color.panelInk.opacity(0.75) : .white.opacity(0.07) }

    // MARK: Zona amarela — a unica que rola

    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 13) {
                    if subtitles.history.isEmpty {
                        Spacer(minLength: 0)
                    }
                    ForEach(Array(subtitles.history.enumerated()), id: \.element.id) { index, block in
                        let age = subtitles.history.count - index
                        block_(
                            block,
                            size: 15,
                            color: .yellowZone,
                            opacity: max(0.6, 0.85 - Double(age) * 0.04),
                            sourceSize: 10.5
                        )
                        .id(block.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.bottom, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
            // Rola sozinho ao chegar bloco novo, mas so ate o fim: o usuario
            // que subiu para reler continua podendo subir.
            .onChange(of: subtitles.history.count) {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    // MARK: Texto corrido — a sessão inteira, selecionável

    /// A fala original inteira, sem hora nem corte de legenda, e o que ainda
    /// está sendo captado emendado no fim, em coral. É a fala e não a
    /// tradução porque o modo existe para tirar o texto do que foi dito; a
    /// tradução continua no botão de copiar do cabeçalho.
    private var prose: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    let text = CaptureExport.prose(subtitles.transcript) { $0.source }
                    let partial = subtitles.partial.isEmpty
                        ? "" : (text.isEmpty ? "" : " ") + subtitles.partial
                    Text("\(text)\(Text(partial).foregroundStyle(Color.redZone))")
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .foregroundStyle(Color.panelText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
            .onChange(of: subtitles.transcript.count) { scrollToEnd(proxy) }
            .onChange(of: subtitles.partial) { scrollToEnd(proxy) }
            .onAppear { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    // MARK: Zonas azul e vermelha — ancoradas, nunca rolam

    private var pinned: some View {
        VStack(alignment: .leading, spacing: 9) {
            // No texto corrido a fala atual e a captada já estão no texto.
            let current = proseMode ? nil : subtitles.current
            let partial = proseMode ? "" : subtitles.partial
            if current != nil || !partial.isEmpty
                || (subtitles.isTranslating && !proseMode) || pipeline.translationError != nil
                || pipeline.isPaused {
                Rectangle()
                    .fill(.white.opacity(0.07))
                    .frame(height: 1)
                    .padding(.bottom, 3)
            }

            if let current {
                block_(current, size: 21, color: .blueZone, opacity: 1, weight: .semibold)
            }

            if !partial.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.redZone)
                            .frame(width: 5, height: 5)
                        Text(L("captando", "hearing"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.redZone.opacity(0.75))
                    }
                    ForEach(LineBreaker.wrap(partial), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.redZone)
                    }
                }
            } else if subtitles.isTranslating, !proseMode {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(.white.opacity(0.5))
                    Text(L("traduzindo", "translating"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            // Sem tradutor de reserva, bloco recusado some da tela — e
            // silêncio do tradutor e silêncio do falante são a mesma imagem.
            if let erro = pipeline.translationError {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(erro)
                        .font(.system(size: 10))
                        .lineLimit(2)
                }
                .foregroundStyle(Color.redZone.opacity(0.85))
                .help(erro)
            }

            // Sem isto, painel pausado e painel em silêncio são a mesma tela.
            if pipeline.isPaused {
                HStack(spacing: 6) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9))
                    Text(L("pausado", "paused"))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.45))
            } else if subtitles.history.isEmpty, subtitles.current == nil,
                      subtitles.partial.isEmpty {
                Text(L("Aguardando fala em \(pipeline.sourceLanguage.displayName)…", "Waiting for speech in \(pipeline.sourceLanguage.displayName)…"))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }

    private func block_(
        _ block: SubtitleBlock,
        size: CGFloat,
        color: Color,
        opacity: Double,
        weight: Font.Weight = .medium,
        sourceSize: CGFloat = 10.5
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: sourceSize < 9 ? 1 : 3) {
                // Origem: pequena e sem destaque, so como ancora. No historico ela
                // encolhe ainda mais — ali ela serve so para localizar o trecho,
                // nao para ser lida.
                //
                // Sem traducao os dois textos sao o mesmo, e a ancora viraria eco:
                // a mesma frase duas vezes, uma apagada em cima da outra.
                if block.source != block.translated {
                    Text(block.source)
                        .font(.system(size: sourceSize))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                ForEach(LineBreaker.wrap(block.translated), id: \.self) { line in
                    Text(line)
                        .font(.system(size: size, weight: weight))
                        .foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .trailing, spacing: 4) {
                blockCopyButton(block.source, language: pipeline.sourceLanguage)
                if block.source != block.translated {
                    blockCopyButton(block.translated, language: pipeline.targetLanguage)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(opacity)
    }

    // MARK: Estados

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(pair)
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.panelText)
                    .lineLimit(1)
                    .shadow(color: readingShadow, radius: 2, y: 1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text(pipeline.engineNames + (pipeline.lastTranslateMs > 0
                    ? " · \(pipeline.lastTranscribeMs + pipeline.lastTranslateMs) ms" : ""))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .shadow(color: readingShadow, radius: 2, y: 1)
                    .help(L("Reconhecimento e tradução usados nesta captura", "Recognition and translation used in this capture"))
            }
            // Largo, com o rótulo "Texto"; sem espaço (380 px com tradução),
            // a pílula vira só ícone e o controle encolhe — antes as pílulas
            // de copiar truncavam em "…" e perdiam o idioma.
            ViewThatFits(in: .horizontal) {
                controls(compact: false)
                controls(compact: true)
            }
        }
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: 6) {
            copyButton(pipeline.sourceLanguage, L("Copiar o texto original", "Copy the original text")) { $0.source }
            if translating {
                copyButton(pipeline.targetLanguage, L("Copiar a tradução", "Copy the translation")) { $0.translated }
            }
            proseToggle(showsLabel: !compact)
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(Color.panelIcon)
                Slider(value: $backgroundOpacity, in: 0.35...1.0)
                    .controlSize(.mini)
                    .frame(width: compact ? 40 : 64)
                    .accessibilityLabel(L("Opacidade do fundo do painel", "Panel background opacity"))
            }
            .padding(.horizontal, seeThrough ? 7 : 0)
            .frame(height: 26)
            .background(seeThrough ? controlFill : .clear, in: Capsule())
            .font(.system(size: 10))
            .help(L("Transparência do fundo", "Background transparency"))

            icon(pipeline.isPaused ? "play.fill" : "pause.fill",
                 pipeline.isPaused ? L("Retomar a transcrição", "Resume transcription") : L("Pausar a transcrição", "Pause transcription")) {
                pipeline.togglePause()
            }
            icon("square.and.arrow.down", L("Exportar a captura com data e hora", "Export the capture with date and time")) { exportCapture() }
                .disabled(subtitles.transcript.isEmpty)
            icon("trash", L("Limpar o que foi captado", "Clear what was captured")) { pipeline.subtitles.clear() }
                .disabled(subtitles.transcript.isEmpty && subtitles.current == nil)
            icon("xmark", L("Parar a tradução", "Stop translating"), bold: true, action: onClose)
        }
    }

    /// Legenda ou texto corrido. Pílula como a de copiar, cheia quando ligada:
    /// o estado tem de se ler sem passar o mouse.
    private func proseToggle(showsLabel: Bool) -> some View {
        Button {
            proseMode.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10, weight: .medium))
                if showsLabel {
                    Text(L("Texto", "Text"))
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .fixedSize()
            .foregroundStyle(proseMode ? Color.panelInk : Color.panelIcon)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(proseMode ? Color.blueZone : controlFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(proseMode ? L("Voltar às legendas", "Back to subtitles") : L("Mostrar como texto corrido, para copiar", "Show as running text, for copying"))
        .accessibilityLabel(L("Texto corrido", "Running text"))
        .accessibilityAddTraits(proseMode ? .isSelected : [])
    }

    /// Há tradução nesta sessão, ou só transcrição?
    private var translating: Bool { pipeline.translationEngine != .transcriptionOnly }

    /// Copia a sessão inteira, uma fala por linha.
    ///
    /// A sessão inteira, e não o bloco: o painel tem 60 blocos na tela e um
    /// par de ícones em cada um viraria muro de botões. Quem quer um trecho só
    /// recorta do que foi colado.
    private func copyButton(
        _ language: Language, _ help: String, _ field: @escaping (SubtitleBlock) -> String
    ) -> some View {
        Button {
            // O que se copia é o que está na tela: no texto corrido, corrido.
            let texto = proseMode
                ? CaptureExport.prose(subtitles.transcript, field: field)
                : subtitles.transcript.map(field).filter { !$0.isEmpty }.joined(separator: "\n")
            copyToPasteboard(texto)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                Text(language.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold))
            }
            .fixedSize()
            .foregroundStyle(Color.blueZone)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(seeThrough ? controlFill : Color.blueZone.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(subtitles.transcript.isEmpty)
        .help(help)
    }

    private func blockCopyButton(_ text: String, language: Language) -> some View {
        Button {
            copyToPasteboard(text)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                Text(language.rawValue.uppercased())
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(muted)
        }
        .buttonStyle(.plain)
        .disabled(text.isEmpty)
        .help(L("Copiar esta fala em \(language.displayName)", "Copy this line in \(language.displayName)"))
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// O par de idiomas, ou só o falado quando não há tradução.
    private var pair: String {
        let source = pipeline.sourceLanguage.displayName
        guard translating else { return source + L(" · só transcrição", " · transcription only") }
        return "\(source) → \(pipeline.targetLanguage.displayName)"
    }

    private func icon(
        _ name: String, _ help: String, bold: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: bold ? .bold : .semibold))
                .foregroundStyle(Color.panelIcon)
                .frame(width: 26, height: 26)
                .background(controlFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Grava a sessão inteira num `.txt`, com o dia e a hora de cada fala.
    ///
    /// `begin`, e não `runModal`: o modal segura o laço principal, e é nele
    /// que a captura roda — o áudio que chegasse durante a escolha do arquivo
    /// encheria o buffer sem ninguém consumindo.
    private func exportCapture() {
        let target: Language? = pipeline.translationEngine == .transcriptionOnly
            ? nil : pipeline.targetLanguage
        let texto = CaptureExport.text(
            subtitles.transcript, from: pipeline.sourceLanguage, to: target
        )
        let panel = NSSavePanel()
        panel.title = L("Exportar a captura", "Export the capture")
        panel.nameFieldStringValue = CaptureExport.suggestedName()
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? texto.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func loading(_ label: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            ProgressView(value: fraction)
                .tint(Color.blueZone)
                .frame(maxWidth: 320)
            Text(L("Os modelos são baixados uma vez e ficam no disco.", "Models download once and stay on disk."))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Não foi possível iniciar", "Could not start"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.redZone)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension Color {
    /// As cores das tres zonas, escolhidas para ler sobre fundo escuro em cima
    /// de video: amarela apagada para o historico, azul clara para o atual,
    /// vermelha suave para o que ainda esta sendo captado.
    ///
    /// Em tom pastel sobre o fundo quase preto: amarelo manteiga, sálvia
    /// (a cor do app) e coral. Todas passam de 8:1 sobre o fundo — legenda
    /// é leitura em movimento, e pastel escuro demais não se lê de relance.
    /// O nome `blueZone` ficou da primeira versão, quando a atual era azul.
    static let yellowZone = Color(hex: 0xF2DDA4)
    static let blueZone = Color(hex: 0xB9DDBF)
    static let redZone = Color(hex: 0xF2A39A)

    /// O fundo do painel e os textos de apoio. O painel é sempre escuro
    /// porque flutua sobre vídeo, então não segue o tema do sistema.
    static let panelInk = Color(hex: 0x171916)
    static let panelText = Color(hex: 0xE6E9E2)
    static let panelMuted = Color(hex: 0xA0A69C)
    static let panelIcon = Color(hex: 0xCDD2C8)
}
