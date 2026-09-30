import Foundation
import Observation

/// O idioma da interface: inglês por padrão, português à escolha.
///
/// Independente dos idiomas de fala e de tradução — quem traduz japonês para
/// português pode querer o app em inglês, e o contrário. Gravado em
/// `idiomaDaInterface`; ausente, inglês, que é o idioma do README e de quem
/// baixa a release sem saber de onde ela veio.
public enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case portuguese = "pt"

    public var id: String { rawValue }

    /// Sempre no próprio idioma: quem não lê a interface atual precisa achar
    /// o seu.
    public var displayName: String {
        switch self {
        case .english: "English"
        case .portuguese: "Português"
        }
    }

    /// Para datas e números no texto exportado.
    public var locale: Locale {
        Locale(identifier: self == .portuguese ? "pt_BR" : "en_US")
    }
}

/// Quem guarda a escolha. `@Observable` para a SwiftUI redesenhar sozinha:
/// toda view que chama `L` lê `language` dentro do `body`, e a troca chega a
/// ela sem ninguém avisar.
@Observable
public final class Interface: @unchecked Sendable {
    public static let shared = Interface()
    public static let preferenceKey = "idiomaDaInterface"

    public var language: InterfaceLanguage {
        didSet { defaults?.set(language.rawValue, forKey: Self.preferenceKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults?

    /// - Parameter defaults: `nil` não grava nada — é o que os autotestes usam.
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        language = defaults?.string(forKey: Self.preferenceKey)
            .flatMap(InterfaceLanguage.init(rawValue:)) ?? .english
    }
}

/// O texto no idioma da interface.
///
/// Português primeiro porque é o idioma em que o código já estava escrito; as
/// duas frases ficam lado a lado, completas, para ninguém montar mensagem por
/// pedaços (a ordem das palavras muda entre os dois).
public func L(_ portuguese: String, _ english: String) -> String {
    Interface.shared.language == .portuguese ? portuguese : english
}
