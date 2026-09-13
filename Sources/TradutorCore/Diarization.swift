import FluidAudio
import Foundation
import OSLog

/// Quem fala em cada trecho.
///
/// É outro modelo, não um recurso do reconhecedor: o `DiarizerManager` do
/// FluidAudio (segmentação + embedding de voz + agrupamento) roda sobre o
/// mesmo áudio de 16 kHz e devolve faixas de tempo com um identificador de
/// locutor. Por isso serve a qualquer reconhecedor que marque tempo — o que
/// hoje são todos.
///
/// Só nos modos de vídeo. Ao vivo não há como: o agrupamento precisa do áudio
/// inteiro para decidir que a voz do minuto 8 é a mesma do minuto 1.
public enum SpeakerDiarizer {

    private static let log = Logger(subsystem: "app.tradutor", category: "Locutores")

    /// Qual modelo identifica as vozes. Escolha do usuário.
    ///
    /// São desenhos diferentes, não versões: `.clustering` segmenta, extrai
    /// embedding de voz e agrupa em execução; `.sortformer` é um modelo só,
    /// ponta a ponta, que já devolve as faixas por locutor.
    public enum Model: String, CaseIterable, Identifiable, Sendable {
        case clustering
        case sortformer

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .clustering: "Agrupamento de vozes"
            case .sortformer: "Sortformer"
            }
        }
    }

    /// Onde os modelos ficam, junto dos outros e fora do backup.
    ///
    /// O FluidAudio trata isto como pasta-base e cria `speaker-diarization`
    /// dentro (13 MB) — diferente do `AsrModels`, que usa o caminho que
    /// recebe. Passar uma subpasta nossa deixava duas pastas, uma vazia.
    static var directory: URL { ModelStorage.root }

    public struct Turn: Sendable {
        public let speaker: String
        public let start: TimeInterval
        public let end: TimeInterval

        public init(speaker: String, start: TimeInterval, end: TimeInterval) {
            self.speaker = speaker
            self.start = start
            self.end = end
        }
    }

    /// Roda a identificação e devolve as faixas, em ordem.
    ///
    /// `progress` recebe a fração; a chamada é síncrona por dentro (o
    /// FluidAudio processa em blocos de 10 s), então vai para uma thread de
    /// fundo — segurar o executor cooperativo travaria a interface.
    /// Distância máxima entre duas vozes para serem a mesma pessoa.
    ///
    /// O `DiarizerManager` multiplica isto por 1,2 e usa como distância
    /// cosseno máxima até um locutor conhecido: acima dela, nasce um locutor
    /// novo. Ou seja, **mais alto junta mais**.
    ///
    /// `numClusters` da configuração parece ser a saída para dizer quantas
    /// vozes esperar, e não é: medido, fixá-lo em 2 numa conversa de duas
    /// pessoas devolveu os mesmos três locutores. Este caminho agrupa em
    /// execução pelo `SpeakerManager`, que só olha o limiar.
    ///
    /// O valor aqui saiu de `tradutor-verify vozes`; ver o comentário da
    /// varredura no CLAUDE.md antes de mexer.
    public static var clusteringThreshold: Float = 0.7

    /// Fala mínima para uma faixa existir.
    ///
    /// O padrão do FluidAudio é 1 s, e num diálogo rápido isso descarta a
    /// troca curta. Medido no vídeo de 9 minutos, com o limiar em 0,70:
    ///
    ///     1,0s (padrão): 2 vozes,  87 faixas, 133 s de fala
    ///     0,5s:          3 vozes, 176 faixas, 202 s   (+52%)
    ///     0,3s:          3 vozes, 215 faixas, 217 s   (+63%)
    ///
    /// A terceira voz que aparece em 0,5 s tem **1 segundo** no total — é
    /// resto, não pessoa, e `pruneTinyVoices` a descarta. Ficou em 0,5 s: o
    /// 0,3 s acrescenta pouco e multiplica faixa de 300 ms, que não chega a
    /// virar legenda.
    public static var minimumSpeech: Float = 0.5

    /// Voz com menos que isto no total é resto de agrupamento, não pessoa.
    ///
    /// Sem este corte, baixar a fala mínima trazia uma terceira voz de 1 s
    /// numa conversa de duas pessoas — e um rótulo errado é pior que nenhum,
    /// porque o leitor acredita nele.
    public static var minimumVoiceTime: TimeInterval = 2.0

    public static func turns(
        in samples: [Float],
        model: Model = .clustering,
        threshold: Float? = nil,
        minimumSpeech: Float? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [Turn] {
        switch model {
        case .sortformer:
            return try await sortformerTurns(in: samples, progress: progress)
        case .clustering:
            return try await clusteringTurns(
                in: samples, threshold: threshold, minimumSpeech: minimumSpeech, progress: progress
            )
        }
    }

    /// Segmentação + embedding de voz + agrupamento em execução.
    private static func clusteringTurns(
        in samples: [Float],
        threshold: Float?,
        minimumSpeech: Float?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [Turn] {
        let models = try await DiarizerModels.downloadIfNeeded(to: directory)
        var config = DiarizerConfig.default
        config.clusteringThreshold = threshold ?? clusteringThreshold
        config.minSpeechDuration = minimumSpeech ?? Self.minimumSpeech
        let manager = DiarizerManager(config: config)
        manager.initialize(models: models)

        let result: DiarizationResult = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(
                        returning: try manager.performCompleteDiarization(
                            samples, sampleRate: 16_000, progressHandler: { progress($0) }
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        let turns = pruneTinyVoices(
            result.segments
                .map {
                    Turn(
                        speaker: $0.speakerId,
                        start: TimeInterval($0.startTimeSeconds),
                        end: TimeInterval($0.endTimeSeconds)
                    )
                }
                .sorted { $0.start < $1.start }
        )
        log.info("locutores: \(Set(turns.map(\.speaker)).count, privacy: .public) em \(turns.count, privacy: .public) faixas")
        return turns
    }

    /// Sortformer: um modelo só, ponta a ponta.
    ///
    /// Não tem limiar de agrupamento nem fala mínima — as faixas saem do
    /// próprio modelo, que decide quantas vozes há dentro do teto de quatro
    /// que a exportação CoreML traz. Por isso os dois ajustes do outro
    /// caminho não se aplicam aqui.
    private static func sortformerTurns(
        in samples: [Float],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [Turn] {
        let diarizer = OfflineSortformerDiarizer()
        // Baixa para a pasta do app, nunca para a do FluidAudio.
        //
        // `initializeFromHuggingFace` não encaminha o diretório e cai no
        // `~/Library/Application Support/FluidAudio` — o comentário dizia uma
        // coisa e o modelo ia para outra, fora do alcance do `CacheCleanup` e
        // da conta de espaço em disco. Carregar e injetar os modelos é o
        // caminho que aceita a pasta.
        let models = try await OfflineSortformerModels.loadFromHuggingFace(
            cacheDirectory: directory,
            progressHandler: { fraction in
                progress(fraction.fractionCompleted * 0.5)
            }
        )
        diarizer.initialize(models: models)

        let timeline: DiarizerTimeline = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try diarizer.processComplete(samples))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        progress(1)

        let turns = pruneTinyVoices(
            timeline.speakers.values
                .flatMap { speaker in
                    speaker.finalizedSegments.map {
                        Turn(
                            speaker: "speaker_\($0.speakerIndex)",
                            start: TimeInterval($0.startTime),
                            end: TimeInterval($0.endTime)
                        )
                    }
                }
                .sorted { $0.start < $1.start }
        )
        log.info("sortformer: \(Set(turns.map(\.speaker)).count, privacy: .public) vozes em \(turns.count, privacy: .public) faixas")
        return turns
    }

    /// Os instantes em que a voz troca, para quem monta trecho a partir de
    /// palavras não juntar duas pessoas. Ver `Transcriber.speakerBoundaries`.
    public static func boundaries(of turns: [Turn]) -> [TimeInterval] {
        var instantes: Set<TimeInterval> = []
        for (index, turn) in turns.enumerated() {
            // Só onde há troca de verdade: duas faixas seguidas da mesma
            // pessoa não são fronteira.
            if index == 0 || turns[index - 1].speaker != turn.speaker {
                instantes.insert(turn.start)
            }
            if index + 1 == turns.count || turns[index + 1].speaker != turn.speaker {
                instantes.insert(turn.end)
            }
        }
        return instantes.sorted()
    }

    /// Tira as vozes que somam quase nada.
    ///
    /// O trecho delas fica **sem** locutor, não com o locutor do vizinho:
    /// chutar quem fala é o erro que o leitor não tem como notar.
    public static func pruneTinyVoices(_ turns: [Turn]) -> [Turn] {
        var total: [String: TimeInterval] = [:]
        for turn in turns { total[turn.speaker, default: 0] += turn.end - turn.start }
        let restos = total.filter { $0.value < minimumVoiceTime }.keys
        guard !restos.isEmpty, restos.count < total.count else { return turns }
        return turns.filter { !restos.contains($0.speaker) }
    }

    /// Marca cada trecho reconhecido com quem estava falando.
    ///
    /// Critério: a **voz** que mais se sobrepõe ao trecho, somando as faixas
    /// dela. Sobreposição parcial é a regra, não a exceção — o reconhecedor
    /// corta na pontuação e a identificação corta na troca de voz, e os dois
    /// cortes não coincidem.
    /// Trecho sem faixa nenhuma fica sem locutor, que é diferente de errar o
    /// locutor.
    ///
    /// Somar por voz, e não escolher a maior faixa isolada, é o que resolve o
    /// trecho largo com ida e volta dentro: 0–3 s e 7–10 s da voz A contra
    /// 3–7 s da voz B são 6 s contra 4 s, e a faixa isolada mais longa é a de
    /// B. Trecho largo é justamente o que a Apple produz.
    public static func assign(_ pieces: [TimedText], to turns: [Turn]) -> [TimedText] {
        guard !turns.isEmpty else { return pieces }
        return pieces.map { piece in
            var totais: [String: TimeInterval] = [:]
            var best: (speaker: String, overlap: TimeInterval)?
            // As faixas vêm ordenadas, e o `>` mantém a primeira em caso de
            // empate: sem isso a escolha mudaria de execução para execução.
            for turn in turns {
                let overlap = min(piece.end, turn.end) - max(piece.start, turn.start)
                guard overlap > 0 else { continue }
                let soma = totais[turn.speaker, default: 0] + overlap
                totais[turn.speaker] = soma
                if soma > (best?.overlap ?? 0) { best = (turn.speaker, soma) }
            }
            guard let best else { return piece }
            return TimedText(
                text: piece.text, start: piece.start, end: piece.end, speaker: best.speaker
            )
        }
    }

    /// Números estáveis e legíveis no lugar dos identificadores do modelo.
    ///
    /// O FluidAudio devolve coisas como "speaker_3"; na tela isso não diz
    /// nada. A ordem é a de quem falou primeiro.
    public static func renumber(_ pieces: [TimedText]) -> [TimedText] {
        var names: [String: Int] = [:]
        for piece in pieces {
            guard let speaker = piece.speaker, names[speaker] == nil else { continue }
            names[speaker] = names.count + 1
        }
        guard !names.isEmpty else { return pieces }
        return pieces.map { piece in
            guard let speaker = piece.speaker, let number = names[speaker] else { return piece }
            return TimedText(
                text: piece.text, start: piece.start, end: piece.end,
                speaker: "Locutor \(number)"
            )
        }
    }
}
