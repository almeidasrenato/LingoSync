import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// Captura o audio de um unico processo via Core Audio process tap.
///
/// O tap e o aggregate device sobrevivem ao fim do processo que os criou. Se
/// nao forem destruidos, ficam pendurados no servidor de audio e o usuario
/// perde o som ate reiniciar. Por isso a limpeza aqui e idempotente e roda
/// tanto em `stop()` quanto em `deinit` quanto no handler de sinal do probe.
public final class ProcessTap {

    private let log = Logger(subsystem: "app.tradutor", category: "ProcessTap")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID: UUID?

    /// Formato real entregue pelo tap. Preenchido por `start`.
    ///
    /// **É uma foto do início, e a taxa muda em serviço.** Para reamostrar,
    /// use `currentSampleRate`.
    public private(set) var format: AudioStreamBasicDescription?

    /// A taxa que o tap está entregando AGORA, relida do Core Audio.
    ///
    /// Medido em 19/09/2026 (`tradutor-probe duplo`): abrir o microfone de um
    /// fone Bluetooth joga o aparelho em HFP e o tap passa de 48 kHz para
    /// 16 kHz. Com o formato lido só no início, o `Resampler` seguia decimando
    /// 3:1 um áudio que já vinha em 16 kHz — um terço das amostras e a fala
    /// três vezes mais rápida, sem erro nenhum. O tom de teste de 220 Hz saía
    /// a 676 Hz com 5 252 amostras/s contra 14 674 sozinho.
    public var currentSampleRate: Double? {
        aggregateSampleRate ?? tapFormatSampleRate ?? format?.mSampleRate
    }

    /// Taxa que o `kAudioTapPropertyFormat` declara agora.
    public var tapFormatSampleRate: Double? {
        guard tapID != kAudioObjectUnknown else { return nil }
        let atual: AudioStreamBasicDescription? = try? audioProperty(
            tapID, kAudioTapPropertyFormat
        )
        return atual?.mSampleRate
    }

    /// Taxa nominal do aggregate device que hospeda o tap.
    ///
    /// Existe porque o formato do tap **não** acompanha a troca de perfil do
    /// aparelho: medido em 19/09/2026, com o fone em HFP o tap continuava
    /// declarando 48 kHz enquanto entregava 16 kHz.
    public var aggregateSampleRate: Double? {
        guard aggregateID != kAudioObjectUnknown else { return nil }
        return try? audioProperty(aggregateID, kAudioDevicePropertyNominalSampleRate)
    }

    public let process: AudioProcess

    public init(process: AudioProcess) {
        self.process = process
    }

    deinit { teardown() }

