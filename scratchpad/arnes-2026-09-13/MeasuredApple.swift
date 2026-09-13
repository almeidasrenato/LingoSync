import TradutorCore
import AVFoundation
import Foundation
import Observation
import Speech

// Reconhecimento de fala do próprio macOS (SpeechAnalyzer, macOS 26).
//
// É o par do tradutor que o app já usa: os modelos são do sistema, não ocupam
// a pasta do app e se atualizam sozinhos. Em troca, só cobre os idiomas que a
// Apple oferece, e cada um precisa estar instalado — o que o próprio app pode
// pedir, ao contrário dos pacotes de tradução.

extension Language {
    /// Região preferida quando o sistema tem mais de uma para o idioma:
    /// português do Brasil, não de Portugal.
    var measuredLocaleHint: Locale {
        switch self {
        case .portuguese: Locale(identifier: "pt-BR")
        case .english: Locale(identifier: "en-US")
        case .spanish: Locale(identifier: "es-ES")
        case .french: Locale(identifier: "fr-FR")
        case .german: Locale(identifier: "de-DE")
        case .italian: Locale(identifier: "it-IT")
        case .japanese: Locale(identifier: "ja-JP")
        case .korean: Locale(identifier: "ko-KR")
        case .chinese: Locale(identifier: "zh-CN")
        default: Locale(identifier: rawValue)
        }
    }
}

@available(macOS 26.0, *)
enum MeasuredLocales {
    /// A variante do sistema que atende o idioma, ou `nil` quando a Apple não
    /// o reconhece.
    ///
    /// Procura na lista real do sistema. `supportedLocale(equivalentTo:)`
    /// devolve variante de árabe, russo e outros que o transcritor não cobre,
    /// e o + oferecia instalar idiomas que não existem — nem conferindo o
    /// código do idioma devolvido isso parava.
    static func locale(for language: Language) async -> Locale? {
        let hint = language.measuredLocaleHint
        let candidates = await SpeechTranscriber.supportedLocales
            .filter { $0.language.languageCode == hint.language.languageCode }
        return candidates.first { $0.identifier(.bcp47) == hint.identifier(.bcp47) }
            ?? candidates.first
    }

    static func isInstalled(_ locale: Locale) async -> Bool {
        let wanted = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == wanted }
    }
}

// MARK: - Reconhecedor

@available(macOS 26.0, *)
public final class MeasuredApple: Transcriber, @unchecked Sendable {

    public let engineName = "Apple"
    public var language: Language {
        // A variante do sistema depende do idioma: trocar exige preparar de novo.
        didSet { if language != oldValue { locale = nil } }
    }
    public var isPrepared: Bool { locale != nil }
    private var locale: Locale?

