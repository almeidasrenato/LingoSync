import AppKit
import AVFoundation
import AudioCapture
import CoreAudio
import Foundation

// Por que o microfone entrega zero amostras.
//
// O `--selftest-microfone` do app devolveu `amostras: 0 · pico 0.00000` nesta
// maquina, e no gate `duplo` o microfone so entregou audio quando havia um
// ProcessTap de pe ao mesmo tempo. Escolher o dispositivo explicitamente nunca
// funcionou. Em vez de adivinhar qual das hipoteses e a certa, cada variante e
// medida: a que entregar audio vira o `MicrophoneTap`.

private struct Variante {
    let nome: String
    let montar: (AVAudioEngine, AudioInputDevice?) throws -> Void
    /// `AVAudioSinkNode` existe para capturar sem caminho de saída. Com ele as
    /// amostras vêm pelo bloco de render, não por `installTap`, e o engine não
    /// precisa abrir o dispositivo de saída — que é o que empurra o fone para
    /// HFP.
    var usaSink = false
}

/// Caminho de hoje: `AudioUnitSetProperty` no audioUnit do inputNode.
private func porAudioUnit(_ engine: AVAudioEngine, _ dispositivo: AudioInputDevice?) throws {
    guard let dispositivo, let unit = engine.inputNode.audioUnit else { return }
    var id = dispositivo.id
    let status = AudioUnitSetProperty(
        unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
        &id, UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard status == noErr else { throw CaptureError.osStatus("AudioUnitSetProperty", status) }
}

/// API alta do AVAudioUnit. Diferente da de baixo, ela **lanca** quando o
/// dispositivo e recusado, em vez de aceitar calada e continuar no anterior.
private func porDeviceID(_ engine: AVAudioEngine, _ dispositivo: AudioInputDevice?) throws {
    guard let dispositivo else { return }
    try engine.inputNode.auAudioUnit.setDeviceID(dispositivo.id)
}

/// Liga a entrada ao mixer com volume zero.
///
/// Hipotese: sem ninguem puxando o grafo, o AVAudioEngine nao roda a entrada e
/// o tap instalado nunca dispara. Volume zero para nao devolver a propria voz
/// no alto-falante.
private func ligarNoMixer(_ engine: AVAudioEngine, formatoExplicito: Bool = true) {
    engine.mainMixerNode.outputVolume = 0
    engine.connect(
        engine.inputNode, to: engine.mainMixerNode,
        format: formatoExplicito ? engine.inputNode.outputFormat(forBus: 0) : nil
    )
}

func runMicVariantTest() -> Never {
    let reportPath = "/tmp/tradutor-microfone-variantes.txt"
    var lines: [String] = []
    func report(_ text: String) {
        lines.append(text)
        try? lines.joined(separator: "\n").write(
            toFile: reportPath, atomically: true, encoding: .utf8
        )
    }

    report("variantes de microfone  \(Date().formatted(date: .abbreviated, time: .standard))")

    guard pedirMicrofoneParaVariantes() else {
        report("FALHA: acesso ao microfone negado.")
        showResult(title: "Microfone negado", body: "Privacidade e Segurança › Microfone.",
                   ok: false, filePath: reportPath)
    }

    let entradas = AudioInputList.all()
    let interno = entradas.first { $0.name.contains("MacBook") }
    report("entradas: \(entradas.map(\.name).joined(separator: ", "))")
    report("padrão: \(AudioInputList.systemDefault?.name ?? "?")")
    report("interno: \(interno?.name ?? "não achei")")
    report("")

    let variantes: [Variante] = [
        Variante(nome: "A  padrão, só installTap (é o MicrophoneTap de hoje)",
                 montar: { _, _ in }),
        Variante(nome: "B  interno por AudioUnitSetProperty (é o seletor de hoje)",
                 montar: porAudioUnit),
        Variante(nome: "C  interno por auAudioUnit.setDeviceID",
                 montar: porDeviceID),
        Variante(nome: "D  padrão + entrada ligada ao mixer",
                 montar: { engine, _ in ligarNoMixer(engine) }),
        Variante(nome: "E  interno por setDeviceID + mixer (formato explícito)",
                 montar: { engine, dispositivo in
                     try porDeviceID(engine, dispositivo)
                     ligarNoMixer(engine)
                 }),
        Variante(nome: "F  interno por setDeviceID + mixer (formato nil)",
                 montar: { engine, dispositivo in
                     try porDeviceID(engine, dispositivo)
                     ligarNoMixer(engine, formatoExplicito: false)
                 }),
        Variante(nome: "G  interno por AudioUnitSetProperty + mixer (formato nil)",
                 montar: { engine, dispositivo in
                     try porAudioUnit(engine, dispositivo)
                     ligarNoMixer(engine, formatoExplicito: false)
                 }),
        Variante(nome: "H  padrão + AVAudioSinkNode", montar: { _, _ in }, usaSink: true),
        Variante(nome: "I  interno por setDeviceID + AVAudioSinkNode",
                 montar: porDeviceID, usaSink: true),
    ]

    for variante in variantes {
        let usaInterno = variante.nome.contains("interno")
        if usaInterno, interno == nil {
            report("\(variante.nome)\n  pulada: não há microfone interno")
            continue
        }

        let engine = AVAudioEngine()
        let anel = RingBuffer()
        var erro: String?
        var taxa: Double = 0

        var sink: AVAudioSinkNode?
        do {
            try variante.montar(engine, usaInterno ? interno : nil)
            let formato = engine.inputNode.outputFormat(forBus: 0)
            taxa = formato.sampleRate
            guard formato.sampleRate > 0, formato.channelCount > 0 else {
                throw CaptureError.unsupportedFormat(
                    "entrada sem formato (\(formato.sampleRate) Hz, \(formato.channelCount) canais)"
                )
            }
            if variante.usaSink {
                let node = AVAudioSinkNode { _, quadros, dados in
                    let lista = UnsafeMutableAudioBufferListPointer(
                        UnsafeMutablePointer(mutating: dados)
                    )
                    guard let primeiro = lista.first, let cru = primeiro.mData else { return noErr }
                    anel.write(UnsafeBufferPointer(
                        start: cru.assumingMemoryBound(to: Float.self), count: Int(quadros)
                    ))
                    return noErr
                }
                engine.attach(node)
                engine.connect(engine.inputNode, to: node, format: formato)
                sink = node
            } else {
                engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: formato) { buffer, _ in
                    guard let canais = buffer.floatChannelData, buffer.frameLength > 0 else { return }
                    anel.write(UnsafeBufferPointer(start: canais[0], count: Int(buffer.frameLength)))
                }
            }
            try engine.start()
        } catch {
            erro = error.localizedDescription
        }

        var coletado: [Float] = []
        var primeiraMs = -1
        if erro == nil {
            var scratch = [Float](repeating: 0, count: 48_000)
            let inicio = Date()
            while Date().timeIntervalSince(inicio) < 3 {
                Thread.sleep(forTimeInterval: 0.05)
                let lido = anel.read(into: &scratch, maximum: scratch.count)
                if lido > 0 {
                    if primeiraMs < 0 {
                        primeiraMs = Int(Date().timeIntervalSince(inicio) * 1000)
                    }
                    coletado.append(contentsOf: scratch[0..<lido])
                }
            }
            if sink == nil { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }

        report(variante.nome)
        if let erro {
            report("  ERRO: \(erro)")
            continue
        }
        var energia: Float = 0
        var pico: Float = 0
        for amostra in coletado {
            energia += amostra * amostra
            pico = Swift.max(pico, Swift.abs(amostra))
        }
        let rms = coletado.isEmpty ? 0 : (energia / Float(coletado.count)).squareRoot()
        report(String(
            format: "  %5d Hz  %6d amostras em 3 s  1ª em %@  pico %.5f  rms %.5f  %@",
            Int(taxa), coletado.count,
            primeiraMs < 0 ? "nunca" : "\(primeiraMs) ms",
            pico, rms,
            coletado.isEmpty ? "ZERO" : "ok"
        ))
    }

    // AVCaptureSession escolhe o dispositivo pelo objeto, não por property do
    // audio unit — e é onde a escolha do usuário pode finalmente valer.
    for (rotulo, alvo) in [("J  AVCaptureSession, dispositivo padrão", nil as String?),
                           ("K  AVCaptureSession, interno", "MacBook")] {
        report(rotulo)
        let encontrados = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
        let escolhido: AVCaptureDevice? = alvo == nil
            ? AVCaptureDevice.default(for: .audio)
            : encontrados.first { $0.localizedName.contains(alvo!) }
        guard let escolhido else {
            report("  pulada: não achei o dispositivo (\(encontrados.map(\.localizedName).joined(separator: ", ")))")
            continue
        }

        let anel = RingBuffer()
        let coletor = CapturaAudio(anel: anel)
        let sessao = AVCaptureSession()
        do {
            let entrada = try AVCaptureDeviceInput(device: escolhido)
            guard sessao.canAddInput(entrada) else {
                throw CaptureError.unsupportedFormat("sessão recusou \(escolhido.localizedName)")
            }
            sessao.addInput(entrada)
            let saida = AVCaptureAudioDataOutput()
            saida.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
            ]
            saida.setSampleBufferDelegate(coletor, queue: DispatchQueue(label: "captura"))
            guard sessao.canAddOutput(saida) else {
                throw CaptureError.unsupportedFormat("sessão recusou a saída de áudio")
            }
            sessao.addOutput(saida)
            sessao.startRunning()
        } catch {
            report("  ERRO: \(error.localizedDescription)")
            continue
        }

        var coletado: [Float] = []
        var primeiraMs = -1
        var scratch = [Float](repeating: 0, count: 48_000)
        let inicio = Date()
        while Date().timeIntervalSince(inicio) < 3 {
            Thread.sleep(forTimeInterval: 0.05)
            let lido = anel.read(into: &scratch, maximum: scratch.count)
            if lido > 0 {
                if primeiraMs < 0 { primeiraMs = Int(Date().timeIntervalSince(inicio) * 1000) }
                coletado.append(contentsOf: scratch[0..<lido])
            }
        }
        sessao.stopRunning()

        var energia: Float = 0
        var pico: Float = 0
        for amostra in coletado {
            energia += amostra * amostra
            pico = Swift.max(pico, Swift.abs(amostra))
        }
        let rms = coletado.isEmpty ? 0 : (energia / Float(coletado.count)).squareRoot()
        report(String(
            format: "  %@  %5d Hz  %6d amostras em 3 s  1ª em %@  pico %.5f  rms %.5f  %@",
            escolhido.localizedName, Int(coletor.taxa), coletado.count,
            primeiraMs < 0 ? "nunca" : "\(primeiraMs) ms",
            pico, rms, coletado.isEmpty ? "ZERO" : "ok"
        ))
    }

    report("")
    report("A variante que entregar áudio é a que o MicrophoneTap passa a usar.")
    showResult(title: "Variantes de microfone medidas",
               body: "Relatório em \(reportPath)", ok: true, filePath: reportPath)
}

private func pedirMicrofoneParaVariantes() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined:
        var concedido = false
        var respondeu = false
        AVCaptureDevice.requestAccess(for: .audio) { permitido in
            concedido = permitido
            respondeu = true
        }
        let limite = Date().addingTimeInterval(60)
        while !respondeu, Date() < limite {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return concedido
    default: return false
    }
}


/// Recebe os buffers da `AVCaptureSession` e despeja no anel.
private final class CapturaAudio: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let anel: RingBuffer
    var taxa: Double = 0

    init(anel: RingBuffer) { self.anel = anel }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if taxa == 0, let formato = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formato) {
            taxa = asbd.pointee.mSampleRate
        }
        var lista = AudioBufferList()
        var bloco: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &lista,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &bloco
        )
        guard status == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(&lista)
        guard let primeiro = buffers.first, let dados = primeiro.mData else { return }
        let quantas = Int(primeiro.mDataByteSize) / MemoryLayout<Float>.size
        guard quantas > 0 else { return }
        anel.write(UnsafeBufferPointer(
            start: dados.assumingMemoryBound(to: Float.self), count: quantas
        ))
    }
}
