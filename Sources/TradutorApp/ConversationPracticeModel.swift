import AudioCapture
import Foundation
import Observation
import TradutorCore

/// Prática de conversa: dois lados ouvidos ao mesmo tempo.
///
/// O professor é o áudio de um aplicativo — um assistente de voz rodando no
/// navegador ou no app dele — e o aluno é o microfone. Os dois passam pelo
/// mesmo `LiveSource`, que é o caminho de áudio do painel ao vivo; o que muda
/// aqui é a tela e as regras de turno.
@MainActor
@Observable
final class ConversationPracticeModel {

    enum Speaker { case professor, aluno }

    struct Turn: Identifiable {
        let id = UUID()
        let speaker: Speaker
        let source: String
        var translated: String?
        /// O olho esconde a **tradução**, não o original: o exercício é ouvir e
        /// conferir depois. Por fala, e não persiste entre sessões.
        var translationHidden = false
    }

    enum State: Equatable {
        case idle
        case loading(String)
        case running
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Sem `private(set)`: o render de QA (`--selftest-layout`) semeia falas
    /// para desenhar a janela sem captura, modelo nem rede.
    var turns: [Turn] = []
    var professorPartial = ""
    private(set) var studentPartial = ""
    /// Acende o losango. Vem do VAD, não de temporizador.
    var isProfessorSpeaking = false
    /// A barra de baixo, "transcrevendo sua resposta".
    var isStudentSpeaking = false

    var sourceLanguage: Language = .english
    var targetLanguage: Language = .portuguese
    var recognitionEngine: RecognitionEngine = .preferred
    var translationEngine: TranslationEngine = .apple

    /// De onde vem a voz do professor: um aplicativo, ou todo o áudio do
    /// sistema. O microfone não entra nesta lista — ele é o outro lado.
    private(set) var availableProcesses: [AudioProcess] = []
    var professorProcess: AudioProcess?

    private(set) var availableInputs: [AudioInputDevice] = []
    /// O microfone do MacBook por padrão, e não o padrão do sistema.
    ///
    /// Contraria a regra do painel ao vivo de propósito, e por medição: o
    /// padrão do sistema costuma ser um fone Bluetooth, e abrir o microfone
    /// dele joga o aparelho inteiro em HFP — 16 kHz na entrada e na saída,
    /// o que derruba junto a captura do aplicativo do professor. Medido em
    /// `tradutor-probe duplo`: 32 096 de 96 000 amostras com o fone, 95 840
    /// com o interno.
    var microphoneDevice: AudioInputDevice? = AudioInputList.builtIn

    /// Quem traduz a palavra no hover. Só a Apple por enquanto: é local e não
    /// custa ida à rede a cada passada de mouse.
    var hoverEngine: TranslationEngine =
        TranslationEngine(rawValue: UserDefaults.standard.string(forKey: "tradutorDoHover") ?? "")
        ?? .apple
    {
        didSet { UserDefaults.standard.set(hoverEngine.rawValue, forKey: "tradutorDoHover") }
    }
    static let hoverEngines: [TranslationEngine] = [.apple]

    private var professor: LiveSource?
    private var student: LiveSource?
    private var transcriber: Transcriber?
    private var translator: (any Translator)?
    private var hoverTranslator: (any Translator)?
    private var pumpTask: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?

    /// Falas do professor esperando tradução. **Sem teto**: perder legenda de
    /// reunião é aceitável, perder a fala do professor é perder a aula.
    private var pending: [UUID] = []

    /// Quando o professor teve voz pela última vez.
    ///
    /// A fala do aluno só vale com o professor calado há pelo menos
    /// `crosstalkGrace`. Sem isso o alto-falante entra pelo microfone e o
    /// aluno "responde" o que o professor acabou de dizer — medido: rms 0,052
    /// no microfone do fone com o professor tocando e ninguém falando.
    private var lastProfessorVoice = Date.distantPast
    private let crosstalkGrace: TimeInterval = 1.0

    /// Cache do hover: palavra + par de idiomas. Custa ~290 ms por string, e
    /// passar o mouse de novo na mesma palavra não pode pagar de novo.
    private var glossary: [String: String] = [:]

    init() {}

    var isRunning: Bool { state == .running }

    /// A última fala do professor, que a tela destaca.
    var lastProfessorTurn: Turn? {
        turns.last { $0.speaker == .professor }
    }

    func refreshSources() {
        availableInputs = AudioInputList.all()
        if let chosen = microphoneDevice, !availableInputs.contains(chosen) {
            microphoneDevice = AudioInputList.builtIn
        }
        // Sem `.microphone`: aqui ele é o aluno, não uma opção de professor.
        availableProcesses = [.systemWide] + ((try? AudioProcessList.all()) ?? [])
            .filter { !$0.isMicrophone }
        if let current = professorProcess, !availableProcesses.contains(current) {
            professorProcess = nil
        }
    }

    // MARK: - Ciclo de vida

