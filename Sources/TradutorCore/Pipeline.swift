import AudioCapture
import Foundation
import Observation
import OSLog

/// Liga captura, reconhecimento e traducao, e publica nas tres zonas.
///
/// A bifurcacao esta em `drain`: o parcial vai direto para a zona vermelha sem
/// passar pela traducao, e so o segmento fechado pelo detector de voz segue
/// para o tradutor. Sem isso a tela pisca.
@MainActor
@Observable
public final class Pipeline {

    public enum State: Equatable {
        case idle
        case loading(String, Double)
        case running
        case failed(String)
    }

    private let log = Logger(subsystem: "app.tradutor", category: "Pipeline")

    public private(set) var state: State = .idle
    public let subtitles = SubtitleStore()

    public var sourceLanguage: Language = .english
    public var targetLanguage: Language = .portuguese

    /// Qual reconhecimento usar, ao vivo e em vídeo. Lembrado entre execuções.
    public var recognitionEngine: RecognitionEngine =
        RecognitionEngine(rawValue: UserDefaults.standard.string(forKey: "motorDeReconhecimento") ?? "")
        ?? .preferred {
        didSet { UserDefaults.standard.set(recognitionEngine.rawValue, forKey: "motorDeReconhecimento") }
    }

    /// Quem traduz, ao vivo e em vídeo. **Todos valem nos dois**, a pedido:
    /// antes o ao vivo trocava a escolha pela Apple por causa do custo, e quem
    /// escolheu DeepL recebia outra coisa sem saber. Ver `liveCostNote`.
    public var translationEngine: TranslationEngine = TranslatorFactory.preferred {
        didSet { UserDefaults.standard.set(translationEngine.rawValue, forKey: "motorDeTraducao") }
    }

    /// Identificar quem fala nas legendas de vídeo. Só vídeo: ao vivo não há
    /// áudio inteiro para agrupar as vozes.
    public var diarizeSpeakers: Bool = UserDefaults.standard.bool(forKey: "identificarLocutores") {
        didSet { UserDefaults.standard.set(diarizeSpeakers, forKey: "identificarLocutores") }
    }

    /// Qual modelo identifica quem fala.
    public var speakerModel: SpeakerDiarizer.Model =
        SpeakerDiarizer.Model(rawValue: UserDefaults.standard.string(forKey: "modeloDeLocutor") ?? "")
        ?? .sortformer
    {
        didSet { UserDefaults.standard.set(speakerModel.rawValue, forKey: "modeloDeLocutor") }
    }

    /// Uma cor por locutor, na janela e no `.srt` exportado.
    public var colorBySpeaker: Bool = UserDefaults.standard.bool(forKey: "coresPorLocutor") {
        didSet { UserDefaults.standard.set(colorBySpeaker, forKey: "coresPorLocutor") }
    }

    /// Lista e selecao vivem aqui, e nao no delegate do app, porque precisam
    /// ser observaveis: gravadas numa propriedade comum, a escolha do Picker
    /// era aceita mas a view nao redesenhava, e o seletor voltava sozinho
    /// para "Escolha um aplicativo".
    public private(set) var availableProcesses: [AudioProcess] = []
    public var selectedProcess: AudioProcess?

    /// Microfones que a máquina tem agora.
    public private(set) var availableInputs: [AudioInputDevice] = []

    /// Qual microfone usar. `nil` é o padrão do sistema — e continua sendo a
    /// escolha certa quando o usuário troca de fone no meio da reunião, porque
    /// o padrão acompanha e um ID gravado não.
    public var selectedInputDevice: AudioInputDevice?

    /// Pausa temporária: a captura continua de pé, o áudio é descartado.
    ///
    /// Parar e religar custaria o tap, o aggregate device e uma volta pelo
    /// Core Audio; o que o usuário quer ao pausar é voltar no instante em que
    /// clicar de novo.
    public private(set) var isPaused = false


    /// Medicoes reais da maquina, mostradas nas preferencias. O plano diz para
    /// medir em vez de confiar na estimativa; isto e o que mede.
    public private(set) var lastTranscribeMs: Int = 0
    public private(set) var lastTranslateMs: Int = 0
    /// Nomes dos motores que estão carregados, ou que serão usados ao iniciar.
    /// O fallback evita que o cabeçalho fique vazio durante o carregamento.
    public var engineNames: String {
        let recognition = transcriber?.engineName
            ?? TranscriberFactory.make(
                for: sourceLanguage, engine: recognitionEngine.forLive
            ).engineName
        let translation = translationEngine == .transcriptionOnly
            ? translationEngine.displayName
            : translator?.engineName ?? translationEngine.displayName
        return "\(recognition)  ·  \(translation)"
    }

