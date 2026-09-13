import Foundation
import OSLog
import Translation

/// Tradutor do sistema: gratuito, local e rápido.
///
/// Traduz uma requisição por vez e usa o contexto do que está dentro dela —
/// por isso vale mandar muitas legendas juntas. Entre requisições não há
/// memória.
///
/// Modelos locais (Qwen3 pelo MLX) foram testados no lugar dele e removidos:
/// custavam de três a dez vezes mais tempo e o português saía pior.
public final class AppleTranslator: Translator, @unchecked Sendable {

    public let engineName = "Apple Translation"
    private let log = Logger(subsystem: "app.tradutor", category: "AppleTranslator")

    private var session: TranslationSession?
    private var pair: (Language, Language)?

    /// A API do sistema cobra ida e volta, não texto: lote grande ganha, e
    /// ainda dá mais contexto ao tradutor dentro da mesma requisição.
    public var preferredBatchSize: Int { 40 }

    public init() {}

    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        // A sessão depende do par de idiomas, que só é conhecido na primeira
        // tradução. Aqui só se confirma que o framework responde.
        progress(1.0, "tradutor do sistema pronto")
    }

    public func reset() {
        session = nil
        pair = nil
    }

    public func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let session = try await session(from: source, to: target)
        let response = try await session.translate(trimmed)
        return response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Uma unica chamada para todas as frases do segmento.
    ///
    /// A resposta chega como sequencia assincrona e fora de ordem, por isso o
    /// indice viaja no `clientIdentifier` e o resultado e remontado na ordem
    /// original — legenda com as frases trocadas seria pior que legenda lenta.
    public func translate(_ texts: [String], from source: Language, to target: Language) async throws -> [String] {
        let trimmed = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let indexed = trimmed.enumerated().filter { !$0.element.isEmpty }
        guard !indexed.isEmpty else { return Array(repeating: "", count: texts.count) }
        guard indexed.count > 1 else {
            var results = Array(repeating: "", count: texts.count)
            results[indexed[0].offset] = try await translate(
                indexed[0].element, from: source, to: target
            )
            return results
        }

        let session = try await session(from: source, to: target)
        let requests = indexed.map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }

        var results = Array(repeating: "", count: texts.count)
        for try await response in session.translate(batch: requests) {
            guard let identifier = response.clientIdentifier,
                  let index = Int(identifier),
                  results.indices.contains(index)
            else { continue }
            results[index] = response.targetText
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return results
    }

    private func session(from source: Language, to target: Language) async throws -> TranslationSession {
        if let session, pair.map({ $0 == source && $1 == target }) == true {
            return session
        }

        let sourceLanguage = Locale.Language(identifier: source.rawValue)
        let targetLanguage = Locale.Language(identifier: target.rawValue)

        let status = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
        guard status == .installed else {
            // Baixar o pacote de idioma exige interface do sistema; não dá
            // para forçar em segundo plano.
            throw AppleTranslatorError.languageNotInstalled(source, target)
        }

        // O construtor direto de sessao chegou no macOS 26. Em macOS 15 a
        // unica porta de entrada e o modificador `.translationTask` do SwiftUI,
        // que exige uma view viva — nao vale o custo enquanto ninguem pedir.
        guard #available(macOS 26.0, *) else {
            throw AppleTranslatorError.needsNewerSystem
        }
        let fresh = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        try await fresh.prepareTranslation()
        self.session = fresh
        self.pair = (source, target)
        log.info("sessao \(source.rawValue, privacy: .public) -> \(target.rawValue, privacy: .public)")
        return fresh
    }
}

public enum AppleTranslatorError: LocalizedError {
    case languageNotInstalled(Language, Language)
    case needsNewerSystem

    public var errorDescription: String? {
        switch self {
        case let .languageNotInstalled(source, target):
            """
            O par \(source.displayName) → \(target.displayName) não está instalado.
            Abra Ajustes do Sistema > Idioma e Região > Idiomas Traduzidos e \
            baixe os dois, depois tente de novo.
            """
        case .needsNewerSystem:
            "O modo rápido de tradução precisa do macOS 26 ou mais recente."
        }
    }
}
