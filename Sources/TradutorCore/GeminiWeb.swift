import AppKit
import Foundation
import OSLog
import WebKit

/// Tradução pelo chat do Gemini, sem API paga e sem conta.
///
/// O `WKWebView` usa armazenamento efêmero (`.nonPersistent()`, mesma escolha
/// do DeepL) — não existe login aqui dentro, então é sempre a sessão anônima
/// do site, nunca a conta do usuário. Medido em 15/09/2026: a sessão anônima
/// cai num modelo mais fraco ("Flash-Lite" em vez do "Flash" da conta logada)
/// e, sozinha, errava concordância de gênero dentro da própria frase
/// ("cansada" onde deveria ser "cansados", na mesma legenda que dizia
/// "vocês dois"). As regras 5 e 6 de `GeminiWeb.instructions` — concordância
/// interna obrigatória e masculino-plural genérico como padrão sem pista de
/// gênero — fecharam essa diferença: anônimo com o prompt endurecido empatou
/// com logado no mesmo teste (seis falas do vídeo `ja-dificil`).
///
/// **Como o texto entra**: ao contrário do DeepL, o campo aqui (editor Quill)
/// aceita `execCommand('insertText')` normalmente — colar por evento
/// sintético de `ClipboardEvent('paste')`, que é o que o DeepL precisa, não
/// fazia nada aqui. Sem carga de página por lote: a mesma conversa recebe uma
/// mensagem por bloco, do jeito que o DeepL faz com limpar-e-colar.
///
/// **O que sinaliza "terminou"**: o site não tem botão de volume como o
/// DeepL. O sinal é o botão "Parar resposta" — existe enquanto gera, some
/// quando termina — cruzado com o número de respostas na conversa (garante
/// que a leitura é da resposta **desta** mensagem, não da anterior).
public enum GeminiWeb {

    /// Sem medição de um teto de caracteres por página, ao contrário do
    /// DeepL (que recusa acima de 1500) — aqui não há carga de página por
    /// lote. O que existe é este tamanho de lote, testado em vídeo real (40
    /// falas, ~1200 caracteres, vídeo `en2` do benchmark) sem problema.
    public static let preferredBatchSize = 40

    /// Nenhum par foi medido como recusado; o site anuncia mais de 200
    /// idiomas.
    public static func supports(_ source: Language, _ target: Language) -> Bool { true }

    /// Nome do idioma em inglês para o prompt — mesmo motivo do
    /// `HunyuanTranslator`: o modelo segue melhor a instrução em inglês.
    /// Português vai como "Brazilian Portuguese": os outros motores de rede
    /// fixam pt-BR, não pt-PT.
    static func promptName(_ language: Language) -> String {
        language == .portuguese ? "Brazilian Portuguese" : HunyuanTranslator.englishName(language)
    }

