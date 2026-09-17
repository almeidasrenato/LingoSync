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
    /// Vale para o ao vivo e para o vídeo: a escolha do usuário não é trocada
    /// em lugar nenhum.
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
        case .google: GoogleWebTranslator()
        case .gemini: GeminiWebTranslator()
        case .hunyuan: HunyuanTranslator()
        case .transcriptionOnly: IdentityTranslator()
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
    /// Google Tradutor, pelo endereço interno do site. Ver `GoogleWebTranslator`.
    case google
    /// Chat do Gemini, sem API paga e sem conta — sempre a sessão anônima do
    /// site. Ver `GeminiWebTranslator`.
    case gemini
    /// Hunyuan-MT-7B (Tencent), local, fora do processo. Só existe quando
    /// `Scripts/hunyuan-setup.sh` tiver rodado — ver `HunyuanTranslator`.
    case hunyuan
    /// Só o texto reconhecido, sem traduzir. Vale nos três caminhos: painel
    /// ao vivo, janela de legendas e item de menu.
    ///
    /// Não se chama `none` de propósito: `TranslationEngine?` existe (ver
    /// `SubtitleJob.translation`) e ali `.none` já quer dizer `nil`.
    case transcriptionOnly = "transcricao"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apple: "Apple"
        case .deepl: "DeepL (site)"
        case .google: "Google (site)"
        case .gemini: "Gemini (site)"
        case .hunyuan: "Hunyuan-MT 7B"
        case .transcriptionOnly: "Só transcrever"
        }
    }

    /// Se o motor pode ser escolhido nesta máquina.
    ///
    /// O Hunyuan mora fora do app, num ambiente de 4,5 GB que o usuário
    /// instala à parte. Oferecer o que não existe daria erro só no meio de uma
    /// geração de dez minutos.
    public var isAvailable: Bool {
        switch self {
        case .apple, .deepl, .google, .gemini, .transcriptionOnly: true
        case .hunyuan: HunyuanTranslator.isInstalled
        }
    }

    /// O que esperar deste motor ao vivo, ou `nil` quando ele é instantâneo.
    ///
    /// Todos os motores valem ao vivo desde 14/09/2026, a pedido. Antes o
    /// caminho ao vivo trocava a escolha pela Apple, calado, porque o custo não
    /// cabia num trecho re-reconhecido a cada 0,6 s — e quem escolheu DeepL
    /// pela qualidade recebia Apple sem perceber. É a mesma lição de "Falhou,
    /// falhou": escolha do usuário não se troca em silêncio.
    ///
    /// O que muda é o atraso, e ele é grande o bastante para ser dito antes:
    ///
    /// ```
    /// Apple       instantâneo, local
    /// Google      ~1 s por bloco
    /// DeepL       2 a 3 s por bloco, e desafio anti-robô quando insiste
    /// Hunyuan     4,5 GB residentes, disputando GPU com o reconhecedor
    /// ```
    /// Motor que não custa nada parado nem por bloco. É o que o app mantém
    /// carregado entre sessões e prepara na abertura; os outros nascem quando
    /// alguém manda traduzir e morrem quando a captura para — o Hunyuan carrega
    /// 7 B de pesos no `prepare` e o DeepL abre uma `WKWebView`, e este app fica
    /// aberto o dia todo na barra de menus.
    public var isInstantaneous: Bool { liveCostNote == nil }

    public var liveCostNote: String? {
        switch self {
        case .apple, .transcriptionOnly: nil
        case .google: "cada bloco vai à rede · ~1 s de atraso"
        case .deepl: "cada bloco carrega o site · 2 a 3 s de atraso"
        case .gemini: "cada bloco manda uma mensagem ao chat · alguns segundos de atraso"
        case .hunyuan: "modelo de 4,5 GB residente · disputa a GPU com o reconhecimento"
        }
    }

    /// Se o texto sai da máquina.
    ///
    /// A primeira linha do CLAUDE.md promete que nada sai; o DeepL é a
    /// exceção que o usuário escolhe, e o painel avisa. O Hunyuan é local
    /// como a Apple.
    public var leavesTheMachine: Bool {
        switch self {
        case .deepl, .google, .gemini: true
        case .apple, .hunyuan, .transcriptionOnly: false
        }
    }

    /// Idiomas cobertos, ou `nil` para todos os do app.
    public var supportedLanguages: [Language]? {
        switch self {
        case .apple, .transcriptionOnly: nil
        // O cartão do modelo lista 33 idiomas, e os 18 do app estão entre
        // eles. Só japonês → português foi medido aqui.
        case .hunyuan: nil
        case .google: nil
        // O site anuncia mais de 200 idiomas; nenhum par foi medido como
        // recusado nos testes contra o DeepL (ver GeminiWeb).
        case .gemini: nil
        case .deepl: DeepLWeb.supportedLanguages
        }
    }

    /// Quanto o trabalho custa por segundo de vídeo, medido no M5.
    ///
    /// Apple e DeepL custam quase o mesmo por motivos opostos: a Apple cobra
    /// por string (ver "Tamanho de lote") e o DeepL por carga de página, que
    /// leva 1400 caracteres de uma vez.
    ///
    /// ```
    ///              96 s (11 falas)   540 s (75 legendas)
    /// Apple               7 s               32 s
    /// DeepL              11 s               20 s
    /// ```
    ///
    /// O DeepL é mais caro no vídeo curto, onde a carga não se dilui, e mais
    /// barato no longo; o 0,12 é o pior dos dois casos. **O que o limita não é
    /// a velocidade, é o desafio anti-robô** — uma execução barrada levou
    /// 195 s no vídeo de 96 s.
    public var costPerSecondOfVideo: Double {
        switch self {
        case .apple: TranslatorFactory.costPerSecondOfVideo
        case .deepl: 0.12
        // Medido em 12/09/2026: 95 s para o vídeo de 540 s, uma fala por
        // requisição com o modelo já carregado, levando a fala anterior como
        // contexto (sem ela eram 84 s — o contexto custa ~13%). Bem abaixo do
        // 1,02× que o Qwen3-8B custava: é tradução, não conversa.
        case .hunyuan: 0.18
        // Medido em 13/09/2026, 110 falas do vídeo de 9 minutos: 1,3 s,
        // contra 11,0 s do DeepL e 36,4 s da Apple.
        case .google: 0.01
        // Medido em 15/09/2026 pelo tradutor-verify traduzir, as 6 falas do
        // vídeo `ja-dificil` (78,1 s), só a fase de tradução: 5,7 a 6,1 s em
        // três execuções, média 5,9 s. `tradutor-verify srt` não tem como
        // trocar o tradutor (fixo em `.apple`, ver o gate), então a medição
        // aqui não passou pelo pipeline inteiro como as dos outros motores —
        // vale refazer se um vídeo mais longo mudar a conta.
        case .gemini: 0.08
        // Sem tradução sobra o reconhecimento, e ele varia demais entre
        // motores para um número só: medido em 540 s, a Apple gastou 10,2 s
        // (0,019) e o Whisper 11,8 s em 97 s (0,12). O 0,05 fica no meio,
        // como estimativa — não como medição de um motor.
        case .transcriptionOnly: 0.05
        }
    }

    /// Para onde a legenda vai de fato.
    ///
    /// Sem tradução o destino é o próprio idioma falado. Uma regra só, aqui,
    /// porque dela dependem a largura da linha (CJK cabe em 20 caracteres), o
    /// sufixo do arquivo gravado e o rótulo da janela — três lugares que
    /// divergiriam se cada um decidisse por conta.
    public func destination(from source: Language, to target: Language) -> Language {
        self == .transcriptionOnly ? source : target
    }

    /// Se o par escolhido passa por este motor.
    public func supports(_ source: Language, _ target: Language) -> Bool {
        switch self {
        case .apple, .hunyuan, .google, .gemini, .transcriptionOnly: true
        case .deepl: DeepLWeb.supports(source, target)
        }
    }
}

/// Não traduz nada: devolve o texto como veio.
///
/// É o que faz "só transcrever" ser uma escolha de tradutor em vez de um
/// desvio em cada um dos três caminhos (painel ao vivo, janela de legendas e
/// item de menu). Sem ele, cada um precisaria do seu `if`, e foi assim que a
/// geração da janela e a do menu divergiram uma vez.
public final class IdentityTranslator: Translator, @unchecked Sendable {

    public let engineName = "Sem tradução"

    public init() {}

    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        progress(1.0, "sem tradução")
    }

    public func reset() {}

    public func translate(_ text: String, from: Language, to: Language) async throws -> String {
        text
    }

    public func translate(_ texts: [String], from: Language, to: Language) async throws -> [String] {
        texts
    }
}
