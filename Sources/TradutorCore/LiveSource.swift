import AudioCapture
import Foundation
import OSLog

/// Uma fonte de áudio ao vivo virando frases prontas.
///
/// Existe porque a janela de prática ouve **dois** lados ao mesmo tempo — o
/// aplicativo do professor e o microfone do aluno — e o caminho de áudio até a
/// frase é o mesmo dos dois. Copiar o laço do `Pipeline` para lá é o erro que
/// este projeto já pagou duas vezes (`SubtitleStudioModel` e `SubtitleJob`
/// tinham cada um a sua cópia da geração, e o usuário via legenda diferente
/// saindo de cada um, até virarem `SubtitleFileBuilder.generate`).
///
/// O que fica de fora daqui é o que **não** é por fonte: fila de tradução,
/// histórico e tela. Isso continua com quem usa.
///
/// `pump()` é uma volta do laço, chamada por quem manda. Com duas fontes na
/// mesma janela, chamar uma depois da outra no mesmo laço já serializa o
/// reconhecedor compartilhado — nenhuma trava a mais.
@MainActor
public final class LiveSource {

    /// De onde vem o som.
    public enum Origin {
        case process(AudioProcess)
        case microphone(AudioInputDevice?)
    }

    private let log = Logger(subsystem: "app.tradutor", category: "LiveSource")

    /// O reconhecedor é **emprestado**, não criado aqui: duas fontes do mesmo
    /// idioma compartilham um modelo. Dois Whisper residentes seriam 2,4 GB
    /// para transcrever a mesma língua.
    private let transcriber: Transcriber
    private let onPartial: (String) -> Void
    private let onPhrase: (String) -> Void

    /// Com que frequência o trecho em andamento é re-reconhecido. Quem chama
    /// decide, porque depende do motor: o Whisper é bem mais lento.
    private let rehearsalInterval: TimeInterval

    private var tap: ProcessTap?
    private var microphone: MicrophoneTap?
    private var ring: RingBuffer?
    private var resampler: Resampler?
    private var segmenter: Segmenter?

    private var tracker = StablePrefixTracker()
    private var phrases = PhraseAccumulator()
    private var rehearsing = false
    private var lastRehearsal = Date.distantPast
    private var scratch = [Float](repeating: 0, count: 48_000)

    /// Há voz agora nesta fonte. É o que acende o losango do professor e o que
    /// impede o turno do aluno de abrir por eco.
    public var isSpeaking: Bool { segmenter?.isSpeaking ?? false }

    /// Pausado, o anel continua sendo esvaziado e o que sai é jogado fora.
    /// Deixar de ler encheria o anel e, ao retomar, os primeiros segundos
    /// seriam áudio de minutos atrás.
    public var isPaused = false

    /// Quanto o reconhecimento da última passada custou.
    public private(set) var lastTranscribeMs = 0

    public init(
        transcriber: Transcriber,
        rehearsalInterval: TimeInterval,
        onPartial: @escaping (String) -> Void,
        onPhrase: @escaping (String) -> Void
    ) {
        self.transcriber = transcriber
        self.rehearsalInterval = rehearsalInterval
        self.onPartial = onPartial
        self.onPhrase = onPhrase
    }

    public func start(_ origin: Origin) throws {
        let ring = RingBuffer()
        let rate: Double

        switch origin {
        case let .process(process):
            let tap = ProcessTap(process: process)
            try tap.start { samples in ring.write(samples) }
            rate = tap.currentSampleRate ?? tap.format?.mSampleRate ?? 48_000
            self.tap = tap
        case let .microphone(device):
            let mic = MicrophoneTap(device: device)
            try mic.start { samples in ring.write(samples) }
            rate = mic.sampleRate ?? 48_000
            self.microphone = mic
        }

        do {
            resampler = try Resampler(inputSampleRate: rate)
        } catch {
            stop()
            throw error
        }

        self.ring = ring
        segmenter = Segmenter()
        tracker.reset()
        _ = phrases.flush()
        lastRehearsal = .distantPast
        isPaused = false
    }

