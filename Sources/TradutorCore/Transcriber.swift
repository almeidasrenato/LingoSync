import AVFoundation
import Foundation
import FluidAudio
import OSLog
import WhisperKit

/// Reconhecimento de fala. Duas implementacoes, escolhidas pelo idioma de
/// origem — a mesma decisao que o Transcrybe tomou, e pelo mesmo motivo:
/// Parakeet e muito mais rapido mas nao cobre CJK, arabe e companhia.
public protocol Transcriber: AnyObject, Sendable {
    var engineName: String { get }
    /// Mutavel de proposito: o Parakeet cobre 25 idiomas com um unico modelo
    /// carregado, entao trocar de idioma nao pode custar um recarregamento.
    var language: Language { get set }
    var isPrepared: Bool { get }
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws
    func transcribe(_ samples: [Float]) async throws -> String
    /// Reconhece marcando quando cada trecho foi falado. É o que permite
    /// gerar legenda com tempo.
    ///
    /// - Parameter progress: fração de 0 a 1 já reconhecida. Num vídeo longo
    ///   no Whisper esta chamada leva minutos; sem progresso a barra
    ///   ficava parada e parecia travada.
    func transcribeTimed(
        _ samples: [Float],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedText]

    /// Instantes em que uma voz troca por outra.
    ///
    /// Quem monta trecho a partir de palavras precisa disto para não juntar
    /// duas pessoas num trecho só — e trecho é indivisível daí para frente:
    /// `SpeakerDiarizer.assign` dá a ele um locutor, o que mais o cobre, e a
    /// palavra da outra pessoa vai junto com o rótulo errado.
    ///
    /// Medido no vídeo de 9 minutos com o reconhecimento da Apple: 14 a 21
    /// dos 135 trechos carregavam duas vozes, somando 13 a 16 s. Com o Qwen,
    /// que corta em cada fala, eram 0 de 211 — por isso isto é opcional:
    /// quem já corta certo ignora.
    var speakerBoundaries: [TimeInterval] { get set }

    /// Instantes de silêncio medidos no áudio, no meio de cada pausa. Mesma
    /// mecânica das fronteiras de voz — ver `SpeechEnergy.pauseBoundaries`.
    var pauseBoundaries: [TimeInterval] { get set }
}

extension Transcriber {
    /// Ignorar é o comportamento padrão: só quem monta trecho a partir de
    /// palavras usa as fronteiras.
    public var speakerBoundaries: [TimeInterval] {
        get { [] }
        set { _ = newValue }
    }

    public var pauseBoundaries: [TimeInterval] {
        get { [] }
        set { _ = newValue }
    }

    public func transcribeTimed(_ samples: [Float]) async throws -> [TimedText] {
        try await transcribeTimed(samples) { _ in }
    }
}

