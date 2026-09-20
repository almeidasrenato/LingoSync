import AVFoundation
import Foundation
import OSLog

/// Uma legenda pronta: texto, tempo de entrada e de saída.
public struct Cue: Sendable {
    public var index: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var source: String
    public var translated: String
    /// Quem fala, quando a identificação de locutor rodou.
    public var speaker: String?

    public init(
        index: Int,
        start: TimeInterval,
        end: TimeInterval,
        source: String,
        translated: String = "",
        speaker: String? = nil
    ) {
        self.index = index
        self.start = start
        self.end = end
        self.source = source
        self.translated = translated
        self.speaker = speaker
    }
}

/// As etapas de gerar legenda de um arquivo.
///
/// A janela de legendas e o item de menu mostram as mesmas, cada um do seu
/// jeito.
public enum GenerationStep: String, CaseIterable, Sendable {
    case extracting = "Extraindo o áudio"
    case loadingASR = "Carregando o reconhecedor"
    case diarizing = "Identificando quem fala"
    case transcribing = "Reconhecendo a fala"
    case loadingTranslator = "Carregando o tradutor"
    case translating = "Traduzindo"
    case saving = "Gravando o arquivo"

    /// Quanto do total cada passo costuma ocupar, medido na prática.
    public var share: ClosedRange<Double> {
        switch self {
        case .extracting: 0.00...0.04
        case .loadingASR: 0.04...0.12
        // Quem fala vem ANTES de reconhecer: as fronteiras de voz entram no
        // reconhecimento para ele não juntar duas pessoas num trecho só.
        case .diarizing: 0.12...0.18
        case .transcribing: 0.18...0.48
        case .loadingTranslator: 0.48...0.52
        case .translating: 0.52...0.97
        case .saving: 0.97...1.00
        }
    }

    /// Progresso total, dado o progresso dentro deste passo.
    public func overall(_ within: Double) -> Double {
        share.lowerBound + (share.upperBound - share.lowerBound) * within
    }
}

/// Gera arquivo `.srt` a partir de um vídeo ou áudio.
///
/// Difere do caminho ao vivo em dois pontos, e os dois vêm de não haver pressa:
/// o áudio inteiro é reconhecido de uma vez, com marcação de tempo, em vez de
/// por confirmação de prefixo; e a tradução vai em blocos grandes, porque o
/// framework da Apple usa contexto dentro de uma mesma requisição — mandar
/// dez legendas juntas dá a ele o diálogo, não frases soltas.
public final class SubtitleFileBuilder {

    public struct Progress: Sendable {
        public let fraction: Double
        public let label: String
        /// Verdadeiro enquanto uma requisição está no ar.
        ///
        /// O tradutor do sistema devolve o lote inteiro de uma vez — não há
        /// retorno por legenda. Então entre o envio e a resposta não existe
        /// progresso nenhum para relatar, e a barra parada parecia
        /// travamento. Com isto a interface pode dizer que está esperando em
        /// vez de fingir que anda.
        public let waiting: Bool

        public init(fraction: Double, label: String, waiting: Bool = false) {
            self.fraction = fraction
            self.label = label
            self.waiting = waiting
        }
    }

    /// Até onde um trecho cresce **antes** de ser traduzido.
    ///
    /// Era 64 (o tamanho de uma legenda) e cortava orações ao meio antes de o
    /// tradutor vê-las. Hoje o corte segue a frase e é a tradução que
    /// `enforceLineLimit` reparte depois.
    public var maximumCharacters = 150
    /// Largura da linha da legenda pronta.
    ///
    /// 42 é a convenção latina. `translate` a troca pela do idioma de
    /// **destino** — ver `lineWidth(for:)` —, porque é lá que o destino é
    /// conhecido.
    public var charactersPerLine = 42

    /// Quantos caracteres cabem numa linha, pelo idioma de destino.
    ///
    /// Japonês e chinês escrevem largura cheia e cabem em 16 a 20 por linha.
    /// Com os 42 latinos, medido en → ja em 161 s: 18 das 49 linhas passavam
    /// de 20, a maior com 42. Coreano fica de fora (usa espaço, como em
    /// `Tokens.isDense`); tailandês não foi medido.
    public static func lineWidth(for target: Language) -> Int {
        switch target {
        case .japanese, .chinese: 20
        default: 42
        }
    }
    public var maximumLines = 2

    /// Quanto a legenda entra antes da fala.
    ///
    /// O reconhecedor marca o início entre 0,15 s e 0,8 s tarde, e antecipar
    /// é prática corrente de legendagem: o olho precisa achar o texto antes
    /// de a voz chegar.
    public var leadIn: TimeInterval = 0.25
    public var minimumDuration: TimeInterval = 1.0
    public var maximumDuration: TimeInterval = 7.0
    /// Tamanho de lote quando o tradutor não opina. Cada motor sobrescreve
    /// isso em `preferredBatchSize`, porque o número certo depende de onde
    /// está o custo — ida e volta ou token gerado.
    public var translationBatch = 10

    /// Quantas legendas do lote anterior são reenviadas junto com o novo.
    ///
    /// **Zero, medido.** `tradutor-verify sobreposicao` planta o caso que a
    /// justificava e reenviar 10 muda 0 das 5 na borda, com o gênero errado
    /// dos dois lados: o framework da Apple não resolve gênero por contexto,
    /// nem a dez linhas nem a uma. E custava 17% do tempo, porque o custo do
    /// tradutor é **por string** (ver `batchSizeGate`). Fica como campo para
    /// quem medir com outro tradutor.
    public var contextOverlap = 0

    /// Silêncios medidos no áudio, usados como fronteira de legenda.
    ///
    /// O trecho pode fechar na pausa e os dois pedaços saírem **contíguos**
    /// (o silêncio ficou dentro do run da Apple); aí `makeCues` não vê pausa
    /// e junta de volta, desfazendo o corte. Foi assim que duas falas viravam
    /// `お疲れ様あれさんお疲れ様です。` e a tradução colapsava as duas.
    public var silences: [ClosedRange<TimeInterval>] = []

    /// Aviso do tradutor sobre a geração que acabou de rodar, ou `nil`.
    ///
    /// Quem chama lê depois de `generate` e mostra ao usuário: é como a troca
    /// silenciosa do DeepL para a Apple deixa de ser silenciosa.
    public private(set) var translationNotice: String?

    /// Quantos lotes a tradução perdeu na última passada. Acima de zero, a
    /// geração falha em vez de entregar legenda pela metade.
    public private(set) var failedBatches = 0

    /// As legendas como saíram do reconhecimento, antes de traduzir.
    ///
    /// Entre o rascunho e `translate` não há mais nada no caminho, então
    /// retraduzir daqui dá o que outra geração daria — e com o **mesmo corte
    /// e os mesmos locutores**, que uma geração nova não repete.
    public private(set) var draft: [Cue] = []

    /// O motor que de fato reconheceu, não o que foi escolhido.
    ///
    /// `TranscriberKind` manda o Parakeet para o Whisper em idioma que ele não
    /// cobre. Quem lê a legenda tem direito de saber o que rodou.
    public private(set) var recognitionName: String?

    /// Quem de fato traduziu.
    public private(set) var translationName: String?

    /// O tradutor da última tradução, vivo até alguém encerrá-lo.
    ///
    /// Não é detalhe: o do DeepL carrega uma janela e o do Hunyuan um servidor
    /// Python de 4,5 GB. Cada geração criava outro e não encerrava o anterior,
    /// e isso ficava vivo até o app fechar — um app de barra de menus, que
    /// fica aberto o dia todo.
    private var translator: (any Translator)?

    /// Qual modelo identifica quem fala, quando `diarize` está ligado.
    public var speakerModel: SpeakerDiarizer.Model = .sortformer

