import Foundation

/// Corta o fluxo continuo de fala em segmentos traduziveis.
///
/// A decisao de onde uma frase termina define o ritmo de leitura na tela
/// inteira, entao ela vive aqui e nao espalhada pelo pipeline. Limiar por
/// energia com piso de ruido adaptativo: resolve fala limpa sem dependencia
/// externa. Se falhar com trilha sonora ao fundo, e aqui que o Silero entra.
public final class Segmenter {

    public struct Configuration: Sendable {
        /// Silencio que fecha um segmento.
        public var silenceToClose: TimeInterval = 0.6
        /// Teto absoluto do trecho em andamento.
        ///
        /// Deixou de ser o que controla a latencia. Antes o texto so aparecia
        /// quando o segmento fechava, entao o teto era o tempo maximo de tela
        /// muda — e baixa-lo para 2,5 s melhorou a latencia as custas de partir
        /// palavras ao meio, porque fala corrida nem sempre tem um vale.
        ///
        /// Agora o texto sai por confirmacao de prefixo estavel, sem cortar
        /// audio, e este valor volta a ser so uma rede de seguranca contra
        /// alguem que fale doze segundos sem respirar.
        public var maximumDuration: TimeInterval = 12.0
        /// Fala minima para o segmento valer a pena.
        public var minimumDuration: TimeInterval = 0.4
        /// Audio guardado antes do inicio da fala, para nao cortar o ataque.
        public var preRoll: TimeInterval = 0.2
        /// Quanto o corte por teto pode recuar procurando um ponto quieto.
        ///
        /// Cortar exatamente no teto parte a palavra em curso, e nenhuma das
        /// metades e reconhecivel: o texto cru saia como "on Friday after."
        /// seguido de um segmento que era so pontuacao. Recuar ate o quadro de
        /// menor energia dos ultimos 0,6 s cai quase sempre entre palavras.
        ///
        /// O que sobra do recuo nao e duplicado: e transferido para o inicio do
        /// proximo segmento, entao nenhum audio se perde nem se repete.
        public var ceilingBackoff: TimeInterval = 0.6
        /// Quantas vezes acima do piso de ruido para ABRIR um trecho de fala.
        public var openMultiplier: Float = 3.5
        /// Quantas vezes acima do piso para CONTINUAR um trecho ja aberto.
        ///
        /// Histerese. Com um limiar so, a voz que baixa no fim da frase — ou
        /// quem fala baixo o tempo todo — cai abaixo dele e o trecho fecha no
        /// meio da fala; o resto some. Exigir menos para continuar do que para
        /// comecar e o que evita isso.
        public var continueMultiplier: Float = 1.5
        /// Quantos quadros seguidos de voz abrem um trecho.
        ///
        /// Tres quadros sao 60 ms: um clique isolado nao deve iniciar um
        /// segmento. Exigir quadros SEGUIDOS e o que derruba fala curta — um
        /// unico quadro abaixo do limiar no meio do ataque zera a contagem.
        public var framesToOpen: Int = 3

        /// Piso absoluto, para silencio digital nao virar fala.
        ///
        /// Era 0,006, alto demais: fala baixa fica abaixo disso e nunca abria
        /// trecho nenhum.
        public var absoluteFloor: Float = 0.0022

        public init() {}
    }

    public struct Segment: Sendable {
        public let samples: [Float]
        public let duration: TimeInterval
        /// true quando fechou por silencio, false quando bateu no teto de tempo.
        public let closedBySilence: Bool
    }

    /// 20 ms a 16 kHz. Publico porque e a unidade em que o corte por teto
    /// escolhe o ponto quieto, e os testes precisam medir nessa granularidade.
    public static let frameSize = 320
    private let sampleRate: Double = Resampler.targetSampleRate
    private let configuration: Configuration

    private var pending: [Float] = []
    private var segment: [Float] = []
    /// Energia de cada quadro ja acumulado em `segment`, para achar o ponto
    /// mais quieto na hora de cortar por teto.
    private var segmentEnergies: [Float] = []
    private var preRollBuffer: [Float] = []
    private var inSpeech = false
    private var silentFrames = 0
    private var speechFrames = 0
    private var noiseFloor: Float = 0.002

