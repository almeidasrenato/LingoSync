import AVFoundation
import Foundation
import Observation
import TradutorCore

/// Estado da janela de legendas: o vídeo, as legendas geradas e onde a
/// reprodução está agora.
@MainActor
@Observable
final class SubtitleStudioModel {

    enum Stage: Equatable {
        case empty
        case ready                      // vídeo escolhido, legenda ainda não
        case working(Step)
        case done
        case failed(String)
        case cancelled
    }

    /// Cada etapa do trabalho, com o quanto dela já foi feito.
    ///
    /// Uma barra só, subindo de 0 a 1, não diz nada quando o passo demora
    /// minutos. Saber em qual dos quatro passos está, quanto tempo já passou e
    /// quanto falta transforma a espera em algo previsível.
    struct Step: Equatable {
        typealias Kind = GenerationStep

        var kind: Kind
        /// Progresso dentro do passo, de 0 a 1.
        var withinStep: Double = 0
        var detail: String = ""
        /// Requisição no ar, sem passos intermediários para relatar.
        var waiting: Bool = false
        var startedAt: Date = Date()
        /// Só a tradução está rodando: a barra vai de 0 a 1 nela, em vez de
        /// começar nos 48% que a tradução ocupa numa geração inteira.
        var translationOnly = false

        var overall: Double {
            let bruto = kind.overall(withinStep)
            guard translationOnly else { return bruto }
            let base = GenerationStep.loadingTranslator.share.lowerBound
            return (bruto - base) / (1 - base)
        }
    }

    private(set) var stage: Stage = .empty
    private(set) var videoURL: URL?
    private(set) var cues: [Cue] = []
    /// Índice da legenda que está sendo falada agora, ou `nil` no silêncio.
    private(set) var activeIndex: Int?
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var savedSRT: URL?
    private(set) var loadedFromFile = false

    /// O que produziu as legendas que estão na tela agora.
    ///
    /// São os motores que **rodaram**, não os que estão nos seletores: trocar
    /// o seletor não muda a legenda que já saiu, e `TranscriberKind` ainda
    /// manda o Parakeet para o Whisper em idioma que ele não cobre.
    struct Origin: Equatable {
        var recognition: String
        var translation: String
    }
    private(set) var origin: Origin?

    /// Verdadeiro enquanto as legendas na tela são um resultado parcial.
    ///
    /// Retraduzir não conta: ali a tela continua com a tradução anterior
    /// inteira até a nova ficar pronta.
    var isPartial: Bool { isWorking && !cues.isEmpty && !retranslating }
    /// Quando o trabalho atual começou, para mostrar tempo decorrido e
    /// estimativa de quanto falta.
    private(set) var jobStartedAt: Date?
    private(set) var elapsed: TimeInterval = 0

    var sourceLanguage: Language = .japanese
    var targetLanguage: Language = .portuguese
    /// Começa com o do menu; trocar aqui vale só para esta janela.
    var recognitionEngine: RecognitionEngine = .preferred
    /// Quem traduz. Também começa com o do menu e vale só para esta janela.
    var translationEngine: TranslationEngine = TranslatorFactory.preferred
    /// Identificar quem fala. Copiado do painel ao abrir a janela, como os
    /// idiomas.
    var diarizeSpeakers = false
    var speakerModel: SpeakerDiarizer.Model = .sortformer
    /// Uma cor por locutor, na lista, no vídeo e no `.srt` exportado.
    var colorBySpeaker = true

    /// O builder da última geração, vivo para poder retraduzir.
    ///
    /// Guarda o rascunho — as legendas antes de traduzir — e o tradutor em
    /// uso. Sem ele, trocar de tradutor exigiria reconhecer o áudio de novo.
    private var builder: SubtitleFileBuilder?
    private var retranslating = false

    /// Dá para traduzir de novo sem reconhecer nada?
    ///
    /// Legenda aberta de arquivo não dá: o `SRTParser` põe o texto em
    /// `translated` e deixa `source` vazio — não há original para traduzir.
    var canRetranslate: Bool {
        !isWorking && !loadedFromFile && !(builder?.draft.isEmpty ?? true)
    }

