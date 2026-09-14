import Foundation
import OSLog

/// Google Tradutor pelo endereço interno do site — JSON, sem navegador.
///
/// O DeepL precisa de um `WKWebView` visível porque o site só traduz quando o
/// editor recebe um evento de cola (ver `DeepLWeb`). Aqui o campo de texto
/// chama um endereço que devolve JSON, e é ele que o app chama: sem janela,
/// sem cookie, sem desafio da Cloudflare.
///
/// Medido em 13/09/2026, 110 falas japonesas, M5: Google 1,3 s · DeepL 11,0 s
/// (mais ~11 s da 1ª carga de página) · Apple 36,4 s. Qualidade entre os dois:
/// gênero 3/8 contra 6/8 do DeepL e 2/9 da Apple; nome próprio 4/4, igual ao
/// DeepL.
///
/// **O site do Google funde linhas; este endereço não.** Cada fala vai como um
/// parâmetro `q` e volta como um item do vetor — não existe texto corrido para
/// fundir. No corte que derrubava o site:
///
///     ヨークの命が惜しければ、海岸の船を全部避 / けろ。
///       site   1 linha  "…mova todos os navios para o mar."
///       aqui   2 linhas "Se a vida de York estiver em risco, evite todos
///                        os navios da costa." / "Kello."
///
/// O preço está na segunda: sem texto corrido não há contexto entre as falas,
/// e o pedaço órfão vira bobagem. É a troca — alinhamento garantido, contexto
/// nenhum.
///
/// O texto sai da máquina e não há API pública: automatizar contraria os
/// termos de uso, como já vale para o site do DeepL. É opção do usuário.
public final class GoogleWebTranslator: Translator, @unchecked Sendable {

    public let engineName = "Google Tradutor"
    private let log = Logger(subsystem: "app.tradutor", category: "Google")

    /// Teto em **bytes de URL**, não em falas: japonês escapado custa 9 bytes
    /// por caractere. Medido: 110 `q` dão 13,7 KB e passam, 220 dão 400 Bad
    /// Request, 880 dão 413. 8000 é metade do que passou.
    public static let urlBudget = 8000

    public var preferredBatchSize: Int { 40 }

    public init() {}

    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        progress(1.0, "Google pronto")
    }

    public func reset() {}

    /// `pt` já é o brasileiro no Google; `pt-PT` é que precisa ser pedido.
    public static func code(for language: Language) -> String {
        language == .chinese ? "zh-CN" : language.rawValue
    }

    public func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        try await translate([text], from: source, to: target).first ?? ""
    }

    public func translate(
        _ texts: [String], from source: Language, to target: Language
    ) async throws -> [String] {
        try await WebAPI.porBlocos(
            texts,
            blocos: { falas in Self.blocos(falas, source: source, target: target) },
            traduzir: { falas in try await self.pedir(falas, from: source, to: target) }
        )
    }

    /// Reparte em requisições que cabem na URL, preservando os índices.
    public static func blocos(_ falas: [String], source: Language, target: Language) -> [[Int]] {
        let base = endereco(source: source, target: target)
        var saida: [[Int]] = []
        var atual: [Int] = []
        var conta = base.utf8.count
        for (indice, fala) in falas.enumerated() {
            let custo = WebAPI.escapar(fala).utf8.count + 3  // "&q=" + texto
            // Fala sozinha maior que o teto vai assim mesmo: uma truncada é
            // melhor que todas desalinhadas.
            if !atual.isEmpty, conta + custo > urlBudget {
                saida.append(atual)
                atual = []
                conta = base.utf8.count
            }
            atual.append(indice)
            conta += custo
        }
        if !atual.isEmpty { saida.append(atual) }
        return saida
    }

    private static func endereco(source: Language, target: Language) -> String {
        "https://clients5.google.com/translate_a/t?client=dict-chrome-ex"
            + "&sl=\(code(for: source))&tl=\(code(for: target))"
    }

    private func pedir(_ falas: [String], from source: Language, to target: Language) async throws -> [String] {
        let consulta = falas.map { "&q=" + WebAPI.escapar($0) }.joined()
        guard let url = URL(string: Self.endereco(source: source, target: target) + consulta)
        else { throw WebAPIError.malformed }

        let dados = try await WebAPI.buscar(URLRequest(url: url))
        guard let saida = try? JSONDecoder().decode([String].self, from: dados) else {
            throw WebAPIError.unexpectedShape
        }
        guard saida.count == falas.count else {
            throw WebAPIError.countMismatch(expected: falas.count, got: saida.count)
        }
        return saida
    }
}

// MARK: - Encanamento

enum WebAPIError: LocalizedError {
    case malformed
    case unexpectedShape
    case countMismatch(expected: Int, got: Int)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .malformed: "Não consegui montar o endereço do tradutor."
        case .unexpectedShape: "O tradutor respondeu num formato que não reconheço."
        case let .countMismatch(esperadas, obtidas):
            "O tradutor devolveu \(obtidas) linhas para \(esperadas)."
        case let .http(codigo): "O tradutor respondeu \(codigo)."
        }
    }
}

public enum WebAPI {

    static let attempts = 3
    static let backoff: [Duration] = [.seconds(2), .seconds(5)]

    /// Sem isto o Google recusa com "your computer may be sending automated
    /// queries" antes de olhar a consulta.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    /// Efêmera, pelo mesmo motivo do `WKWebView` do DeepL: nada de site fica
    /// em disco.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }()

    static func buscar(_ pedido: URLRequest) async throws -> Data {
        var ultimo: Error = WebAPIError.unexpectedShape
        for tentativa in 0..<attempts {
            try Task.checkCancellation()
            do {
                let (dados, resposta) = try await session.data(for: pedido)
                let codigo = (resposta as? HTTPURLResponse)?.statusCode ?? 0
                guard codigo == 200 else { throw WebAPIError.http(codigo) }
                return dados
            } catch let erro as WebAPIError {
                // Só 429 e 5xx merecem outra tentativa; 400 não melhora.
                guard case let .http(codigo) = erro, codigo == 429 || codigo >= 500 else { throw erro }
                ultimo = erro
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                ultimo = error
            }
            if tentativa < backoff.count { try await Task.sleep(for: backoff[tentativa]) }
        }
        throw ultimo
    }

    /// `.alphanumerics` e não `.urlQueryAllowed`: legenda tem `&`, `+` e `#`,
    /// e os três mudam de sentido dentro de uma consulta. Mesmo critério do
    /// `DeepLWeb.url`.
    public static func escapar(_ texto: String) -> String {
        texto.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    /// Preserva a posição das falas vazias e reparte. **Bloco que falha
    /// derruba a tradução inteira**: cair para outro tradutor deixava a
    /// legenda misturada, e o aviso de uma linha não era lido.
    public static func porBlocos(
        _ texts: [String],
        blocos: ([String]) -> [[Int]],
        traduzir: ([String]) async throws -> [String]
    ) async throws -> [String] {
        let limpas = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cheias = limpas.enumerated().filter { !$0.element.isEmpty }
        guard !cheias.isEmpty else { return Array(repeating: "", count: texts.count) }

        var saida = Array(repeating: "", count: texts.count)
        for bloco in blocos(cheias.map(\.element)) {
            try Task.checkCancellation()
            let falas = bloco.map { cheias[$0].element }
            let traduzidas = try await traduzir(falas)
            for (posicao, texto) in zip(bloco, traduzidas) {
                saida[cheias[posicao].offset] = texto
            }
        }
        return saida
    }
}
