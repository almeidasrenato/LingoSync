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

    /// O 0.6B não pontua em inglês.
    ///
    /// Em 161 s de conversa: **zero** sinais, contra 63 do Parakeet, 73 da
    /// Apple e 73 do próprio 1.7B. Sem ponto o agrupador perde a fronteira de
    /// frase. Em japonês o mesmo modelo pontua normal — é por idioma, e só o
    /// inglês foi medido.
    static let unpunctuated: [Size: [Language]] = [.small: [.english]]

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

        // `-f srt` em vez de json de propósito: o próprio modelo quebra o
        // texto em falas com pontuação, que é o formato que a legenda quer, e
        // o `SRTParser` do app já sabe ler isso — inclusive o piso de duração
        // que conserta os blocos de duração zero que ele às vezes emite.
        let process = Process()
        let optimizedMemory = size == .large
            && ProcessInfo.processInfo.environment["TRADUTOR_QWEN_SEM_OTIMIZACAO"] == nil
        process.executableURL = optimizedMemory
            ? Self.home.appendingPathComponent("venv/bin/python") : Self.executable
        var arguments = [
            "--model", size.rawValue,
            "--language", idioma,
            "--timestamps",
            "-f", "srt",
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

        let srt = folder.appendingPathComponent("fala.srt")
        let cues = try SRTParser.parse(contentsOf: srt)
        progress(1)
        return cues.map {
            TimedText(text: $0.translated, start: $0.start, end: $0.end)
        }
    }

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
