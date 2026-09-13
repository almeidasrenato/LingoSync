import Foundation
import OSLog

/// Um termo que você quer traduzido sempre do mesmo jeito.
public struct Term: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    /// Como aparece no idioma de origem: 納豆, もやし, 山梨県.
    public var source: String
    /// Como deve aparecer na tradução: natto, broto de feijão, Yamanashi.
    public var target: String
    public var enabled = true

    public init(source: String, target: String, enabled: Bool = true) {
        self.source = source
        self.target = target
        self.enabled = enabled
    }
}

/// Lista de termos aplicada antes de traduzir.
///
/// Os erros que sobram na legenda quase nunca são de gramática — são
/// substantivos concretos. 「もやし」 (broto de feijão) sai como "cogumelos",
/// 「水菜」 (mizuna) vira "alface". Nenhum ajuste de prompt ou troca de modelo
/// resolve isso de forma confiável, porque é uma escolha de vocabulário que só
/// quem assiste sabe qual é.
///
/// O termo é substituído **no texto de origem, antes de traduzir**, e não
/// depois. Medido com o tradutor do sistema: uma palavra estrangeira no meio
/// do japonês atravessa intacta, e ainda dá ao tradutor uma palavra de verdade
/// com que concordar em gênero. Trocar depois exigiria adivinhar qual pedaço
/// da tradução corresponde ao termo.
public final class Glossary: @unchecked Sendable {

    private let log = Logger(subsystem: "app.tradutor", category: "Glossary")
    private let lock = NSLock()
    private var terms: [Term] = []

    /// Um arquivo por par de idiomas: 納豆 não se traduz igual em inglês e em
    /// português.
    private let url: URL

    /// - Parameter directory: onde guardar. O padrão é Application Support;
    ///   os testes passam uma pasta temporária, porque um teste que escreve na
    ///   lista real do usuário a destrói — e foi exatamente o que aconteceu:
    ///   o gate trocava a lista pelos termos de teste e restaurava num
    ///   `defer` que `exit()` nunca executa.
    public init(source: Language, target: Language, directory: URL? = nil) {
        let folder = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tradutor", isDirectory: true)
            .appendingPathComponent("glossarios", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("\(source.rawValue)-\(target.rawValue).json")
        load()
    }

    public var all: [Term] {
        lock.lock(); defer { lock.unlock() }
        return terms
    }

    /// Os termos como aparecem no idioma de origem, para dar ao
    /// reconhecedor o que ele nunca viu.
    public var activeSources: [String] {
        lock.lock(); defer { lock.unlock() }
        return terms.filter { $0.enabled && !$0.source.isEmpty }.map(\.source)
    }

    public var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return terms.filter(\.enabled).count
    }

    public func replaceAll(with newTerms: [Term]) {
        lock.lock()
        terms = newTerms
        lock.unlock()
        save()
    }

    /// Substitui os termos no texto de origem.
    ///
    /// Os mais longos primeiro: sem isso, um termo curto que seja prefixo de
    /// outro come o começo do longo e o resto vira lixo.
    public func apply(to text: String) -> String {
        lock.lock()
        let active = terms.filter { $0.enabled && !$0.source.isEmpty && !$0.target.isEmpty }
            .sorted { $0.source.count > $1.source.count }
        lock.unlock()

        guard !active.isEmpty else { return text }
        var result = text
        for term in active {
            result = result.replacingOccurrences(of: term.source, with: term.target)
        }
        return result
    }

    // MARK: - Disco

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Term].self, from: data)
        else { return }
        lock.lock()
        terms = decoded
        lock.unlock()
    }

    private func save() {
        lock.lock()
        let snapshot = terms
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("nao consegui gravar o glossario: \(error.localizedDescription, privacy: .public)")
        }
    }
}