    private let log = Logger(subsystem: "app.tradutor", category: "SubtitleFile")

    public init(draft: [Cue] = []) {
        self.draft = draft
    }

    // MARK: - Passo a passo

    /// Extrai o áudio de um arquivo de mídia em 16 kHz mono.
    ///
    /// Aceita arquivo sem extensão: o AVFoundation escolhe o demuxer pela
    /// extensão, então o arquivo é reapresentado por um link temporário
    /// `.mp4`. Se o conteúdo não for um container que o sistema leia, o erro
    /// diz qual formato é e quais são aceitos.
    /// - Parameter language: o idioma que se espera ouvir, quando se sabe.
    ///   `tracks.first` pegava a faixa da frente e a legenda saía do áudio
    ///   errado, com timecode válido e nada reclamando. Sem faixa que declare
    ///   o idioma pedido, a primeira continua valendo.
    public static func extractAudio(
        from url: URL, preferring language: Language? = nil, processing: Bool = true
    ) async throws -> [Float] {
        // Distinguir "não consigo ler" de "formato não serve".
        //
        // Sem isto, um arquivo que o app não tem permissão de abrir produzia
        // "formato não reconhecido" — que manda o usuário converter um arquivo
        // que está perfeito. O caso comum é a permissão de Arquivos e Pastas:
        // o app lê o que veio pelo seletor, não um caminho qualquer.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SubtitleFileError.notFound(url.lastPathComponent)
        }
        guard FileManager.default.isReadableFile(atPath: url.path),
              let probe = try? FileHandle(forReadingFrom: url)
        else {
            throw SubtitleFileError.unreadable(url.lastPathComponent)
        }
        try? probe.close()

        let detected = MediaProbe.sniff(url)

        // 1. Do jeito que veio.
        if let samples = try? await decode(url, preferring: language, processing: processing) { return samples }

        // 2. Reapresentado como mp4, para o caso de o nome ser o problema.
        if let aliased = try? mp4Alias(for: url) {
            // A pasta inteira, não só o link: apagar só o link deixava uma
            // pasta vazia por vídeo — havia 88 acumuladas.
            defer { try? FileManager.default.removeItem(at: aliased.deletingLastPathComponent()) }
            if let samples = try? await decode(aliased, preferring: language, processing: processing) { return samples }
        }

