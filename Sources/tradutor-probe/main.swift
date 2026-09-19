import AudioCapture
import AVFoundation
import Foundation

// Ferramenta de linha de comando das fases 1 a 3. Existe para provar que a
// captura funciona antes de qualquer investimento em interface.
//
//   tradutor-probe list
//   tradutor-probe record <pid> [segundos] [saida.wav]
//   tradutor-probe segment <pid> [segundos]

let arguments = CommandLine.arguments

func usage() -> Never {
    print("""
    uso:
      tradutor-probe list
          lista os processos que o Core Audio conhece, com quem esta tocando som primeiro

      tradutor-probe record <pid> [segundos] [saida.wav]
          grava o audio de um processo em WAV 16 kHz mono   (fases 1 e 2)

      tradutor-probe segment <pid> [segundos]
          mostra os segmentos de fala conforme eles fecham  (fase 3)

      tradutor-probe selftest
          verifica ring buffer, resampler e segmentador sem precisar de audio
    """)
    exit(1)
}

// Aberto como .app (sem argumentos): roda o diagnostico, que e o caminho
// pelo qual o macOS finalmente apresenta o pedido de permissao.
if Bundle.main.bundlePath.hasSuffix(".app"), Bundle.main.bundleIdentifier != nil {
    if arguments.contains("isolamento") { runIsolationTest() }
    if arguments.contains("geral") { runSystemWideTest() }
    if arguments.contains("duplo") { runDualCaptureTest() }
    if arguments.contains("variantes") { runMicVariantTest() }
    if arguments.count == 1 { runBundledDiagnostic() }
}

guard arguments.count >= 2 else { usage() }

// Limpeza de emergencia. Um tap que sobrevive ao processo trava o audio do
// sistema ate reiniciar, entao Ctrl-C precisa passar por aqui.
final class TapHolder: @unchecked Sendable {
    var tap: ProcessTap?
}
let holder = TapHolder()

func installSignalHandlers() {
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            FileHandle.standardError.write(Data("\nencerrando, destruindo tap...\n".utf8))
            holder.tap?.stop()
            holder.tap = nil
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
}
var signalSources: [DispatchSourceSignal] = []

func resolveProcess(_ pidString: String) -> AudioProcess {
    guard let pid = pid_t(pidString) else {
        print("pid invalido: \(pidString)")
        exit(1)
    }
    do {
        let processes = try AudioProcessList.all()
        if let match = processes.first(where: { $0.pids.contains(pid) }) { return match }
        print("pid \(pid) nao aparece na lista de audio do sistema.")
        print("rode `tradutor-probe list` para ver o que esta disponivel.")
        exit(1)
    } catch {
        print("erro: \(error.localizedDescription)")
        exit(1)
    }
}

