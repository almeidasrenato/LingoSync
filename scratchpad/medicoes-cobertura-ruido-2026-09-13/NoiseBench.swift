import AVFoundation
import Accelerate
import Foundation
import TradutorCore

func highpass(_ input: [Float], hz: Double) -> [Float] {
    let omega = 2 * Double.pi * hz / 16000
    let c = cos(omega), alpha = sin(omega) / sqrt(2), a0 = 1 + alpha
    let coefficients = [(1+c)/2/a0, -(1+c)/a0, (1+c)/2/a0, -2*c/a0, (1-alpha)/a0]
    let setup = vDSP_biquad_CreateSetup(coefficients, 1)!
    defer { vDSP_biquad_DestroySetup(setup) }
    var out = input
    for _ in 0..<2 {
        var delay: [Float] = [0,0,0,0]
        var filtered = [Float](repeating: 0, count: input.count)
        vDSP_biquad(setup, &delay, out, 1, &filtered, 1, vDSP_Length(input.count))
        out = filtered
    }
    return out
}

func writeWav(_ samples: [Float], _ path: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    let file = try AVAudioFile(forWriting: path, settings: format.settings)
    try file.write(from: buffer)
}

func energy(_ samples: [Float]) -> Float { var mean: Float = 0; vDSP_measqv(samples, 1, &mean, vDSP_Length(samples.count)); return mean }

@main struct Bench {
 static func main() async throws {
    let args = CommandLine.arguments
    let root = URL(fileURLWithPath: args[2])
    if args[1] == "fixtures" {
        let files = [("ja-longo", "video exemplo conversa de pessoas.mp4"),
                     ("ja-musica", "video exemplo 2 (Conversa mais complexa).mp4"),
                     ("en-conversa", "video exemplo conversa de pessoas ingles.mp4"),
                     ("en-dialogo", "video exemplo conversa de pessoas 2 ingles.mp4")]
        let source = URL(fileURLWithPath: args[3])
        var metadata: [[String: Any]] = []
        for (id, name) in files {
            let raw = try await SubtitleFileBuilder.extractAudio(from: source.appendingPathComponent(name), processing: false)
            try writeWav(raw, root.appendingPathComponent("\(id)-clean.wav"))
            var variants = [("clean", raw)]
            if id.hasPrefix("ja") {
                let quiet = raw.enumerated().map { $0.element * (($0.offset / 320000) % 2 == 1 ? Float(pow(10, -30.0/20)) : 1) }
                variants.append(("alternado", quiet))
                var noise = raw.indices.map { Float(sin(2 * .pi * 43 * Double($0) / 16000) + 0.6*sin(2 * .pi * 67 * Double($0) / 16000) + 0.3*sin(2 * .pi * 91 * Double($0) / 16000)) }
                let rms = sqrt(energy(noise))
                for i in noise.indices { noise[i] /= rms }
                for db in [-39, -33, -27, -21] {
                    let level = Float(pow(10, Double(db)/20))
                    variants.append(("rumble\(db)", zip(quiet, noise).map { $0 + $1*level }))
                }
            }
            for (variant, samples) in variants {
                try writeWav(samples, root.appendingPathComponent("\(id)-\(variant).wav"))
                metadata.append(["video":id,"variant":variant,"samples":samples.count,"rms":sqrt(energy(samples)),"peak":samples.map(abs).max() ?? 0])
            }
        }
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("fixtures.json"))
        print("fixtures prontas"); return
    }
    let engine = RecognitionEngine(rawValue: args[3])!
    let repeats = Int(args[4])!
    let modes = args[5].components(separatedBy: ",")
    let fileNames = args.dropFirst(6)
    for file in fileNames {
        let transcriber = TranscriberFactory.make(for: file.hasPrefix("en") ? .english : .japanese, engine: engine)
        try await transcriber.prepare { _, _ in }
        let raw = try await SubtitleFileBuilder.extractAudio(from: root.appendingPathComponent(file), processing: false)
        for repeatIndex in 1...repeats {
            // Alternar a ordem reduz a influência do aquecimento entre variantes.
            for mode in repeatIndex % 2 == 1 ? modes : modes.reversed() {
                let start = Date()
                let denoised: [Float]
                switch mode {
                case "hp100": denoised = highpass(raw, hz: 100)
                case "hp180": denoised = highpass(raw, hz: 180)
                default: denoised = raw
                }
                let samples = SubtitleFileBuilder.prepareAudio(denoised)
                let processSeconds = Date().timeIntervalSince(start)
                let pieces = try await transcriber.transcribeTimed(samples) { _ in }
                let text = pieces.map(\.text).joined(separator: " ")
                let result: [String: Any] = ["file":String(file),"engine":engine.rawValue,"mode":mode,"repeat":repeatIndex,
                    "characters":text.filter { !$0.isWhitespace }.count,"text":text,
                    "pieces":pieces.map { ["start":$0.start,"end":$0.end,"text":$0.text] },
                    "seconds":Date().timeIntervalSince(start),"processingSeconds":processSeconds]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                FileHandle.standardOutput.write(data); print(""); fflush(stdout)
            }
        }
    }
 }
}