        // 3. Não é falta de nome: o formato não serve mesmo.
        throw SubtitleFileError.unsupportedFormat(
            file: url.lastPathComponent,
            detected: detected
        )
    }

    /// Devolve uma URL que o `AVPlayer` consegue tocar.
    ///
    /// O player escolhe o demuxer pela extensão, igual ao leitor de áudio. Um
    /// mp4 chamado só `gravacao` abre para extração (que já tenta o apelido)
    /// mas não toca: a janela ficava preta. Aqui o apelido é devolvido para
    /// quem chamou manter vivo enquanto o vídeo estiver aberto.
    ///
    /// Devolve `nil` quando o arquivo já toca do jeito que está.
    public static func playableAlias(for url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        if let playable = try? await asset.load(.isPlayable), playable {
            let tracks = try? await asset.loadTracks(withMediaType: .audio)
            if tracks?.isEmpty == false { return nil }
        }
        return try? mp4Alias(for: url)
    }

    /// Link temporário com extensão `.mp4` apontando para o arquivo original.
    private static func mp4Alias(for url: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradutor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let alias = directory.appendingPathComponent("midia.mp4")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        return alias
    }

    private static func decode(_ url: URL, preferring language: Language?, processing: Bool) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = await pickTrack(tracks, preferring: language) else {
            throw SubtitleFileError.noAudioTrack(url.lastPathComponent)
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
            ]
        )
        guard reader.canAdd(output) else {
            throw SubtitleFileError.cannotDecode(url.lastPathComponent)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw SubtitleFileError.cannotDecode(url.lastPathComponent)
        }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer
            ) == kCMBlockBufferNoErr, let pointer else { continue }

            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { floats in
                samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: length / 4))
            }
            CMSampleBufferInvalidate(buffer)
        }

        if reader.status == .failed {
            throw SubtitleFileError.cannotDecode(
                reader.error?.localizedDescription ?? url.lastPathComponent
            )
        }
        guard !samples.isEmpty else {
            throw SubtitleFileError.noAudioTrack(url.lastPathComponent)
        }
        return processing ? prepareAudio(samples) : samples
    }

    /// A medição guarda o PCM original como régua e aplica ao reconhecimento
    /// exatamente o mesmo tratamento do app, sem mudar variáveis de ambiente.
    public static func prepareAudio(_ samples: [Float]) -> [Float] {
        levelQuietSpeech(boostQuietAudio(samples))
    }

    /// A faixa que fala o idioma pedido, ou a primeira.
    ///
    /// Os dois campos que o container traz dizem a mesma coisa em formatos
    /// diferentes — `languageCode` em ISO 639-2 ("jpn"), `extendedLanguageTag`
    /// em BCP-47 ("ja-JP"). Normalizar os dois por `Locale.Language` evita a
    /// tabela de conversão que ninguém mantém, e trata "und" (não declarado)
    /// como o que ele é: nenhuma correspondência.
    static func pickTrack(
        _ tracks: [AVAssetTrack], preferring language: Language?
    ) async -> AVAssetTrack? {
        guard let language, tracks.count > 1 else { return tracks.first }
        let wanted = Locale.Language(identifier: language.rawValue).languageCode
        for track in tracks {
            let tags = [
                try? await track.load(.extendedLanguageTag),
                try? await track.load(.languageCode),
            ].compactMap { $0 }
            if tags.contains(where: { Locale.Language(identifier: $0).languageCode == wanted }) {
                return track
            }
        }
        return tracks.first
    }

    /// Recupera nível apenas em arquivos muito baixos, antes do ASR e das vozes.
    ///
    /// Medido em 13/09/2026: ganho genérico até RMS 0,03 piorou o Whisper
    /// com atenuação de 20 dB. Com 40 dB de atenuação, o ganho recuperou texto
    /// e aproximou os dois diarizadores da saída no nível original. Por isso
    /// só entra abaixo de RMS 0,003; áudio normal/moderado passa intacto.
    /// Não é AGC ao vivo nem redução de ruído: mede o arquivo inteiro uma vez.
    public static func boostQuietAudio(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var energy = 0.0
        var peak: Float = 0
        for sample in samples {
            guard sample.isFinite else { return samples }
            energy += Double(sample) * Double(sample)
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(energy / Double(samples.count))
        // Silêncio digital e resíduos quase inaudíveis não ganham volume.
        guard rms > 0.00001, rms < 0.003 else { return samples }
        let gain = min(Float(20), Float(0.03 / rms), 0.95 / peak)
        guard gain > 1 else { return samples }
        return samples.map { $0 * gain }
    }


    /// Iguala o nível ao longo do arquivo, para a fala baixa não sumir ao
    /// lado da alta.
    ///
    /// Medido atenuando **só metade das janelas de 20 s**, que é como fala
    /// baixa aparece de verdade — alguém baixo no meio de quem fala alto:
    ///
    ///     vídeo com música, −30 dB alternado   Whisper  355 → 716 caracteres
    ///     vídeo de 9 min,   −30 dB alternado   Whisper 3571 → 4484
    ///     vídeo com música, −30 dB alternado   Apple    603 → 717
    ///
    /// Baixar o arquivo INTEIRO não perde nada (o modelo normaliza a janela
    /// que decodifica), e é por isso que `boostQuietAudio`, que mede o
    /// arquivo todo, não enxerga este caso. Os dois rodam nesta ordem.
    ///
    /// Só amplifica: comprimir a fala alta mudaria o que já estava bom, e
    /// amplificar silêncio é o que faz o Whisper preencher a pausa com frase
    /// de cortesia.
    public static func levelQuietSpeech(_ samples: [Float]) -> [Float] {
        // Para refazer a medição de cima sem recompilar.
        guard ProcessInfo.processInfo.environment["TRADUTOR_SEM_NIVELAMENTO"] == nil else {
            return samples
        }
        guard samples.count > levelingWindow * 4 else { return samples }

        // Dois tamanhos, cada um para uma pergunta. O quadro de 20 ms diz
        // onde está o fundo: entre duas sílabas a voz cessa, e é essa pausa
        // curta que revela o ruído de sala mesmo num arquivo que nunca fica
        // em silêncio. A janela de 0,5 s diz o nível da fala ali.
        //
        // Estimar o fundo pela janela de 0,5 s foi tentado e falha no caso
        // que importa: quando metade do arquivo é fala baixa, o percentil
        // baixo cai dentro dessa metade e ela vira "ruído" — ganho 1, nada
        // recuperado. O gate de `tempos` tem exatamente esse caso.
        let frame = 320                        // 20 ms
        var frames: [Float] = []
        frames.reserveCapacity(samples.count / frame + 1)
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / levelingWindow + 1)
        var cursor = 0
        while cursor < samples.count {
            let end = min(cursor + levelingWindow, samples.count)
            var energy = 0.0
            var inner = cursor
            while inner < end {
                let stop = min(inner + frame, end)
                var chunk = 0.0
                for index in inner..<stop {
                    let value = Double(samples[index])
                    guard value.isFinite else { return samples }
                    chunk += value * value
                }
                frames.append(Float((chunk / Double(stop - inner)).squareRoot()))
                energy += chunk
                inner = stop
            }
            levels.append(Float((energy / Double(end - cursor)).squareRoot()))
            cursor = end
        }

        // Onde está o fundo deste arquivo, e onde está a fala.
        //
        // Piso ABSOLUTO não serve, e isso foi medido: com 0,0005 fixo, o
        // ruído de sala de um dos vídeos foi amplificado 20× e o detector de
        // energia passou a ver fala onde não havia — 196 trechos de fala
        // contra 186 no mesmo arquivo sem nivelar, e 402 s de "voz" contra
        // 357 s. Ruído amplificado é pior que fala baixa: ele vira alucinação
        // com timecode.
        //
        // O critério é o mesmo do `Segmenter` do tempo real: fala é o que
        // está bem acima do fundo do próprio material. O fundo é o percentil
        // 10 dos quadros de 20 ms; o alvo, o percentil 75 das janelas que
        // passaram do fundo.
        let quiet = frames.sorted()
        let noise = quiet[Int(Double(quiet.count) * 0.10)]
        let speechFloor = max(levelingFloor, noise * levelingNoiseMultiplier)
        let alive = levels.filter { $0 > speechFloor }.sorted()
        guard alive.count > 3 else { return samples }
        let target = alive[Int(Double(alive.count) * 0.75)]

        let gains = levels.map { level -> Float in
            guard level > speechFloor else { return 1 }
            return min(levelingCeiling, max(1, target / level))
        }
        guard gains.contains(where: { $0 > 1.05 }) else { return samples }

        var output = samples
        for (slot, gain) in gains.enumerated() {
            let start = slot * levelingWindow
            let end = min(start + levelingWindow, samples.count)
            guard start < end else { break }
            // O ganho caminha até o da janela seguinte em vez de saltar: um
            // degrau de ganho no meio de uma palavra é um clique, e clique é
            // exatamente o que o detector de voz confunde com ataque de fala.
            let next = gains[min(slot + 1, gains.count - 1)]
            let span = Float(end - start)
            for index in start..<end {
                let mix = gain + (next - gain) * (Float(index - start) / span)
                output[index] = max(-0.99, min(0.99, samples[index] * mix))
            }
        }
        return output
    }

    /// Meio segundo a 16 kHz: curto o bastante para acompanhar a troca de
    /// quem fala, longo o bastante para não seguir a sílaba.
    public static let levelingWindow = 8_000

    /// Teto do ganho, 26 dB. Acima disso o que sobe é ruído de sala.
    public static let levelingCeiling: Float = 20

    /// Abaixo daqui a janela é silêncio digital, e não ganha nada em
    /// hipótese nenhuma.
    public static let levelingFloor: Float = 0.0005

    /// Quantas vezes acima do fundo do arquivo uma janela precisa estar para
    /// contar como fala. Três, o mesmo patamar que o `Segmenter` usa para
    /// abrir um trecho no tempo real.
    public static let levelingNoiseMultiplier: Float = 3

    /// Junta palavras ou trechos marcados em legendas de tamanho legível,
    /// preferindo cortar na pontuação.
    /// - Parameter mediaDuration: duração do vídeo, quando conhecida. Legenda
    ///   que começa depois do fim nunca aparece, e legenda que passa do fim
    ///   fica pendurada no último quadro.
    public func makeCues(from timed: [TimedText], mediaDuration: TimeInterval? = nil) -> [Cue] {
        // Em ordem cronológica antes de qualquer coisa: os blocos que o
        // reconhecedor corta se sobrepõem nas bordas e os trechos não saem
        // ordenados. Sem isto, a entrada antecipada mede o recuo contra a
        // legenda errada.
        let ordered = timed.sorted { $0.start < $1.start }

        var cues: [Cue] = []
        var buffer: [TimedText] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            // Junta pela regra da escrita, não com espaço fixo.
            //
            // Dois trechos japoneses viravam "よかったです。 頑張ろうね。" — com
            // um espaço no meio que não existe em japonês. Eram 6 no vídeo de
            // 9 minutos, e esse texto é o que vai para o tradutor e para o
            // `.srt` quando se pede o original junto. `Tokens.join` só põe
            // espaço quando os dois lados são de escrita que usa espaço, então
            // inglês e português continuam idênticos.
            let text = Tokens.join(buffer.map(\.text))
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard SentenceSplitter.hasContent(text) else { buffer.removeAll(); return }

            // A entrada antecipada nunca invade a legenda anterior nem passa
            // do começo do arquivo.
            let floor = cues.last.map { $0.end } ?? 0
            let spokenEnd = buffer.map(\.end).max()!
            var start = max(floor, buffer.first!.start - leadIn)
            // A antecipação pode ceder espaço; o fim de uma fala que cabe
            // no teto não pode ser cortado por causa dela.
            if spokenEnd - buffer.first!.start <= maximumDuration {
                start = max(start, spokenEnd - maximumDuration)
            }
            // Nunca menos que o mínimo na tela, mesmo para uma palavra solta.
            let end = max(spokenEnd, start + minimumDuration)
            cues.append(Cue(
                index: cues.count + 1, start: start, end: end, source: text,
                speaker: buffer.first?.speaker
            ))
            buffer.removeAll()
        }

        for piece in ordered {
            // Uma pausa longa entre trechos é fronteira natural de legenda.
            if let last = buffer.last, piece.start - last.end > 0.8 { flush() }
            // E o silêncio medido no áudio também, mesmo com os trechos
            // colados: o reconhecedor corta onde a palavra cruza a fronteira,
            // não onde o silêncio está, então o que casa é o intervalo.
            if let last = buffer.last,
               silences.contains(where: { $0.contains(last.end) || $0.contains(piece.start) }) {
                flush()
            }
            // Troca de locutor também é: duas pessoas na mesma legenda é o
            // que fazia a leitura embaralhar quando há diálogo rápido.
            if let last = buffer.last, last.speaker != piece.speaker { flush() }

            // Fecha antes de acrescentar o trecho que faria ultrapassar o
            // teto; limitar depois cortaria o fim da fala já agrupada.
            if let first = buffer.first, piece.end - first.start > maximumDuration { flush() }

            buffer.append(piece)
            let text = Tokens.join(buffer.map(\.text))
            let span = (buffer.last?.end ?? 0) - (buffer.first?.start ?? 0)
            let endsSentence = piece.text.last
                .map { SentenceSplitter.sentenceEnders.contains($0) } ?? false

            if endsSentence || text.count >= maximumCharacters || span >= maximumDuration {
                flush()
            }
        }
        flush()

        return bridgeShortGaps(
            fixOverlaps(mergeTinyCues(fixOverlaps(clamp(cues, to: mediaDuration))))
        )
    }

    /// O caminho inteiro: do vídeo às legendas traduzidas, sem gravar nada.
    ///
    /// A janela de legendas e o item de menu tinham cada um sua cópia destes
    /// passos, e as cópias divergiam — o usuário via legenda melhor saindo de
    /// um do que do outro para o mesmo vídeo. Agora os dois chamam isto.
    ///
    /// - Parameters:
    ///   - progress: etapa, fração dentro dela e um detalhe legível. Chamado
    ///     de threads quaisquer.
    ///   - onBatch: cada lote traduzido, para mostrar antes do fim.
    /// - Throws: `CancellationError` quando a tarefa é cancelada entre etapas.
    public func generate(
        from url: URL,
        source: Language,
        target: Language,
        engine: RecognitionEngine = .whisper,
        /// Quem traduz. Explicito, e nao a preferencia gravada, para que as
        /// verificacoes rodem iguais em qualquer maquina e sem rede.
        translation: TranslationEngine = .apple,
        diarize: Bool = false,
        progress: @escaping @Sendable (GenerationStep, Double, String, Bool) -> Void,
        onBatch: (@Sendable ([Cue]) -> Void)? = nil
    ) async throws -> [Cue] {
        progress(.extracting, 0, "", false)
        let samples = try await Self.extractAudio(from: url, preferring: source)
        try Task.checkCancellation()
        let seconds = Double(samples.count) / 16_000

        let transcriber = TranscriberFactory.make(for: source, engine: engine)
        recognitionName = transcriber.engineName
        progress(.loadingASR, 0, transcriber.engineName, false)
        try await transcriber.prepare { fraction, label in
            progress(.loadingASR, fraction, label, false)
        }
        try Task.checkCancellation()

        // Quem fala primeiro, quando pedido: as fronteiras de voz vão para o
        // reconhecedor, que sem elas junta o fim de uma fala com o começo da
        // outra no mesmo trecho — e trecho é indivisível daí para frente.
        //
        // Medido no vídeo de 9 minutos com o reconhecimento da Apple: 23 dos
        // 132 trechos carregavam duas vozes (17%, 17,4 s de voz minoritária);
        // com as fronteiras, 1 de 251 (0%, 0,3 s).
        var turns: [SpeakerDiarizer.Turn] = []
        if diarize {
            progress(.diarizing, 0, "", false)
            do {
                turns = try await SpeakerDiarizer.turns(
                    in: samples, model: speakerModel
                ) { fraction in
                    progress(.diarizing, fraction, "", false)
                }
                // Um identificador por pessoa, não por trecho de voz: ver
                // `SpeakerDiarizer.mergeSameVoice`.
                if ProcessInfo.processInfo.environment["TRADUTOR_SEM_FUSAO"] == nil {
                    let limiar = ProcessInfo.processInfo.environment["TRADUTOR_FUSAO_LIMIAR"]
                        .flatMap(Float.init) ?? SpeakerDiarizer.sameVoiceThreshold
                    turns = (try? await SpeakerDiarizer.mergeSameVoice(
                        turns, in: samples, threshold: limiar)) ?? turns
                }
                transcriber.speakerBoundaries = SpeakerDiarizer.boundaries(of: turns)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Legenda sem locutor é melhor que nenhuma legenda.
                log.error("identificação de locutores falhou: \(error.localizedDescription, privacy: .public)")
            }
            try Task.checkCancellation()
        }

        // A pausa que o reconhecedor não expõe fecha o trecho aqui.
        //
        // Em japonês a Apple embute o silêncio na duração do caractere que
        // abre a fala seguinte, e duas pessoas separadas por um segundo de
        // silêncio caem no mesmo trecho — que daí em diante é indivisível.
        // Visto no vídeo de 9 minutos: `お疲れ様あれさんお疲れ様です。` num
        // trecho só, e a tradução colapsou as duas falas numa.
        //
        // Vale com ou sem identificação de locutor: é silêncio, não voz.
        if ProcessInfo.processInfo.environment["TRADUTOR_SEM_PAUSAS"] == nil {
            let pausas = SpeechEnergy.pauseBoundaries(
                samples, minimumPause: SpeechEnergy.subtitlePause)
            transcriber.pauseBoundaries = pausas
            silences = SpeechEnergy.silences(samples)
        }

        progress(.transcribing, 0, String(format: "0 de %.0f s de áudio", seconds), false)
        let timed = try await transcriber.transcribeForSubtitles(samples) { fraction in
            progress(.transcribing, fraction,
                     String(format: "%.0f de %.0f s de áudio", fraction * seconds, seconds), false)
        }
        try Task.checkCancellation()

        guard !timed.isEmpty else { throw SubtitleFileError.noSpeech }

        // A atribuição é aqui, porque precisa dos tempos do reconhecimento —
        // e antes do agrupamento, porque a troca de locutor é fronteira de
        // legenda.
        let pieces = turns.isEmpty
            ? timed
            : SpeakerDiarizer.renumber(SpeakerDiarizer.assign(timed, to: turns))

        draft = makeCues(from: pieces, mediaDuration: seconds)
        return try await translateDraft(
            translation: translation, source: source, target: target,
            progress: progress, onBatch: onBatch
        )
    }

    /// Traduz o rascunho de novo, com outro tradutor, sem reconhecer nada.
    ///
    /// É o mesmo caminho do fim de `generate` — de propósito: a janela e o
    /// item de menu já tiveram cada um a sua cópia dos passos e as cópias
    /// divergiram, e o usuário via legenda diferente saindo de cada um.
    public func retranslate(
        using translation: TranslationEngine,
        from source: Language,
        to target: Language,
        progress: @escaping @Sendable (GenerationStep, Double, String, Bool) -> Void,
        onBatch: (@Sendable ([Cue]) -> Void)? = nil,
        preserveCueTiming: Bool = false
    ) async throws -> [Cue] {
        guard !draft.isEmpty else { throw SubtitleFileError.noSpeech }
        return try await translateDraft(
            translation: translation, source: source, target: target,
            progress: progress, onBatch: onBatch,
            preserveCueTiming: preserveCueTiming
        )
    }

    private func translateDraft(
        translation: TranslationEngine,
        source: Language,
        target: Language,
        progress: @escaping @Sendable (GenerationStep, Double, String, Bool) -> Void,
        onBatch: (@Sendable ([Cue]) -> Void)?,
        preserveCueTiming: Bool = false
    ) async throws -> [Cue] {
        progress(.loadingTranslator, 0, "\(draft.count) legendas", false)
        // Um tradutor vivo por vez. O anterior é encerrado antes de o próximo
        // nascer: janela do DeepL fechada, servidor do Hunyuan morto.
        finish()
        let translator = TranslatorFactory.make(translation)
        self.translator = translator
        // E encerrado assim que a tradução termina — inclusive quando ela
        // falha ou é cancelada. A janela do DeepL fecha sozinha no fim do
        // trabalho, em vez de ficar aberta até alguém mexer na janela de
        // legendas, e o servidor do Hunyuan devolve os 4,5 GB na hora.
        //
        // A ordem importa: `defer` roda depois do aviso ser lido lá embaixo, e
        // `DeepLWebTranslator.reset()` zera o `fallbackCount` de onde o aviso
        // sai. Ler primeiro, fechar depois.
        defer { finish() }
        translationName = translator.engineName
        translationNotice = nil
        try await translator.prepare { _, _ in }
        try Task.checkCancellation()

        progress(.translating, 0, "0 de \(draft.count)", false)
        failedBatches = 0
        // Sem tradução o destino é o próprio idioma falado: é o que dá a
        // largura de linha certa sem um caso especial aqui dentro.
        let translated = await translate(
            draft,
            using: translator,
            from: source,
            to: translation.destination(from: source, to: target),
            progress: { progress(.translating, $0.fraction, $0.label, $0.waiting) },
            onBatch: onBatch,
            preserveCueTiming: preserveCueTiming
        )
        try Task.checkCancellation()
        // Nenhum tradutor de reserva, a pedido: lote perdido derruba a
        // tradução em vez de deixar aquele pedaço no idioma de origem. O
        // rascunho do reconhecimento fica de pé, e tentar de novo refaz só
        // esta etapa.
        if failedBatches > 0 {
            throw SubtitleFileError.translationFailed(
                translationNotice ?? "A tradução não foi concluída.")
        }
        let avisos = [translationNotice, translator.completionNotice].compactMap { $0 }
        translationNotice = avisos.isEmpty ? nil : avisos.joined(separator: " ")
        return translated
    }

    /// Encerra o tradutor que ficou vivo.
    ///
    /// Quem gera legenda chama isto quando termina de usar o builder — a
    /// janela do DeepL e o servidor do Hunyuan não se fecham sozinhos.
    public func finish() {
        translator?.reset()
        translator = nil
    }

    /// Traduz em blocos, mantendo a ordem.
    ///
    /// - Parameter onBatch: chamado a cada lote pronto, com tudo que já foi
    ///   traduzido até ali. É o que permite mostrar as legendas conforme saem
    ///   em vez de esperar o arquivo inteiro.
    public func translate(
        _ cues: [Cue],
        using translator: any Translator,
        from source: Language,
        to target: Language,
        progress: @Sendable (Progress) -> Void = { _ in },
        onBatch: (@Sendable ([Cue]) -> Void)? = nil,
        preserveCueTiming: Bool = false
    ) async -> [Cue] {
        var result = cues
        var done = 0
        var lotesFalhos = 0
        // A linha da legenda tem a largura do idioma que vai ser lido, não a
        // do que foi falado. É aqui porque é aqui que o destino é conhecido.
        charactersPerLine = Self.lineWidth(for: target)

        // O reconhecimento já acabou e a fala inteira está aqui. Segurá-la
        // até o primeiro lote traduzido voltar deixa a lista **vazia** o
        // tempo todo da espera: relatado em 20/09/2026 como "capturou o
        // áudio com a Apple e não renderizou a captura", e a captura de tela
        // do autoteste mostra o painel em "Traduzindo 52%" com a lista em
        // branco. É a Apple que expõe isso — ela reconhece 109 s de áudio em
        // 0,5 s, então sobram os ~11 s inteiros da tradução sem nada na tela;
        // com um reconhecedor lento a barra de progresso disfarça.
        //
        // A decisão antiga ("só o que já foi traduzido, senão a lista enche
        // de linhas em branco") partia de uma premissa errada: a legenda sem
        // tradução **não é branca**, ela tem a fala reconhecida, e a janela
        // já sabe mostrá-la — `displayText` cai em `cue.source` quando
        // `translated` está vazio, e `displayLines` usa a largura do idioma
        // falado nesse caso.
        //
        // Sai cru, não por `finalize`: a repartição por largura é da
        // tradução, e a lista quebra a própria linha.
        onBatch?(result)

        // Quem sabe o tamanho certo é o tradutor, não este código.
        let step = max(1, translator.preferredBatchSize)

        for start in stride(from: 0, to: cues.count, by: step) {
            let end = min(start + step, cues.count)

            // Com `contextOverlap` acima de zero, as legendas anteriores
            // viajam junto só como contexto e as traduções delas são
            // descartadas ao voltar. Hoje é zero — ver o comentário do campo.
            let contextStart = max(0, start - contextOverlap)
            let slice = Array(cues[contextStart..<end])
            let texts = slice.map(\.source)

            // Antes de mandar: diz qual faixa está no ar. É o único momento
            // em que a interface pode dizer algo honesto sobre uma espera que
            // não tem passos intermediários.
            progress(Progress(
                fraction: Double(done) / Double(max(cues.count, 1)),
                label: "\(start + 1)–\(end) de \(cues.count)",
                waiting: true
            ))

            // Uma segunda tentativa do MESMO lote, não do arquivo inteiro —
            // o Gemini às vezes devolve a origem sem traduzir mesmo depois do
            // reload interno do `GeminiDriver`, e refazer só este pedaço custa
            // uma requisição, não a tradução inteira de novo.
            var translations: [String]?
            for tentativa in 0..<2 {
                do {
                    let resultado = try await translator.translate(texts, from: source, to: target)
                    // Resposta com contagem diferente da entrada é o defeito
                    // que não devolve erro: a legenda 5 recebe a tradução da
                    // 4, com timecode válido e arquivo sem nada de errado.
                    // Melhor sem tradução do que retomar sem conferir.
                    guard resultado.count == texts.count else {
                        log.error("lote \(start): \(resultado.count) traduções para \(texts.count) textos")
                        continue
                    }
                    translations = resultado
                    break
                } catch {
                    log.error("lote \(start) falhou (tentativa \(tentativa + 1)): \(error.localizedDescription, privacy: .public)")
                }
                if Task.isCancelled { break }
            }
            guard let translations else {
                // Seguir é certo — perder dez minutos de trabalho por um lote
                // seria pior —, mas em silêncio não: o `.srt` sai com esse
                // pedaço no idioma de origem, e sem aviso isso parece geração
                // completa. Ver `translationNotice`.
                lotesFalhos += 1
                continue
            }

            let discard = start - contextStart
            for (offset, translated) in translations.enumerated() where offset >= discard {
                let index = contextStart + offset
                guard index < result.count else { continue }
                result[index].translated = translated
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            done = end
            progress(Progress(
                fraction: Double(done) / Double(max(cues.count, 1)),
                label: "\(done) de \(cues.count)"
            ))
            // Só o que já foi traduzido: entregar as legendas ainda em branco
            // encheria a lista de linhas vazias que depois mudariam sozinhas.
            if let onBatch {
                onBatch(finalize(Array(result.prefix(done)), preservingTiming: preserveCueTiming))
            }

            if Task.isCancelled {
                note(lotesFalhos)
                return finalize(Array(result.prefix(done)), preservingTiming: preserveCueTiming)
            }
        }
        note(lotesFalhos)
        return finalize(result, preservingTiming: preserveCueTiming)
    }

    private func finalize(_ cues: [Cue], preservingTiming: Bool) -> [Cue] {
        preservingTiming
            ? Self.capitalizeSentences(cues)
            : Self.capitalizeSentences(enforceLineLimit(cues))
    }

    /// Registra o que não foi traduzido, para a interface poder dizer.
    ///
    /// O aviso continua porque `translate` é usado sozinho nos gates; quem
    /// gera legenda de verdade passa por `translateDraft`, e lá a falha vira
    /// erro: legenda meio traduzida é arquivo plausível e errado.
    private func note(_ lotesFalhos: Int) {
        guard lotesFalhos > 0 else { return }
        failedBatches = lotesFalhos
        translationNotice = lotesFalhos == 1
            ? "1 lote não foi traduzido — essas legendas saíram no idioma original."
            : "\(lotesFalhos) lotes não foram traduzidos — essas legendas saíram no idioma original."
    }

    /// Começo de frase com maiúscula.
    ///
    /// O tradutor do sistema devolve minúscula na maioria das falas curtas —
    /// medido, 15 de 57 legendas começavam com maiúscula. Isso tem conserto
    /// aqui, sem envolver o tradutor.
    ///
    /// O caminho tentado antes era prefixar cada fala com travessão até o
    /// tradutor e removê-lo na volta: subia para 40 de 57, e de graça vinham
    /// outras mudanças — "você também, kamimura? sim, EU tenho vinte anos"
    /// virava "o senhor kamimura também? sim, ELE tem vinte anos". Trocar
    /// caixa por sentido não vale; a caixa se resolve por conta.
    ///
    /// Só capitaliza quem começa frase: a legenda anterior tem de ter
    /// terminado em pontuação. `enforceLineLimit` corta legenda no meio da
    /// frase, e a segunda metade não leva maiúscula.
    public static func capitalizeSentences(_ cues: [Cue]) -> [Cue] {
        var result = cues
        var startsSentence = true
        for index in result.indices {
            let text = result[index].translated
            guard !text.isEmpty else { continue }
            if startsSentence, let first = text.first, first.isLowercase {
                result[index].translated = first.uppercased() + text.dropFirst()
            }
            // O travessão de troca de locutor entra na renderização, depois
            // disto, então aqui a última letra é sempre a da fala.
            startsSentence = ".!?…\"'）」".contains(result[index].translated.last ?? " ")
                || result[index].translated.hasSuffix(".\"")
        }
        return result
    }

    /// Divide as legendas cuja tradução não cabe em duas linhas.
    ///
    /// O corte do original acontece antes de traduzir, então não há como saber
    /// ali quanto a tradução vai crescer. Uma legenda de três linhas cobre o
    /// vídeo e não dá tempo de ler; dividir no tempo é preferível a encolher a
    /// fonte ou cortar texto.
    ///
    /// A divisão é equilibrada de propósito. Agrupar as linhas de duas em duas
    /// deixava sobra: três linhas viravam 2+1, e a última parte era uma
    /// palavra solta ocupando meio segundo de tela — "etc." piscando e sumindo.
    /// Repartir por número de caracteres dá pedaços de tamanho parecido, e
    /// cada um recebe tempo proporcional ao que carrega.
    public func enforceLineLimit(_ cues: [Cue]) -> [Cue] {
        // Repartir uma vez não basta. A conta era `caracteres / (42 × 2)`,
        // supondo que toda linha chega aos 42 — não chega, porque a quebra
        // procura pontuação e espaço. Hoje a conta é por **linhas** e o que
        // sobrar grande volta para outra passada (2 de 4 gerações do vídeo de
        // 9 minutos saíam com três linhas).
        var atual = cues
        for _ in 0..<3 {
            let (proximo, repartiu) = splitOversized(atual)
            atual = proximo
            if !repartiu { break }
        }
        for index in atual.indices { atual[index].index = index + 1 }
        return fixOverlaps(atual)
    }

    /// Uma passada de repartição. Devolve se alguma legenda foi repartida.
    private func splitOversized(_ cues: [Cue]) -> ([Cue], Bool) {
        var result: [Cue] = []
        var repartiu = false
        // O último locutor conhecido, na mesma regra do `SRTWriter`: é ele que
        // decide se esta legenda vai receber travessão lá na frente.
        var anterior: String?

        for cue in cues {
            let text = cue.translated.isEmpty ? cue.source : cue.translated
            // Medir o texto **como ele será mostrado**, travessão incluído.
            //
            // O travessão entra na renderização e ocupa duas colunas da
            // primeira linha: medir sem ele deixava passar legenda de três
            // linhas. A repartição é do texto puro — só a primeira parte
            // recebe o travessão, as seguintes são do mesmo locutor.
            let renderizado = SpeakerMark.decorate(text, speaker: cue.speaker, previous: anterior)
            anterior = SpeakerMark.advance(anterior, with: cue.speaker)
            guard LineBreaker.wrap(renderizado, maximum: charactersPerLine).count > maximumLines else {
                result.append(cue)
                continue
            }

            // Por linhas, não por caracteres: é a quebra real que decide.
            let linhas = LineBreaker.wrap(renderizado, maximum: charactersPerLine).count
            let pedacos = max(2, Int(ceil(Double(linhas) / Double(maximumLines))))
            let parts = splitEvenly(text, into: pedacos)
            guard parts.count > 1 else {
                result.append(cue)
                continue
            }

            repartiu = true
            let sourceParts = splitSource(cue.source, into: parts.count)

            let totalCharacters = max(parts.reduce(0) { $0 + $1.count }, 1)
            let span = cue.end - cue.start
            // Repartir não cria tempo: em legendas curtas, reduz o mínimo
            // por parte e reserva esse tempo também para as partes seguintes.
            let minimumPart = min(minimumDuration * 0.7, span / Double(parts.count))
            var cursor = cue.start

            for (offset, part) in parts.enumerated() {
                let isLast = offset == parts.count - 1
                let share = span * Double(part.count) / Double(totalCharacters)
                let latestEnd = cue.end - Double(parts.count - offset - 1) * minimumPart
                let end = isLast
                    ? cue.end
                    : min(cursor + max(share, minimumPart), latestEnd)

                result.append(Cue(
                    index: result.count + 1,
                    start: cursor,
                    end: end,
                    source: offset < sourceParts.count ? sourceParts[offset] : "",
                    translated: part,
                    // Repartir não muda quem fala. Sem isto, uma legenda longa
                    // identificada virava várias sem dono: sem cor na janela e
                    // sem travessão no arquivo.
                    speaker: cue.speaker
                ))
                cursor = end
            }
        }
        return (result, repartiu)
    }

    /// Reparte o texto original junto com a tradução, mas só em fronteira de
    /// verdade.
    ///
    /// Repetir a frase inteira em todas as partes faz a linha do original
    /// dizer que um trecho curto corresponde a uma frase longa que já passou.
    /// Mas cortar por caractere é pior em japonês e chinês, onde não há espaço
    /// entre palavras: `など` virava `な` numa parte e `ど` na outra.
    ///
    /// Então: divide se houver espaço ou pontuação onde cortar; se não houver,
    /// o original fica só na primeira parte e as seguintes ficam sem ele.
    private func splitSource(_ source: String, into count: Int) -> [String] {
        let clean = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard count > 1, !clean.isEmpty else { return [clean] }

        let boundaries = CharacterSet(charactersIn: " 、。，,;；:：!！?？")
        let pieces = clean
            .components(separatedBy: boundaries)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard pieces.count >= count else {
            // Sem onde cortar sem mutilar palavra: original só na primeira.
            return [clean] + Array(repeating: "", count: count - 1)
        }

        // Distribui os pedaços entre as partes, mantendo a ordem.
        var result = [String](repeating: "", count: count)
        for (index, piece) in pieces.enumerated() {
            let slot = min(index * count / pieces.count, count - 1)
            result[slot] = result[slot].isEmpty
                ? piece
                : result[slot] + " " + piece
        }
        return result
    }

    /// Reparte o texto em `count` pedaços de tamanho parecido, cortando em
    /// espaço e preferindo pontuação quando ela cai perto do ponto ideal.
    private func splitEvenly(_ text: String, into count: Int) -> [String] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard count > 1, clean.count >= count * 2 else { return [clean] }

        let target = Double(clean.count) / Double(count)
        var units = clean.split(separator: " ").map(String.init)
        var separator = " "

        // Japonês, chinês e tailandês não separam palavras por espaço: uma
        // frase inteira vira uma "palavra" só e não haveria onde repartir.
        // Quando a maior unidade não cabe no alvo, o corte passa a ser por
        // caractere.
        if units.isEmpty || (units.map(\.count).max() ?? 0) > Int(target) {
            units = clean.map(String.init)
            separator = ""
        }
        guard units.count >= count else { return [clean] }

        var parts: [String] = []
        var current: [String] = []

        func length(_ pieces: [String]) -> Int {
            pieces.joined(separator: separator).count
        }

        for unit in units {
            let remaining = count - parts.count
            // A última parte fica com tudo que sobrar.
            guard remaining > 1 else { current.append(unit); continue }

            if !current.isEmpty {
                let without = length(current)
                let with = length(current + [unit])
                let endsClause = current.last?.last.map { ",;:.!?—、。".contains($0) } ?? false

                // Fecha antes de adicionar quando isso deixa a parte mais
                // perto do alvo. Só medir depois de adicionar fazia a primeira
                // parte engolir o texto todo e não sobrava nada para dividir.
                let closerWithout = abs(Double(without) - target) <= abs(Double(with) - target)
                if closerWithout, endsClause || Double(without) >= target * 0.55 {
                    parts.append(current.joined(separator: separator))
                    current = [unit]
                    continue
                }
            }
            current.append(unit)
        }

        if !current.isEmpty { parts.append(current.joined(separator: separator)) }
        return parts.filter { !$0.isEmpty }
    }

    /// Legendas não podem se sobrepor, ficar fora de ordem, nem terminar antes
    /// de começar.
    ///
    /// A versão anterior só empurrava o ponto médio entre duas legendas que se
    /// tocavam, e isso produzia coisas como `00:00:31,189 --> 00:00:27,220`
    /// quando os tempos de origem vinham desordenados: o fim ficava antes do
    /// início e o arquivo virava lixo para qualquer player.
    private func fixOverlaps(_ cues: [Cue]) -> [Cue] {
        guard !cues.isEmpty else { return [] }
        var result = cues.sorted { $0.start < $1.start }
        let minimumOnScreen: TimeInterval = 0.4

        for index in result.indices {
            // Nunca antes do fim da anterior.
            if index > 0 {
                result[index].start = max(result[index].start, result[index - 1].end)
            }
            // Nunca terminar antes de começar.
            if result[index].end <= result[index].start {
                result[index].end = result[index].start + minimumOnScreen
            }
            // E a anterior nao pode invadir esta.
            if index > 0, result[index - 1].end > result[index].start {
                result[index - 1].end = max(
                    result[index].start,
                    result[index - 1].start + minimumOnScreen
                )
            }
        }

        for index in result.indices { result[index].index = index + 1 }
        return result
    }

    /// Corta o que cai fora do vídeo e o que fica tempo demais na tela.
    ///
    /// O reconhecedor inventa texto no silêncio do fim e o marca depois do
    /// último quadro: no vídeo de 18 min saiu uma legenda começando aos 18:04
    /// — três segundos além do fim — e durando vinte segundos, quando o teto
    /// é sete. Ninguém jamais a veria, e ela ainda entrava no arquivo.
    private func clamp(_ cues: [Cue], to mediaDuration: TimeInterval?) -> [Cue] {
        var result: [Cue] = []

        for var cue in cues {
            if let mediaDuration {
                // Começa depois do fim: não existe quadro para mostrá-la.
                guard cue.start < mediaDuration - 0.2 else { continue }
                cue.end = min(cue.end, mediaDuration)
            }

            // Um trecho isolado e longo demais é quase sempre invenção no
            // silêncio. Fica o tempo de ser lido, não o tempo inteiro.
            if cue.end - cue.start > maximumDuration {
                cue.end = cue.start + maximumDuration
            }

            guard cue.end > cue.start else { continue }
            result.append(cue)
        }
        return result
    }

    /// Buraco entre duas legendas menor que isto apaga a tela no meio da
    /// fala, e é isso que se vê como a legenda piscando.
    ///
    /// Medido no vídeo japonês de 9 minutos: com o Whisper são **38 buracos
    /// abaixo de 1 s, somando 25,5 s de tela apagada** com alguém falando;
    /// com a Apple, 10 e 6,4 s. A diferença não é defeito do Whisper — ele
    /// pontua cada fala curta, e o agrupador fecha legenda na pontuação, que
    /// é o que se quer. O que falta é segurar a legenda até a seguinte.
    public var maximumGap: TimeInterval = 1.0

    /// O respiro que fica entre duas legendas, para a troca ser visível.
    ///
    /// Duas caixas de texto que se sucedem sem intervalo nenhum parecem uma
    /// só mudando de conteúdo. A legendagem usa dois quadros; 0,08 s é isso a
    /// 24 quadros por segundo.
    public var minimumGap: TimeInterval = 0.08

    /// Segura cada legenda até quase a seguinte, quando o buraco é curto.
    ///
    /// Prática corrente de legendagem, e aqui ela resolve um defeito real: o
    /// reconhecedor corta em cada frase, e entre uma frase e a próxima da
    /// mesma pessoa há meio segundo em que a tela fica vazia. Não estende
    /// além do teto de leitura nem encurta nada — só preenche o vão.
    private func bridgeShortGaps(_ cues: [Cue]) -> [Cue] {
        guard cues.count > 1 else { return cues }
        var result = cues
        for index in 0..<(result.count - 1) {
            let gap = result[index + 1].start - result[index].end
            guard gap > minimumGap, gap < maximumGap else { continue }
            let alvo = result[index + 1].start - minimumGap
            // Nem além do teto de leitura, nem para trás.
            let teto = result[index].start + maximumDuration
            result[index].end = max(result[index].end, min(alvo, teto))
        }
        return result
    }

    /// Junta legendas curtas demais para serem lidas com a vizinha.
    ///
    /// O corte por frase às vezes deixa um resto de uma palavra sozinho —
    /// "etc." ocupando meio segundo de tela. Isso pisca e não dá tempo de ler.
    private func mergeTinyCues(_ cues: [Cue]) -> [Cue] {
        guard cues.count > 1 else { return cues }
        var result: [Cue] = []

        for cue in cues {
            let tooShort = cue.end - cue.start < minimumDuration * 0.7
            let tooFewCharacters = cue.source.count <= 6

            // Só juntar se o intervalo inteiro couber. Acrescentar o texto e
            // cortar o fim em 7 s fazia a legenda desaparecer antes da fala
            // acrescentada (7,1–9,4 s no caso de regressão).
            if (tooShort || tooFewCharacters),
               var previous = result.last,
               // Resposta curta de outra pessoa NÃO é sobra de corte: é a
               // fala dela. Juntar desfazia o trabalho das fronteiras de voz
               // — "Você entregou o relatório?" e "Sim." viravam uma legenda
               // só, atribuída a quem perguntou.
               previous.speaker == cue.speaker,
               max(previous.end, cue.end) - previous.start <= maximumDuration,
               cue.start - previous.end < 1.5 {
                // Pela regra da escrita, como em `makeCues`: junta com espaço
                // só onde o espaço existe. Era o último lugar que ainda
                // devolvia "よかったです。 頑張ろうね。".
                previous.source = Tokens.join([previous.source, cue.source])
                previous.end = max(previous.end, cue.end)
                result[result.count - 1] = previous
                continue
            }
            result.append(cue)
        }
        return result
    }
}