    private var tap: ProcessTap?
    private var microphone: MicrophoneTap?
    private var ring: RingBuffer?
    private var resampler: Resampler?
    private var segmenter: Segmenter?
    /// Os reconhecedores ficam residentes depois de carregados. Carregar
    /// custa segundos; guardar custa memoria que a maquina tem. Trocar de
    /// idioma dentro do mesmo motor nao recarrega nada, e voltar para um
    /// motor ja usado tambem nao.
    private var engines: [TranscriberKind: Transcriber] = [:]
    private var transcriber: Transcriber?
    private var translator: (any Translator)?
    /// Com que motor o `translator` foi feito. Sem isto, trocar a escolha
    /// para "só transcrever" no meio da sessão não mudava nada: o tradutor
    /// só era criado quando ainda não existia nenhum.
    private var loadedTranslator: TranslationEngine?
    /// Ultimo texto reconhecido, para descontar a sobreposicao do proximo.
    private var previousSource = ""
    private var tracker = StablePrefixTracker()
    private var phrases = PhraseAccumulator()
    /// Impede duas transcricoes simultâneas do mesmo trecho.
    private var rehearsing = false

    /// Texto cru de cada segmento, antes de qualquer limpeza.
    ///
    /// Guardado porque o que chega a tela ja passou por deduplicacao e corte
    /// em frases: sem o cru nao da para saber qual das etapas errou.
    public private(set) var rawTranscripts: [String] = []
    private var pumpTask: Task<Void, Never>?
    private var loadedFor: Language?

    /// Fila de segmentos esperando reconhecimento e traducao.
    ///
    /// Antes isto era uma corrente de `Task` encadeadas, cada uma esperando a
    /// anterior. Se traduzir custasse mais que o intervalo entre segmentos, a
    /// corrente crescia e NUNCA drenava: o atraso aumentava a sessao inteira
    /// ate o usuario estar lendo o que foi dito minutos antes. Com fila
    /// explicita da para limitar o tamanho e descartar o que ja envelheceu.
    private var queue: [String] = []
    private var worker: Task<Void, Never>?

    /// Acima disso, o mais antigo e descartado. Legenda atrasada demais nao
    /// tem valor — melhor pular do que empurrar o atraso para frente.
    /// Fala longa rende muitas oracoes seguidas; com teto de 3 elas eram
    /// descartadas antes de chegar a tela.
    private let maximumBacklog = 12
    public private(set) var droppedSegments = 0

    /// O que a última tradução disse ao falhar, ou `nil`.
    ///
    /// Sem tradutor de reserva — a mesma regra do vídeo —, um bloco que o
    /// DeepL recuse some da tela. Calado, isso parece silêncio do falante.
    public private(set) var translationError: String?

    public init() {}

    /// Recarrega a lista de aplicativos, preservando a escolha atual.
    public func refreshProcesses() {
        availableInputs = AudioInputList.all()
        if let selected = selectedInputDevice, !availableInputs.contains(selected) {
            selectedInputDevice = nil
        }
        availableProcesses = [.systemWide, .microphone] + ((try? AudioProcessList.all()) ?? [])
        // A selecao so cai quando o aplicativo escolhido sumiu de verdade.
        if let current = selectedProcess, !availableProcesses.contains(current) {
            selectedProcess = nil
        }
    }

    /// Verdadeiro quando os modelos ja estao na memoria e ligar e imediato.
    public var isWarm: Bool {
        transcriber?.isPrepared == true && translator != nil
    }

