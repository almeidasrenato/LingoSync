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
    var onOpacityChange: (Double) -> Void

    @State private var windowOpacity = OverlayPanel.minimumOpacity

    private var subtitles: SubtitleStore { pipeline.subtitles }
    private let bottomAnchor = "fim-do-historico"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 10)

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
                history
                    .frame(minHeight: 0)
                    .layoutPriority(-1)
                pinned
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.panelInk)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .tint(Color.blueZone)
    }

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

    // MARK: Zonas azul e vermelha — ancoradas, nunca rolam

    private var pinned: some View {
        VStack(alignment: .leading, spacing: 9) {
            if subtitles.current != nil || !subtitles.partial.isEmpty
                || subtitles.isTranslating || pipeline.translationError != nil
                || pipeline.isPaused {
                Rectangle()
                    .fill(.white.opacity(0.07))
                    .frame(height: 1)
                    .padding(.bottom, 3)
            }

            if let current = subtitles.current {
                block_(current, size: 21, color: .blueZone, opacity: 1, weight: .semibold)
            }

            if !subtitles.partial.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.redZone)
                            .frame(width: 5, height: 5)
                        Text("captando")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.redZone.opacity(0.75))
                    }
                    ForEach(LineBreaker.wrap(subtitles.partial), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.redZone)
                    }
                }
            } else if subtitles.isTranslating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(.white.opacity(0.5))
                    Text("traduzindo")
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
                    Text("pausado")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.45))
            } else if subtitles.history.isEmpty, subtitles.current == nil,
                      subtitles.partial.isEmpty {
                Text("Aguardando fala em \(pipeline.sourceLanguage.displayName)…")
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
                        .foregroundStyle(Color.panelMuted)
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
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text(pipeline.engineNames + (pipeline.lastTranslateMs > 0
                    ? " · \(pipeline.lastTranscribeMs + pipeline.lastTranslateMs) ms" : ""))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.panelMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Reconhecimento e tradução usados nesta captura")
            }
            HStack(spacing: 6) {
                copyButton(pipeline.sourceLanguage, "Copiar o texto original") { $0.source }
                if translating {
                    copyButton(pipeline.targetLanguage, "Copiar a tradução") { $0.translated }
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundStyle(Color.panelIcon)
                    Slider(value: $windowOpacity, in: OverlayPanel.minimumOpacity...1.0)
                        .controlSize(.mini)
                        .frame(width: 54)
                        .accessibilityLabel("Opacidade do painel")
                }
                .font(.system(size: 10))
                .help("Transparência da janela")
                .onChange(of: windowOpacity) { _, value in onOpacityChange(value) }

                icon(pipeline.isPaused ? "play.fill" : "pause.fill",
                     pipeline.isPaused ? "Retomar a transcrição" : "Pausar a transcrição") {
                    pipeline.togglePause()
                }
                icon("square.and.arrow.down", "Exportar a captura com data e hora") { exportCapture() }
                    .disabled(subtitles.transcript.isEmpty)
                icon("trash", "Limpar o que foi captado") { pipeline.subtitles.clear() }
                    .disabled(subtitles.transcript.isEmpty && subtitles.current == nil)
                icon("xmark", "Parar a tradução", bold: true, action: onClose)
            }
        }
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
            let texto = subtitles.transcript
                .map(field)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            copyToPasteboard(texto)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                Text(language.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.blueZone)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Color.blueZone.opacity(0.14), in: Capsule())
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
            .foregroundStyle(Color.panelMuted)
        }
        .buttonStyle(.plain)
        .disabled(text.isEmpty)
        .help("Copiar esta fala em \(language.displayName)")
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// O par de idiomas, ou só o falado quando não há tradução.
    private var pair: String {
        let source = pipeline.sourceLanguage.displayName
        guard translating else { return source + " · só transcrição" }
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
                .background(.white.opacity(0.07), in: Circle())
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
        panel.title = "Exportar a captura"
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
            Text("Os modelos são baixados uma vez e ficam no disco.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Não foi possível iniciar")
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