    public func stop() {
        tap?.stop()
        tap = nil
        microphone?.stop()
        microphone = nil
        ring = nil
        resampler = nil
        segmenter = nil
        tracker.reset()
        _ = phrases.flush()
        isPaused = false
    }

    /// Descarta o trecho em andamento sem soltar a captura.
    public func discardInFlight() {
        _ = segmenter?.flush()
        tracker.reset()
        _ = phrases.flush()
        onPartial("")
    }

    /// Uma volta do laço: lê o anel, fecha o que o silêncio fechou e ensaia o
    /// trecho em andamento quando é hora.
    public func pump() async {
        refreshResamplerIfRateChanged()
        guard let ring, let resampler, let segmenter else { return }

        let count = ring.read(into: &scratch, maximum: scratch.count)
        if isPaused {
            lastRehearsal = Date()
            return
        }
        if count > 0, let converted = try? resampler.resample(Array(scratch[0..<count])) {
            // Uma pausa real é o único corte de áudio que continua existindo:
            // ali não há palavra sendo partida.
            for segment in segmenter.feed(converted) {
                await finishUtterance(segment.samples)
            }
        }

        guard segmenter.isSpeaking, !rehearsing,
              Date().timeIntervalSince(lastRehearsal) > rehearsalInterval
        else { return }
        lastRehearsal = Date()
        let inFlight = segmenter.inFlight
        if inFlight.count > 8_000 {  // meio segundo de fala
            await rehearse(inFlight)
        }
    }

    /// A fonte trocou de taxa em serviço? Refaz o conversor.
    ///
    /// Abrir o microfone de um fone Bluetooth joga o aparelho em HFP e a
    /// captura cai de 48 kHz para 16 kHz — a do microfone E a do aplicativo,
    /// porque o tap segue o dispositivo. Reamostrar com a razão velha não dá
    /// erro: dá um terço das amostras e a fala três vezes mais rápida.
    private func refreshResamplerIfRateChanged() {
        guard let resampler else { return }
        guard let rate = tap?.currentSampleRate ?? microphone?.sampleRate, rate > 0 else { return }
        guard abs(rate - resampler.inputSampleRate) > 1 else { return }
        guard let fresh = try? Resampler(inputSampleRate: rate) else { return }
        log.info("a fonte trocou de \(resampler.inputSampleRate) para \(rate) Hz")
        self.resampler = fresh
    }

    /// Uma passada de reconhecimento sobre o trecho em andamento.
    private func rehearse(_ samples: [Float]) async {
        rehearsing = true
        defer { rehearsing = false }

        let started = Date()
        guard let hypothesis = try? await transcriber.transcribe(samples),
              !hypothesis.isEmpty
        else { return }
        lastTranscribeMs = Int(Date().timeIntervalSince(started) * 1000)

        let newlyConfirmed = tracker.feed(hypothesis)
        onPartial(Tokens.join(tracker.pending))

        guard !newlyConfirmed.isEmpty else { return }
        for phrase in phrases.append(newlyConfirmed) { onPhrase(phrase) }
    }

    /// A fala terminou de verdade: o que sobrou não vai mudar mais.
    private func finishUtterance(_ samples: [Float]) async {
        // Uma última passada sobre o trecho completo, que agora inclui o
        // silêncio final e costuma sair melhor que as intermediárias.
        var remaining: [String]
        if let hypothesis = try? await transcriber.transcribe(samples), !hypothesis.isEmpty {
            remaining = tracker.reconcile(hypothesis)
        } else {
            remaining = tracker.flush()
        }
        var closed = phrases.append(remaining)
        if let leftover = phrases.flush() { closed.append(leftover) }

        tracker.reset()
        onPartial("")
        for phrase in closed { onPhrase(phrase) }
    }
}