    private var framesToClose: Int { Int(configuration.silenceToClose * sampleRate) / Self.frameSize }
    private var backoffFrames: Int { Int(configuration.ceilingBackoff * sampleRate) / Self.frameSize }
    private var preRollSamples: Int { Int(configuration.preRoll * sampleRate) }
    private var maximumSamples: Int { Int(configuration.maximumDuration * sampleRate) }
    private var minimumSamples: Int { Int(configuration.minimumDuration * sampleRate) }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        pending.reserveCapacity(Self.frameSize * 4)
        segment.reserveCapacity(maximumSamples)
    }

    /// Audio ainda nao fechado. E o que alimenta a zona vermelha, que mostra
    /// o parcial sem esperar a traducao.
    public var inFlight: [Float] { segment }

    public var isSpeaking: Bool { inSpeech }

    /// O piso de ruído que o gate vem medindo. Quem for mexer no nível do
    /// áudio precisa dele para não levantar o ruído junto.
    public var noiseLevel: Float { noiseFloor }

    /// Alimenta o segmentador. Devolve os segmentos que fecharam nesta chamada.
    public func feed(_ samples: [Float]) -> [Segment] {
        pending.append(contentsOf: samples)
        var closed: [Segment] = []

        while pending.count >= Self.frameSize {
            let frame = Array(pending.prefix(Self.frameSize))
            pending.removeFirst(Self.frameSize)

            let energy = rms(frame)
            let openThreshold = max(
                noiseFloor * configuration.openMultiplier, configuration.absoluteFloor
            )
            let continueThreshold = max(
                noiseFloor * configuration.continueMultiplier, configuration.absoluteFloor * 0.6
            )
            // Ja falando, basta o limiar baixo para seguir falando.
            let isVoice = energy > (inSpeech ? continueThreshold : openThreshold)

            if energy <= openThreshold {
                // Piso de ruido sobe devagar e desce rapido: adapta a mudanca
                // de ambiente sem deixar um trecho alto travar o limiar no alto.
                noiseFloor = energy < noiseFloor
                    ? noiseFloor * 0.9 + energy * 0.1
                    : noiseFloor * 0.995 + energy * 0.005
            }

            if inSpeech {
                segment.append(contentsOf: frame)
                segmentEnergies.append(energy)
                silentFrames = isVoice ? 0 : silentFrames + 1

                if silentFrames >= framesToClose {
                    if let finished = close(bySilence: true) { closed.append(finished) }
                } else if segment.count >= maximumSamples {
                    let cut = quietestCutPoint()
                    let tail = Array(segment[cut...])
                    let tailEnergies = Array(segmentEnergies[(cut / Self.frameSize)...])
                    segment = Array(segment[0..<cut])

                    if let finished = close(bySilence: false) { closed.append(finished) }

                    // Sem silencio real, a fala continua: reabre com o que
                    // sobrou do recuo, que ainda nao foi entregue a ninguem.
                    inSpeech = true
                    silentFrames = 0
                    segment = tail
                    segmentEnergies = tailEnergies
                }
            } else {
                preRollBuffer.append(contentsOf: frame)
                if preRollBuffer.count > preRollSamples {
                    preRollBuffer.removeFirst(preRollBuffer.count - preRollSamples)
                }
                speechFrames = isVoice ? speechFrames + 1 : 0

                // Tres quadros seguidos (60 ms) para abrir: um clique isolado
                // nao deve iniciar um segmento.
                if speechFrames >= configuration.framesToOpen {
                    inSpeech = true
                    silentFrames = 0
                    speechFrames = 0
                    segment = preRollBuffer
                    // O pre-roll nao tem energias medidas; entra como quieto,
                    // que e o que ele e por definicao.
                    segmentEnergies = Array(
                        repeating: 0,
                        count: preRollBuffer.count / Self.frameSize
                    )
                    preRollBuffer.removeAll(keepingCapacity: true)
                }
            }
        }
        return closed
    }

    /// Fecha o que estiver aberto. Chamado ao parar a captura.
    public func flush() -> Segment? {
        guard inSpeech else { return nil }
        return close(bySilence: false)
    }

    /// Indice de amostra onde cortar: fim do quadro mais quieto dos ultimos
    /// `ceilingBackoff` segundos. Nunca corta antes da metade do segmento,
    /// para o recuo nao devorar a fala inteira.
    private func quietestCutPoint() -> Int {
        let totalFrames = segmentEnergies.count
        guard totalFrames > 2 else { return segment.count }

        let window = min(backoffFrames, totalFrames / 2)
        guard window > 0 else { return segment.count }

        let start = totalFrames - window
        var bestFrame = totalFrames - 1
        for index in start..<totalFrames where segmentEnergies[index] < segmentEnergies[bestFrame] {
            bestFrame = index
        }
        return min((bestFrame + 1) * Self.frameSize, segment.count)
    }

    private func close(bySilence: Bool) -> Segment? {
        defer {
            segment.removeAll(keepingCapacity: true)
            segmentEnergies.removeAll(keepingCapacity: true)
            inSpeech = false
            silentFrames = 0
        }
        guard segment.count >= minimumSamples else { return nil }
        return Segment(
            samples: segment,
            duration: Double(segment.count) / sampleRate,
            closedBySilence: bySilence
        )
    }

    private func rms(_ frame: [Float]) -> Float {
        var sum: Float = 0
        for sample in frame { sum += sample * sample }
        return (sum / Float(frame.count)).squareRoot()
    }
}
