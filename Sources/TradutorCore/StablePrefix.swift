import Foundation
import NaturalLanguage

/// Em que unidades o texto reconhecido é comparado e confirmado.
///
/// O *LocalAgreement-2* confirma o prefixo em que duas passadas concordam, e a
/// unidade era a palavra separada por espaço — que japonês e chinês não têm.
/// Medido em 75 s de japonês: 224 caracteres e 16 frases viravam **8
/// unidades**, a maior com três frases inteiras, e a zona azul só andava
/// quando duas passadas repetiam o bloco todo.
///
/// Onde não há espaço a unidade passa a ser o caractere; `join` desfaz pela
/// mesma regra, senão "今日は" voltaria à tela como "今 日 は".
public enum Tokens {

    /// Escrita que não separa palavra com espaço.
    ///
    /// Kana, kanji e a pontuação de largura inteira que vem com eles.
    /// Coreano mantém palavras e espaços; retirar o espaço muda a escrita.
    /// Fora dessas faixas o texto continua sendo partido por espaço, então
    /// para inglês, português e afins nada muda: `split` devolve exatamente o
    /// que `split(separator: " ")` devolvia, e `join` exatamente o que
    /// `joined(separator: " ")` devolvia.
    public static func isDense(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F,   // pontuação CJK: 。、「」
             0x3040...0x30FF,   // hiragana e katakana
             0x3400...0x4DBF,   // kanji, extensão A
             0x4E00...0x9FFF,   // kanji
             0xF900...0xFAFF,   // kanji de compatibilidade
             0xFF00...0xFF60,   // largura inteira: ！？０９
             0xFF61...0xFF9F:   // katakana de meia largura
            return true
        default:
            return false
        }
    }

    public static func split(_ text: String) -> [String] {
        // Não mudar a unidade de inglês/coreano por causa de um sinal de
        // pontuação de largura inteira. No japonês, espaços que os resultados
        // parciais inserem entre caracteres não podem bloquear a confirmação.
        guard text.contains(where: { $0.isLetter && isDense($0) }) else {
            return text.split(separator: " ").map(String.init)
        }
        var tokens: [String] = []
        var word = ""
        for character in text {
            if character.isWhitespace {
                if !word.isEmpty { tokens.append(word); word = "" }
            } else if isDense(character) {
                if !word.isEmpty { tokens.append(word); word = "" }
                tokens.append(String(character))
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    /// Tira o espaço que o reconhecedor põe entre dois caracteres de escrita
    /// densa.
    ///
    /// A Apple devolve `ですか ？` e `よかったです。 頑張ろうね。` — espaços que
    /// não existem em japonês e seguem para o tradutor e para o `.srt`. Eram
    /// 12 no vídeo de 9 minutos, e nascem **dentro** do trecho, no texto do
    /// run, então o conserto é aqui e não na junção.
    ///
    /// Só entre dois densos: `今 20歳` mantém o espaço, porque `2` não é.
    public static func tightenDense(_ text: String) -> String {
        var result = ""
        var pending = 0
        for character in text {
            if character == " " {
                pending += 1
                continue
            }
            if pending > 0 {
                // Um espaço só, entre dois densos. Dois espaços seguidos são
                // outra coisa e ficam como estão — assim texto sem escrita
                // densa sai byte a byte igual ao que entrou.
                let colar = pending == 1
                    && result.last.map(isDense) == true
                    && isDense(character)
                if !colar { result += String(repeating: " ", count: pending) }
                pending = 0
            }
            result.append(character)
        }
        if pending > 0 { result += String(repeating: " ", count: pending) }
        return result
    }

    /// Pedaços de escrita densa que se podem separar sem partir palavra.
    ///
    /// A repartição de legenda e a quebra de linha cortavam japonês por
    /// caractere, onde quer que caísse o meio: na palestra do TEDxWasedaU a
    /// Apple saiu com `…一人でブ` / `ツブツ…` e `まあま` / `だまだ…` em legendas
    /// seguidas. As palavras vêm do `NLTokenizer` do sistema, que em japonês
    /// devolve morfema (`思っ|て|い|ます`) e não tem classe gramatical. Então
    /// partícula e auxiliar conhecidos grudam na palavra de antes (`話を`,
    /// `思っています`) — linha começando por `を` ou `ます` é a quebra que o
    /// leitor japonês estranha — e o prefixo de cortesia gruda na seguinte
    /// (`お話し`). Pontuação e espaço ficam com o pedaço anterior. Juntos, os
    /// pedaços são o texto exato.
    public static func phrases(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var starts = tokenizer.tokens(for: text.startIndex..<text.endIndex).map(\.lowerBound)
        guard !starts.isEmpty else { return text.isEmpty ? [] : [text] }
        starts[0] = text.startIndex
        var result: [String] = []
        var prefix = ""
        for (offset, start) in starts.enumerated() {
            let end = offset + 1 < starts.count ? starts[offset + 1] : text.endIndex
            let word = String(text[start..<end])
            let bare = word.trimmingCharacters(in: .whitespaces)
            if attachesForward.contains(bare) {
                prefix += word
                continue
            }
            // Katakana e letra latina seguidas são uma palavra só: o
            // tokenizador partiu `テッドックス` em `テッド|ッ|クス`, e a linha
            // quebrava ali.
            let sameRun = result.last?.last(where: { !$0.isWhitespace }).map { last in
                bare.first.map { (isKatakana(last) && isKatakana($0)) || (last.isASCII && last.isLetter && $0.isASCII && $0.isLetter) } ?? false
            } ?? false
            let glues = sameRun || attachesBackward.contains(bare.filter(\.isLetter))
                || (bare.count == 1 && bare.first.map(isHiragana) == true)
            if prefix.isEmpty, glues, let last = result.last?.last(where: { !$0.isWhitespace }), last.isLetter {
                result[result.count - 1] += word
            } else {
                result.append(prefix + word)
            }
            prefix = ""
        }
        if !prefix.isEmpty { result.append(prefix) }
        return result
    }

    /// Partículas e auxiliares japoneses: nunca abrem pedaço.
    static let attachesBackward: Set<String> = [
        "は", "が", "を", "に", "で", "と", "も", "の", "へ", "や", "か", "ね", "よ", "な", "わ", "さ",
        "て", "た", "だ", "ば", "ん", "う", "い", "る", "ず",
        "から", "まで", "より", "けど", "けれど", "ので", "のに", "って", "だけ", "しか",
        "ほど", "など", "ながら", "たり", "だり", "ちゃ", "じゃ", "とか",
        "ない", "なかっ", "ます", "ませ", "まし", "です", "でし", "でしょ", "だろ", "だっ",
        "たい", "たく", "たかっ", "れる", "られる", "れ", "られ", "せる", "させる", "せ", "させ",
        "いる", "いう", "おり", "ござい",
        // Auxiliar depois de て: `…にして` / `やがる` saiu numa legenda do
        // anime e a tradução ganhou um "Vai fazer" solto.
        "やがる", "やがっ", "ちゃう", "ちゃっ", "じゃう", "じゃっ", "しまう", "しまっ", "しまい",
    ]

    /// Prefixo de cortesia: vai com a palavra seguinte.
    static let attachesForward: Set<String> = ["お", "ご"]

    private static func isKatakana(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x30A1...0x30FF).contains(scalar.value) || (0xFF66...0xFF9F).contains(scalar.value)
    }

    private static func isHiragana(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x3041...0x309F).contains(scalar.value)
    }

    public static func join(_ tokens: [String]) -> String {
        if !tokens.contains(where: { $0.contains(where: { $0.isLetter && isDense($0) }) }) {
            return tokens.joined(separator: " ")
        }
        var result = ""
        for token in tokens {
            if let last = result.last, let first = token.first,
               !last.isWhitespace, !first.isWhitespace,
               !isDense(last), !isDense(first) {
                result.append(" ")
            }
            result += token
        }
        return result
    }
}