/// A marca de troca de locutor.
///
/// Existe fora do `SRTWriter` porque a janela de legendas mostra a mesma
/// legenda na tela: antes o travessão só aparecia no arquivo, e quem assistia
/// para conferir antes de exportar via uma legenda diferente da que ia sair.
public enum SpeakerMark {

    public static let dash = "— "

    /// O texto com travessão quando esta legenda começa a fala de outra pessoa.
    ///
    /// `previous` é o último locutor **conhecido**, não o da legenda anterior.
    /// Trecho sem locutor no meio é coisa que o app produz de propósito —
    /// `pruneTinyVoices` descarta a voz curta e deixa o trecho sem dono — e
    /// tratar esse buraco como troca diria ao leitor que apareceu gente nova.
    public static func decorate(_ text: String, speaker: String?, previous: String?) -> String {
        guard let speaker, speaker != previous else { return text }
        return dash + text
    }

    /// Qual é o último locutor conhecido depois desta legenda.
    public static func advance(_ previous: String?, with speaker: String?) -> String? {
        speaker ?? previous
    }
}

/// Serializa no formato SubRip.
public enum SRTWriter {

    /// - Parameter colorBySpeaker: envolve cada legenda em
    ///   `<font color="#RRGGBB">`, uma cor por locutor. O SubRip não tem
    ///   sintaxe de locutor, mas a tag de cor é entendida pelo VLC, mpv e a
    ///   maioria dos players — e quem não entende mostra a tag na tela, por
    ///   isso isto é opção e não padrão.
    /// - Parameter charactersPerLine: largura da linha, que é a do idioma de
    ///   destino — `SubtitleFileBuilder.lineWidth(for:)`. Estava fixa em 42, e
    ///   com destino japonês a legenda saía com o dobro do que a convenção
    ///   admite. O padrão é a largura latina, para quem só tem as legendas na
    ///   mão e não o idioma.
    public static func render(
        _ cues: [Cue], includeSource: Bool = false, colorBySpeaker: Bool = false,
        charactersPerLine: Int = 42
    ) -> String {
        var output = ""
        var number = 1
        var previousSpeaker: String?
        for cue in cues {
            var text = cue.translated.isEmpty ? cue.source : cue.translated
            guard SentenceSplitter.hasContent(text) else { continue }

            // Troca de locutor ganha travessão, que é a convenção de legenda
            // para diálogo. O nome não vai para o arquivo: ele ocupa metade da
            // linha e o leitor já sabe quem é pela cena. A regra é
            // `SpeakerMark`, compartilhada com a janela.
            text = SpeakerMark.decorate(text, speaker: cue.speaker, previous: previousSpeaker)
            previousSpeaker = SpeakerMark.advance(previousSpeaker, with: cue.speaker)

            output += "\(number)\n"
            output += "\(timecode(cue.start)) --> \(timecode(cue.end))\n"
            // Duas linhas é a convenção de legendagem; a largura vem do
            // idioma que vai ser lido.
            var body = LineBreaker.wrap(text, maximum: charactersPerLine)
                .joined(separator: "\n")
            // A cor envolve o bloco inteiro, depois da quebra: uma tag por
            // linha dobraria o tamanho do arquivo sem mudar nada na tela.
            if colorBySpeaker, let hex = SpeakerPalette.hex(for: cue.speaker) {
                body = "<font color=\"\(hex)\">\(body)</font>"
            }
            output += body
            if includeSource, !cue.source.isEmpty {
                output += "\n<i>\(cue.source)</i>"
            }
            output += "\n\n"
            number += 1
        }
        return output
    }