    private(set) var player: AVPlayer?
    private var timeObserver: Any?
    /// Quem avisa que o vídeo chegou ao fim.
    private var endObserver: (any NSObjectProtocol)?
    private var job: Task<Void, Never>?
    private var clock: Timer?
    /// Apelido `.mp4` mantido vivo enquanto o vídeo estiver aberto.
    private var playableAlias: URL?

    var canGenerate: Bool {
        guard videoURL != nil else { return false }
        return !isWorking
    }

    /// A mensagem da falha, quando houve uma. É o que a faixa vermelha mostra.
    var failureMessage: String? {
        if case let .failed(message) = stage { return message }
        return nil
    }

    /// Tenta de novo o que falhou.
    ///
    /// Quando o rascunho do reconhecimento está de pé — que é o caso quando
    /// quem falhou foi a tradução — refaz **só** a tradução: reconhecer de
    /// novo custa minutos e daria o mesmo texto. Sem rascunho, refaz tudo.
    func retryFailed() {
        if canRetranslate { retranslate() } else { generate() }
    }

    var isWorking: Bool {
        if case .working = stage { return true }
        return false
    }

    /// Quanto falta, estimado pelo ritmo até agora. Só aparece depois de haver
    /// progresso suficiente para a conta valer alguma coisa.
    var estimatedRemaining: TimeInterval? {
        guard case let .working(step) = stage, elapsed > 4, step.overall > 0.05 else { return nil }
        return elapsed / step.overall - elapsed
    }

    var videoName: String { videoURL?.lastPathComponent ?? "Nenhum vídeo escolhido" }

    /// Nome sugerido na hora de exportar: o do vídeo com o idioma no meio,
    /// que é a convenção que os players usam para achar a legenda sozinhos.
    var suggestedSRTName: String {
        guard let videoURL else { return "legenda.\(targetLanguage.rawValue).srt" }
        return videoURL.deletingPathExtension().lastPathComponent
            + ".\(targetLanguage.rawValue).srt"
    }

    private(set) var exportError: String?

    /// O que o tradutor avisou no fim da última geração, ou `nil`.
    ///
    /// Hoje só o DeepL avisa: bloco que o site recusa é traduzido pela Apple,
    /// e sem isto a legenda trocava de qualidade no meio do arquivo sem
    /// explicação nenhuma.
    private(set) var notice: String?

    /// A legenda como ela sai no arquivo, travessão incluído.
    ///
    /// A janela mostrava só a cor e o `.srt` saía com travessão: quem assistia
    /// para conferir antes de exportar via uma legenda diferente da que ia
    /// sair — e o travessão muda a largura da linha, que é onde a quebra de 42
    /// caracteres decide o corte.
    /// Largura da linha, pelo idioma de destino.
    ///
    /// A janela tem de mostrar a legenda com a mesma largura com que ela vai
    /// ser gravada: quem assiste para conferir antes de exportar precisa ver o
    /// que vai sair. Com o 42 fixo e destino japonês, a janela mostrava em 42
    /// e o arquivo saía em 20 — a mesma divergência que o travessão já causou
    /// uma vez, e pelo mesmo motivo.
    var charactersPerLine: Int { SubtitleFileBuilder.lineWidth(for: targetLanguage) }

    /// A legenda repartida em linhas, como a janela mostra e como o arquivo
    /// grava.
    ///
    /// Mora aqui, e não na view, de propósito: enquanto a view tinha a própria
    /// largura, ela podia ficar para trás sem nada acusar — e ficou, com o 42
    /// fixo depois que o arquivo passou a usar 20 em japonês. Sem largura na
    /// view não há o que divergir, e o autoteste confere esta função, que é a
    /// mesma que desenha.
    func displayLines(at index: Int) -> [String] {
        LineBreaker.wrap(displayText(at: index), maximum: charactersPerLine)
    }

    func displayText(at index: Int) -> String {
        guard cues.indices.contains(index) else { return "" }
        let cue = cues[index]
        let texto = cue.translated.isEmpty ? cue.source : cue.translated
        // Último locutor conhecido, pulando os trechos sem dono — é a mesma
        // regra do arquivo, em `SpeakerMark`.
        let anterior = cues[..<index].last(where: { $0.speaker != nil })?.speaker
        return SpeakerMark.decorate(texto, speaker: cue.speaker, previous: anterior)
    }