    /// O prompt que faz o Gemini se comportar como motor de tradução em
    /// lote, não como assistente de chat.
    ///
    /// Veio de três rodadas medidas contra o DeepL, nas mesmas falas
    /// (vídeo `en2`, 40 falas, e o `ja-dificil`, 6 falas — ver CLAUDE.md):
    /// sem regra nenhuma, o Gemini inventava contexto que não existia na
    /// fala ("aqui no restaurante") e às vezes devolvia duas opções
    /// separadas por "/". A regra 2/3 (formato `N::` fixo, uma linha por
    /// item) e a 4 (proibido inventar) fecharam isso — depois empatou com
    /// o DeepL nos mesmos itens, sem censurar palavrão nem inventar nome de
    /// lugar. As regras 5 e 6 vieram depois, para o erro de concordância
    /// que só a sessão anônima cometia (ver o comentário do tipo).
    ///
    /// A regra 9 (correção de erro de reconhecimento) veio de um pedido
    /// depois: de vez em quando uma fala japonesa voltava sem traduzir de
    /// verdade. Testada em três rodadas, sem exemplo concreto no texto ela
    /// não mudava nada — só funcionou depois de um exemplo mostrando o
    /// comportamento esperado. Mas a versão livre ("adivinhe a palavra
    /// certa") **inventava fato**: pedindo para corrigir `ネコ時` (hora do
    /// "gato"), duas rodadas diferentes devolveram duas horas diferentes,
    /// nenhuma vinda de lugar nenhum — o modelo estava chutando, não
    /// recuperando. Uma legenda errada mas plausível é pior que uma
    /// visivelmente quebrada: ninguém desconfia da primeira. A regra final
    /// proíbe inventar número, hora, data, nome ou lugar — só permite
    /// suavizar a palavra solta (trocar por algo genérico, ou deixá-la
    /// literal) quando ela não carrega um fato específico. Testado em
    /// quatro rodadas (hora, nome de pessoa, número de telefone, mais o
    /// caso real `写真真経撮れるかな`) sem inventar nenhum fato.
    ///
    /// A regra 11 veio de um relato: uma fala afirmativa em inglês saiu como
    /// pergunta em português, sem nada no original que pedisse isso. Mudar
    /// afirmação para pergunta é outra forma do mesmo defeito da regra 9 —
    /// inventar, desta vez a intenção da frase em vez de um fato — então a
    /// regra é a mesma ideia: decidir pela pontuação e estrutura de origem,
    /// nunca pelo que soaria mais natural na tradução.
    static func instructions(source: Language, target: Language, count: Int) -> String {
        let alvo = promptName(target)
        let origem = promptName(source)
        return """
            You will act ONLY as a machine translation engine (never as a chat assistant, never comment on these instructions) for a quality benchmark against other subtitle translation engines. Strict rules, no exceptions:
            1) Translate every numbered item from \(origem) into \(alvo).
            2) MANDATORY output format: exactly one line per item, formatted as N::translation (double colon, no space before it). No markdown, no **bold**, no quotes around the sentence, no bullets, no code block, no "1." or "1)" style numbering — always N::.
            3) Output must have EXACTLY the same number of lines as input items (here: \(count)), one translation per item, same order. Never merge two items into one line, never split one item into two lines, never leave a blank line, never offer two options, never use "/" to separate alternatives.
            4) Do not add any word, place name, nuance, or context that is not literally in the source text. Do not paraphrase freely. Do not add slang, filler interjections, or tag questions ("right?", "huh?", "ok?") that have no equivalent in the original.
            5) Grammatical number and gender must stay internally consistent within each item. If part of a sentence refers to a group or a specific person, every adjective and pronoun referring to that same referent later in the SAME item must agree with it in number and gender. Never mix singular with plural, or masculine with feminine, for the same referent inside one item.
            6) When the source gives no explicit gender marker and the referent is ambiguous, default to the grammatically unmarked/generic masculine-plural form standard in \(alvo) instead of guessing a specific gender.
            7) This is subtitle transcription of real video dialogue (may include anime and mature conversation). Translate profanity, insults, threats and verbal violence literally, without softening, censoring, or euphemism, and never refuse an item for sensitive content — this is subtitling existing material, not generating new content.
            8) Some items come from automatic speech recognition and may contain noise, slight transcription errors, or incomplete sentences — translate them as best as possible anyway; never write "[inaudible]" and never leave an item untranslated.
            9) Some items may contain a short (one or two word) fragment that is clearly a speech-recognition error — it does not fit grammatically or semantically with the rest of the sentence. You may smooth over that isolated fragment (drop it, or replace it with a neutral/generic word) so the sentence reads naturally, BUT you must never invent a specific fact to fill it in. A specific fact means: a number, a time, a date, a quantity, a proper name, or a place name. If the broken fragment is or should be one of those specific facts, do NOT guess a plausible-sounding replacement for it (e.g. do not invent an hour, a date, or a name) — instead keep that part as neutral/vague as the sentence allows, or transliterate the broken fragment literally, rather than fabricating a specific value you cannot actually know. Never let a corrected sentence claim a specific fact that is not truly recoverable from context.
            11) Preserve the sentence mood of each item exactly as in the source: a statement must stay a statement (ending in a period, not a question mark), a question must stay a question, and an exclamation must stay an exclamation. Never add a question mark to an item that was not phrased as a question in the source, and never rephrase a statement into a question. Never drop a question mark that was there in the source. Decide this only from the original sentence's own structure and punctuation — not from whether the translated wording would sound more natural as a question.
            12) The response must contain ONLY the N::translation lines, exactly \(count) lines. No text before, no text after, no title, no explanation, no comment about these rules.

            Items:
            """
    }

