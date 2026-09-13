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
/// de fala real, porque para o modelo elas *são* uma predição confiante. O que
/// as denuncia é o texto, e o fato de aparecerem isoladas.
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
    /// A exigência de estar isolado é o que evita apagar um agradecimento
    /// verdadeiro: num vídeo que de fato termina agradecendo, a frase vem
    /// cercada de outras palavras, ou o trecho inteiro é ela — e aí o corte
    /// custa uma legenda no fim, não conteúdo no meio.
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

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