    public init(language: Language) {
        self.language = language
    }

    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        progress(0.2, "verificando o reconhecimento da Apple")
        guard let locale = await MeasuredLocales.locale(for: language) else {
            throw MeasuredError.unsupported(language)
        }
        guard await MeasuredLocales.isInstalled(locale) else {
            throw MeasuredError.notInstalled(language)
        }
        self.locale = locale
        progress(1, "reconhecimento da Apple pronto")
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        try await analyze(samples) { _ in }
            .map { String($0.text.characters).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public func transcribeTimed(
        _ samples: [Float],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedText] {
        let results = try await analyze(samples, progress: progress)
        progress(1)
        let limites = speakerBoundaries
        return results
            .flatMap { Self.phrases(in: $0, boundaries: limites) }
            .sorted { $0.start < $1.start }
    }

    /// Nada de mascarar o que foi dito.
    ///
    /// `SpeechTranscriber.TranscriptionOption` tem um único caso,
    /// `.etiquetteReplacements`, que substitui palavrão por eufemismo. Legenda
    /// é transcrição: quem falou, falou. Fica vazio, e o
    /// `tradutor-verify motores` falha se alguém acrescentar algo aqui.
    public static let transcriptionOptions: Set<SpeechTranscriber.TranscriptionOption> = []

    /// Passa o áudio inteiro pelo sistema e devolve os resultados finais.
    private func analyze(
        _ samples: [Float],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeechTranscriber.Result] {
        guard let locale else { throw TranscriberError.notPrepared }

        let module = SpeechTranscriber(
            locale: locale,
            // Vazio de propósito. A única opção de transcrição que o sistema
            // oferece é `.etiquetteReplacements`, que troca palavrão por
            // eufemismo — numa legenda isso é falsear a fala. Não ligar.
            transcriptionOptions: Self.transcriptionOptions,
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [module])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            ?? Self.sourceFormat
        let buffers = try Self.convert(samples, to: format)
        let duration = Double(samples.count) / 16_000

        // Os resultados chegam conforme o sistema avança no áudio; o fim de
        // cada um diz quanto já foi reconhecido.
        let collector = Task {
            var all: [SpeechTranscriber.Result] = []
            for try await result in module.results {
                all.append(result)
                if duration > 0 { progress(min(1, result.range.end.seconds / duration)) }
            }
            return all
        }

        let input = AsyncStream<AnalyzerInput> { continuation in
            for buffer in buffers { continuation.yield(AnalyzerInput(buffer: buffer)) }
            continuation.finish()
        }
        do {
            if let last = try await analyzer.analyzeSequence(input) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    func measured(_ samples: [Float], boundaries: [Double]) async throws -> [String: Any] {
        let results = try await analyze(samples) { _ in }
        func dict(_ x: TimedText) -> [String: Any] { ["text": x.text, "start": x.start, "end": x.end] }
        return ["before": results.flatMap { Self.oldPhrases(in: $0, boundaries: boundaries) }.map(dict),
                "received": results.flatMap { Self.phrases(in: $0, boundaries: boundaries) }.map(dict),
                "raw": results.map { String($0.text.characters) }]
    }
    /// Junta as palavras marcadas em trechos curtos.
    ///
    /// O sistema dá o tempo de cada palavra. Soltas, elas estragariam japonês
    /// e chinês: o agrupador de legendas junta os pedaços com espaço, e
    /// "今日は" viraria "今日 は". Juntando aqui pelo texto original, o espaço
    /// só entra entre trechos — como já acontece com os segmentos do Whisper.
    /// Fronteiras de voz, quando a identificação de locutor está ligada.
    /// Ver `Transcriber.speakerBoundaries`.
    public var speakerBoundaries: [TimeInterval] = []

    static func oldPhrases(
        in result: SpeechTranscriber.Result, boundaries: [TimeInterval] = []
    ) -> [TimedText] {
        var pieces: [TimedText] = []
        var text = ""
        var start: Double?
        var end = 0.0
        /// De que lado das fronteiras está o trecho em montagem.
        var currentSide = 0

        func close() {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let start, !clean.isEmpty {
                // Pontuação solta não é um trecho: ela é o fim do anterior.
                //
                // O teto de tempo fecha o trecho e o `。` chega no run
                // seguinte, sozinho. Virando trecho próprio ele é descartado
                // adiante por `hasContent`, e o fim de frase desaparece — no
                // vídeo de 9 minutos em japonês eram 4 de 98.
                if !SentenceSplitter.hasContent(clean), let last = pieces.popLast() {
                    pieces.append(TimedText(
                        text: last.text + clean, start: last.start, end: max(last.end, end)
                    ))
                } else {
                    pieces.append(TimedText(text: clean, start: start, end: max(end, start)))
                }
            }
            text = ""
            start = nil
        }

        for run in result.text.runs {
            let piece = String(result.text[run.range].characters)
            guard let range = run.audioTimeRange else {
                text += piece          // pontuação costuma vir sem tempo
                continue
            }
            // Pausa longa é fronteira natural.
            if start != nil, range.start.seconds - end > 0.5 { close() }
            // Troca de voz também, e esta não se vê no áudio: sem ela, a
            // última palavra de quem entrou fica no trecho de quem saiu.
            //
            // Cada palavra vai para o lado da fronteira em que está o seu
            // **meio**, e o trecho fecha quando esse lado muda. Comparar
            // contra o início ou o fim da palavra não serve: a fronteira vem
            // de um modelo por quadro e erra ±100 ms contra o tempo da
            // palavra, então o corte caía uma palavra tarde e o "E" de
            // "Entendi" ficava no trecho da outra pessoa. O meio é o ponto
            // que tolera esse desencontro.
            let lado = Self.side(of: (range.start.seconds + range.end.seconds) / 2,
                                in: boundaries)
            if start != nil, lado != currentSide { close() }
            currentSide = lado
            if start == nil { start = range.start.seconds }
            text += piece
            end = range.end.seconds

            let endsSentence = piece.trimmingCharacters(in: .whitespaces).last
                .map { SentenceSplitter.sentenceEnders.contains($0) } ?? false
            if endsSentence { close(); continue }

            if end - (start ?? end) >= 5 { close() }
        }
        close()

        if pieces.isEmpty {
            let whole = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !whole.isEmpty {
                pieces.append(TimedText(
                    text: whole, start: result.range.start.seconds, end: result.range.end.seconds
                ))
            }
        }
        return pieces
    }

    static func phrases(
        in result: SpeechTranscriber.Result, boundaries: [TimeInterval] = []
    ) -> [TimedText] {
        var pieces: [TimedText] = []
        var text = ""
        var start: Double?
        var end = 0.0
        /// De que lado das fronteiras está o trecho em montagem.
        var currentSide = 0

        func close() {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let start, !clean.isEmpty {
                // Pontuação solta não é um trecho: ela é o fim do anterior.
                //
                // O teto de tempo fecha o trecho e o `。` chega no run
                // seguinte, sozinho. Virando trecho próprio ele é descartado
                // adiante por `hasContent`, e o fim de frase desaparece — no
                // vídeo de 9 minutos em japonês eram 4 de 98.
                if !SentenceSplitter.hasContent(clean), let last = pieces.popLast() {
                    pieces.append(TimedText(
                        text: last.text + clean, start: last.start, end: max(last.end, end)
                    ))
                } else {
                    pieces.append(TimedText(text: clean, start: start, end: max(end, start)))
                }
            }
            text = ""
            start = nil
        }

        for run in result.text.runs {
            let piece = String(result.text[run.range].characters)
            guard let range = run.audioTimeRange else {
                text += piece          // pontuação costuma vir sem tempo
                continue
            }
            // Pausa longa é fronteira natural.
            if start != nil, range.start.seconds - end > 0.5 { close() }
            if start != nil, range.end.seconds - range.start.seconds >= 2.0 { close() }
            // Troca de voz também, e esta não se vê no áudio: sem ela, a
            // última palavra de quem entrou fica no trecho de quem saiu.
            //
            // Cada palavra vai para o lado da fronteira em que está o seu
            // **meio**, e o trecho fecha quando esse lado muda. Comparar
            // contra o início ou o fim da palavra não serve: a fronteira vem
            // de um modelo por quadro e erra ±100 ms contra o tempo da
            // palavra, então o corte caía uma palavra tarde e o "E" de
            // "Entendi" ficava no trecho da outra pessoa. O meio é o ponto
            // que tolera esse desencontro.
            let lado = Self.side(of: (range.start.seconds + range.end.seconds) / 2,
                                in: boundaries)
            if start != nil, lado != currentSide { close() }
            currentSide = lado
            if let aberto = start, range.end.seconds - aberto >= Self.hardCeiling { close() }
            if start == nil { start = range.start.seconds }
            text += piece
            end = range.end.seconds

            let endsSentence = piece.trimmingCharacters(in: .whitespaces).last
                .map { SentenceSplitter.sentenceEnders.contains($0) } ?? false
            if endsSentence { close(); continue }

            // O fecho por tempo espera um lugar seguro para cortar.
            //
            // Em inglês cada run do sistema é uma palavra inteira, com o
            // espaço junto, e cortar no teto cai entre palavras. Em japonês
            // os runs são sub-palavra e o corte parte a palavra ao meio:
            // `今日` saía como `…はい今` / `日から…`, `もちろん` como
            // `…はいもち` / `ろんです。`. Eram 21 dos 133 trechos do vídeo de
            // 9 minutos (16%), contra 3 de 54 no inglês — o texto quebrado
            // chegava assim ao tradutor.
            //
            // Lugar seguro é onde o texto já terminou: espaço (inglês) ou
            // pontuação de frase ou de oração (os dois). Passado o teto duro
            // o corte sai de qualquer jeito, senão uma fala corrida sem
            // pontuação cresceria sem limite.
            let span = end - (start ?? end)
            if span >= Self.softCeiling, Self.isSafeBreak(text) { close() }
            else if span >= Self.hardCeiling { close() }
        }
        close()

        if pieces.isEmpty {
            let whole = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !whole.isEmpty {
                pieces.append(TimedText(
                    text: whole, start: result.range.start.seconds, end: result.range.end.seconds
                ))
            }
        }
        return pieces
    }

    /// A partir daqui o trecho já está grande e fecha no primeiro lugar
    /// seguro. Era o teto único de 5 s, que fechava onde estivesse.
    static let softCeiling: Double = 5

    /// E daqui não espera mais. Sete segundos porque é o teto da legenda
    /// (`SubtitleFileBuilder.maximumDuration`): acima disso o trecho viraria
    /// uma legenda que passa do tempo de leitura.
    static let hardCeiling: Double = 7

    /// Dá para cortar aqui sem partir palavra?
    ///
    /// Espaço no fim é fronteira de palavra em inglês — o sistema entrega o
    /// espaço junto do run. Em japonês não há espaço, e o que sobra é a
    /// pontuação, de frase ou de oração (`、` inclusive).
    static func isSafeBreak(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last.isWhitespace
            || SentenceSplitter.sentenceEnders.contains(last)
            || SentenceSplitter.clauseEnders.contains(last)
    }

    /// Em qual intervalo entre fronteiras cai um instante.
    ///
    /// Sem fronteiras dá sempre zero, e aí `phrases` se comporta como antes.
    static func side(of time: Double, in boundaries: [TimeInterval]) -> Int {
        boundaries.reduce(into: 0) { count, limite in
            if limite <= time { count += 1 }
        }
    }

    // MARK: Áudio

    private static let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    /// Converte para o formato que o sistema pede, em pedaços de 10 s — assim
    /// ele começa a reconhecer antes de o áudio inteiro estar convertido.
    private static func convert(_ samples: [Float], to target: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        let converter: AVAudioConverter?
        if target == sourceFormat {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: sourceFormat, to: target) else {
                throw MeasuredError.audioFormat
            }
            converter = made
        }

        let chunkFrames = 160_000
        var output: [AVAudioPCMBuffer] = []
        var start = 0
        while start < samples.count {
            let end = min(start + chunkFrames, samples.count)
            let count = end - start
            guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count))
            else { throw MeasuredError.audioFormat }
            input.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                input.floatChannelData![0].update(from: source.baseAddress! + start, count: count)
            }

            guard let converter else {
                output.append(input)
                start = end
                continue
            }

            let capacity = AVAudioFrameCount(Double(count) * target.sampleRate / 16_000) + 1024
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
            else { throw MeasuredError.audioFormat }
            let isLast = end == samples.count
            var supplied = false
            var failure: NSError?
            converter.convert(to: converted, error: &failure) { _, status in
                if supplied {
                    status.pointee = isLast ? .endOfStream : .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return input
            }
            if let failure { throw failure }
            output.append(converted)
            start = end
        }
        return output
    }
}