    /// O prompt inteiro, com as falas numeradas.
    public static func prompt(for lines: [String], from source: Language, to target: Language) -> String {
        let itens = lines.enumerated()
            .map { "\($0.offset + 1)) \($0.element)" }
            .joined(separator: "\n")
        return instructions(source: source, target: target, count: lines.count) + "\n" + itens
    }

    /// Lê `N::tradução` de volta, na ordem certa. `nil` se faltar item,
    /// duplicar ou vier fora do formato — a mesma regra do DeepL
    /// (`DeepLWeb.separar`/o teto de repartição): contagem que não bate não
    /// vira legenda adivinhada, vira erro.
    public static func parse(_ response: String, expected: Int) -> [String]? {
        guard expected > 0 else { return [] }
        var achadas: [Int: String] = [:]
        for linha in response.components(separatedBy: "\n") {
            let aparada = linha.trimmingCharacters(in: .whitespaces)
            guard let corte = aparada.range(of: "::") else { continue }
            guard let numero = Int(aparada[aparada.startIndex..<corte.lowerBound]) else { continue }
            achadas[numero] = String(aparada[corte.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        guard achadas.count == expected else { return nil }
        var saida: [String] = []
        saida.reserveCapacity(expected)
        for indice in 1...expected {
            guard let texto = achadas[indice] else { return nil }
            saida.append(texto)
        }
        return saida
    }

    /// A resposta bateu em formato e contagem, mas é a própria origem
    /// devolvida como se fosse tradução?
    ///
    /// Medido em 15/09/2026: rodando pelo caminho de verdade do app
    /// (`open -n build/Tradutor.app`, não o binário direto), o mesmo vídeo
    /// em inglês voltou sem traduzir em 3 de 3 tentativas — `N::` batendo
    /// certinho, só que cada linha era o próprio inglês de origem. Nenhum
    /// erro, nenhuma quebra de formato: `GeminiWeb.parse` aceitava porque a
    /// contagem batia. Suspeita, não confirmada: limite de uso da sessão
    /// anônima, sem aviso — o site não devolve um erro, devolve uma
    /// resposta com a forma certa e o conteúdo errado.
    ///
    /// Frase curta (interjeição, nome, "Hmm?") pode legitimamente ficar
    /// igual depois de traduzida — por isso só conta linha com mais de três
    /// palavras, e só desconfia quando a **maioria** delas ficou intocada.
    /// Uma ou duas por acaso não bastam.
    public static func pareceIntocado(source: [String], translated: [String]) -> Bool {
        func achatada(_ texto: String) -> String {
            texto.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let pares = zip(source, translated).filter { origem, _ in
            origem.split(separator: " ").count > 3
        }
        guard pares.count >= 2 else { return false }
        let iguais = pares.filter { origem, traduzido in achatada(origem) == achatada(traduzido) }.count
        return iguais * 2 > pares.count
    }
}

// MARK: - O tradutor

public final class GeminiWebTranslator: Translator, @unchecked Sendable {

    public let engineName = "Gemini (site)"
    public var preferredBatchSize: Int { GeminiWeb.preferredBatchSize }

    private let driver = GeminiDriver()
    private let log = Logger(subsystem: "app.tradutor", category: "Gemini")

    /// **Não há rede de segurança**, igual ao DeepL: bloco que o site não
    /// entregar derruba a tradução inteira, com o erro na tela e o botão de
    /// tentar de novo. `GeminiDriver` grava o prompt e a resposta crua em
    /// `/tmp/tradutor-gemini-erro.txt` quando isso acontece, para poder
    /// mandar o log de volta.
    public init() {}

    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        progress(0.4, "abrindo o Gemini…")
        await driver.warmUp()
        progress(1.0, "Gemini pronto")
    }

    public func reset() {
        let driver = self.driver
        Task { @MainActor in driver.close() }
    }

    public func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        let result = try await translate([text], from: source, to: target)
        return result.first ?? ""
    }

    public func translate(
        _ texts: [String], from source: Language, to target: Language
    ) async throws -> [String] {
        let trimmed = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cheias = trimmed.enumerated().filter { !$0.element.isEmpty }
        guard !cheias.isEmpty else { return Array(repeating: "", count: texts.count) }

        var saida = Array(repeating: "", count: texts.count)
        var inicio = 0
        let total = (cheias.count + GeminiWeb.preferredBatchSize - 1) / GeminiWeb.preferredBatchSize
        var numero = 0
        while inicio < cheias.count {
            numero += 1
            let fim = min(inicio + GeminiWeb.preferredBatchSize, cheias.count)
            let bloco = Array(cheias[inicio..<fim])
            let falas = bloco.map(\.element)
            let rotulo = "bloco \(numero) de \(total)"
            let traduzidas: [String]
            do {
                traduzidas = try await driver.translate(falas, from: source, to: target, label: rotulo)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.error("Gemini falhou em \(rotulo, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw error
            }
            for (item, texto) in zip(bloco, traduzidas) {
                saida[item.offset] = texto
            }
            inicio = fim
        }
        return saida
    }
}

public enum GeminiWebError: LocalizedError {
    case timedOut(String)
    /// Resposta chegou, mas não bateu com `N::tradução` vezes a contagem
    /// esperada — o log completo foi para `/tmp/tradutor-gemini-erro.txt`.
    case malformedResponse(String)
    /// Resposta veio no formato certo, mas devolveu a própria origem em vez
    /// de traduzir — ver `GeminiWeb.pareceIntocado`.
    case untranslated(String)

    public var errorDescription: String? {
        switch self {
        case let .timedOut(bloco):
            "O Gemini não respondeu a tempo (\(bloco)). Pode ser limite de uso do site."
        case let .malformedResponse(bloco):
            "O Gemini devolveu uma resposta fora do formato esperado (\(bloco)). Log em /tmp/tradutor-gemini-erro.txt."
        case let .untranslated(bloco):
            "O Gemini devolveu o texto sem traduzir (\(bloco)). Pode ser limite de uso do site. Log em /tmp/tradutor-gemini-erro.txt."
        }
    }
}

// MARK: - O motor do site, sem janela

/// Dirige um `WKWebView` sem janela nenhuma — mesmo desenho do `DeepLDriver`,
/// sem o motivo de existir uma versão com janela: nada aqui depende de
/// temporizador de página em segundo plano (a espera é por leitura de
/// estado, não por um `setTimeout` da página).
@MainActor
final class GeminiDriver {

    /// Quanto esperar por um lote antes de desistir dele. Mesmo valor do
    /// DeepL — nenhuma medição própria sugeriu outro número.
    private static let responseTimeout: TimeInterval = 90
    /// Leituras iguais seguidas do texto da resposta antes de aceitá-la como
    /// pronta. A resposta aparece aos poucos (streaming); sem isto, uma
    /// pausa no meio da geração passaria por "terminou".
    private static let stableReads = 3
    /// Onde o log de erro fica — para poder colar de volta quando falhar.
    private static let errorLogPath = "/tmp/tradutor-gemini-erro.txt"
    /// Depois de quantos lotes a conversa é jogada fora e recomeça do zero.
    ///
    /// Pedido em 15/09/2026: em sessões longas (ao vivo, ou um vídeo com
    /// muitos lotes), de vez em quando um bloco japonês voltava sem
    /// traduzir — sem quebrar o formato `N::`, só devolvendo o próprio
    /// japonês como se fosse a "tradução". Isso não é erro de formato (a
    /// contagem bate) e por isso não cai na rede de segurança do
    /// `GeminiWeb.parse`. É plausível que seja o histórico da conversa
    /// crescendo e diluindo a instrução — não medido ao certo, e por isso o
    /// número abaixo é um palpite conservador, não uma medição. Recomeçar a
    /// conversa é mais simples e mais seguro que confiar numa mensagem extra
    /// "lembrando as regras" no meio de um histórico que só cresce: a
    /// conversa nova nunca tem outra coisa no contexto além da instrução.
    private static let maxBatchesPerConversation = 15
    /// E também por tempo, para a sessão ao vivo — que manda poucos lotes
    /// mas por horas — não passar batido do limite de lotes.
    private static let maxConversationAge: TimeInterval = 600

    private var webView: WKWebView?
    /// Se a conversa já está carregada. Uma vez carregada, os lotes
    /// seguintes entram como mensagem nova na mesma conversa — sem recarregar
    /// a página a cada lote, do jeito que o DeepL reaproveita a página entre
    /// blocos. Some quando `deveRenovar` decide recomeçar, ou quando `close`
    /// é chamado.
    private var conversationLoaded = false
    private var lotesNestaConversa = 0
    private var conversaComecouEm: Date?
    private let log = Logger(subsystem: "app.tradutor", category: "Gemini")

    /// Criado fora do main actor — quem chama é um `Translator`, que não é
    /// isolado. Nada aqui toca AppKit antes de `view()`, que é isolado.
    nonisolated init() {}

    func warmUp() {
        _ = view()
    }

    func close() {
        webView = nil
        conversationLoaded = false
        lotesNestaConversa = 0
        conversaComecouEm = nil
    }

    /// Se é hora de recomeçar a conversa — ver o comentário de
    /// `maxBatchesPerConversation`.
    private func deveRenovar() -> Bool {
        guard conversationLoaded else { return false }
        if lotesNestaConversa >= Self.maxBatchesPerConversation { return true }
        if let inicio = conversaComecouEm,
           Date().timeIntervalSince(inicio) > Self.maxConversationAge { return true }
        return false
    }

    private func view() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        // Efêmero de propósito: sem isto haveria risco de herdar cookie de
        // sessão de outro lugar. Sempre a sessão anônima do site — ver o
        // comentário do tipo, no arquivo.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 620), configuration: config)
        webView = view
        return view
    }

    /// Esvazia o campo, se existir.
    private static let limpar = """
        (function () {
          var campo = document.querySelector('[contenteditable="true"]');
          if (!campo) return "sem-campo";
          campo.focus();
          document.execCommand('selectAll', false, null);
          document.execCommand('delete', false, null);
          return "ok";
        })();
        """

    /// Insere uma linha e, se não for a última, a quebra de parágrafo.
    ///
    /// Ao contrário do DeepL, `execCommand('insertText')` funciona aqui — o
    /// editor do Gemini (Quill) aceita, e o do DeepL ignora. Mas **um só**
    /// `execCommand` com o prompt inteiro (2000+ caracteres, dezenas de
    /// linhas) truncava no meio às vezes — medido em 15/09/2026, sempre logo
    /// depois de uma carga de página: o campo ficava com 224 dos 2401
    /// caracteres enviados, e a mensagem saía cortada no meio de uma regra.
    /// Inserir linha por linha, do jeito que alguém digitando faria, não
    /// truncou nenhuma vez depois disso.
    private static func inserirLinha(_ linha: String, quebra: Bool) -> String {
        """
        (function () {
          var campo = document.querySelector('[contenteditable="true"]');
          if (!campo) return "sem-campo";
          campo.focus();
          document.execCommand('insertText', false, \(DeepLWeb.jsLiteral(linha)));
          \(quebra ? "document.execCommand('insertParagraph', false, null);" : "")
          return "ok";
        })();
        """
    }

    /// Clica em "Enviar mensagem" — o rótulo é fixo porque a página é
    /// carregada com `hl=pt-BR` (ver `traduzir`), então o texto do botão não
    /// varia com o idioma do sistema de quem estiver rodando o app.
    private static let enviar = """
        (function () {
          var botoes = document.querySelectorAll('button[aria-label]');
          for (var i = 0; i < botoes.length; i++) {
            if (botoes[i].getAttribute('aria-label') === 'Enviar mensagem' && !botoes[i].disabled) {
              botoes[i].click();
              return "ok";
            }
          }
          return "sem-botao";
        })();
        """

    /// Uma leitura do estado da conversa.
    ///
    /// `gerando` é o "Parar resposta" — existe enquanto o Gemini ainda está
    /// escrevendo, some quando termina. É o equivalente do botão de volume
    /// do DeepL, mas aqui não há ícone de "traduzindo"; o que há é este botão
    /// trocando de lugar com o de enviar.
    private static let leitura = """
        (function () {
          var gerando = false;
          var botoes = document.querySelectorAll('button[aria-label]');
          for (var i = 0; i < botoes.length; i++) {
            if (botoes[i].getAttribute('aria-label') === 'Parar resposta') { gerando = true; break; }
          }
          var respostas = document.querySelectorAll('model-response message-content');
          var ult = respostas.length ? respostas[respostas.length - 1] : null;
          return JSON.stringify({
            gerando: gerando,
            respostas: respostas.length,
            ultima: ult ? (ult.innerText || ult.textContent || '') : ''
          });
        })();
        """

    func translate(
        _ lines: [String], from source: Language, to target: Language, label: String
    ) async throws -> [String] {
        try await traduzir(lines, from: source, to: target, label: label, recarregou: false)
    }

    /// Uma linha de diagnóstico por leitura seria demais em uso normal — o
    /// mesmo motivo do `ASR_DEBUG` em `Transcriber.swift`. Só escreve com a
    /// variável ligada.
    private static func debug(_ mensagem: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["TRADUTOR_GEMINI_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data("[gemini] \(mensagem())\n".utf8))
    }

    /// Limpa e digita o prompt linha por linha — ver o comentário de
    /// `inserirLinha` sobre por que não é um `execCommand` só.
    private func inserir(_ view: WKWebView, texto: String) async throws -> Bool {
        guard (try? await view.evaluateJavaScript(Self.limpar)) as? String == "ok" else { return false }
        let linhas = texto.components(separatedBy: "\n")
        for (indice, linha) in linhas.enumerated() {
            try Task.checkCancellation()
            let quebra = indice < linhas.count - 1
            let resultado = try? await view.evaluateJavaScript(
                Self.inserirLinha(linha, quebra: quebra)
            ) as? String
            guard resultado == "ok" else { return false }
        }
        return true
    }

    private func traduzir(
        _ lines: [String], from source: Language, to target: Language,
        label: String, recarregou: Bool
    ) async throws -> [String] {
        try Task.checkCancellation()
        let view = self.view()

        if deveRenovar() {
            Self.debug("renovando conversa depois de \(lotesNestaConversa) lotes")
            conversationLoaded = false
        }

        if !conversationLoaded {
            // hl=pt-BR fixa o idioma da interface — os seletores de botão
            // acima procuram o texto em português, e sem isto o idioma do
            // sistema de quem roda o app mudaria o rótulo.
            guard let url = URL(string: "https://gemini.google.com/app?hl=pt-BR") else {
                throw GeminiWebError.timedOut(label)
            }
            view.load(URLRequest(url: url))
            let achouCampo = try await aguardarCampo(view, prazo: 15)
            Self.debug("achouCampo=\(achouCampo)")
            guard achouCampo else {
                throw GeminiWebError.timedOut(label)
            }
            conversationLoaded = true
            lotesNestaConversa = 0
            conversaComecouEm = Date()
        }

        let antes = (try? await ler(view))?.respostas ?? 0
        let texto = GeminiWeb.prompt(for: lines, from: source, to: target)
        let inseriu = try await inserir(view, texto: texto)
        let enviou = inseriu
            ? (try? await view.evaluateJavaScript(Self.enviar)) as? String
            : nil
        Self.debug("antes=\(antes) enviado=\(texto.count) inseriu=\(inseriu) enviou=\(enviou ?? "nil")")

        guard enviou == "ok" else {
            log.notice("nao consegui enviar em \(label, privacy: .public) (inserir=\(inseriu, privacy: .public), enviar=\(enviou ?? "-", privacy: .public))")
            guard !recarregou else {
                await registrarFalha(
                    view, motivo: "não consegui enviar (inserir=\(inseriu), enviar=\(enviou ?? "-"))",
                    label: label
                )
                throw GeminiWebError.timedOut(label)
            }
            conversationLoaded = false
            return try await traduzir(lines, from: source, to: target, label: label, recarregou: true)
        }

        let relogio = Date()
        let resposta: String
        do {
            resposta = try await esperar(view, apos: antes, label: label)
        } catch {
            // A conversa atual pode ter travado; a próxima tentativa começa
            // carregando a página de novo. O que a página mostrava no
            // instante da desistência é o que ajuda a saber se foi limite de
            // uso, desafio anti-robô, ou outra coisa — só o "não respondeu a
            // tempo" na tela não diz qual dos três.
            await registrarFalha(view, motivo: "\(error.localizedDescription)", label: label)
            conversationLoaded = false
            throw error
        }
        log.notice("\(label, privacy: .public): \(lines.count) falas, \(Int(Date().timeIntervalSince(relogio) * 1000))ms")

        guard let traduzidas = GeminiWeb.parse(resposta, expected: lines.count) else {
            registrarErro(prompt: texto, resposta: resposta, label: label)
            throw GeminiWebError.malformedResponse(label)
        }

        if source != target, GeminiWeb.pareceIntocado(source: lines, translated: traduzidas) {
            log.notice("Gemini devolveu a origem sem traduzir em \(label, privacy: .public)")
            guard !recarregou else {
                registrarErro(prompt: texto, resposta: resposta, label: label)
                throw GeminiWebError.untranslated(label)
            }
            conversationLoaded = false
            return try await traduzir(lines, from: source, to: target, label: label, recarregou: true)
        }

        lotesNestaConversa += 1
        return traduzidas
    }

    /// Espera a resposta **desta** mensagem — não a anterior, que continua
    /// visível até a nova aparecer.
    ///
    /// Duas fases: primeiro uma nova resposta precisa aparecer (a contagem de
    /// respostas crescer além de `apos`), depois ela precisa parar de gerar
    /// (`gerando` falso) e ficar com o mesmo texto em `stableReads` leituras
    /// seguidas — a resposta chega aos poucos, e ler no meio devolveria uma
    /// legenda cortada.
    private func esperar(_ view: WKWebView, apos: Int, label: String) async throws -> String {
        let limite = Date().addingTimeInterval(Self.responseTimeout)
        var anterior = ""
        var iguais = 0
        var apareceu = false

        while Date() < limite {
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()

            guard let estado = try? await ler(view) else {
                Self.debug("ler() = nil")
                continue
            }
            Self.debug("gerando=\(estado.gerando) respostas=\(estado.respostas) apos=\(apos) ultima=\(estado.ultima.prefix(40))")

            if !apareceu {
                guard estado.respostas > apos else { continue }
                apareceu = true
            }

            if estado.gerando {
                iguais = 0
                anterior = estado.ultima
                continue
            }

            iguais = estado.ultima == anterior ? iguais + 1 : 0
            anterior = estado.ultima
            guard iguais >= Self.stableReads, !estado.ultima.isEmpty else { continue }

            return estado.ultima
        }
        throw GeminiWebError.timedOut(label)
    }

    /// Espera o campo de entrada existir, depois da carga da página.
    private func aguardarCampo(_ view: WKWebView, prazo: TimeInterval) async throws -> Bool {
        let limite = Date().addingTimeInterval(prazo)
        while Date() < limite {
            try Task.checkCancellation()
            let achou = (try? await view.evaluateJavaScript(
                "!!document.querySelector('[contenteditable=\"true\"]')"
            )) as? Bool
            if achou == true { return true }
            try await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func ler(_ view: WKWebView) async throws -> Estado? {
        guard let bruto = try await view.evaluateJavaScript(Self.leitura) as? String,
              let dados = bruto.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(Estado.self, from: dados)
    }

    /// Grava o prompt e a resposta crua — para poder colar de volta quando a
    /// tradução falhar. Só escreve no caminho de erro; uma tradução que dá
    /// certo não toca este arquivo.
    private func registrarErro(prompt: String, resposta: String, label: String) {
        anexarLog("""
            === \(label) · resposta fora do formato ===
            --- prompt enviado ---
            \(prompt)
            --- resposta crua ---
            \(resposta)
            """)
        log.error("Gemini: resposta fora do formato em \(label, privacy: .public); log em \(Self.errorLogPath, privacy: .public)")
    }

    /// Grava o que a página mostrava no instante em que desistiu — timeout,
    /// desafio anti-robô, ou aviso de limite de uso, o texto da tela é o que
    /// diferencia um do outro, e "não respondeu a tempo" sozinho não diz
    /// qual foi.
    private func registrarFalha(_ view: WKWebView, motivo: String, label: String) async {
        let pagina = (try? await view.evaluateJavaScript(
            "(document.body.innerText || '').slice(0, 4000)"
        )) as? String ?? "(não consegui ler a página)"
        anexarLog("""
            === \(label) · \(motivo) ===
            --- url ---
            \(view.url?.absoluteString ?? "-")
            --- texto visível na página ---
            \(pagina)
            """)
        log.error("Gemini: \(motivo, privacy: .public) em \(label, privacy: .public); log em \(Self.errorLogPath, privacy: .public)")
    }

    private func anexarLog(_ bloco: String) {
        let carimbo = ISO8601DateFormatter().string(from: Date())
        let anterior = (try? String(contentsOfFile: Self.errorLogPath, encoding: .utf8)) ?? ""
        try? (anterior + "\n\(carimbo) " + bloco + "\n")
            .write(toFile: Self.errorLogPath, atomically: true, encoding: .utf8)
    }

    private struct Estado: Decodable {
        let gerando: Bool
        let respostas: Int
        let ultima: String
    }
}