/// Um trecho reconhecido com o tempo em que foi falado.
public struct TimedText: Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    /// Quem falou, quando a identificação de locutor rodou. Ver
    /// `SpeakerDiarizer` — os reconhecedores não preenchem isto.
    public let speaker: String?

    public init(
        text: String, start: TimeInterval, end: TimeInterval, speaker: String? = nil
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// Qual família de reconhecimento usar. Escolha do usuário; uma família nova
/// entra aqui e aparece sozinha no seletor.
public enum RecognitionEngine: String, CaseIterable, Identifiable, Sendable {
    /// O reconhecimento do macOS 26, com os idiomas instalados no sistema.
    case apple
    /// Parakeet TDT v3 (NVIDIA, CC-BY 4.0). Só os idiomas europeus, mas a
    /// ~120x tempo real. ~469 MB.
    case parakeet
    /// Whisper large-v3-turbo (WhisperKit, MIT). Todos os idiomas do app,
    /// inclusive os que o Parakeet não cobre. ~1,2 GB.
    case whisper
    /// Qwen3-ASR 0.6B (Alibaba, Apache-2.0). Só nos modos de vídeo, e só
    /// quando `Scripts/qwen-setup.sh` tiver sido rodado. Ver `QwenTranscriber`.
    case qwen
    /// O mesmo, no tamanho 1.7B. Só aparece com `qwen-setup.sh --grande`.
    case qwenLarge

    public var id: String { rawValue }

    /// Padrão do app: o da Apple, quando o sistema tem (macOS 26). Nada na
    /// pasta do app, e no japonês medido foi quase três vezes mais rápido que
    /// o Whisper.
    public static var preferred: RecognitionEngine {
        RecognitionEngine.apple.isAvailable ? .apple : .whisper
    }

    public var displayName: String {
        switch self {
        case .parakeet: "Parakeet TDT v3"
        case .whisper: "Whisper turbo"
        case .qwen: "Qwen3-ASR 0.6B"
        case .qwenLarge: "Qwen3-ASR 1.7B"
        case .apple: "Apple"
        }
    }

    /// Idiomas que a família reconhece, ou `nil` para todos os do app. A
    /// Apple também devolve `nil`: a lista dela depende do que está instalado
    /// e vem de `AppleSpeechLanguages`.
    public var supportedLanguages: [Language]? {
        switch self {
        case .apple, .whisper: nil
        case .parakeet: Language.allCases.filter(\.hasParakeetSupport)
        case .qwen: QwenTranscriber.languages(for: .small)
        case .qwenLarge: QwenTranscriber.languages(for: .large)
        }
    }

    /// Se serve para a tradução ao vivo.
    ///
    /// O Qwen roda fora do processo, carregando o modelo a cada chamada, a
    /// 17× tempo real. O tempo real re-reconhece o trecho em andamento a cada
    /// 0,6 s — não cabe. Ele fica nos modos de vídeo.
    public var supportsLive: Bool {
        switch self {
        case .apple, .parakeet, .whisper: true
        case .qwen, .qwenLarge: false
        }
    }

    /// O motor que o tempo real usa quando o escolhido só serve a vídeo.
    ///
    /// Trocar calado seria pior: o painel diz qual carregou, em
    /// `Pipeline.engineNames`.
    public var forLive: RecognitionEngine { supportsLive ? self : .preferred }

    /// Se dá para identificar quem fala junto com este motor.
    ///
    /// Quem identifica é outro modelo (`SpeakerDiarizer`, do FluidAudio), que
    /// roda sobre o mesmo áudio — então a exigência sobre o reconhecedor é só
    /// uma: devolver tempo por trecho, para haver o que atribuir. Todos os
    /// motores atuais devolvem. A propriedade existe para um motor sem tempo
    /// poder dizer que não.
    public var supportsDiarization: Bool {
        switch self {
        case .apple, .parakeet, .whisper, .qwen, .qwenLarge: true
        }
    }

    public var isAvailable: Bool {
        switch self {
        case .parakeet, .whisper:
            return true
        case .qwen:
            return QwenTranscriber.isInstalled(.small)
        case .qwenLarge:
            return QwenTranscriber.isInstalled(.large)
        case .apple:
            if #available(macOS 26.0, *) { return true }
            return false
        }
    }
}

public enum TranscriberKind: Hashable, Sendable {
    case parakeet
    case whisper
    case apple
    case qwen
    case qwenLarge

    public init(for language: Language, engine: RecognitionEngine = .whisper) {
        switch engine {
        case .apple where engine.isAvailable: self = .apple
        case .qwen where engine.isAvailable: self = .qwen
        case .qwenLarge where engine.isAvailable: self = .qwenLarge
        // Rede de seguranca: o seletor de idioma ja limita o Parakeet aos
        // idiomas que ele cobre, mas uma preferencia gravada antes de o
        // idioma mudar chegaria aqui pedindo japones ao Parakeet.
        case .parakeet where !language.hasParakeetSupport: self = .whisper
        case .parakeet: self = .parakeet
        default: self = .whisper
        }
    }
}

public enum TranscriberFactory {
    /// Uma linha decide todo o orcamento de latencia do reconhecimento.
    public static func make(for language: Language, engine: RecognitionEngine = .whisper) -> Transcriber {
        switch TranscriberKind(for: language, engine: engine) {
        case .parakeet:
            return ParakeetTranscriber(language: language)
        case .whisper:
            return WhisperTranscriber(language: language)
        case .qwen:
            return QwenTranscriber(language: language, size: .small)
        case .qwenLarge:
            return QwenTranscriber(language: language, size: .large)
        case .apple:
            if #available(macOS 26.0, *) { return AppleSpeechTranscriber(language: language) }
            // Inalcançável: `.apple` só sai de `TranscriberKind` quando disponível.
            return WhisperTranscriber(language: language)
        }
    }
}

// MARK: - Parakeet

public final class ParakeetTranscriber: Transcriber, @unchecked Sendable {

    public let engineName = "Parakeet TDT v3"
    private let log = Logger(subsystem: "app.tradutor", category: "Parakeet")
    public var language: Language
    public var isPrepared: Bool { manager != nil }
    private var manager: AsrManager?
    /// O decodificador TDT carrega estado entre chamadas. Manter esse estado
    /// atravessa a emenda entre segmentos e melhora a continuidade; ele so e
    /// zerado quando o pipeline reinicia.
    private var decoderState: TdtDecoderState?

    public init(language: Language) {
        self.language = language
    }

    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let name = engineName
        let directory = ModelStorage.parakeet
        // Só diz "baixando" quando vai baixar: o rótulo fixo fazia parecer
        // que o modelo era baixado de novo a cada uso.
        let verb = AsrModels.modelsExist(at: directory, version: .v3) ? "carregando" : "baixando"
        progress(0.1, "\(verb) \(name)")
        let models = try await AsrModels.downloadAndLoad(to: directory, version: .v3) { fraction in
            progress(0.1 + fraction.fractionCompleted * 0.7, "\(verb) \(name)")
        }
        progress(0.8, "carregando \(name) no Neural Engine")
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        self.decoderState = try TdtDecoderState()
        progress(1.0, "Parakeet pronto")
        log.info("Parakeet v3 pronto para \(self.language.rawValue, privacy: .public)")
    }

    /// Sem progresso: a ~120× tempo real, termina antes de a barra importar.
    public func transcribeTimed(
        _ samples: [Float],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedText] {
        let result = try await recognize(samples)

        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // Sem marcacao, o trecho inteiro vira um bloco so com a duracao
            // do audio — melhor que devolver nada.
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [TimedText(
                text: text,
                start: 0,
                end: Double(samples.count) / 16_000
            )]
        }

        let words = buildWordTimings(from: timings)
        return words.compactMap { word in
            let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TimedText(text: text, start: word.startTime, end: word.endTime)
        }
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        try await recognize(samples).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A chamada ao modelo, com a retentativa unica do Neural Engine.
    ///
    /// O FluidAudio tem o proprio enum `Language`, e o modulo dele tambem
    /// exporta um tipo chamado `FluidAudio` — entao nem `Language` sozinho
    /// nem `FluidAudio.Language` resolvem para o tipo certo aqui. O ajudante
    /// generico `scriptHint` deixa o tipo ser deduzido do parametro.
    private func recognize(_ samples: [Float]) async throws -> ASRResult {
        guard let manager, decoderState != nil else {
            throw TranscriberError.notPrepared
        }
        return try await AneRetry.once { isRetry in
            if isRetry {
                // A chamada que falhou pode ter deixado o decodificador no
                // meio de uma hipotese; a segunda comeca limpa.
                self.decoderState = try TdtDecoderState()
                self.log.warning("\(self.engineName, privacy: .public) falhou; segunda tentativa")
            }
            guard var state = self.decoderState else { throw TranscriberError.notPrepared }
            let result = try await manager.transcribe(
                samples, decoderState: &state, language: scriptHint(self.language.rawValue)
            )
            self.decoderState = state
            return result
        }
    }
}