    /// Grava as legendas onde o usuário escolher.
    func export(to url: URL) {
        exportError = nil
        do {
            try SRTWriter.render(
                cues, colorBySpeaker: diarizeSpeakers && colorBySpeaker,
                charactersPerLine: charactersPerLine
            ).write(to: url, atomically: true, encoding: .utf8)
            savedSRT = url
        } catch {
            exportError = error.localizedDescription
        }
    }

    // Sem `deinit` de propriedade isolada: a limpeza acontece em `stop()`, e
    // a janela chama isso ao fechar. Tocar em `player` no deinit nao compila
    // sob concorrencia estrita, e o observador ja e removido la.

    // MARK: - Vídeo

    func open(_ url: URL) {
        stop()
        videoURL = url
        cues = []
        activeIndex = nil
        savedSRT = nil
        loadedFromFile = false
        origin = nil
        builder?.finish()
        builder = nil
        stage = .ready

        // Do vídeo anterior não sobra tempo nem duração: com um arquivo que
        // nem carrega, a barra continuava mostrando a posição do outro.
        currentTime = 0
        duration = 0

        // Toca direto; se o nome não tiver extensão, um apelido `.mp4` entra
        // no lugar. Sem isso a janela ficava preta para o mesmo arquivo que a
        // geração de SRT aceitava sem reclamar.
        let player = AVPlayer(url: url)
        // Volume e mudo são do usuário, não do arquivo: um player novo nasce
        // em 1 e sem mudo, e quem tinha silenciado levava o susto ao abrir o
        // vídeo seguinte. `swapPlayer` já fazia isso; abrir, não.
        player.volume = volume
        player.isMuted = isMuted
        self.player = player

        Task { [weak self] in
            guard let alias = await SubtitleFileBuilder.playableAlias(for: url) else { return }
            await MainActor.run {
                guard let self, self.videoURL == url else { return }
                self.playableAlias = alias
                self.swapPlayer(to: alias)
                // A duração também tem que sair do apelido: lida do arquivo
                // sem extensão ela vinha zero, e sem duração a barra e o
                // limite de busca não funcionam.
                self.loadDuration(from: alias)
            }
        }

        installTimeObserver(on: player)

        loadDuration(from: url)
    }

    private func loadDuration(from url: URL) {
        // A carga do vídeo anterior pode terminar depois de abrir o próximo,
        // inclusive o mesmo URL outra vez. A identidade do player distingue
        // cada abertura; comparar apenas o caminho não fecha essa corrida.
        guard let expectedPlayer = player else { return }
        Task { [weak self] in
            let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
            guard let seconds, seconds.isFinite, seconds > 0 else { return }
            await MainActor.run {
                guard let self, self.player === expectedPlayer else { return }
                self.duration = seconds
            }
        }
    }

    /// Troca a fonte do player preservando onde a reprodução estava.
    private func swapPlayer(to url: URL) {
        let wasPlaying = isPlaying
        let position = currentTime

        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()

        let replacement = AVPlayer(url: url)
        replacement.volume = volume
        replacement.isMuted = isMuted
        player = replacement
        installTimeObserver(on: replacement)
        if position > 0 {
            replacement.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        }
        if wasPlaying { replacement.play() }
    }

    func stop() {
        job?.cancel()
        job = nil
        builder?.finish()
        clock?.invalidate()
        clock = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false

        if let playableAlias {
            try? FileManager.default.removeItem(
                at: playableAlias.deletingLastPathComponent()
            )
        }
        playableAlias = nil
    }