    /// Liga a captura. O bloco recebe amostras mono, na taxa nativa do tap
    /// (48 kHz na pratica), e roda em contexto de tempo real: copie e saia.
    public func start(onSamples: @escaping (UnsafeBufferPointer<Float>) -> Void) throws {
        precondition(tapID == kAudioObjectUnknown, "ProcessTap ja iniciado")

        // 1. O tap sobre o processo escolhido.
        let uuid = UUID()
        tapUUID = uuid
        let description: CATapDescription
        if process.isSystemWide {
            // Tap global sem exclusao nenhuma.
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        } else {
            // Todos os processos do aplicativo de uma vez. Passar so o
            // principal e o que fazia o Chrome capturar silencio: o audio dele
            // vive no helper de renderizacao.
            guard !process.objectIDs.isEmpty else {
                throw CaptureError.processNotFound(process.pid)
            }
            description = CATapDescription(stereoMixdownOfProcesses: process.objectIDs)
        }
        description.uuid = uuid
        description.name = "Tradutor-\(process.pid)"
        description.muteBehavior = .unmuted  // o usuario continua ouvindo o app
        description.isPrivate = true
        // `exclusive` decide se a lista de processos e de inclusao ou de
        // exclusao. O inicializador ja acerta isso, mas deixar explicito
        // evita o erro que estava aqui: o valor era fixado em `false` sempre,
        // o que transformava o tap global (lista de exclusao VAZIA = capture
        // tudo) em um tap inclusivo de lista vazia — ou seja, capture nada.
        description.isExclusive = process.isSystemWide

        try check(
            "AudioHardwareCreateProcessTap",
            AudioHardwareCreateProcessTap(description, &tapID)
        )
        guard tapID != kAudioObjectUnknown else {
            throw CaptureError.osStatus("AudioHardwareCreateProcessTap", -1)
        }

        let streamFormat: AudioStreamBasicDescription = try audioProperty(
            tapID, kAudioTapPropertyFormat
        )
        format = streamFormat

        guard streamFormat.mFormatID == kAudioFormatLinearPCM,
              streamFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              streamFormat.mBitsPerChannel == 32
        else {
            teardown()
            throw CaptureError.unsupportedFormat(
                "esperado Float32 PCM, veio formatID=\(streamFormat.mFormatID) bits=\(streamFormat.mBitsPerChannel)"
            )
        }

        let channels = Int(streamFormat.mChannelsPerFrame)
        let interleaved = streamFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        // 2. O tap so produz som dentro de um aggregate device.
        let aggregateUID = UUID().uuidString
        let mainDeviceUID = try defaultOutputDeviceUID()

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tradutor Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: mainDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // A lista de sub-dispositivos precisa conter o device real. Com
            // ela vazia o aggregate ate roda no clock certo e o IOProc dispara
            // na cadencia esperada, mas o stream do tap nao aparece na entrada
            // e o que chega e silencio digital.
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: mainDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        try check(
            "AudioHardwareCreateAggregateDevice",
            AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        )

        // 3. Ler as amostras. Downmix para mono acontece aqui porque e barato
        //    e reduz pela metade o que atravessa o ring buffer.
        var scratch = [Float](repeating: 0, count: 8192)

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            _, inInputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )
            if ProcessInfo.processInfo.environment["TAP_DEBUG"] != nil {
                let summary = buffers.enumerated().map {
                    "buf\($0.offset): ch=\($0.element.mNumberChannels) bytes=\($0.element.mDataByteSize)"
                }.joined(separator: "  ")
                FileHandle.standardError.write(Data("[tap] \(buffers.count) buffers  \(summary)\n".utf8))
            }
            guard let first = buffers.first, first.mDataByteSize > 0 else { return }

            if interleaved {
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                guard frames > 0, let raw = first.mData else { return }
                let src = raw.assumingMemoryBound(to: Float.self)
                if scratch.count < frames { scratch = [Float](repeating: 0, count: frames * 2) }
                scratch.withUnsafeMutableBufferPointer { dst in
                    for frame in 0..<frames {
                        var sum: Float = 0
                        for channel in 0..<channels {
                            sum += src[frame * channels + channel]
                        }
                        dst[frame] = sum / Float(channels)
                    }
                    onSamples(UnsafeBufferPointer(rebasing: dst[0..<frames]))
                }
            } else {
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                guard frames > 0 else { return }
                if scratch.count < frames { scratch = [Float](repeating: 0, count: frames * 2) }
                scratch.withUnsafeMutableBufferPointer { dst in
                    for frame in 0..<frames { dst[frame] = 0 }
                    var used = 0
                    for buffer in buffers {
                        guard let raw = buffer.mData else { continue }
                        let src = raw.assumingMemoryBound(to: Float.self)
                        for frame in 0..<frames { dst[frame] += src[frame] }
                        used += 1
                    }
                    if used > 1 {
                        let scale = 1 / Float(used)
                        for frame in 0..<frames { dst[frame] *= scale }
                    }
                    onSamples(UnsafeBufferPointer(rebasing: dst[0..<frames]))
                }
            }
        }

        guard status == noErr, ioProcID != nil else {
            teardown()
            throw CaptureError.osStatus("AudioDeviceCreateIOProcIDWithBlock", status)
        }

        try check("AudioDeviceStart", AudioDeviceStart(aggregateID, ioProcID))
        log.info(
            """
            tap ativo em \(self.process.name, privacy: .public)             (\(self.process.objectIDs.count) processo(s): \(self.process.pids.map(String.init).joined(separator: ", "), privacy: .public))
            """
        )
    }

    public func stop() { teardown() }

    /// Idempotente de proposito: chamada por stop, deinit e handler de sinal.
    private func teardown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func defaultOutputDeviceUID() throws -> String {
        let deviceID: AudioObjectID = try audioProperty(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice
        )
        let uid: CFString = try audioProperty(deviceID, kAudioDevicePropertyDeviceUID)
        return uid as String
    }
}
