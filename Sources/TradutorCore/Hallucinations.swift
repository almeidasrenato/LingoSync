import Foundation

/// Frases que o Whisper inventa quando não há fala.
///
/// Em silêncio, música ou ruído, o modelo preenche o vazio com frases de
/// encerramento aprendidas dos vídeos em que foi treinado. Em japonês
/// "ご視聴ありがとうございました" aparece sozinha no meio de um vídeo de
/// supermercado; em inglês, "Thank you for watching".
///
/// Elas vêm com tempo e probabilidades normais — os números que o modelo
/// reporta (`noSpeechProb`, `avgLogprob`, razão de compressão) não as separam
/// de fala real, porque para o modelo elas *são* uma predição confiante. O texto
/// isolado é suspeito, mas também pode ter sido dito: confira o áudio antes de
/// apagar, quando houver reconhecimento da Apple instalado para o idioma.
public enum Hallucinations {

    /// Comparadas depois de tirar pontuação, espaço e caixa.
    private static let phrases: [String] = [
        // japonês
        "ご視聴ありがとうございました",
        "ご視聴ありがとうございます",
        "最後までご視聴いただきありがとうございました",
        "チャンネル登録をお願いします",
        "チャンネル登録よろしくお願いします",
        "おやすみなさい",
        "本日はご覧いただきありがとうございます",
        // inglês
        "thankyouforwatching",
        "thanksforwatching",
        "thankyousomuchforwatching",
        "pleasesubscribetomychannel",
        "subscribetomychannel",
        "seeyouinthenextvideo",
        // português e espanhol, para quando a origem for essa
        "obrigadoporassistir",
        "graciasporver",
    ]

    /// Verdadeiro quando o trecho é *só* uma dessas frases.
    ///
    /// Isto identifica candidatos, não prova alucinação. `filter` confirma
    /// no áudio para preservar um agradecimento que foi realmente falado.
    public static func isIsolatedFiller(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return true }

        for phrase in phrases {
            let target = normalize(phrase)
            guard !target.isEmpty else { continue }
            if normalized == target { return true }
            // Repetição da mesma frase colada em si mesma também é alucinação.
            if normalized.count <= target.count * 3,
               normalized.hasPrefix(target),
               normalized.replacingOccurrences(of: target, with: "").isEmpty {
                return true
            }
        }
        return false
    }

    public static func isConfirmed(_ text: String, by confirmation: String) -> Bool {
        let target = normalize(text)
        return !target.isEmpty && normalize(confirmation).contains(target)
    }

    /// Só candidatos pagam outra transcrição. Sem o idioma instalado, mantém
    /// o descarte anterior; não instala modelo nem usa rede. Medido em en/ja.
    public static func filter(
        _ pieces: [TimedText], samples: [Float], language: Language
    ) async throws -> [TimedText] {
        try Task.checkCancellation()
        let suspects = pieces.indices.filter { isIsolatedFiller(pieces[$0].text) }
        guard !suspects.isEmpty else { return pieces }
        var rejected = Set(suspects)
        guard #available(macOS 26.0, *), language == .english || language == .japanese else {
            return pieces.enumerated().filter { !rejected.contains($0.offset) }.map(\.element)
        }
        let apple = AppleSpeechTranscriber(language: language)
        let duration = Double(samples.count) / 16_000
        for index in suspects {
            try Task.checkCancellation()
            let piece = pieces[index]
            // Whisper pode inventar tempos depois do fim do arquivo. Nunca
            // passe um recorte vazio ao SpeechAnalyzer: ele não finaliza.
            guard !normalize(piece.text).isEmpty, piece.start.isFinite, piece.end.isFinite,
                  piece.end > piece.start, piece.start < duration, piece.end > 0 else { continue }
            let start = Int(max(0, piece.start - 0.5) * 16_000)
            let end = Int(min(duration, piece.end + 0.5) * 16_000)
            guard end > start else { continue }
            do {
                if !apple.isPrepared { try await apple.prepare { _, _ in } }
                let confirmation = try await apple.transcribe(Array(samples[start..<end]))
                if isConfirmed(piece.text, by: confirmation) { rejected.remove(index) }
            } catch {
                try Task.checkCancellation()
                // Falha na conferência não autoriza devolver a frase suspeita.
                if !apple.isPrepared { break }
            }
        }
        try Task.checkCancellation()
        return pieces.enumerated().filter { !rejected.contains($0.offset) }.map(\.element)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
