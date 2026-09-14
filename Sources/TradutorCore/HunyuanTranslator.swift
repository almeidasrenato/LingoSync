import Foundation
import OSLog

/// Hunyuan-MT-7B (Tencent), tradutor local que roda fora do processo.
///
/// O DeepL ganha da Apple em japonês mas manda o texto para fora; este é o
/// candidato a fazer o mesmo sem sair daqui — pesos abertos, especializado em
/// tradução, 33 idiomas. Mesmo desenho do `QwenTranscriber`: MLX em Python,
/// ambiente por `Scripts/hunyuan-setup.sh`, e o motor só aparece quando ele
/// existe.
///
/// - **O processo fica vivo entre as falas**: um 7B leva dezenas de segundos
///   para carregar. O servidor lê uma linha JSON e devolve outra.
/// - **Uma fala por requisição**: várias juntas devolvem um bloco e a contagem
///   de linhas deixa de ser garantida — o mesmo problema do site do DeepL.
public final class HunyuanTranslator: Translator, @unchecked Sendable {

    public let engineName = "Hunyuan-MT 7B"
    private let log = Logger(subsystem: "app.tradutor", category: "Hunyuan")

    /// Onde `Scripts/hunyuan-setup.sh` instala.
    public static let home = ModelStorage.root
        .deletingLastPathComponent()
        .appendingPathComponent("hunyuan", isDirectory: true)

    static var python: URL { home.appendingPathComponent("venv/bin/python") }
    static var server: URL { home.appendingPathComponent("servidor.py") }
    static var model: URL { home.appendingPathComponent("modelo", isDirectory: true) }

    /// O motor só aparece no seletor com o ambiente e o modelo em disco.
    public static var isInstalled: Bool {
        let arquivos = FileManager.default
        return arquivos.isExecutableFile(atPath: python.path)
            && arquivos.fileExists(atPath: server.path)
            && arquivos.fileExists(atPath: model.appendingPathComponent("config.json").path)
    }

    /// Lote de um: a alternativa é o modelo devolver um bloco e a contagem de
    /// legendas deixar de bater. Ver o comentário do tipo.
    public var preferredBatchSize: Int { 20 }

    /// Abaixo disto, a fala não vai para o modelo.
    ///
    /// Interjeição de uma palavra é onde ele derrapa: em "あ" ele devolveu
    /// "Ah… Parece que houve um erro na tradução" — comentou a tarefa em vez
    /// de traduzir. Sem contexto não há o que um modelo de instrução entenda
    /// ali, e a Apple resolve "あ" em milissegundos, sem inventar.
    ///
    /// Sem espaço dentro **e** menos de 4 caracteres: japonês não separa
    /// palavra por espaço, então o tamanho é o que sobra como critério.
    public static let shortestForModel = 4

    public static func tooShort(_ text: String) -> Bool {
        text.count < shortestForModel && !text.contains(where: \.isWhitespace)
    }

    /// Fala curta e o que o modelo não der conta caem aqui.
    private let backup = AppleTranslator()

    /// A última fala traduzida, que vai como contexto da próxima.
    private var lastPair: (source: String, target: String)?

    private var process: Process?
    private var toServer: FileHandle?
    private var fromServer: FileHandle?
    private var buffer = Data()

    public init() {}

    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard Self.isInstalled else { throw HunyuanError.notInstalled }
        guard process == nil else { return }

        progress(0.1, "carregando Hunyuan-MT…")

        let entrada = Pipe()
        let saida = Pipe()
        let process = Process()
        process.executableURL = Self.python
        process.arguments = [Self.server.path]
        var ambiente = ProcessInfo.processInfo.environment
        // O modelo está em disco; consulta ao Hugging Face a cada carga seria
        // segundos jogados fora — o mesmo erro que o WhisperKit fazia.
        ambiente["HF_HOME"] = Self.home.appendingPathComponent("hf").path
        ambiente["HF_HUB_OFFLINE"] = "1"
        process.environment = ambiente
        process.standardInput = entrada
        process.standardOutput = saida
        process.standardError = FileHandle.nullDevice

        try process.run()
        self.process = process
        toServer = entrada.fileHandleForWriting
        fromServer = saida.fileHandleForReading

        // Leitura sem bloquear.
        //
        // `availableData` prende a thread até chegar byte ou o pipe fechar — e
        // preso ali o prazo não vale (ele só é olhado entre leituras) e o
        // cancelamento não chega. O modelo de 7B leva dezenas de segundos para
        // carregar, e a janela ficava surda todo esse tempo. Com `O_NONBLOCK` o
        // `read` volta na hora, e quem espera é o laço — que sabe olhar o
        // relógio e atender o cancelamento.
        let descritor = saida.fileHandleForReading.fileDescriptor
        let flags = fcntl(descritor, F_GETFL, 0)
        if flags != -1 { _ = fcntl(descritor, F_SETFL, flags | O_NONBLOCK) }

