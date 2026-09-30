import Foundation
import NaturalLanguage

/// Idiomas que o app oferece, com o que cada motor precisa saber sobre eles.
public enum Language: String, CaseIterable, Identifiable, Sendable, Codable {
    case portuguese = "pt"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case dutch = "nl"
    case polish = "pl"
    case russian = "ru"
    case ukrainian = "uk"
    case japanese = "ja"
    case chinese = "zh"
    case korean = "ko"
    case arabic = "ar"
    case hindi = "hi"
    case turkish = "tr"
    case vietnamese = "vi"
    case thai = "th"

    public var id: String { rawValue }

    /// No idioma da interface.
    public var displayName: String {
        switch self {
        case .portuguese: L("Português", "Portuguese")
        case .english: L("Inglês", "English")
        case .spanish: L("Espanhol", "Spanish")
        case .french: L("Francês", "French")
        case .german: L("Alemão", "German")
        case .italian: L("Italiano", "Italian")
        case .dutch: L("Holandês", "Dutch")
        case .polish: L("Polonês", "Polish")
        case .russian: L("Russo", "Russian")
        case .ukrainian: L("Ucraniano", "Ukrainian")
        case .japanese: L("Japonês", "Japanese")
        case .chinese: L("Chinês", "Chinese")
        case .korean: L("Coreano", "Korean")
        case .arabic: L("Árabe", "Arabic")
        case .hindi: L("Híndi", "Hindi")
        case .turkish: L("Turco", "Turkish")
        case .vietnamese: L("Vietnamita", "Vietnamese")
        case .thai: L("Tailandês", "Thai")
        }
    }

    /// Parakeet TDT v3 cobre 25 idiomas europeus e roda perto de 120x tempo
    /// real. Fora dessa lista o Whisper assume, ao custo de uns 240 ms.
    public var hasParakeetSupport: Bool {
        switch self {
        case .portuguese, .english, .spanish, .french, .german, .italian,
             .dutch, .polish, .russian, .ukrainian:
            true
        case .japanese, .chinese, .korean, .arabic, .hindi, .turkish,
             .vietnamese, .thai:
            false
        }
    }
}

extension Language {
    /// O idioma de um texto que já existe — uma legenda importada.
    ///
    /// Era o seletor de fala, que nasce em inglês e não é gravado: um `.srt`
    /// japonês importado como original ia ao tradutor "from English" (visto
    /// no registro do Gemini de 22/09/2026) e seria exportado como `.en.srt`.
    /// Aqui o texto está inteiro na mão, e o detector do sistema acerta:
    /// medido, 1,000 no japonês, 0,999 a 1,000 nos três `.pt.srt` de exemplo,
    /// 0,994 no inglês.
    ///
    /// - Returns: `nil` abaixo de 0,8 de certeza — uma legenda de uma palavra
    ///   só ("OK" deu 0,29) — ou fora dos idiomas do app; quem chama fica
    ///   com o seletor.
    public static func detect(in texts: [String]) -> Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(texts.joined(separator: "\n"))
        guard let (found, certainty) = recognizer.languageHypotheses(withMaximum: 1).first,
              certainty >= 0.8
        else { return nil }
        let code = Locale.Language(identifier: found.rawValue).languageCode
        return allCases.first { Locale.Language(identifier: $0.rawValue).languageCode == code }
    }
}
