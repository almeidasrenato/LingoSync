import Foundation

/// Tradução.
///
/// O app já teve três motores: o framework do sistema e dois modelos locais
/// (Qwen3-4B e 8B pelo MLX). Os modelos locais foram removidos — custavam de
/// três a dez vezes mais tempo e o resultado ficava abaixo do tradutor do
/// sistema em português. Sobrou o que entrega melhor texto mais rápido.
public protocol Translator: AnyObject, Sendable {
    var engineName: String { get }
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws
    func translate(_ text: String, from: Language, to: Language) async throws -> String

    /// Traduz várias legendas de uma vez.
    ///
    /// Um segmento costuma render três ou quatro frases. Em série são três ou
    /// quatro idas e voltas; com lote, uma só.
    func translate(_ texts: [String], from: Language, to: Language) async throws -> [String]

    /// Quantas legendas convém mandar por vez.
    var preferredBatchSize: Int { get }

    func reset()

    /// O que o usuário precisa saber no fim, quando o motor não fez o trabalho
    /// todo sozinho. `nil` quando nada fora do normal aconteceu.
    ///
    /// Existe por causa do DeepL: bloco que o site recusa cai para a Apple e a
    /// legenda sai metade de cada um. Sem este aviso a troca de qualidade no
    /// meio do arquivo não tinha como ser explicada.
    var completionNotice: String? { get }
}

extension Translator {
    public var preferredBatchSize: Int { 10 }
    public var completionNotice: String? { nil }

    /// Padrão em série, para motores sem API de lote.
    public func translate(_ texts: [String], from: Language, to: Language) async throws -> [String] {
        var results: [String] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            results.append(try await translate(text, from: from, to: to))
        }
        return results
    }
}

public enum TranslatorError: LocalizedError {
    case notPrepared

    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            "O tradutor ainda não terminou de carregar."
        }
    }
}

public enum TranslatorFactory {

    /// Quanto o trabalho custa por segundo de vídeo, medido no M5.
    public static let costPerSecondOfVideo = 0.10

    /// Estimativa legível para um vídeo de determinada duração.
    ///
    /// O custo é do motor escolhido, não um número só. Medidos, os dois ficam
    /// perto — ver `TranslationEngine.costPerSecondOfVideo` —, mas a conta sai
    /// de quem vai fazer o trabalho, e não de uma constante que vale para um
    /// motor e é chute para o outro.
    public static func estimate(
        forVideoOf seconds: TimeInterval, using engine: TranslationEngine = .apple
    ) -> String {
        guard seconds > 0 else { return "" }
        let total = seconds * engine.costPerSecondOfVideo
        if total < 90 { return "≈ \(Int(total.rounded())) s" }
        return "≈ \(Int((total / 60).rounded())) min"
    }

    /// O que o usuário escolheu, ou a Apple.
    ///
    /// Vale só para os modos de vídeo. Ao vivo a escolha é ignorada de
    /// propósito — ver `TranslationEngine.supportsLive`.
    /// A preferência gravada, desde que ela ainda exista nesta máquina.
    ///
    /// O ambiente do Hunyuan pode ser apagado depois de escolhido — são 4,5 GB
    /// numa pasta que o usuário controla. Sem esta rede, a preferência
    /// sobreviveria à desinstalação e a geração falharia no meio.
    public static var preferred: TranslationEngine {
        let gravado = TranslationEngine(
            rawValue: UserDefaults.standard.string(forKey: "motorDeTraducao") ?? ""
        )
        guard let gravado, gravado.isAvailable else { return .apple }
        return gravado
    }

    /// - Parameter engine: passe explícito quem não pode depender da
    ///   preferência — o caminho ao vivo e as verificações, que precisam
    ///   rodar iguais em qualquer máquina e sem rede.
    public static func make(_ engine: TranslationEngine = preferred) -> any Translator {
        switch engine {
        case .apple: AppleTranslator()
        case .deepl: DeepLWebTranslator()
        case .hunyuan: HunyuanTranslator()
        }
    }
}

