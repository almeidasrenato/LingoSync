import AVFoundation
import Foundation
import OSLog

/// Qwen3-ASR 0.6B (Alibaba, Apache-2.0), o único reconhecedor do app que não
/// roda dentro do processo.
///
/// Não há port CoreML utilizável; o que existe é MLX em Python. Ele vive num
/// ambiente próprio (`Scripts/qwen-setup.sh`) e o app só o oferece quando esse
/// ambiente existe.
///
/// Em 96 s de japonês limpo devolve 281 caracteres contra 260 do Whisper e 248
/// da Apple — mas o que importa para legenda é o formato: **uma fala por
/// bloco, com pontuação**, enquanto a Apple emenda pergunta e resposta na
/// mesma linha. Desvio de início +0,03 s, melhor que os +0,06 s do Whisper.
///
/// Custa 17× tempo real contra 172× da Apple, e daí `supportsLive` ser falso.
public final class QwenTranscriber: Transcriber, @unchecked Sendable {

    /// Qual dos dois tamanhos. O 1.7B só existe em disco se o setup tiver
    /// rodado com `--grande`.
    ///
    /// **Os pesos de 4 bits foram medidos e recusados.** São 45% mais rápidos
    /// (25,1 s contra 45,2 s no vídeo de 9 minutos) e transcrevem um pouco
    /// menos, pelo caminho do app, em 3 dos 4 vídeos de exemplo:
    ///
    /// ```
    ///                4 bits   float16
    /// perca            128      129
    /// anime            261      265
    /// 9 min japonês   1425     1448
    /// 161 s inglês    1645     1635
    /// ```
    ///
    /// Meio por cento de texto, e num app de legenda texto vale mais que
    /// segundos. Num WAV cru, sem `boostQuietAudio` nem `levelQuietSpeech`,
    /// o 4 bits parecia ganhar (1634 contra 1449) — meça pelo caminho do app,
    /// que é onde a diferença se inverte.
    ///
    /// Dois becos medidos junto, no 0.6B: **8 bits é mais lento que float16**
    /// (6,0 s contra 4,9 s em 96 s) e **`--dtype bfloat16` é mais lento e
    /// pior** (21,0 s e 1444 caracteres contra 19,3 s e 1661 em 540 s).
    public enum Size: String, Sendable {
        case small = "Qwen/Qwen3-ASR-0.6B"
        case large = "Qwen/Qwen3-ASR-1.7B"

        var folder: String {
            "models--" + rawValue.replacingOccurrences(of: "/", with: "--")
        }
    }

    public let engineName: String
    private let size: Size
    public var language: Language
    public var isPrepared: Bool { Self.isInstalled(size) }
    /// Ver `Transcriber.speakerBoundaries`. O SRT pronto do Qwen não sabia
    /// delas; agrupando aqui, troca de voz fecha trecho como na Apple.
    public var speakerBoundaries: [TimeInterval] = []
    public var pauseBoundaries: [TimeInterval] = []
    private let log = Logger(subsystem: "app.tradutor", category: "Qwen")

    /// Onde `Scripts/qwen-setup.sh` instala.
    public static let home = ModelStorage.root
        .deletingLastPathComponent()
        .appendingPathComponent("qwen", isDirectory: true)

    static var executable: URL {
        home.appendingPathComponent("venv/bin/mlx-qwen3-asr")
    }

    // O cache livre do MLX nasce maior que a RAM desta máquina. Em 97 s de
    // japonês, limitar a 512 MiB e manter buffers residentes reduziu 12,2 s
    // para 9,9 s e o pico de 11,2 para 7,9 GiB, com SRT idêntico.
    // Só muda a gestão dos buffers: CLI, pesos, precisão e alinhador iguais.
    // O processo termina ao fim do vídeo e libera a RAM.
    private static let memoryLauncher = """
    import mlx.core as mx
    from mlx_qwen3_asr.cli import main
    try:
        mx.set_cache_limit(512 * 1024 * 1024)
        info = mx.device_info()
        mx.set_wired_limit(min(info["max_recommended_working_set_size"], info["memory_size"] // 2))
    except (AttributeError, KeyError, RuntimeError, ValueError):
        # MLX antigo ou limite indisponível: executa o mesmo CLI normalmente.
        pass
    main()
    """