// MARK: - Idiomas

/// Quais idiomas o reconhecimento da Apple oferece e quais já estão no Mac.
///
/// Compartilhado entre o menu e a janela de legendas: instalar num lugar tem
/// que aparecer no outro.
@MainActor
@Observable
public final class MeasuredLanguages {

    public static let shared = MeasuredLanguages()

    public private(set) var supported: [Language] = []
    public private(set) var installed: [Language] = []
    public private(set) var installing: Language?
    public private(set) var installProgress: Double = 0
    public private(set) var lastError: String?

    /// Os que dá para instalar pelo botão +.
    public var installable: [Language] { supported.filter { !installed.contains($0) } }

    public func refresh() async {
        guard #available(macOS 26.0, *) else { return }
        var supported: [Language] = []
        var installed: [Language] = []
        for language in Language.allCases {
            guard let locale = await MeasuredLocales.locale(for: language) else { continue }
            supported.append(language)
            if await MeasuredLocales.isInstalled(locale) { installed.append(language) }
        }
        self.supported = supported
        self.installed = installed
    }

    /// Baixa o idioma pelo sistema. Devolve verdadeiro quando ele ficou
    /// instalado.
    @discardableResult
    public func install(_ language: Language) async -> Bool {
        guard #available(macOS 26.0, *), installing == nil else { return false }
        installing = language
        installProgress = 0
        lastError = nil
        defer { installing = nil }

        do {
            guard let locale = await MeasuredLocales.locale(for: language) else {
                throw MeasuredError.unsupported(language)
            }
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                let observation = request.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in self?.installProgress = fraction }
                }
                defer { observation.invalidate() }
                try await request.downloadAndInstall()
            }
            await refresh()
            return installed.contains(language)
        } catch {
            lastError = "Não foi possível instalar \(language.displayName): \(error.localizedDescription)"
            return false
        }
    }
}

public enum MeasuredError: LocalizedError {
    case unsupported(Language)
    case notInstalled(Language)
    case audioFormat

    public var errorDescription: String? {
        switch self {
        case let .unsupported(language):
            "O reconhecimento da Apple não cobre \(language.displayName). Escolha Parakeet / Whisper no seletor de reconhecimento."
        case let .notInstalled(language):
            "\(language.displayName) ainda não está instalado no reconhecimento da Apple. Use o botão + ao lado do idioma."
        case .audioFormat:
            "Não foi possível converter o áudio para o formato do reconhecimento da Apple."
        }
    }
}