    func start() async {
        guard !isRunning, let process = professorProcess else { return }

        state = .loading("carregando o reconhecimento…")
        let recognition = TranscriberFactory.make(
            for: sourceLanguage, engine: recognitionEngine.forLive
        )
        recognition.language = sourceLanguage
        do {
            if !recognition.isPrepared {
                try await recognition.prepare { _, _ in }
            }
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        transcriber = recognition

        state = .loading("carregando a tradução…")
        let engine = TranslatorFactory.make(translationEngine)
        do {
            try await engine.prepare { _, _ in }
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        translator = engine

        guard await MicrophoneTap.requestAccess() else {
            state = .failed(
                "A prática precisa do microfone. "
                + "Ajustes do Sistema › Privacidade e Segurança › Microfone."
            )
            return
        }

        // Um reconhecedor para os dois lados: mesmo idioma, mesmo modelo. Dois
        // Whisper residentes seriam 2,4 GB para a mesma língua.
        let interval = TranscriberKind(
            for: sourceLanguage, engine: recognitionEngine.forLive
        ) == .whisper ? 1.2 : 0.6

        let professor = LiveSource(
            transcriber: recognition,
            rehearsalInterval: interval,
            onPartial: { [weak self] text in self?.professorPartial = text },
            onPhrase: { [weak self] phrase in self?.commitProfessor(phrase) }
        )
        let student = LiveSource(
            transcriber: recognition,
            rehearsalInterval: interval,
            onPartial: { [weak self] text in self?.studentPartial = text },
            onPhrase: { [weak self] phrase in self?.commitStudent(phrase) }
        )

        do {
            try professor.start(.process(process))
            try student.start(.microphone(microphoneDevice))
        } catch {
            professor.stop()
            student.stop()
            state = .failed(error.localizedDescription)
            return
        }

        self.professor = professor
        self.student = student
        turns.removeAll()
        pending.removeAll()
        professorPartial = ""
        studentPartial = ""
        state = .running

        pumpTask = Task { [weak self] in await self?.pump() }
        translateTask = Task { [weak self] in await self?.drainTranslations() }
    }

    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        translateTask?.cancel()
        translateTask = nil
        professor?.stop()
        professor = nil
        student?.stop()
        student = nil
        // O DeepL e o Hunyuan não se soltam sozinhos, e esta janela pode ficar
        // aberta o dia todo.
        if translationEngine.isInstantaneous == false {
            translator?.reset()
            translator = nil
        }
        professorPartial = ""
        studentPartial = ""
        isProfessorSpeaking = false
        isStudentSpeaking = false
        state = .idle
    }

    func toggleHidden(_ turn: Turn) {
        guard let index = turns.firstIndex(where: { $0.id == turn.id }) else { return }
        turns[index].translationHidden.toggle()
    }

    // MARK: - Laço

    /// Os dois lados na mesma volta: chamar um depois do outro já serializa o
    /// reconhecedor compartilhado, sem trava nenhuma.
    private func pump() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            await professor?.pump()
            await student?.pump()

            let speaking = professor?.isSpeaking ?? false
            if speaking { lastProfessorVoice = Date() }
            isProfessorSpeaking = speaking
            isStudentSpeaking = (student?.isSpeaking ?? false) && !inProfessorShadow
        }
    }

    /// O professor falou agora, ou acabou de calar.
    private var inProfessorShadow: Bool {
        Date().timeIntervalSince(lastProfessorVoice) < crosstalkGrace
    }

    private func commitProfessor(_ phrase: String) {
        guard SentenceSplitter.hasContent(phrase) else { return }
        let turn = Turn(speaker: .professor, source: phrase)
        turns.append(turn)
        pending.append(turn.id)
    }

    /// A fala do aluno não é traduzida: quem falou sabe o que disse.
    private func commitStudent(_ phrase: String) {
        guard SentenceSplitter.hasContent(phrase) else { return }
        // Eco do alto-falante entrando pelo microfone não é resposta.
        guard !inProfessorShadow else { return }
        turns.append(Turn(speaker: .aluno, source: phrase))
    }

    private func drainTranslations() async {
        while !Task.isCancelled {
            guard let next = pending.first else {
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            pending.removeFirst()
            await translate(next)
        }
    }

    private func translate(_ id: UUID) async {
        guard let translator,
              let index = turns.firstIndex(where: { $0.id == id })
        else { return }
        let source = turns[index].source
        guard let result = try? await translator.translate(
            source, from: sourceLanguage, to: targetLanguage
        ), !result.isEmpty else { return }
        guard let fresh = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[fresh].translated = result
    }

    // MARK: - Hover

    /// Traduz uma palavra solta, para o balão que aparece sob o ponteiro.
    ///
    /// É gloss, não tradução: o framework da Apple não recebe o contexto da
    /// frase. Serve para destravar a leitura, não para conferir sentido — a
    /// tradução da fala inteira está logo abaixo dela.
    func gloss(for word: String) async -> String? {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 1 else { return nil }
        let key = "\(sourceLanguage.rawValue)>\(targetLanguage.rawValue):\(clean.lowercased())"
        if let cached = glossary[key] { return cached }

        if hoverTranslator == nil {
            // Próprio, e não o das falas: as bolhas podem estar no DeepL, e o
            // hover não vai à rede a cada passada de mouse.
            let engine = TranslatorFactory.make(hoverEngine)
            guard (try? await engine.prepare { _, _ in }) != nil else { return nil }
            hoverTranslator = engine
        }
        guard let hoverTranslator,
              let result = try? await hoverTranslator.translate(
                  clean, from: sourceLanguage, to: targetLanguage
              ), !result.isEmpty
        else { return nil }
        glossary[key] = result
        return result
    }
}