    /// O motor só aparece no seletor quando o ambiente está instalado.
    public static func isInstalled(_ size: Size = .small) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        // O ambiente pode existir sem o modelo grande: o setup só o baixa com
        // `--grande`, e são 3,4 GB.
        let model = home
            .appendingPathComponent("hf/hub", isDirectory: true)
            .appendingPathComponent(size.folder, isDirectory: true)
        return FileManager.default.fileExists(atPath: model.path)
    }

    /// Os idiomas que o `--list-languages` do modelo aceita, cruzados com os
    /// que o app oferece. Ficam de fora polonês, ucraniano, vietnamita e
    /// tailandês.
    public static let languages: [Language] = [
        .portuguese, .english, .spanish, .french, .german, .italian, .dutch,
        .russian, .japanese, .chinese, .korean, .arabic, .hindi, .turkish,
    ]

    /// Tamanho que não serve para um idioma. Vazio hoje.
    ///
    /// O inglês ficou fora do 0.6B por "não pontuar": zero sinais em 161 s,
    /// contra 73 do 1.7B. Era o SRT do pacote, não o modelo — o texto do
    /// mesmo arquivo tem 65 sinais, e o pacote joga toda a pontuação fora no
    /// primeiro caractere que não casa com o alinhador (ver
    /// `transcribeTimed`). Medido de novo em 23/09/2026, pelo caminho do app.
    static let unpunctuated: [Size: [Language]] = [:]

    /// O que este tamanho oferece de fato.
    public static func languages(for size: Size) -> [Language] {
        let fora = unpunctuated[size] ?? []
        return languages.filter { !fora.contains($0) }
    }

    /// Nome do idioma como o `--language` espera.
    private static func flag(for language: Language) -> String {
        switch language {
        case .portuguese: "Portuguese"
        case .english: "English"
        case .spanish: "Spanish"
        case .french: "French"
        case .german: "German"
        case .italian: "Italian"
        case .dutch: "Dutch"
        case .russian: "Russian"
        case .japanese: "Japanese"
        case .chinese: "Chinese"
        case .korean: "Korean"
        case .arabic: "Arabic"
        case .hindi: "Hindi"
        case .turkish: "Turkish"
        case .polish, .ukrainian, .vietnamese, .thai: ""
        }
    }

    public init(language: Language, size: Size = .small) {
        self.language = language
        self.size = size
        self.engineName = size == .large ? "Qwen3-ASR 1.7B" : "Qwen3-ASR 0.6B"
    }

    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard Self.isInstalled(size) else {
            throw TranscriberError.qwenMissing(Self.home.path)
        }
        guard Self.languages(for: size).contains(language) else {
            throw TranscriberError.unsupportedLanguage(engineName, language)
        }
        // O modelo carrega dentro do processo Python, a cada chamada. Não há
        // o que manter quente aqui — e é por isso que ele não serve ao vivo.
        progress(1, "\(engineName) pronto")
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribeTimed(samples) { _ in }
            .map(\.text)
            .joined(separator: " ")
    }

    public func transcribeTimed(
        _ samples: [Float],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedText] {
        guard Self.isInstalled(size) else { throw TranscriberError.qwenMissing(Self.home.path) }
        let idioma = Self.flag(for: language)
        guard !idioma.isEmpty else {
            throw TranscriberError.unsupportedLanguage(engineName, language)
        }

        // O processo lê e escreve arquivo, não memória.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradutor-qwen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let audio = folder.appendingPathComponent("fala.wav")
        try Self.writeWAV(samples, to: audio)
        // Régua de medição: o mesmo WAV preparado pelo app pode alimentar
        // todas as variantes. copyItem recusa sobrescrever uma captura anterior.
        if let capture = ProcessInfo.processInfo.environment["TRADUTOR_QWEN_GUARDAR_WAV"] {
            try FileManager.default.copyItem(at: audio, to: URL(fileURLWithPath: capture))
        }
        progress(0.1)

        // `-f json`, e o agrupamento em falas é nosso. O SRT do pacote
        // reaplica a pontuação do texto aos segmentos do alinhador e, no
        // primeiro caractere que não bate — um espaço dentro de `TED Talks`
        // basta —, devolve **tudo sem pontuação**: na palestra do
        // TEDxWasedaU (16 min) o 0.6B tinha 201 sinais no texto e 0 no SRT,
        // e a legenda saía cortada pela largura, no meio da palavra. E o
        // agrupamento dele não conhecia as fronteiras de voz.
        let process = Process()
        let optimizedMemory = size == .large
            && ProcessInfo.processInfo.environment["TRADUTOR_QWEN_SEM_OTIMIZACAO"] == nil
        process.executableURL = optimizedMemory
            ? Self.home.appendingPathComponent("venv/bin/python") : Self.executable
        var arguments = [
            "--model", size.rawValue,
            "--language", idioma,
            "--timestamps",
            "-f", "json",
            "-o", folder.path,
            "--no-progress",
            "--quiet",
        ]
        arguments.append(audio.path)
        process.arguments = optimizedMemory ? ["-c", Self.memoryLauncher] + arguments : arguments
        var environment = ProcessInfo.processInfo.environment
        // O modelo fica na pasta do app, nunca em ~/.cache.
        environment["HF_HOME"] = Self.home.appendingPathComponent("hf").path
        // Sem rede: o modelo já está em disco, e uma consulta ao Hugging Face
        // a cada legenda custaria segundos — o mesmo erro que o WhisperKit
        // fazia.
        environment["HF_HUB_OFFLINE"] = "1"
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()

        try process.run()
        // `waitUntilExit` bloqueia a thread; num contexto async isso trava o
        // executor cooperativo.
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    process.waitUntilExit()
                    continuation.resume()
                }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()

        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let linha = stderr
                .components(separatedBy: "\n")
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            log.error("qwen falhou: \(linha, privacy: .public)")
            throw TranscriberError.qwenFailed(linha)
        }
        progress(0.9)

        let json = folder.appendingPathComponent("fala.json")
        let output = try JSONDecoder().decode(Output.self, from: Data(contentsOf: json))
        progress(1)
        let runs = Self.punctuated(output.segments ?? [], text: output.text)
        return Self.phrases(runs, boundaries: (speakerBoundaries + pauseBoundaries).sorted())
    }

    struct Output: Decodable {
        let text: String
        let segments: [Segment]?
    }

    public struct Segment: Decodable, Sendable {
        let text: String
        let start: Double
        let end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// Os segmentos do alinhador (uma palavra, ou um caractere em japonês),
    /// com a pontuação do texto de volta.
    ///
    /// Tolerante: o que não casa segue sem pontuação e o texto é
    /// reencontrado adiante, em vez de o arquivo inteiro perder a
    /// pontuação — que é o que o pacote faz.
    public static func punctuated(_ segments: [Segment], text: String) -> [TimedText] {
        let chars = Array(text)
        var cursor = 0
        func isMark(_ c: Character) -> Bool { c.isPunctuation || c.isSymbol }
        func matches(_ word: [Character], at start: Int) -> Int? {
            var i = start
            for c in word {
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                guard i < chars.count, String(chars[i]).lowercased() == String(c).lowercased() else { return nil }
                i += 1
            }
            return i
        }
        var runs: [TimedText] = []
        for segment in segments {
            let word = Array(segment.text.filter { !$0.isWhitespace })
            guard !word.isEmpty else { continue }
            var start = cursor
            var leading = ""
            while start < chars.count, chars[start].isWhitespace || isMark(chars[start]) {
                if !chars[start].isWhitespace { leading.append(chars[start]) }
                start += 1
            }
            var end = matches(word, at: start)
            if end == nil {
                leading = ""
                // Reencontra adiante; perto, para não casar com outra
                // ocorrência da mesma palavra lá na frente.
                end = (cursor..<min(chars.count, cursor + 40)).lazy.compactMap { matches(word, at: $0) }.first
            }
            var body = String(word)
            if let found = end {
                cursor = found
                var trailing = ""
                while cursor < chars.count, isMark(chars[cursor]), !"「『（(\"“".contains(chars[cursor]) {
                    trailing.append(chars[cursor])
                    cursor += 1
                }
                body = leading + body + trailing
            }
            runs.append(TimedText(text: body, start: segment.start, end: max(segment.end, segment.start)))
        }
        return runs
    }

    /// Junta os segmentos em trechos: fecha na pontuação de frase, na pausa,
    /// na troca de voz e no teto de tempo — as mesmas regras da Apple
    /// (`AppleSpeechTranscriber.phrases`), agora com o tempo de cada palavra
    /// que o alinhador já dava e o SRT pronto jogava fora.
    public static func phrases(_ runs: [TimedText], boundaries: [TimeInterval] = []) -> [TimedText] {
        var pieces: [TimedText] = []
        var current: [TimedText] = []
        var side = 0
        func close() {
            guard let first = current.first, let last = current.last else { return }
            let text = Tokens.join(current.map(\.text)).trimmingCharacters(in: .whitespaces)
            if SentenceSplitter.hasContent(text) {
                pieces.append(TimedText(text: text, start: first.start, end: last.end))
            } else if let previous = pieces.popLast() {
                // Pontuação solta é o fim do trecho anterior.
                pieces.append(TimedText(text: previous.text + text, start: previous.start, end: previous.end))
            }
            current = []
        }
        for run in runs {
            if let last = current.last, run.start - last.end >= pauseGap { close() }
            let meio = (run.start + run.end) / 2
            let lado = boundaries.filter { $0 <= meio }.count
            if !current.isEmpty, lado != side { close() }
            side = lado
            if let first = current.first, run.end - first.start >= hardCeiling { close() }
            current.append(run)
            let span = run.end - (current.first?.start ?? run.end)
            if let mark = run.text.last, SentenceSplitter.sentenceEnders.contains(mark) {
                close()
            } else if span >= softCeiling, let mark = run.text.last,
                      SentenceSplitter.clauseEnders.contains(mark) {
                close()
            }
        }
        close()
        return pieces
    }

    /// Silêncio entre palavras que fecha o trecho. O mesmo meio segundo da
    /// Apple.
    static let pauseGap = 0.5
    static let softCeiling = 5.0
    static let hardCeiling = 7.0

    /// WAV 16 kHz mono, que é o formato em que o áudio já está.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else { throw TranscriberError.qwenFailed("formato de áudio inválido") }

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
        )
        // Em blocos: um buffer do tamanho de um vídeo inteiro é memória demais
        // para nada.
        let chunk = 16_000 * 30
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(end - offset)
            ) else { throw TranscriberError.qwenFailed("sem memória para o buffer") }
            buffer.frameLength = AVAudioFrameCount(end - offset)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(
                    from: source.baseAddress! + offset, count: end - offset
                )
            }
            try file.write(from: buffer)
            offset = end
        }
    }
}
