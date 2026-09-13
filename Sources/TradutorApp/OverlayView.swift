import SwiftUI
import TradutorCore

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
                pinned
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
        )
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
                            opacity: max(0.3, 0.7 - Double(age) * 0.07),
                            sourceSize: 8
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
            if subtitles.current != nil || !subtitles.partial.isEmpty || subtitles.isTranslating {
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

            if subtitles.history.isEmpty, subtitles.current == nil, subtitles.partial.isEmpty {
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
        VStack(alignment: .leading, spacing: sourceSize < 9 ? 1 : 3) {
            // Origem: pequena e sem destaque, so como ancora. No historico ela
            // encolhe ainda mais — ali ela serve so para localizar o trecho,
            // nao para ser lida.
            Text(block.source)
                .font(.system(size: sourceSize))
                .foregroundStyle(.white.opacity(0.3 * opacity))
                .lineLimit(1)
                .truncationMode(.tail)

            ForEach(LineBreaker.wrap(block.translated), id: \.self) { line in
                Text(line)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(opacity)
    }

    // MARK: Estados

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(pipeline.sourceLanguage.displayName) → \(pipeline.targetLanguage.displayName)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))

            if pipeline.lastTranslateMs > 0 {
                Text("\(pipeline.lastTranscribeMs + pipeline.lastTranslateMs) ms")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.26))
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Parar a tradução")
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
    static let yellowZone = Color(red: 0.86, green: 0.68, blue: 0.29)
    static let blueZone = Color(red: 0.56, green: 0.74, blue: 0.96)
    static let redZone = Color(red: 0.92, green: 0.44, blue: 0.38)
}