/// Uma segunda tentativa quando a predicao no Neural Engine falha.
///
/// Medido no Parakeet japones: a primeira inferencia depois de carregar as
/// vezes estoura o tempo do ANE — "ANE op async execution has timed out" — e
/// a transcricao inteira falha. O usuario ve "nenhuma fala reconhecida" num
/// audio cheio de fala, e em outra execucao os mesmos 96 s levaram 59 s em
/// vez dos 2 s de sempre. Quente, o modelo nao erra mais.
///
/// Uma tentativa so: se a segunda falhar tambem, o erro sobe — repetir sem
/// limite esconderia um modelo quebrado. Cancelamento nunca e retentado:
/// quem cancelou quer parar.
public enum AneRetry {
    public static func once<T>(
        _ attempt: (_ isRetry: Bool) async throws -> T
    ) async throws -> T {
        do {
            return try await attempt(false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return try await attempt(true)
        }
    }
}

// MARK: - Whisper

public final class WhisperTranscriber: Transcriber, @unchecked Sendable {

    public let engineName = "Whisper turbo"
    private let log = Logger(subsystem: "app.tradutor", category: "Whisper")
    /// Trocar o idioma so muda a opcao de decodificacao; o modelo carregado
    /// continua servindo.
    public var language: Language
    public var isPrepared: Bool { pipeline != nil }
    private var pipeline: WhisperKit?

