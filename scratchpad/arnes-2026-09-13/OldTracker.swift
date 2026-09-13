import Foundation
import TradutorCore
enum OldTokens { static func split(_ s:String)->[String] { s.split(separator: " ").map(String.init) }; static func join(_ s:[String])->String { s.joined(separator:" ") } }
/// Decide que parte de uma transcrição em andamento já pode ser considerada
/// definitiva.
///
/// O problema que isto resolve: cortar o áudio para transcrever em pedaços
/// parte palavras ao meio, e nenhuma das metades é reconhecível — "reported"
/// vira "Reaper's" no fim de um bloco e "ported" no começo do seguinte.
/// Escolher um ponto de corte mais quieto ajuda, mas não elimina, porque fala
/// contínua nem sempre tem um vale entre palavras.
///
/// A saída é não cortar o áudio. Transcreve-se o trecho inteiro repetidamente,
/// e a cada passada compara-se com a anterior: o prefixo em que duas passadas
/// consecutivas concordam é estável e pode ir para a tela. O que ainda oscila
/// fica na zona vermelha, onde mudar é esperado.
///
/// É a política *LocalAgreement-2*, a mesma do `whisper-streaming`.
public struct OldTracker {

    private var previous: [String] = []

    /// Tudo que já foi confirmado desde o último `reset()`.
    public private(set) var confirmed: [String] = []

    public init() {}

    /// Palavras da hipótese atual que ainda não foram confirmadas.
    /// É o que a zona vermelha mostra.
    public var pending: [String] {
        previous.count > confirmed.count ? Array(previous.dropFirst(confirmed.count)) : []
    }

    /// Alimenta uma nova transcrição do mesmo áudio e devolve as palavras que
    /// passaram a ser definitivas nesta passada.
    public mutating func feed(_ hypothesis: String) -> [String] {
        let words = OldTokens.split(hypothesis)

        // O reconhecedor transcreve o trecho inteiro do zero a cada passada e
        // as vezes REESCREVE o que ja saiu na tela — troca uma palavra la
        // atras, junta duas, corta uma. Confirmar por indice sem checar isso
        // desalinha as posicoes e produz texto embaralhado do tipo
        // "running in been running in production".
        //
        // Como nao da para desdizer o que ja foi exibido, uma passada que
        // discorda do passado nao confirma nada: espera a proxima, que quase
        // sempre reconcilia.
        var aligned = 0
        while aligned < min(confirmed.count, words.count),
              Self.normalize(confirmed[aligned]) == Self.normalize(words[aligned]) {
            aligned += 1
        }
        guard aligned == confirmed.count else {
            previous = words
            return []
        }

        var common = confirmed.count
        while common < min(previous.count, words.count),
              Self.normalize(previous[common]) == Self.normalize(words[common]) {
            common += 1
        }
        previous = words

        guard common > confirmed.count else { return [] }
        let newly = Array(words[confirmed.count..<common])
        confirmed.append(contentsOf: newly)
        return newly
    }

    /// Aceita tudo que estiver pendente como definitivo. Chamado quando o
    /// detector de voz encontra uma pausa real: ali não há mais o que oscilar.
    public mutating func flush() -> [String] {
        let remaining = pending
        confirmed.append(contentsOf: remaining)
        return remaining
    }

    /// Fecha o trecho usando a transcrição final, que é feita sobre o áudio
    /// completo e costuma ser melhor que as passadas intermediárias.
    ///
    /// Existe porque `feed` + `flush` perdiam texto no fim de falas longas: se
    /// a transcrição final divergisse do que já fora confirmado, `feed`
    /// devolvia vazio por causa da guarda de alinhamento, e `flush` calculava
    /// o pendente a partir de uma hipótese mais curta — o fim da frase
    /// simplesmente sumia da tela.
    ///
    /// Aqui a regra é outra: alinha o que dá, e tudo o que a transcrição final
    /// disser além do ponto de alinhamento entra. Nada se perde.
    public mutating func reconcile(_ hypothesis: String) -> [String] {
        let words = OldTokens.split(hypothesis)
        guard !words.isEmpty else { return flush() }

        var aligned = 0
        while aligned < min(confirmed.count, words.count),
              Self.normalize(confirmed[aligned]) == Self.normalize(words[aligned]) {
            aligned += 1
        }

        let tail = aligned < words.count ? Array(words[aligned...]) : []
        confirmed.append(contentsOf: tail)
        previous = words
        return tail
    }

    public mutating func reset() {
        previous.removeAll()
        confirmed.removeAll()
    }

    /// Compara sem caixa nem pontuação: o reconhecedor muda a pontuação de uma
    /// palavra entre passadas sem que a palavra em si tenha mudado, e tratar
    /// isso como divergência travaria a confirmação para sempre.
    private static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Junta palavras confirmadas até formarem uma unidade que valha a pena
/// traduzir.
///
/// Traduzir palavra a palavra desperdiça o contexto da frase e enche a tela de
/// fragmentos; esperar a frase inteira devolve a latência que se quis cortar.
/// O meio-termo é fechar na pontuação, ou num limite de caracteres.
public struct OldAccumulator {

    /// Teto rígido. Acima disso fecha onde estiver.
    public var maximumCharacters = 75

    /// A partir daqui uma vírgula já serve de fecho.
    ///
    /// Cortar num número fixo de caracteres parte a oração ao meio, e o
    /// tradutor recebe um fragmento sem sujeito ou sem verbo — "us through
    /// every edge case" virou "Nós através de todos os casos extremos".
    /// Fechar na vírgula entrega uma oração inteira, que traduz bem e ainda
    /// cabe em duas linhas.
    public var clauseThreshold = 32

    private var words: [String] = []

    public init() {}

    public var current: String { OldTokens.join(words) }
    public var isEmpty: Bool { words.isEmpty }

    /// Adiciona palavras e devolve as frases que fecharam.
    public mutating func append(_ newWords: [String]) -> [String] {
        var closed: [String] = []
        for word in newWords {
            words.append(word)
            guard let last = word.last else { continue }

            let endsSentence = SentenceSplitter.sentenceEnders.contains(last)
            let endsClause = SentenceSplitter.clauseEnders.contains(last)
                && current.count >= clauseThreshold

            if endsSentence || endsClause || current.count >= maximumCharacters {
                closed.append(current)
                words.removeAll(keepingCapacity: true)
            }
        }
        return closed
    }

    /// Fecha o que houver, mesmo incompleto.
    public mutating func flush() -> String? {
        guard !words.isEmpty else { return nil }
        let text = current
        words.removeAll(keepingCapacity: true)
        return text
    }
}
