import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Um dispositivo de entrada que o Core Audio conhece.
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let name: String

    public init(id: AudioDeviceID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum AudioInputList {

    /// Microfones e entradas de linha, na ordem em que o sistema os devolve.
    ///
    /// O filtro é ter stream de entrada: um alto-falante também é um
    /// `AudioDevice`, e listá-lo daria um microfone que nunca capta nada.
    public static func all() -> [AudioInputDevice] {
        let devices: [AudioObjectID] = (try? audioPropertyArray(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDevices
        )) ?? []

        return devices.compactMap { device in
            let streams: [AudioObjectID] = (try? audioPropertyArray(
                device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput
            )) ?? []
            guard !streams.isEmpty else { return nil }

            guard let name = (try? audioProperty(device, kAudioObjectPropertyName) as CFString)
                .map({ $0 as String }), !name.isEmpty
            else { return nil }

            // O nosso próprio aggregate device do tap aparece aqui enquanto a
            // captura de aplicativo está ligada. Oferecê-lo como microfone
            // seria capturar a si mesmo.
            guard !name.hasPrefix("Tradutor") else { return nil }

            return AudioInputDevice(id: device, name: name)
        }
    }

    /// O que o usuário escolheu nas Preferências do Sistema.
    public static var systemDefault: AudioInputDevice? {
        guard let id = try? audioProperty(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultInputDevice
        ) as AudioDeviceID else { return nil }
        return all().first { $0.id == id }
    }
}

/// Captura do microfone, com a mesma forma do `ProcessTap`.
///
/// `AVAudioEngine` e não o HAL cru de propósito: entrada é o caso que o
/// framework do sistema resolve bem, e o `ProcessTap` só existe em CoreAudio
/// puro porque não há API alta para tap de processo. Copiar aquele arquivo
/// para a entrada seria trezentas linhas para o que aqui são trinta.
public final class MicrophoneTap {

    private let log = Logger(subsystem: "app.tradutor", category: "MicrophoneTap")
    private let engine = AVAudioEngine()
    /// O tap do AVAudioEngine roda em tempo real. Um buffer fixo evita que o
    /// callback realoque um Array enquanto o hardware ainda escreve nele.
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
    private var running = false

    /// `nil` significa o dispositivo padrão do sistema — que é o padrão daqui
    /// também, e o que continua valendo quando o usuário troca de fone no meio
    /// da reunião.
    public let device: AudioInputDevice?

    /// Taxa real da entrada. Preenchida por `start`, como no `ProcessTap`.
    public private(set) var sampleRate: Double?

    public init(device: AudioInputDevice? = nil) {
        self.device = device
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    /// Pergunta ao sistema. Negada, a captura entrega silêncio sem erro —
    /// o mesmo modo de falhar da permissão de gravação de tela.
    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// - Parameter onSamples: amostras mono na taxa nativa da entrada, em
    ///   contexto de áudio: copie e saia.
    public func start(onSamples: @escaping (UnsafeBufferPointer<Float>) -> Void) throws {
        precondition(!running, "MicrophoneTap ja iniciado")

        let input = engine.inputNode
        // Tem de ser ANTES de ler o formato: trocar o dispositivo troca a taxa
        // de amostragem, e um tap instalado com o formato do dispositivo
        // anterior é rejeitado pelo AVAudioEngine em tempo de execução.
        if let device, let unit = input.audioUnit {
            var id = device.id
            try check(
                "AudioUnitSetProperty(CurrentDevice)",
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            )
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.unsupportedFormat(
                "entrada sem formato (taxa \(format.sampleRate), \(format.channelCount) canais)"
            )
        }
        sampleRate = format.sampleRate

        let scratch = self.scratch
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let count = Int(buffer.format.channelCount)
            guard frames > 0, count > 0, frames <= 8192 else { return }

            // Em mono nao ha nada para misturar. Entregar o ponteiro do
            // proprio AVAudioPCMBuffer evita uma copia no caso normal; o
            // consumidor copia sincronicamente para o RingBuffer.
            if count == 1, buffer.stride == 1 {
                onSamples(UnsafeBufferPointer(start: channels[0], count: frames))
                return
            }

            // Downmix para mono. `stride` e 1 no formato deintercalado e o
            // numero de canais no intercalado; ignorá-lo lia canais errados.
            let stride = buffer.stride
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<count {
                    sum += channels[channel][frame * stride]
                }
                scratch[frame] = sum / Float(count)
            }
            onSamples(UnsafeBufferPointer(start: scratch, count: frames))
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
        log.info("microfone ativo: \(self.device?.name ?? "padrão do sistema", privacy: .public)")
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}