    private func installTimeObserver(on player: AVPlayer) {
        // Uma vez por décimo de segundo é o suficiente para trocar a legenda
        // no tempo certo sem acordar a interface à toa.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(seconds: time.seconds)
            }
        }

        // No fim do vídeo o player para sozinho: sem isto `isPlaying`
        // continuava verdadeiro, o botão dizia "pausar" e o primeiro clique
        // não fazia nada visível.
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    private func tick(seconds: TimeInterval) {
        currentTime = seconds
        activeIndex = index(at: seconds)
    }

    /// Qual legenda cobre este instante. Busca binária porque o observador
    /// dispara dez vezes por segundo.
    private func index(at seconds: TimeInterval) -> Int? {
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let cue = cues[middle]
            if seconds < cue.start {
                high = middle - 1
            } else if seconds > cue.end {
                low = middle + 1
            } else {
                return middle
            }
        }
        return nil
    }

    // MARK: - Reprodução

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
            player.rate = rate
        }
        isPlaying.toggle()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    /// Velocidade de reprodução. Útil para acompanhar fala rápida num idioma
    /// que se está aprendendo.
    var rate: Float = 1.0 {
        didSet {
            guard isPlaying else { return }
            player?.rate = rate
        }
    }

    var volume: Float = 1.0 {
        didSet {
            player?.volume = volume
            // Mexer no volume tira do mudo: é o que o gesto quer dizer.
            if volume > 0, isMuted { isMuted = false }
        }
    }

    var isMuted = false {
        didSet { player?.isMuted = isMuted }
    }

    func toggleMute() { isMuted.toggle() }

    /// Esconde o vídeo e deixa só as legendas.
    ///
    /// Para praticar escuta, a imagem atrapalha mais do que ajuda — e sem ela
    /// a lista ocupa a janela inteira.
    var showsVideo = true

    /// Largura da coluna de legendas. O resto é vídeo, então arrastar o
    /// divisor aumenta um e diminui o outro.
    var listWidth: CGFloat = SubtitleStudioModel.defaultListWidth

    /// 320 cortava a fala em três linhas e obrigava a alargar a cada abertura,
    /// e agora cada linha traz também o original.
    static let defaultListWidth: CGFloat = 400
    /// A lista precisa caber um horário e um trecho de fala; o vídeo precisa
    /// sobrar como vídeo.
    static let minimumListWidth: CGFloat = 240
    static let minimumVideoWidth: CGFloat = 360

    /// O limite do divisor, dada a largura que a janela tem agora.
    ///
    /// Era um teto fixo de 560: numa janela larga o divisor travava no meio do
    /// caminho e parecia defeito. Numa estreita, encolher a janela com a lista
    /// larga deixava o vídeo com alguns pixels.
    static func clampListWidth(_ largura: CGFloat, available: CGFloat) -> CGFloat {
        let teto = available > 0
            ? max(minimumListWidth, available - minimumVideoWidth)
            : 560
        return min(teto, max(minimumListWidth, largura))
    }

    /// Progresso de 0 a 1, para a barra de posição.
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    func seek(toProgress fraction: Double, exact: Bool = true) {
        guard duration > 0 else { return }
        seek(to: fraction * duration, exact: exact)
    }

    /// Tamanho da legenda sobre o vídeo, multiplicando o corpo que já
    /// acompanha a largura. Guardado entre sessões: é preferência de quem
    /// assiste, não do vídeo.
    ///
    /// Chave nova de propósito: o padrão mudou de 100% para 60%, e quem já
    /// tinha 100% gravado na chave antiga não veria a mudança.
    var subtitleScale: Double = UserDefaults.standard.object(forKey: "tamanhoLegenda") as? Double
        ?? SubtitleStudioModel.defaultSubtitleScale {
        didSet { UserDefaults.standard.set(subtitleScale, forKey: "tamanhoLegenda") }
    }

    /// 100% cobria demais a imagem; 60% foi o que o usuário escolheu usando.
    static let defaultSubtitleScale = 0.6
    static let subtitleScaleRange: ClosedRange<Double> = 0.3...2.0

    /// Um passo de 10%: "um pouco", e não um salto que obrigue a voltar.
    func resizeSubtitles(by steps: Int) {
        let next = ((subtitleScale + Double(steps) * 0.1) * 10).rounded() / 10
        subtitleScale = min(Self.subtitleScaleRange.upperBound,
                            max(Self.subtitleScaleRange.lowerBound, next))
    }

    /// - Parameter exact: `false` enquanto se arrasta a barra. Busca exata
    ///   decodifica a partir do quadro-chave anterior a cada evento do mouse,
    ///   e a barra arrastava atrás do cursor; a exata vem no fim do arrasto.
    func seek(to seconds: TimeInterval, exact: Bool = true) {
        guard let player else { return }
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))

        if !exact {
            let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
            player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                        toleranceBefore: tolerance, toleranceAfter: tolerance)
            currentTime = clamped
            activeIndex = index(at: clamped)
            return
        }

        // Tolerância zero: sem isso o player pula para o quadro-chave mais
        // próximo e a legenda escolhida não é a que aparece.
        //
        // Com o vídeo pausado o observador periódico não dispara, então o
        // tempo e a legenda ativa são atualizados aqui na mão — senão clicar
        // numa legenda enquanto pausado movia o vídeo mas não mudava nada na
        // tela. O `completionHandler` garante que o quadro novo já foi
        // desenhado antes de considerarmos a busca terminada.
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            guard finished else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = clamped
                self.activeIndex = self.index(at: clamped)
            }
        }

        currentTime = clamped
        activeIndex = index(at: clamped)
    }

    /// Vai para o começo de uma legenda específica.
    func jump(to index: Int) {
        guard cues.indices.contains(index) else { return }
        // Um pelinho antes do início, para a legenda já estar na tela quando
        // o quadro aparecer.
        seek(to: max(0, cues[index].start + 0.02))
        activeIndex = index
    }

    /// Próxima legenda a partir de onde está — mesmo parado no silêncio entre
    /// duas.
    func jumpToNextCue() {
        guard !cues.isEmpty else { return }
        let next = cues.firstIndex { $0.start > currentTime + 0.05 }
        jump(to: next ?? cues.count - 1)
    }

    func jumpToPreviousCue() {
        guard !cues.isEmpty else { return }
        // Se já passou mais de um segundo da legenda atual, volta para o
        // começo dela em vez de pular para a anterior — é o que um player de
        // música faz, e a expectativa é a mesma.
        if let active = activeIndex, currentTime - cues[active].start > 1.0 {
            jump(to: active)
            return
        }
        let previous = cues.lastIndex { $0.start < currentTime - 0.05 }
        jump(to: previous ?? 0)
    }

    // MARK: - Geração

    func generate() {
        guard let url = videoURL else { return }

        // Regerar começa do zero: manter as legendas antigas na tela enquanto
        // outras estão sendo feitas confunde, e clicar numa delas levaria o
        // vídeo a um tempo que vai deixar de valer.
        job?.cancel()
        cues = []
        activeIndex = nil
        savedSRT = nil
        loadedFromFile = false
        origin = nil

        jobStartedAt = Date()
        elapsed = 0
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let started = self.jobStartedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }

        job = Task { await runGeneration(url) }
    }

    /// Traduz de novo, com o tradutor escolhido agora, sem reconhecer nada.
    ///
    /// O que está na tela **não sai** enquanto a tradução nova é feita, e nem
    /// se ela for cancelada ou falhar: trocar de tradutor não pode custar a
    /// legenda que já estava boa. Por isso as legendas parciais também não
    /// chegam aqui — só a lista pronta, no fim.
    func retranslate() {
        guard canRetranslate, let builder else { return }

        job?.cancel()
        retranslating = true
        jobStartedAt = Date()
        elapsed = 0
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let started = self.jobStartedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
        update(.loadingTranslator)

        job = Task { [weak self] in
            guard let self else { return }
            do {
                let translated = try await builder.retranslate(
                    using: self.translationEngine,
                    from: self.sourceLanguage,
                    to: self.targetLanguage,
                    progress: { [weak self] step, fraction, detail, waiting in
                        Task { @MainActor in self?.advance(step, fraction, detail, waiting) }
                    }
                )
                guard !Task.isCancelled else { return }
                self.cues = translated
                self.notice = builder.translationNotice
                self.origin = Origin(
                    recognition: builder.recognitionName ?? "",
                    translation: builder.translationName ?? ""
                )
                // O arquivo exportado antes não corresponde mais ao que está
                // na tela.
                self.savedSRT = nil
                self.activeIndex = self.index(at: self.currentTime)
                self.finishJob(.done)
            } catch {
                // A tradução anterior continua na tela, inteira.
                self.finishJob(Task.isCancelled ? .cancelled : .failed(error.localizedDescription))
            }
        }
    }

    private func finishJob(_ stage: Stage) {
        retranslating = false
        clock?.invalidate()
        clock = nil
        elapsed = Date().timeIntervalSince(jobStartedAt ?? Date())
        self.stage = stage
    }

    /// Interrompe o trabalho em curso.
    ///
    /// O reconhecimento é uma chamada só, longa e não interrompível — o
    /// cancelamento não a mata no meio; ele garante que o resultado seja
    /// descartado e que nenhuma etapa seguinte comece.
    func cancelGeneration() {
        guard isWorking else { return }
        job?.cancel()
        job = nil
        clock?.invalidate()
        clock = nil
        jobStartedAt = nil
        retranslating = false
        stage = .cancelled
    }

    /// Abre um `.srt` já pronto em vez de gerar.
    func loadSubtitles(from url: URL) {
        do {
            let parsed = try SRTParser.parse(contentsOf: url)
            guard !parsed.isEmpty else {
                stage = .failed("Nenhuma legenda encontrada em \(url.lastPathComponent).")
                return
            }
            job?.cancel()
            job = nil
            cues = parsed
            savedSRT = url
            loadedFromFile = true
            // Legenda de arquivo não tem original: o rascunho que estava aqui
            // não corresponde mais ao que está na tela.
            origin = nil
            activeIndex = index(at: currentTime)
            stage = .done
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    private func update(
        _ kind: Step.Kind, _ within: Double = 0, _ detail: String = "", _ waiting: Bool = false
    ) {
        stage = .working(Step(
            kind: kind, withinStep: within, detail: detail, waiting: waiting,
            translationOnly: retranslating
        ))
    }

    /// Progresso vindo de outra thread. Só vale enquanto trabalha e só para
    /// frente: uma atualização atrasada chegando depois de cancelar punha a
    /// janela de volta em "trabalhando", e uma chegando depois do passo
    /// seguinte fazia a barra andar para trás.
    private func advance(
        _ kind: Step.Kind, _ within: Double, _ detail: String, _ waiting: Bool = false
    ) {
        guard case let .working(step) = stage else { return }
        let order = Step.Kind.allCases
        let current = order.firstIndex(of: step.kind) ?? 0
        let next = order.firstIndex(of: kind) ?? 0
        guard next > current || (next == current && within >= step.withinStep) else { return }
        update(kind, within, detail, waiting)
    }

    private func runGeneration(_ url: URL) async {
        // O anterior encerra aqui: a janela do DeepL e o servidor do Hunyuan
        // ficam vivos até alguém mandar parar.
        builder?.finish()
        let builder = SubtitleFileBuilder()
        self.builder = builder
        builder.speakerModel = speakerModel

        do {
            notice = nil
            update(.extracting)
            // O mesmo caminho do item de menu "Gerar legenda de um vídeo".
            let translated = try await builder.generate(
                from: url,
                source: sourceLanguage,
                target: targetLanguage,
                engine: recognitionEngine,
                translation: translationEngine,
                diarize: diarizeSpeakers,
                progress: { [weak self] step, fraction, detail, waiting in
                    Task { @MainActor in self?.advance(step, fraction, detail, waiting) }
                },
                onBatch: { [weak self] partial in
                    // As legendas prontas vão para a tela na hora. Dá para
                    // começar a assistir enquanto o resto é traduzido, em vez
                    // de esperar o arquivo inteiro.
                    Task { @MainActor in
                        guard let self, self.isWorking else { return }
                        self.cues = partial
                        self.activeIndex = self.index(at: self.currentTime)
                    }
                }
            )
            // Cancelar já pôs a janela em "cancelado" e parou o relógio.
            guard !Task.isCancelled else { return }

            // Nada vai para o disco aqui: o .srt só sai quando o usuário
            // exporta. Antes cada geração gravava um ao lado do vídeo sem
            // ninguém pedir — e sobrescrevia o que já estivesse lá.
            cues = translated
            notice = builder.translationNotice
            origin = Origin(
                recognition: builder.recognitionName ?? "",
                translation: builder.translationName ?? ""
            )
            activeIndex = index(at: currentTime)
            finishJob(.done)
        } catch {
            finishJob(Task.isCancelled ? .cancelled : .failed(error.localizedDescription))
        }
    }
}