    /// 809 M, decoder destilado. O nome da OpenAI para ele é
    /// `large-v3-v20240930`; o sufixo `_turbo` é o empacotamento do WhisperKit
    /// para o Neural Engine, outra coisa.
    ///
    /// O large-v3 completo (1,55 B) já foi opção e saiu — ver CLAUDE.md.
    private static let modelIdentifier = "large-v3-v20240930_turbo"

    /// A pasta do modelo, se ele já estiver inteiro no disco.
    private static func localModel(_ variant: String) -> URL? {
        let folder = ModelStorage.whisper.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/openai_whisper-\(variant)", isDirectory: true)
        let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        let complete = required.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        return complete ? folder : nil
    }

    /// Confianca minima do primeiro token de uma janela.
    ///
    /// O padrao do WhisperKit e -1,5, e e o numero que fazia a legenda variar
    /// de execucao para execucao. Abaixo dele o WhisperKit re-decodifica a
    /// mesma janela com temperatura 0,2 · 0,4 · 0,6 · 0,8 · 1,0 — e o
    /// amostrador, com temperatura acima de zero, sorteia o token
    /// (`Float.random`, sem semente). O mesmo arquivo dava 9, 20, 25 ou 34
    /// trechos, e em uma execucao a cada tres os primeiros 32 s do dialogo
    /// sumiam inteiros.
    ///
    /// Medido no video de conversa com musica ao fundo, quatro execucoes cada:
    ///
    ///     -1,5 (padrao) : 34 / 25 / 20 / 31 trechos, 7 a 17 retentativas
    ///     -3,0          : 30 / 32 / 30 / 32 trechos, nenhuma retentativa
    ///
    /// Em audio limpo o texto sai identico ao da melhor execucao do padrao
    /// (unica diferenca em 96 s: um tempo 0,02 s adiante). A cobertura do
    /// .srt desse video subiu de 44% para 70%.
    ///
    /// Zerar `temperatureFallbackCount` tambem acaba com o sorteio, e foi
    /// medido: cai para 9 trechos: as retentativas aleatorias recuperavam
    /// texto de verdade. O caminho certo e nao precisar delas.
    ///
    /// As outras defesas do WhisperKit continuam de pe: `noSpeechThreshold`,
    /// `compressionRatioThreshold` e `logProbThreshold`, mais o filtro de
    /// `isRealSpeech` e a lista de alucinacoes.
    public static let firstTokenLogProbThreshold: Float = -3.0