    /// `00:01:23,456` — SubRip usa vírgula como separador decimal.
    public static func timecode(_ seconds: TimeInterval) -> String {
        // Arredonda uma vez; truncar a fração perdia 1 ms a cada ida e volta.
        let ticks = Int((max(0, seconds) * 1000).rounded())
        let total = ticks / 1000
        let milliseconds = ticks % 1000
        return String(
            format: "%02d:%02d:%02d,%03d",
            total / 3600, (total % 3600) / 60, total % 60, milliseconds
        )
    }
}

/// Lê um arquivo `.srt` de volta para legendas.
///
/// Serve para abrir uma legenda já pronta — a que o app gerou antes, ou uma
/// baixada de outro lugar — sem ter que reconhecer o áudio de novo.
public enum SRTParser {

    public static func parse(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        // Aceita as três quebras de linha que aparecem na prática: SRT de
        // origem Windows vem com CRLF, e um bloco pode ter linha em branco
        // com espaços.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            // Linha só de espaços é linha em branco. Sem isto os dois blocos
            // viravam um, e o número e o timecode do segundo apareciam dentro
            // do texto do primeiro — arquivo aceito, legenda embaralhada.
            .replacingOccurrences(
                of: "(?m)^[ \t]+$", with: "", options: .regularExpression
            )

        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard lines.count >= 2 else { continue }

            // A primeira linha pode ser o número ou já o tempo.
            let timeLineIndex = lines[0].contains("-->") ? 0 : 1
            guard lines.count > timeLineIndex,
                  let (start, end) = parseTimes(lines[timeLineIndex])
            else { continue }

            let body = Tokens.join(lines.dropFirst(timeLineIndex + 1).map {
                $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            }).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }

