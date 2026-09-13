import Foundation

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

    public var displayName: String {
        switch self {
        case .portuguese: "Português"
        case .english: "Inglês"
        case .spanish: "Espanhol"
        case .french: "Francês"
        case .german: "Alemão"
        case .italian: "Italiano"
        case .dutch: "Holandês"
        case .polish: "Polonês"
        case .russian: "Russo"
        case .ukrainian: "Ucraniano"
        case .japanese: "Japonês"
        case .chinese: "Chinês"
        case .korean: "Coreano"
        case .arabic: "Árabe"
        case .hindi: "Híndi"
        case .turkish: "Turco"
        case .vietnamese: "Vietnamita"
        case .thai: "Tailandês"
        }
    }

    /// Nome do idioma escrito nele mesmo. Vai no prompt de traducao, porque
    /// o modelo responde melhor ao endonimo do que ao nome em portugues.
    public var endonym: String {
        switch self {
        case .portuguese: "português"
        case .english: "English"
        case .spanish: "español"
        case .french: "français"
        case .german: "Deutsch"
        case .italian: "italiano"
        case .dutch: "Nederlands"
        case .polish: "polski"
        case .russian: "русский"
        case .ukrainian: "українська"
        case .japanese: "日本語"
        case .chinese: "中文"
        case .korean: "한국어"
        case .arabic: "العربية"
        case .hindi: "हिन्दी"
        case .turkish: "Türkçe"
        case .vietnamese: "Tiếng Việt"
        case .thai: "ไทย"
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