    public init(language: Language) {
        self.language = language
    }

    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let nome = engineName
        let variant = ProcessInfo.processInfo.environment["WHISPER_MODELO"] ?? Self.modelIdentifier
        // Já em disco: usa direto. `WhisperKit.download` consulta o Hugging
        // Face toda vez, mesmo com tudo baixado — eram 6 s e uma ida à rede a
        // cada carga, e sem internet a carga falhava.
        let folder: URL
        if let local = Self.localModel(variant) {
            folder = local
        } else {
            // Download separado do `WhisperKitConfig(download: true)` só para
            // ter progresso: são 1,2 GB, e na primeira vez a barra ficava
            // parada minutos em "baixando".
            progress(0.05, "baixando \(nome)")
            folder = try await WhisperKit.download(
                variant: variant,
                downloadBase: ModelStorage.whisper
            ) { baixado in
                progress(0.05 + baixado.fractionCompleted * 0.45,
                         String(format: "baixando %@: %.0f%%", nome, baixado.fractionCompleted * 100))
            }
        }
        // Com ASR_DEBUG o WhisperKit conta por que descartou cada janela
        // ("Fallback #N (razao)"), que e a unica forma de saber qual limiar
        // disparou. O padrao e .error: em uso normal isso sao centenas de
        // linhas por video.
        let depurando = ProcessInfo.processInfo.environment["ASR_DEBUG"] != nil
        if depurando {
            // Sem callback as mensagens vao para o os_log, fora do terminal.
            Logging.shared.loggingCallback = { mensagem in
                FileHandle.standardError.write(Data("[whisperkit] \(mensagem)\n".utf8))
            }
        }
        let config = WhisperKitConfig(
            downloadBase: ModelStorage.whisper,
            modelFolder: folder.path,
            // Sem isto o tokenizador é procurado no padrão do Hugging Face
            // (`~/Documents/huggingface`) e, não achando, buscado na rede —
            // o que está em disco fica em `whisper/models/openai/...`.
            tokenizerFolder: ModelStorage.whisper,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            // `verbose` e o interruptor geral: com ele falso o WhisperKit
            // forca o nivel para .none e ignora `logLevel`.
            verbose: depurando,
            logLevel: depurando ? .info : .error,
            prewarm: true,
            load: true,
            download: false
        )
        // Na primeira vez o sistema compila o modelo para o Neural Engine, e
        // isso não reporta progresso nenhum.
        progress(0.5, "carregando \(nome)")
        pipeline = try await WhisperKit(config)
        progress(1.0, "Whisper pronto")
        log.info("Whisper turbo pronto para \(self.language.rawValue, privacy: .public)")
    }

    /// Repete a passada quando ela sai pobre, e fica com a melhor.
    ///
    /// O WhisperKit re-decodifica a janela com temperatura acima de zero
    /// quando um dos três limiares dispara, e aí o amostrador **sorteia** o
    /// token. Em áudio difícil isso vira loteria: medido num vídeo de 78 s
    /// com fala baixa e vento, três execuções do mesmo arquivo deram 4, 14 e
    /// 9 trechos — uma pegou só o começo, outra só o fim.
    ///
    /// Não dá para tirar o sorteio: `temperatureFallbackCount = 0` foi medido
    /// e derruba a captação (30 trechos para 9), e o `Float.random` do
    /// WhisperKit não aceita semente. O que dá é **notar que a passada saiu
    /// ruim e tentar de novo**, ficando com a que cobriu mais fala.
    ///
    /// Em áudio normal a primeira passada já passa do piso e nada se repete —
    /// o custo só aparece onde o problema existe.
    public func transcribeTimed(
        _ samples: [Float],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedText] {
        let regioes = SpeechEnergy.regions(samples, minimumPause: 0.5)

        var melhor: [TimedText] = []
        var melhorCobertura = -1.0
        for tentativa in 1...Self.maximumAttempts {
            try Task.checkCancellation()
            let saida = try await transcribeOnce(samples) { fracao in
                // A barra não pode voltar: cada tentativa ocupa a sua fatia.
                let fatia = 1 / Double(Self.maximumAttempts)
                progress(min(1, (Double(tentativa - 1) + fracao) * fatia))
            }
            let cobertura = Self.reached(regioes, by: saida)
            if cobertura > melhorCobertura {
                melhorCobertura = cobertura
                melhor = saida
            }
            if ProcessInfo.processInfo.environment["ASR_DEBUG"] != nil {
                FileHandle.standardError.write(Data(String(
                    format: "[passada %d] cobertura %.0f%% · %d trechos · %d caracteres\n",
                    tentativa, cobertura * 100, saida.count,
                    saida.reduce(0) { $0 + $1.text.count }).utf8))
            }
            if cobertura >= Self.coverageFloor { break }
            log.info("passada \(tentativa, privacy: .public) cobriu \(Int(cobertura * 100), privacy: .public)% da fala; repetindo")
        }
        progress(1)
        return melhor
    }