switch arguments[1] {

case "selftest":
    runSelfTest()

case "list":
    do {
        let processes = try AudioProcessList.all()
        guard !processes.isEmpty else {
            print("nenhum processo de audio visivel.")
            print("se isso persistir, a permissao de captura de audio provavelmente foi negada.")
            exit(1)
        }
        print("PID".padding(toLength: 8, withPad: " ", startingAt: 0)
            + "SOM".padding(toLength: 6, withPad: " ", startingAt: 0)
            + "APP")
        for process in processes {
            print("\(process.pid)".padding(toLength: 8, withPad: " ", startingAt: 0)
                + (process.isPlaying ? "sim" : "-").padding(toLength: 6, withPad: " ", startingAt: 0)
                + process.name)
        }
    } catch {
        print("erro: \(error.localizedDescription)")
        exit(1)
    }

case "record":
    guard arguments.count >= 3 else { usage() }
    let process = resolveProcess(arguments[2])
    let seconds = arguments.count >= 4 ? (Double(arguments[3]) ?? 10) : 10
    let outputPath = arguments.count >= 5 ? arguments[4] : "captura.wav"

    installSignalHandlers()

    let ring = RingBuffer(seconds: max(seconds + 5, 30))
    let tap = ProcessTap(process: process)
    holder.tap = tap

    do {
        try tap.start { samples in ring.write(samples) }
    } catch {
        print("erro ao iniciar o tap: \(error.localizedDescription)")
        exit(1)
    }

    let inputRate = tap.format?.mSampleRate ?? 48_000
    print("gravando \(process.name) (\(process.objectIDs.count) processo(s)) por \(Int(seconds))s  (\(Int(inputRate)) Hz -> 16000 Hz mono)")

    let resampler = try! Resampler(inputSampleRate: inputRate)
    var collected: [Float] = []
    var scratch = [Float](repeating: 0, count: 48_000)
    let deadline = Date().addingTimeInterval(seconds)

    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
        let count = ring.read(into: &scratch, maximum: scratch.count)
        if count > 0 {
            collected.append(contentsOf: try! resampler.resample(Array(scratch[0..<count])))
        }
    }
    tap.stop()
    holder.tap = nil

    let peak = collected.reduce(Float(0)) { Swift.max($0, Swift.abs($1)) }
    var energy: Float = 0
    for sample in collected { energy += sample * sample }
    let rms = collected.isEmpty ? 0 : (energy / Float(collected.count)).squareRoot()

    print("amostras: \(collected.count)  esperado: \(Int(seconds * 16_000))")
    print(String(format: "pico: %.4f   rms: %.4f", peak, rms))
    if ring.overflows > 0 { print("aviso: \(ring.overflows) estouros do ring buffer") }

    if rms < 0.0001 {
        print("")
        print("SILENCIO. O tap abriu mas nao veio audio. Causas provaveis, em ordem:")
        print("  1. o app escolhido nao estava tocando som durante a gravacao")
        print("  2. a permissao de captura de audio foi negada")
        print("     (Ajustes > Privacidade e Seguranca > Gravacao de Audio)")
        exit(1)
    }

    try! writeWAV(collected, sampleRate: 16_000, to: outputPath)
    print("gravado em \(outputPath)")

case "segment":
    guard arguments.count >= 3 else { usage() }
    let process = resolveProcess(arguments[2])
    let seconds = arguments.count >= 4 ? (Double(arguments[3]) ?? 30) : 30

    installSignalHandlers()

    let ring = RingBuffer()
    let tap = ProcessTap(process: process)
    holder.tap = tap
    do {
        try tap.start { samples in ring.write(samples) }
    } catch {
        print("erro ao iniciar o tap: \(error.localizedDescription)")
        exit(1)
    }

    let resampler = try! Resampler(inputSampleRate: tap.format?.mSampleRate ?? 48_000)
    let segmenter = Segmenter()
    var scratch = [Float](repeating: 0, count: 48_000)
    let deadline = Date().addingTimeInterval(seconds)
    let started = Date()
    var index = 0

    print("ouvindo \(process.name) por \(Int(seconds))s. Ctrl-C encerra.")
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
        let count = ring.read(into: &scratch, maximum: scratch.count)
        guard count > 0 else { continue }
        let converted = try! resampler.resample(Array(scratch[0..<count]))
        for segment in segmenter.feed(converted) {
            index += 1
            print(String(
                format: "[%6.2fs] segmento %2d   %.2fs   %@",
                Date().timeIntervalSince(started),
                index,
                segment.duration,
                segment.closedBySilence ? "fechou no silencio" : "bateu no teto de 8s"
            ))
        }
    }
    if let last = segmenter.flush() {
        index += 1
        print(String(format: "[final ] segmento %2d   %.2fs", index, last.duration))
    }
    tap.stop()
    holder.tap = nil
    print("total: \(index) segmentos")

default:
    usage()
}

func writeWAV(_ samples: [Float], sampleRate: Double, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
    )
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
        buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
    }
    try file.write(from: buffer)
}