            cues.append(Cue(
                index: cues.count + 1,
                start: start,
                end: end > start ? end : start + 0.2,
                source: "",
                translated: body
            ))
        }
        return cues.sorted { $0.start < $1.start }
    }

    public static func parse(contentsOf url: URL) throws -> [Cue] {
        // SRT antigo costuma vir em Latin-1; tentar só UTF-8 devolve nada.
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let cues = parse(text)
            if !cues.isEmpty { return cues }
        }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) {
            let cues = parse(text)
            if !cues.isEmpty { return cues }
        }
        throw SubtitleFileError.emptySubtitles(url.lastPathComponent)
    }

    /// `00:01:23,456 --> 00:01:25,789`, com vírgula ou ponto no decimal.
    private static func parseTimes(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = seconds(parts[0]), let end = seconds(parts[1])
        else { return nil }
        return (start, end)
    }

    private static func seconds(_ text: String) -> TimeInterval? {
        let clean = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let pieces = clean.components(separatedBy: ":")
        guard pieces.count == 3,
              let hours = Double(pieces[0]),
              let minutes = Double(pieces[1]),
              let secs = Double(pieces[2]),
              hours.isFinite, hours >= 0, hours < 1_000_000,
              minutes.isFinite, (0..<60).contains(minutes),
              secs.isFinite, (0..<60).contains(secs)
        else { return nil }
        return hours * 3600 + minutes * 60 + secs
    }
}

