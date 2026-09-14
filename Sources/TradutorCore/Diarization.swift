import FluidAudio
import Foundation
import OSLog

/// Quem fala em cada trecho.
///
/// Outro modelo, não recurso do reconhecedor: o FluidAudio roda sobre o mesmo
/// áudio de 16 kHz e devolve faixas com identificador de locutor. Serve a
/// qualquer reconhecedor que marque tempo. Só em vídeo — o agrupamento precisa
/// do áudio inteiro para saber que a voz do minuto 8 é a do minuto 1.
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
    /// O `DiarizerManager` multiplica por 1,2 e usa como distância cosseno
    /// máxima até um locutor conhecido — **mais alto junta mais**.
    /// `numClusters` **não** serve para dizer quantas vozes esperar: fixá-lo
    /// em 2 numa conversa de duas pessoas devolveu os mesmos três locutores,
    /// porque este caminho só olha o limiar. Valor de `tradutor-verify
    /// vozes`; ver o CLAUDE.md antes de mexer.
    public static var clusteringThreshold: Float = 0.7

    /// Fala mínima para uma faixa existir.
    ///
    /// O padrão de 1 s descarta a troca curta. Medido no vídeo de 9 minutos:
    ///
    ///     1,0s (padrão): 2 vozes,  87 faixas, 133 s de fala
    ///     0,5s:          3 vozes, 176 faixas, 202 s
    ///     0,3s:          3 vozes, 215 faixas, 217 s
    ///
    /// A terceira voz de 0,5 s tem 1 segundo no total — resto, não pessoa, e
    /// `pruneTinyVoices` a descarta. 0,3 s acrescenta pouco e multiplica faixa
    /// de 300 ms, que não vira legenda.
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
        config.chunkOverlap = chunkOverlap
        // Sonda de medição, para refazer a varredura sem recompilar.
        if let valor = ProcessInfo.processInfo.environment["TRADUTOR_CLUSTER_OVERLAP"],
           let numero = Float(valor) { config.chunkOverlap = numero }
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

    /// Junta os identificadores que são a mesma voz.
    ///
    /// O Sortformer parte uma pessoa em mais de um identificador — quatro num
    /// diálogo de duas —, o que dá travessão onde ninguém trocou de turno e
    /// cor nova no meio da conversa. Quem diz se dois rótulos são a mesma
    /// pessoa é o **embedding de voz**, outro modelo (o mesmo do caminho de
    /// agrupamento, 13 MB), aplicado uma vez por identificador.
    public static func mergeSameVoice(
        _ turns: [Turn], in samples: [Float], threshold: Float = sameVoiceThreshold
    ) async throws -> [Turn] {
        let labels = Array(Set(turns.map(\.speaker)))
        guard labels.count > 1 else { return turns }

        let models = try await DiarizerModels.downloadIfNeeded(to: directory)
        let manager = DiarizerManager(config: .default)
        manager.initialize(models: models)

        // Embedding de trecho curto é ruído: o modelo precisa de voz para
        // caracterizar voz. Quem não junta o mínimo fica de fora da fusão e
        // segue com o rótulo que tinha.
        var embeddings: [String: [Float]] = [:]
        for label in labels {
            let owned = turns.filter { $0.speaker == label }
                .sorted { ($0.end - $0.start) > ($1.end - $1.start) }
            var audio: [Float] = []
            for turn in owned where audio.count < Int(sampleSeconds * 16_000) {
                let from = max(0, Int(turn.start * 16_000))
                let to = min(samples.count, Int(turn.end * 16_000))
                if to > from { audio.append(contentsOf: samples[from..<to]) }
            }
            guard audio.count >= Int(minimumVoiceForEmbedding * 16_000) else { continue }
            if let embedding = try? manager.extractSpeakerEmbedding(from: audio),
               manager.validateEmbedding(embedding) {
                embeddings[label] = embedding
            }
        }
        guard embeddings.count > 1 else { return turns }

        // Quem falou primeiro dá o nome ao grupo, para a saída não depender da
        // ordem em que o dicionário foi percorrido.
        let firstHeard = Dictionary(
            turns.map { ($0.speaker, $0.start) }, uniquingKeysWith: min)
        let groupOf = groupSameVoice(embeddings, firstHeard: firstHeard, threshold: threshold)
        let merged = Set(groupOf.filter { $0.key != $0.value }.keys)
        guard !merged.isEmpty else { return turns }
        log.info("fusão de vozes: \(labels.count, privacy: .public) identificadores viraram \(Set(groupOf.values).count, privacy: .public)")
        return turns.map {
            Turn(speaker: groupOf[$0.speaker] ?? $0.speaker, start: $0.start, end: $0.end)
        }
    }

    /// Qual identificador representa cada um, dado o quanto as vozes se
    /// parecem. Separado de `mergeSameVoice` para poder ser verificado sem
    /// carregar modelo nenhum — ver `tradutor-verify locutores`.
    ///
    /// Encadeamento simples: se A se parece com B e B com C, os três ficam
    /// juntos mesmo que A e C estejam além do limiar. É o que se quer aqui,
    /// porque a mesma pessoa muda de tom ao longo de uma conversa e os
    /// pedaços dela chegam justamente como uma corrente.
    public static func groupSameVoice(
        _ embeddings: [String: [Float]], firstHeard: [String: TimeInterval], threshold: Float
    ) -> [String: String] {
        let ordered = embeddings.keys.sorted {
            (firstHeard[$0] ?? 0, $0) < (firstHeard[$1] ?? 0, $1)
        }
        var groupOf: [String: String] = [:]
        for (index, label) in ordered.enumerated() {
            var chosen = label
            for earlier in ordered[..<index] {
                guard let a = embeddings[label], let b = embeddings[earlier] else { continue }
                if cosineDistance(a, b) < threshold {
                    chosen = groupOf[earlier] ?? earlier
                    break
                }
            }
            groupOf[label] = chosen
        }
        return groupOf
    }

    /// Distância de cosseno entre dois embeddings já normalizados.
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            na += a[index] * a[index]
            nb += b[index] * b[index]
        }
        guard na > 0, nb > 0 else { return 2 }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Abaixo desta distância os dois identificadores são a mesma pessoa.
    ///
    /// Varrido de 0,35 a 0,65 nos quatro vídeos de exemplo. O único com
    /// verdade conhecida é a conversa de 9 minutos, que tem duas pessoas:
    ///
    ///     limiar   9 min (2 pessoas)   inglês longo
    ///     0,35            3                 3
    ///     0,45 a 0,60     2                 3
    ///     0,65            2                 2   ← funde o que não devia
    ///
    /// Meio da faixa que acerta, longe das duas bordas. Fundir demais é pior
    /// que fundir de menos: separado sobra uma cor, fundido some uma pessoa.
    public static var sameVoiceThreshold: Float = 0.50

    /// Quanto áudio por identificador vai para o embedding.
    static let sampleSeconds: Double = 12

    /// Menos que isto não caracteriza voz nenhuma.
    static let minimumVoiceForEmbedding: Double = 2

    /// Os instantes em que a voz troca, para quem monta trecho a partir de
    /// palavras não juntar duas pessoas. Ver `Transcriber.speakerBoundaries`.
    /// - Parameter shift: quanto adiantar cada fronteira. O modelo marca a
    ///   troca ~1 s **depois** dela, o bastante para a primeira palavra de
    ///   quem entrou ficar na legenda de quem saiu. Cruas, 12 de 43 legendas
    ///   juntavam duas pessoas; adiantando, 2 de 43. Duas suspeitas medidas e
    ///   descartadas: descartar fronteira de faixa curta e encaixá-la no vale
    ///   de energia mais próximo — resultado idêntico nas duas.
    public static func boundaries(
        of turns: [Turn], shift: TimeInterval = boundaryLead
    ) -> [TimeInterval] {
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
        guard shift != 0 else { return instantes.sorted() }
        return Set(instantes.map { max(0, $0 - shift) }).sorted()
    }

    /// Sobreposição entre os blocos de 10 s do agrupamento.
    ///
    /// Com o padrão zero, a mesma pessoa muda de rótulo entre blocos. Acerto
    /// de identidade contra os três gabaritos:
    ///
    ///     sobreposição        0 s    2 s    5 s
    ///     9 min, 2 pessoas    88%    91%    91%
    ///     japonês, 10 vozes   72%    78%    72%
    ///     inglês, 5 pessoas   61%    61%    57%
    ///
    /// 5 s piora o inglês e dobra o tempo. Vale só para quem escolhe o
    /// agrupamento; o padrão do app é o Sortformer.
    public static let chunkOverlap: Float = 2

    /// Quanto as fronteiras de voz são adiantadas, em segundos.
    ///
    /// Varrido contra os três gabaritos humanos, contando as legendas que
    /// juntam a fala de duas pessoas:
    ///
    ///     adiantamento      cruas  0,25  0,40  0,50  0,60  0,75
    ///     9 min, 2 pessoas      6     6     2     1     1     3
    ///     inglês, 5 pessoas    12     9     3     2     2     2
    ///     japonês, 10 pessoas   4     2     2     2     2     2
    ///
    /// 0,50 e 0,60 empatam e ganham nos três. Acima disso o vídeo de duas
    /// pessoas — o caso comum — volta a piorar.
    public static let boundaryLead: TimeInterval = 0.50

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
    /// dela — o reconhecedor corta na pontuação e a identificação na troca de
    /// voz, e os dois cortes não coincidem. Trecho sem faixa fica sem locutor,
    /// que é diferente de errar o locutor.
    ///
    /// Somar por voz, e não pegar a maior faixa isolada, resolve o trecho
    /// largo com ida e volta dentro: A em 0–3 s e 7–10 s soma 6 s e perdia
    /// para os 4 s de B. Trecho largo é o que a Apple produz.
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