    /// Fração dos trechos de fala que precisa ter recebido **algum** texto
    /// para a passada ser aceita de primeira.
    ///
    /// A medida é alcance, não cobertura de tempo: contar segundos cobertos
    /// pune quem corta fino, e o Whisper corta fino de propósito — no vídeo
    /// de 9 minutos ele cobre 51% do tempo com a legenda inteira certa, e
    /// repetir ali seria triplicar o tempo à toa.
    public static let coverageFloor = 0.75

    /// Teto de tentativas. Três porque a terceira já raspa o que a primeira
    /// deixou: medido no vídeo difícil, 4 · 14 · 9 trechos nas três.
    public static let maximumAttempts = 3

    /// Fração dos trechos de fala que algum texto alcançou.
    ///
    /// É a medida certa de "passada pobre": contar caracteres premiaria a
    /// execução que repete a mesma frase — que é justamente o defeito que a
    /// retentativa com temperatura produz — e contar segundos cobertos
    /// puniria quem corta fino.
    public static func reached(_ regions: [ClosedRange<Double>], by pieces: [TimedText]) -> Double {
        guard !regions.isEmpty else { return 1 }
        let alcancados = regions.filter { region in
            pieces.contains { $0.end > region.lowerBound && $0.start < region.upperBound }
        }
        return Double(alcancados.count) / Double(regions.count)
    }

    private func transcribeOnce(
        _ samples: [Float],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedText] {
        guard let pipeline else { throw TranscriberError.notPrepared }

        var options = decodingOptions()
        options.withoutTimestamps = false
        options.wordTimestamps = true
        // Arquivo longo: deixa o WhisperKit fatiar nas pausas, senao ele so
        // enxerga os primeiros 30 s.
        options.chunkingStrategy = .vad

        // O WhisperKit mantem um `Progress` com um filho por bloco do VAD.
        // Ler a fracao dele de tempos em tempos custa nada; o callback por
        // token dispararia milhares de vezes, de varias threads ao mesmo tempo.
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                if let fraction = self?.pipeline?.progress.fractionCompleted {
                    progress(min(1, max(0, fraction)))
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { monitor.cancel() }

        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
        progress(1)

        let all = results.flatMap(\.segments)
        let kept = all.filter(Self.isRealSpeech)
        if ProcessInfo.processInfo.environment["ASR_DEBUG"] != nil {
            for segment in all.prefix(6) {
                FileHandle.standardError.write(Data(String(
                    format: "[bruto] %.2f-%.2f  %@\n",
                    segment.start, segment.end,
                    WhisperTranscriber.stripSpecialTokens(segment.text)
                ).utf8))
            }
            for segment in all where !Self.isRealSpeech(segment) {
                FileHandle.standardError.write(Data(String(
                    format: "[filtrado] %.1f-%.1f noSpeech=%.2f logprob=%.2f compr=%.2f  %@\n",
                    segment.start, segment.end, segment.noSpeechProb,
                    segment.avgLogprob, segment.compressionRatio,
                    WhisperTranscriber.stripSpecialTokens(segment.text)
                ).utf8))
            }
            FileHandle.standardError.write(Data(
                "[asr] \(all.count) segmentos, \(kept.count) mantidos\n".utf8))
        }

        return kept
            .compactMap { segment -> TimedText? in
                let text = WhisperTranscriber.stripSpecialTokens(segment.text)
                guard !text.isEmpty else { return nil }
                // As metricas do proprio modelo nao pegam a frase de cortesia
                // inventada: para ele e uma predicao confiante. O texto pega.
                guard !Hallucinations.isIsolatedFiller(text) else { return nil }
                return TimedText(
                    text: text,
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end)
                )
            }
            // Os blocos que o WhisperKit corta pelo detector de voz se
            // sobrepoem nas bordas, entao os segmentos nao saem em ordem
            // cronologica. Sem ordenar, a legenda 5 começava depois de
            // terminar.
            .sorted { $0.start < $1.start }
    }