public enum SubtitleFileError: LocalizedError {
    case noAudioTrack(String)
    case cannotDecode(String)
    case unsupportedFormat(file: String, detected: String?)
    case emptySubtitles(String)
    case notFound(String)
    case unreadable(String)
    case noSpeech
    /// A tradução não terminou. O reconhecimento continua de pé: tentar de
    /// novo refaz só esta etapa.
    case translationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSpeech:
            return "Nenhuma fala foi reconhecida neste vídeo."

        case let .translationFailed(detalhe):
            return "A tradução falhou: \(detalhe)"

        case let .noAudioTrack(name):
            return "\(name) não tem trilha de áudio que o sistema consiga ler."

        case let .cannotDecode(detail):
            return "Não foi possível decodificar o áudio: \(detail)"

        case let .notFound(name):
            return "\(name) não está mais no lugar de onde foi escolhido."

        case let .unreadable(name):
            return """
            O app não conseguiu abrir \(name). O arquivo existe, mas o acesso \
            foi negado.

            Isso costuma ser permissão de pasta: escolha o arquivo de novo pelo \
            botão Abrir vídeo, ou libere o acesso em Ajustes do Sistema > \
            Privacidade e Segurança > Arquivos e Pastas.
            """

        case let .emptySubtitles(name):
            return "\(name) não contém nenhuma legenda que o app consiga ler."

        case let .unsupportedFormat(file, detected):
            let aceitos = MediaProbe.supportedNames.joined(separator: ", ")
            if let detected {
                return """
                \(file) é um arquivo \(detected), e esse formato de vídeo é \
                diferente dos que o app aceita.

                Formatos aceitos: \(aceitos).

                Converter para MP4 resolve — o ffmpeg faz isso sem recodificar \
                o vídeo na maioria dos casos.
                """
            }
            return """
            Não foi possível reconhecer o formato de \(file). O conteúdo não \
            corresponde a nenhum container conhecido, mesmo tratando-o como MP4.

            Formatos aceitos: \(aceitos).
            """
        }
    }
}
