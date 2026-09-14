import Foundation
import AVFoundation
import TradutorCore
import WhisperKit

struct Line: Codable {
    var text: String
    var start: Double
    var end: Double
}
struct Measurement: Codable {
    var file: String
    var mode: String
    var seconds: Double
    var duration: Double
    var attempts: [[TranscriptionSegment]]
    var pieces: [Line]
    var cues: [Line]
}
@main struct Measure {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let out = URL(fileURLWithPath: args[0], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var files: [(String,String,Language)] = [
            ("ja-musica", "video exemplo 2 (Conversa mais complexa).mp4", .japanese),
            ("en-conversa", "video exemplo conversa de pessoas ingles.mp4", .english),
            ("en-dialogo", "video exemplo conversa de pessoas 2 ingles.mp4", .english),
            ("ja-longo", "video exemplo conversa de pessoas.mp4", .japanese),
            ("ja-dificil", "Video perca de fala japones.mp4", .japanese),
        ]
        if args.count > 1 && args[1] == "synthetic" {
            files = [("ja-boa-noite", "/tmp/tradutor-qualidade-falas/ja-boa-noite.wav", .japanese),
                ("en-obrigado", "/tmp/tradutor-qualidade-falas/en-obrigado.wav", .english),
                ("ja-contexto", "/tmp/tradutor-qualidade-falas/ja-contexto.wav", .japanese),
                ("en-contexto", "/tmp/tradutor-qualidade-falas/en-contexto.wav", .english)]
        }
        if args.count > 1 && args[1] == "noise" {
            files = [("ja-silencio", "/tmp/tradutor-qualidade-falas/silencio.wav", .japanese),
                ("en-silencio", "/tmp/tradutor-qualidade-falas/silencio.wav", .english),
                ("ja-ruido", "/tmp/tradutor-qualidade-falas/ruido.wav", .japanese),
                ("en-ruido", "/tmp/tradutor-qualidade-falas/ruido.wav", .english)]
        }
        if args.count > 1 && !["synthetic", "noise"].contains(args[1]) { files = files.filter { $0.0 == args[1] } }
        let modes = args.count > 2 ? [args[2]] : ["vad", "serial", "blank"]
        let folder = ModelStorage.whisper.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo")
        print("Carregando Whisper"); fflush(stdout)
        let pipeline = try await WhisperKit(WhisperKitConfig(
            downloadBase: ModelStorage.whisper, modelFolder: folder.path,
            tokenizerFolder: ModelStorage.whisper,
            computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine),
            verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for (name, file, lang) in files {
            let samples = try await SubtitleFileBuilder.extractAudio(from: URL(fileURLWithPath: file.hasPrefix("/") ? file : "Videos Exemplo/" + file), preferring: lang)
            let duration = Double(samples.count) / 16000
            try samples.withUnsafeBytes { try Data($0).write(to: out.appendingPathComponent(name + ".f32")) }
            let regions = SpeechEnergy.regions(samples, minimumPause: 0.5)
            for mode in modes {
                var options = DecodingOptions()
                options.language = lang.rawValue; options.task = .transcribe; options.temperature = 0
                options.firstTokenLogProbThreshold = WhisperTranscriber.firstTokenLogProbThreshold
                options.withoutTimestamps = false; options.wordTimestamps = true
                options.chunkingStrategy = mode == "serial" ? ChunkingStrategy.none : .vad
                options.suppressBlank = mode == "blank"
                var attempts: [[TranscriptionSegment]] = []
                var best: [TimedText] = []; var reached = -1.0
                let started = Date()
                for _ in 1...WhisperTranscriber.maximumAttempts {
                    let raw = try await pipeline.transcribe(audioArray: samples, decodeOptions: options).flatMap(\.segments)
                    attempts.append(raw)
                    let kept = raw.filter { $0.noSpeechProb < 0.6 && $0.avgLogprob > -1 && $0.compressionRatio < 2.4 }
                        .compactMap { segment -> TimedText? in
                            let text = WhisperTranscriber.stripSpecialTokens(segment.text)
                            guard !text.isEmpty, !Hallucinations.isIsolatedFiller(text) else { return nil }
                            return TimedText(text: text, start: Double(segment.start), end: Double(segment.end))
                        }.sorted { $0.start < $1.start }
                    let coverage = WhisperTranscriber.reached(regions, by: kept)
                    if coverage > reached { best = kept; reached = coverage }
                    if coverage >= WhisperTranscriber.coverageFloor { break }
                }
                let builder = SubtitleFileBuilder(); builder.silences = SpeechEnergy.silences(samples)
                let cues = builder.makeCues(from: best, mediaDuration: duration)
                let result = Measurement(file: file, mode: mode, seconds: Date().timeIntervalSince(started), duration: duration,
                    attempts: attempts, pieces: best.map { Line(text: $0.text, start: $0.start, end: $0.end) },
                    cues: cues.map { Line(text: $0.source, start: $0.start, end: $0.end) })
                try encoder.encode(result).write(to: out.appendingPathComponent(name + "-" + mode + ".json"))
                print("\(name) \(mode): \(attempts.count) passadas, \(best.count) trechos, \(best.reduce(0) { $0 + $1.text.count }) caracteres, \(String(format: "%.1f", result.seconds))s")
                fflush(stdout)
            }
        }
    }
}
