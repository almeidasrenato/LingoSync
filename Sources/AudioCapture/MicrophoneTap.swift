import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Um dispositivo de entrada que o Core Audio conhece.
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let name: String
    /// UID do Core Audio. É por ele que a `AVCaptureSession` encontra o mesmo
    /// dispositivo: `AVCaptureDevice.uniqueID` de áudio é exatamente este
    /// texto. Sem ele a escolha teria que casar por nome, que repete.
    public let uid: String

    public init(id: AudioDeviceID, name: String, uid: String = "") {
        self.id = id
        self.name = name
        self.uid = uid
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

            let uid = (try? audioProperty(device, kAudioDevicePropertyDeviceUID) as CFString)
                .map { $0 as String } ?? ""
            return AudioInputDevice(id: device, name: name, uid: uid)
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

    /// O microfone embutido do Mac, quando existe.
    ///
    /// É o padrão da janela de prática: o padrão do sistema costuma ser um
    /// fone Bluetooth, e abrir o microfone dele derruba o perfil do aparelho
    /// para HFP — 16 kHz na entrada E na saída, o que estraga junto a captura
    /// do aplicativo. Ver `ProcessTap.currentSampleRate`.
    public static var builtIn: AudioInputDevice? {
        let entradas = all()
        return entradas.first { $0.uid.contains("BuiltIn") }
            ?? entradas.first { $0.name.contains("MacBook") || $0.name.contains("Built-in") }
    }
}

/// Captura do microfone, com a mesma forma do `ProcessTap`.
///
/// `AVCaptureSession`, e não `AVAudioEngine`. Medido em 19/09/2026 com o gate
/// `tradutor-probe variantes`, 3 s por variante, duas rodadas:
///
/// ```
/// installTap sozinho (o que estava aqui)            0 amostras
/// installTap + dispositivo por AudioUnitSetProperty  0 amostras
/// installTap + dispositivo por setDeviceID           0 amostras
/// entrada ligada ao mixer                            0 / 45056  (não repete)
/// AVAudioSinkNode                                48000 amostras, padrão só
/// AVCaptureSession, padrão                       48000 amostras
/// AVCaptureSession, escolhendo o interno        143872 amostras, 48 kHz
/// ```
///
/// Duas coisas que só a última faz. **Entrega áudio de forma repetível**: com
/// `installTap` o bloco simplesmente nunca era chamado, sem erro nenhum — o
/// mesmo modo de falhar silencioso da permissão negada, e foi assim que o
/// `--selftest-microfone` do app vinha devolvendo `amostras: 0`. E **respeita
/// a escolha do dispositivo**: pelos três caminhos do `AVAudioEngine` o
/// formato continuava em 16 kHz (o do fone) mesmo pedindo o microfone interno,
/// prova de que o pedido era ignorado calado; aqui o interno chega em 48 kHz.
///
/// `audioSettings` pede mono Float32, então não há downmix na mão.
public final class MicrophoneTap {

    private let log = Logger(subsystem: "app.tradutor", category: "MicrophoneTap")
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.tradutor.microfone")
    private var receiver: SampleReceiver?
    private var running = false

    /// `nil` significa o dispositivo padrão do sistema — o que continua valendo
    /// quando o usuário troca de fone no meio da reunião, porque o padrão
    /// acompanha e um ID gravado não.
    public let device: AudioInputDevice?

    /// Taxa real da entrada. Sai do formato ativo do dispositivo ao iniciar e
    /// é corrigida pelo primeiro buffer, que é quem sabe de verdade.
    public var sampleRate: Double? { receiver?.sampleRate ?? declaredRate }
    private var declaredRate: Double?

    public init(device: AudioInputDevice? = nil) {
        self.device = device
    }

    deinit { stop() }

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

        guard let capture = resolveDevice() else {
            throw CaptureError.unsupportedFormat(
                "não achei a entrada \(device?.name ?? "padrão do sistema")"
            )
        }

        let input = try AVCaptureDeviceInput(device: capture)
        guard session.canAddInput(input) else {
            throw CaptureError.unsupportedFormat("a sessão recusou \(capture.localizedName)")
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // Mono Float32 na origem: sem isto viria estéreo intercalado e o
        // downmix voltaria para cá.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ]
        let receiver = SampleReceiver(onSamples: onSamples)
        output.setSampleBufferDelegate(receiver, queue: queue)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CaptureError.unsupportedFormat("a sessão recusou a saída de áudio")
        }
        session.addOutput(output)
        self.receiver = receiver

        declaredRate = CMAudioFormatDescriptionGetStreamBasicDescription(
            capture.activeFormat.formatDescription
        )?.pointee.mSampleRate

        session.startRunning()
        running = true
        log.info("microfone ativo: \(capture.localizedName, privacy: .public)")
    }

    public func stop() {
        guard running else { return }
        session.stopRunning()
        for output in session.outputs { session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
        receiver = nil
        running = false
    }

    /// Casa a escolha do Core Audio com o objeto da `AVCaptureSession`.
    ///
    /// Pelo UID primeiro: `AVCaptureDevice.uniqueID` de áudio é o UID do Core
    /// Audio. O nome é a rede de segurança, e repete entre aparelhos iguais.
    private func resolveDevice() -> AVCaptureDevice? {
        guard let device else { return AVCaptureDevice.default(for: .audio) }
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
        return found.first { $0.uniqueID == device.uid && !device.uid.isEmpty }
            ?? found.first { $0.localizedName == device.name }
            ?? AVCaptureDevice.default(for: .audio)
    }
}

/// Recebe os buffers da sessão e repassa as amostras.
private final class SampleReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let onSamples: (UnsafeBufferPointer<Float>) -> Void
    /// Escrita na fila da captura, lida pelo consumidor. `Double` de 64 bits
    /// não rasga em leitura, e um valor velho por um buffer não muda nada.
    private(set) var sampleRate: Double?

    init(onSamples: @escaping (UnsafeBufferPointer<Float>) -> Void) {
        self.onSamples = onSamples
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
           asbd.pointee.mSampleRate != sampleRate {
            // A taxa muda em serviço quando o aparelho troca de perfil
            // (Bluetooth entrando em HFP). Quem reamostra precisa saber.
            sampleRate = asbd.pointee.mSampleRate
        }

        var list = AudioBufferList()
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(&list)
        guard let first = buffers.first, let raw = first.mData else { return }
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        onSamples(UnsafeBufferPointer(
            start: raw.assumingMemoryBound(to: Float.self), count: count
        ))
    }
}
