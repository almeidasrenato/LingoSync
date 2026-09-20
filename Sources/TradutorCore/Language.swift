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