    /// Quanto os modelos ocupam em disco.
    public var modelDiskUsage: String {
        let bytes = ModelStorage.diskUsageBytes()
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: - Ciclo de vida

    public func start(on process: AudioProcess) async {
        guard !isRunning else { return }

        do {
            try await loadModelsIfNeeded()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        let ring = RingBuffer()
        let rate: Double
        if process.isMicrophone {
            guard await MicrophoneTap.requestAccess() else {
                state = .failed(
                    "O Tradutor precisa de acesso ao microfone. "
                    + "Ajustes do Sistema › Privacidade e Segurança › Microfone."
                )
                return
            }
            let mic = MicrophoneTap(device: selectedInputDevice)
            do {
                try mic.start { samples in ring.write(samples) }
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
            rate = mic.sampleRate ?? 48_000
            self.microphone = mic
        } else {
            let tap = ProcessTap(process: process)
            do {
                try tap.start { samples in ring.write(samples) }
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
            rate = tap.format?.mSampleRate ?? 48_000
            self.tap = tap
        }

        do {
            resampler = try Resampler(inputSampleRate: rate)
        } catch {
            tap?.stop()
            microphone?.stop()
            tap = nil
            microphone = nil
            state = .failed(error.localizedDescription)
            return
        }

        self.ring = ring
        self.segmenter = Segmenter()
        translator?.reset()
        previousSource = ""
        rawTranscripts.removeAll()
        tracker.reset()
        _ = phrases.flush()
        subtitles.clear()
        state = .running

        droppedSegments = 0
        isPaused = false
        queue.removeAll()
        pumpTask = Task { [weak self] in await self?.pump() }
        worker = Task { [weak self] in await self?.drainQueue() }
        log.info("pipeline rodando em \(process.name, privacy: .public)")
    }

    /// Pausa e retoma sem soltar a captura.
    ///
    /// O trecho em andamento é **descartado** ao pausar, não guardado: retomar
    /// dez minutos depois e ver sair a meia frase de antes da pausa seria pior
    /// que perdê-la. O que já foi confirmado fica na tela.
    public func togglePause() {
        guard isRunning else { return }
        isPaused.toggle()
        guard isPaused else { return }
        _ = segmenter?.flush()
        tracker.reset()
        _ = phrases.flush()
        subtitles.setPartial("")
    }

    /// Para a captura. Os modelos continuam carregados de proposito: religar
    /// tem que ser imediato.
    public func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        worker?.cancel()
        worker = nil
        queue.removeAll()
        tap?.stop()
        tap = nil
        microphone?.stop()
        microphone = nil
        isPaused = false
        // A janela do DeepL e o servidor do Hunyuan não se fecham sozinhos, e
        // este app fica aberto o dia todo na barra de menus. A Apple fica —
        // ela não custa nada parada, e soltá-la apagaria o "modelos
        // carregados" do painel sem motivo.
        if let loaded = loadedTranslator, !loaded.isInstantaneous {
            translator?.reset()
            translator = nil
            loadedTranslator = nil
        }
        ring = nil
        resampler = nil
        segmenter = nil
        subtitles.setPartial("")
        state = .idle
    }

    // MARK: - Modelos

    /// Carrega os modelos sem iniciar captura. Chamado na abertura do app,
    /// para que o primeiro ⌥⌘T nao espere pelo disco.
    public func preload() async {
        // Tradutor de rede ou de modelo residente fica de fora: ele só nasce
        // quando alguém manda traduzir. Ver `TranslationEngine.isInstantaneous`.
        try? await loadModelsIfNeeded(includingTranslator: translationEngine.isInstantaneous)
        if case .loading = state { state = .idle }
    }

    private func loadModelsIfNeeded(includingTranslator: Bool = true) async throws {
        // O motor depende da escolha e do idioma de origem: nos modelos,
        // portugues usa Parakeet e japones usa Whisper. Trocar entre dois
        // idiomas do mesmo motor nao recarrega nada.
        let kind = TranscriberKind(for: sourceLanguage, engine: recognitionEngine.forLive)
        let engine: Transcriber
        if let cached = engines[kind] {
            engine = cached
        } else {
            engine = TranscriberFactory.make(for: sourceLanguage, engine: recognitionEngine.forLive)
            engines[kind] = engine
        }
        engine.language = sourceLanguage
        if !engine.isPrepared {
            try await engine.prepare { [weak self] fraction, label in
                Task { @MainActor in self?.state = .loading(label, fraction * 0.5) }
            }
        }
        transcriber = engine
        loadedFor = sourceLanguage

        let wanted = translationEngine
        if includingTranslator, translator == nil || loadedTranslator != wanted {
            translator?.reset()
            let engine = TranslatorFactory.make(wanted)
            try await engine.prepare { [weak self] fraction, label in
                Task { @MainActor in self?.state = .loading(label, 0.5 + fraction * 0.5) }
            }
            translator = engine
            loadedTranslator = wanted
        }
        translationError = nil
    }

    // MARK: - Laco

    /// Com que frequencia o trecho em andamento e re-reconhecido.
    ///
    /// Cada passada custa uma transcricao do trecho inteiro. O Parakeet roda a
    /// ~120x tempo real, entao 0,6 s e folgado; o Whisper e bem mais lento,
    /// por isso o intervalo dobra quando ele esta no comando.
    private var rehearsalInterval: TimeInterval {
        TranscriberKind(for: sourceLanguage, engine: recognitionEngine.forLive) == .whisper ? 1.2 : 0.6
    }

    private func pump() async {
        var scratch = [Float](repeating: 0, count: 48_000)
        var lastRehearsal = Date.distantPast

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            guard let ring, let resampler, let segmenter else { continue }

            let count = ring.read(into: &scratch, maximum: scratch.count)
            // Pausado, o anel continua sendo esvaziado e o que sai é jogado
            // fora. Deixar de ler encheria o anel e, ao retomar, os primeiros
            // segundos seriam áudio de minutos atrás.
            if isPaused {
                lastRehearsal = Date()
                continue
            }
            if count > 0 {
                if let converted = try? resampler.resample(Array(scratch[0..<count])) {
                    // Uma pausa real e o unico corte de audio que continua
                    // existindo: ali nao ha palavra sendo partida.
                    for segment in segmenter.feed(converted) {
                        await finishUtterance(segment.samples)
                    }
                }
            }

            // Enquanto a fala corre, o trecho em andamento e re-reconhecido
            // inteiro. Nada de cortar audio no meio de palavra.
            if segmenter.isSpeaking,
               !rehearsing,
               Date().timeIntervalSince(lastRehearsal) > rehearsalInterval {
                lastRehearsal = Date()
                let inFlight = segmenter.inFlight
                if inFlight.count > 8_000 {  // meio segundo de fala
                    await rehearse(inFlight)
                }
            }
        }
    }

    /// Uma passada de reconhecimento sobre o trecho em andamento.
    private func rehearse(_ samples: [Float]) async {
        guard let transcriber else { return }
        rehearsing = true
        defer { rehearsing = false }

        let started = Date()
        guard let hypothesis = try? await transcriber.transcribe(samples),
              !hypothesis.isEmpty
        else { return }
        lastTranscribeMs = Int(Date().timeIntervalSince(started) * 1000)

        let newlyConfirmed = tracker.feed(hypothesis)
        subtitles.setPartial(Tokens.join(tracker.pending))

        guard !newlyConfirmed.isEmpty else { return }
        for phrase in phrases.append(newlyConfirmed) {
            enqueuePhrase(phrase)
        }
    }

    /// A fala terminou de verdade: o que sobrou nao vai mudar mais.
    private func finishUtterance(_ samples: [Float]) async {
        // Uma ultima passada sobre o trecho completo, que agora inclui o
        // silencio final e costuma sair melhor que as intermediarias.
        var remaining: [String]
        if let transcriber, let hypothesis = try? await transcriber.transcribe(samples),
           !hypothesis.isEmpty {
            remaining = tracker.reconcile(hypothesis)
        } else {
            remaining = tracker.flush()
        }
        var closed = phrases.append(remaining)
        if let leftover = phrases.flush() { closed.append(leftover) }

        tracker.reset()
        subtitles.setPartial("")
        for phrase in closed { enqueuePhrase(phrase) }
    }

    private func enqueuePhrase(_ phrase: String) {
        guard SentenceSplitter.hasContent(phrase) else { return }
        queue.append(phrase)
        while queue.count > maximumBacklog {
            queue.removeFirst()
            droppedSegments += 1
            log.warning("fila cheia, segmento descartado (total: \(self.droppedSegments))")
        }
    }

    /// Consome a fila em ordem — fora de ordem, o historico de dialogo perde
    /// sentido e a legenda aparece embaralhada.
    private func drainQueue() async {
        while !Task.isCancelled {
            guard !queue.isEmpty else {
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            let phrase = queue.removeFirst()
            await translateAndCommit(phrase)
        }
    }

    /// Recebe texto ja definitivo e cuida so da traducao e da exibicao.
    private func translateAndCommit(_ phrase: String) async {
        guard let translator else { return }

        rawTranscripts.append(phrase)
        if rawTranscripts.count > 40 { rawTranscripts.removeFirst() }

        // Rede de seguranca: o reconhecedor as vezes repete o fim da frase
        // anterior no comeco da seguinte.
        let deduplicated = OverlapTrimmer.dropRepeatedPrefix(phrase, after: previousSource)
        previousSource = phrase

        let sentences = SentenceSplitter.split(deduplicated)
        guard !sentences.isEmpty else { return }

        subtitles.beginTranslating()

        let startTranslate = Date()
        let translations: [String]
        do {
            translations = try await translator.translate(
                sentences, from: sourceLanguage, to: targetLanguage
            )
        } catch {
            log.error("traducao falhou: \(error.localizedDescription, privacy: .public)")
            translationError = error.localizedDescription
            subtitles.endTranslating()
            return
        }
        translationError = nil
        lastTranslateMs = Int(Date().timeIntervalSince(startTranslate) * 1000)

        for (sentence, translated) in zip(sentences, translations)
        where SentenceSplitter.hasContent(translated) {
            subtitles.commit(SubtitleBlock(source: sentence, translated: translated))
        }
    }
}