    /// Descarta o que o modelo inventou.
    ///
    /// O Whisper preenche silencio e musica com frases de cortesia aprendidas
    /// do material de treino — em japones, "ご視聴ありがとうございました"
    /// (obrigado por assistir) aparece sozinha no meio do video. Ela vinha com
    /// tempo e tudo, indistinguivel de fala real na saida final.
    ///
    /// Os dois numeros que o proprio modelo reporta separam isso: a
    /// probabilidade de nao haver fala no trecho, e a confianca media dos
    /// tokens. Alucinacao pontua mal nos dois.
    private static func isRealSpeech(_ segment: TranscriptionSegment) -> Bool {
        guard segment.noSpeechProb < 0.6 else { return false }
        guard segment.avgLogprob > -1.0 else { return false }

        // Repeticao degenerada: o modelo trava numa frase e a repete. Razao de
        // compressao alta e a assinatura disso.
        guard segment.compressionRatio < 2.4 else { return false }
        return true
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let pipeline else { throw TranscriberError.notPrepared }
        let options = decodingOptions()
        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
        let raw = results.map(\.text).joined(separator: " ")
        return WhisperTranscriber.stripSpecialTokens(raw)
    }

    private func decodingOptions() -> DecodingOptions {
        var options = DecodingOptions()
        // Idioma fixo: com autodeteccao, uma pausa longa faz o modelo achar
        // que a lingua mudou no meio da conversa.
        options.language = language.rawValue
        options.task = .transcribe          // nunca .translate: so traduz p/ ingles
        options.temperature = 0
        options.withoutTimestamps = true
        options.chunkingStrategy = .none
        options.firstTokenLogProbThreshold = Self.firstTokenLogProbThreshold
        return options
    }

    /// Tira os tokens especiais do Whisper (`<|ja|>`, `<|transcribe|>`,
    /// `<|notimestamps|>`) do texto.
    ///
    /// O padrao anterior era `<|[^>]*|>` com os pipes SEM escape, o que em
    /// expressao regular nao e o delimitador do Whisper e sim alternancia:
    /// "<" ou "qualquer coisa que nao seja >" ou ">". A alternativa do meio
    /// casa com a transcricao inteira, entao toda saida do Whisper era
    /// apagada e voltava vazia — sem erro nenhum.
    public static func stripSpecialTokens(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: "<\\|[^|<>]*\\|>",
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Converte o codigo do nosso idioma para o enum de idioma de quem chama,
/// deduzido do contexto. Existe so por causa da colisao de nomes descrita em
/// `ParakeetTranscriber.transcribe`.
private func scriptHint<T: RawRepresentable>(_ code: String) -> T? where T.RawValue == String {
    T(rawValue: code)
}

public enum TranscriberError: LocalizedError {
    case notPrepared
    case unsupportedLanguage(String, Language)
    case qwenMissing(String)
    case qwenFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            "O reconhecedor ainda nao terminou de carregar os modelos."
        case let .qwenMissing(path):
            "O Qwen3-ASR não está instalado. Rode Scripts/qwen-setup.sh, que cria o ambiente em \(path)."
        case let .qwenFailed(detail):
            "O Qwen3-ASR falhou: \(detail)"
        case let .unsupportedLanguage(engine, language):
            "\(engine) não reconhece \(language.displayName). Escolha outro reconhecimento ou outro idioma."
        }
    }
}