        // A primeira linha é o aviso de que o modelo carregou. 7B em 4 bits
        // leva dezenas de segundos; sem esperar, a primeira fala falharia.
        guard let pronto = try await readLine(timeout: 300),
              pronto["ready"] != nil
        else {
            stop()
            throw HunyuanError.didNotStart
        }
        progress(1.0, "Hunyuan-MT pronto")
    }

    public func reset() {
        stop()
    }

    private func stop() {
        lastPair = nil
        toServer?.closeFile()
        // Fechar também a ponta de leitura: quem estiver bloqueado em
        // `availableData` só acorda quando o pipe fecha, e sem isso o
        // cancelamento ficava esperando uma resposta que não vinha mais.
        fromServer?.closeFile()

        // `terminate()` é SIGTERM, e o servidor pode estar dentro de uma
        // chamada do Metal que não atende sinal na hora. Sem a escalada, o
        // processo ficava vivo com o app achando que o matou — 4,5 GB órfãos,
        // e o servidor seguinte competindo com ele pela GPU.
        if let process, process.isRunning {
            process.terminate()
            let limite = Date().addingTimeInterval(2)
            while process.isRunning, Date() < limite {
                usleep(50_000)
            }
            if process.isRunning {
                log.notice("Hunyuan nao respondeu ao terminate; matando")
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process = nil
        toServer = nil
        fromServer = nil
        buffer = Data()
    }

    public func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        let limpo = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty else { return "" }

        // Fala de uma palavra não passa pelo modelo — ver `shortestForModel`.
        // Ela ainda entra no contexto da próxima: "あ" respondido continua
        // sendo parte da conversa.
        if Self.tooShort(limpo) {
            let curta = try await backup.translate(limpo, from: source, to: target)
            lastPair = (limpo, curta)
            return curta
        }

        guard let toServer else { throw TranslatorError.notPrepared }

        var pedido: [String: String] = [
            "text": limpo,
            "source": Self.englishName(source),
            "target": Self.englishName(target),
        ]
        // A fala anterior vai como turno já respondido: dá contexto e mostra
        // o formato da resposta certa, que é só a tradução.
        if let lastPair {
            pedido["prev_source"] = lastPair.source
            pedido["prev_target"] = lastPair.target
        }
        let dados = try JSONSerialization.data(withJSONObject: pedido)
        toServer.write(dados)
        toServer.write(Data("\n".utf8))

        guard let resposta = try await readLine(timeout: 120) else {
            throw HunyuanError.noAnswer
        }
        if let erro = resposta["error"] {
            log.error("Hunyuan: \(erro, privacy: .public)")
            throw HunyuanError.model(erro)
        }
        let traduzido = (resposta["text"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lastPair = (limpo, traduzido)
        return traduzido
    }

    /// Uma linha JSON do servidor, ou `nil` se ele fechou.
    ///
    /// Lê em pedaços porque `availableData` não respeita fronteira de linha: a
    /// resposta pode chegar partida, ou duas podem chegar juntas.
    private func readLine(timeout: TimeInterval) async throws -> [String: String]? {
        guard let fromServer else { return nil }
        let limite = Date().addingTimeInterval(timeout)

        while Date() < limite {
            if let quebra = buffer.firstIndex(of: 0x0A) {
                let linha = buffer[..<quebra]
                buffer.removeSubrange(...quebra)
                guard !linha.isEmpty else { continue }
                // Linha que não é JSON é ruído da biblioteca, não resposta:
                // o `transformers` cospe aviso de configuração ao carregar.
                // Ignorar e seguir lendo; falhar aqui derrubaria a carga.
                guard let objeto = try? JSONSerialization.jsonObject(with: linha),
                      let dicionario = objeto as? [String: Any]
                else { continue }
                return dicionario.compactMapValues { "\($0)" }
            }
            switch Self.lerSemBloquear(fromServer.fileDescriptor) {
            case let .dados(pedaco):
                buffer.append(pedaco)
            case .vazio:
                // Ainda não chegou nada: espera um pouco e olha o relógio e o
                // cancelamento, que é o que este laço sabe fazer.
                try await Task.sleep(for: .milliseconds(50))
                try Task.checkCancellation()
            case .fim:
                // O servidor fechou o pipe. Insistir aqui era ficar 300 s (na
                // carga) ou 120 s (na fala) esperando quem não responde mais,
                // com a janela parada em "carregando" o tempo todo.
                log.notice("o servidor do Hunyuan saiu")
                return nil
            }
        }
        return nil
    }

    private enum Leitura {
        case dados(Data)
        /// Nada agora — o servidor ainda está pensando.
        case vazio
        /// O pipe fechou: não vem mais nada.
        case fim
    }

    /// Um `read` que volta na hora, com ou sem dado.
    ///
    /// Separa as três respostas que o laço precisa distinguir e que
    /// `availableData` mistura: chegou, ainda não chegou, e acabou.
    private static func lerSemBloquear(_ descritor: Int32) -> Leitura {
        var pedaco = [UInt8](repeating: 0, count: 64 * 1024)
        let lidos = read(descritor, &pedaco, pedaco.count)
        if lidos > 0 { return .dados(Data(pedaco[..<lidos])) }
        if lidos == 0 { return .fim }
        // EAGAIN/EWOULDBLOCK é "ainda não chegou"; EINTR é sinal no meio.
        return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? .vazio : .fim
    }

    /// Nome do idioma em inglês, que é o que o prompt do modelo espera.
    public static func englishName(_ language: Language) -> String {
        switch language {
        case .portuguese: "Portuguese"
        case .english: "English"
        case .spanish: "Spanish"
        case .french: "French"
        case .german: "German"
        case .italian: "Italian"
        case .dutch: "Dutch"
        case .polish: "Polish"
        case .russian: "Russian"
        case .ukrainian: "Ukrainian"
        case .japanese: "Japanese"
        case .chinese: "Chinese"
        case .korean: "Korean"
        case .arabic: "Arabic"
        case .hindi: "Hindi"
        case .turkish: "Turkish"
        case .vietnamese: "Vietnamese"
        case .thai: "Thai"
        }
    }
}

public enum HunyuanError: LocalizedError {
    case notInstalled
    case didNotStart
    case noAnswer
    case model(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "O Hunyuan-MT não está instalado. Rode Scripts/hunyuan-setup.sh."
        case .didNotStart:
            "O Hunyuan-MT não terminou de carregar."
        case .noAnswer:
            "O Hunyuan-MT não respondeu a tempo."
        case let .model(detalhe):
            "O Hunyuan-MT falhou: \(detalhe)"
        }
    }
}