/// De onde a tradução vem.
///
/// A Apple é local, instantânea e não pede nada a ninguém. O DeepL ganha dela
/// em japonês — medido, ver o CLAUDE.md — ao preço de o texto sair da máquina.
/// É escolha do usuário, e o padrão é o que não sai.
public enum TranslationEngine: String, CaseIterable, Identifiable, Sendable {
    case apple
    case deepl
    /// Hunyuan-MT-7B (Tencent), local, fora do processo. Só existe quando
    /// `Scripts/hunyuan-setup.sh` tiver rodado — ver `HunyuanTranslator`.
    case hunyuan

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apple: "Apple"
        case .deepl: "DeepL (site)"
        case .hunyuan: "Hunyuan-MT 7B"
        }
    }

    /// Se o motor pode ser escolhido nesta máquina.
    ///
    /// O Hunyuan mora fora do app, num ambiente de 4,5 GB que o usuário
    /// instala à parte. Oferecer o que não existe daria erro só no meio de uma
    /// geração de dez minutos.
    public var isAvailable: Bool {
        switch self {
        case .apple, .deepl: true
        case .hunyuan: HunyuanTranslator.isInstalled
        }
    }

    /// Se serve para a tradução ao vivo.
    ///
    /// O DeepL é uma carga de página por bloco, de segundos. O tempo real
    /// re-reconhece o trecho em andamento a cada 0,6 s e traduz o que fecha —
    /// não cabe, e o painel diria a verdade errada. Ao vivo é sempre a Apple.
    public var supportsLive: Bool { self == .apple }

    /// Se o texto sai da máquina.
    ///
    /// A primeira linha do CLAUDE.md promete que nada sai; o DeepL é a
    /// exceção que o usuário escolhe, e o painel avisa. O Hunyuan é local
    /// como a Apple.
    public var leavesTheMachine: Bool { self == .deepl }

    /// Idiomas cobertos, ou `nil` para todos os do app.
    public var supportedLanguages: [Language]? {
        switch self {
        case .apple: nil
        // O cartão do modelo lista 33 idiomas, e os 18 do app estão entre
        // eles. Só japonês → português foi medido aqui.
        case .hunyuan: nil
        case .deepl: DeepLWeb.supportedLanguages
        }
    }

    /// Quanto o trabalho custa por segundo de vídeo, medido no M5.
    ///
    /// Os dois custam quase o mesmo, por motivos opostos: a Apple cobra por
    /// string (ver "Tamanho de lote") e o DeepL cobra por carga de página, que
    /// leva 1400 caracteres de uma vez. Medido em 12/09/2026, mesmo vídeo e
    /// mesmas opções:
    ///
    /// ```
    ///              96 s (11 falas)   540 s (75 legendas)
    /// Apple               7 s               32 s
    /// DeepL              11 s               20 s
    /// ```
    ///
    /// Ou seja: o DeepL é mais caro no vídeo curto, onde a carga de página não
    /// se dilui, e mais barato no longo. O 0,12 aqui é o pior dos dois casos.
    ///
    /// **Não é a velocidade que limita o DeepL, é o desafio anti-robô.** Uma
    /// execução com desafio da Cloudflare no meio levou 195 s no vídeo de 96 s
    /// — quinze vezes o normal, porque cada bloco espera o tempo esgotar antes
    /// de cair para a Apple.
    public var costPerSecondOfVideo: Double {
        switch self {
        case .apple: TranslatorFactory.costPerSecondOfVideo
        case .deepl: 0.12
        // Medido em 12/09/2026: 95 s para o vídeo de 540 s, uma fala por
        // requisição com o modelo já carregado, levando a fala anterior como
        // contexto (sem ela eram 84 s — o contexto custa ~13%). Bem abaixo do
        // 1,02× que o Qwen3-8B custava: é tradução, não conversa.
        case .hunyuan: 0.18
        }
    }

    /// Se o par escolhido passa por este motor.
    public func supports(_ source: Language, _ target: Language) -> Bool {
        switch self {
        case .apple, .hunyuan: true
        case .deepl: DeepLWeb.supports(source, target)
        }
    }
}