/// Decide que parte de uma transcrição em andamento já pode ser considerada
/// definitiva.
///
/// Cortar o áudio parte palavras ao meio e nenhuma metade é reconhecível —
/// "reported" vira "Reaper's" no fim de um bloco e "ported" no começo do
/// seguinte; cortar no ponto mais quieto ajuda e não elimina.
///
/// A saída é não cortar: o trecho é transcrito inteiro, repetidamente, e vai
/// para a tela o prefixo em que duas passadas concordam. O que oscila fica na
/// zona vermelha, onde mudar é esperado. É a política *LocalAgreement-2*, do
/// `whisper-streaming`.
public struct StablePrefixTracker {

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
        let words = Tokens.split(hypothesis)

        // O reconhecedor as vezes REESCREVE o que ja saiu na tela, e
        // confirmar por indice sem checar isso produz texto embaralhado
        // ("running in been running in production"). Como nao da para desdizer
        // o exibido, passada que discorda do passado nao confirma nada.
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
    /// `feed` + `flush` perdiam texto no fim de falas longas: divergindo do
    /// que já fora confirmado, `feed` devolvia vazio pela guarda de
    /// alinhamento e `flush` partia de uma hipótese mais curta. Aqui a regra é
    /// outra: alinha o que dá, e tudo além do ponto de alinhamento entra.
    public mutating func reconcile(_ hypothesis: String) -> [String] {
        let words = Tokens.split(hypothesis)
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
public struct PhraseAccumulator {

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

    public var current: String { Tokens.join(words).trimmingCharacters(in: .whitespacesAndNewlines) }
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
