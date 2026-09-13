import Foundation
import Observation

/// Um bloco fechado: origem reconhecida mais a traducao correspondente.
public struct SubtitleBlock: Identifiable, Sendable {
    public let id = UUID()
    public let source: String
    public let translated: String
    public let at: Date

    public init(source: String, translated: String, at: Date = Date()) {
        self.source = source
        self.translated = translated
        self.at = at
    }
}

/// O modelo das tres zonas da tela.
///
///   amarela  blocos antigos, opacidade decrescente
///   azul     o bloco que acabou de ser traduzido, com todo o destaque
///   vermelha o parcial cru do reconhecedor, sem traducao
///
/// A zona vermelha e o que evita o tremor da tela. O texto parcial do
/// reconhecedor muda a cada instante; traduzi-lo faria a legenda piscar e
/// ficar ilegivel. Entao o parcial aparece cru, e so o segmento ja fechado
/// pelo detector de voz atravessa a traducao — e uma vez escrito, nunca muda.
@MainActor
@Observable
public final class SubtitleStore {

    /// Quantos blocos o historico guarda.
    ///
    /// Era 4 quando tudo ficava empilhado na tela. Agora que o historico rola
    /// dentro da propria area, guardar mais e o que da sentido a rolagem — o
    /// teto existe so para a sessao nao crescer sem limite.
    public var historyLimit = 60

    public private(set) var history: [SubtitleBlock] = []
    public private(set) var current: SubtitleBlock?
    public private(set) var partial: String = ""
    public private(set) var isTranslating = false

    public init() {}

    public func setPartial(_ text: String) {
        let clean = SentenceSplitter.tidy(text)
        partial = SentenceSplitter.hasContent(clean) ? clean : ""
    }

    public func beginTranslating() {
        isTranslating = true
    }

    public func commit(_ block: SubtitleBlock) {
        if let current {
            history.append(current)
            if history.count > historyLimit {
                history.removeFirst(history.count - historyLimit)
            }
        }
        current = block
        partial = ""
        isTranslating = false
    }

    public func clear() {
        history.removeAll()
        current = nil
        partial = ""
        isTranslating = false
    }
}

/// Remove a repeticao criada pela sobreposicao entre segmentos.
///
/// Quando o segmentador corta no teto, ele repete a cauda do audio no inicio
/// do proximo bloco — sem isso a palavra cortada ao meio se perde. O efeito
/// colateral e que essa cauda e reconhecida duas vezes e apareceria duas vezes
/// na tela ("...Friday afternoon." seguido de "afternoon, it has been...").
public enum OverlapTrimmer {

    /// Quantas palavras do fim do bloco anterior sao procuradas no comeco do
    /// novo. A sobreposicao e de 0,25 s, entao poucas palavras bastam.
    private static let maximumWords = 8

    public static func dropRepeatedPrefix(_ text: String, after previous: String) -> String {
        // Mesma unidade do confirmador de prefixo: em japonês, caractere.
        // Comparando por espaço, o bloco inteiro era uma palavra só e a cauda
        // repetida nunca casava.
        let previousWords = Tokens.split(previous)
        let newWords = Tokens.split(text)
        guard !previousWords.isEmpty, !newWords.isEmpty else { return text }

        let limit = min(maximumWords, previousWords.count, newWords.count)
        guard limit > 0 else { return text }

        // Da maior sobreposicao para a menor: prefere cortar mais quando ha
        // ambiguidade, porque repetir incomoda mais que faltar uma palavra
        // que ja foi lida no bloco anterior.
        for count in stride(from: limit, through: 1, by: -1) {
            // Um caractere japonês/chinês coincidente pode iniciar outra
            // palavra: "これは" + "はじめまして" não repete o "は".
            // ponytail: dois caracteres ainda são heurística; certeza exige
            // associar a repetição ao intervalo de áudio sobreposto.
            if count == 1, newWords[0].count == 1,
               newWords[0].first.map(Tokens.isDense) == true { continue }
            let tail = previousWords.suffix(count).map(normalize)
            let head = newWords.prefix(count).map(normalize)
            if tail == head, !tail.contains(where: \.isEmpty) {
                return Tokens.join(Array(newWords.dropFirst(count)))
            }
        }
        return text
    }

    /// Compara sem pontuacao nem caixa: o reconhecedor pontua a mesma palavra
    /// de um jeito no fim de um bloco e de outro no comeco do seguinte.
    private static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Corta o texto reconhecido em frases.
///
/// Um segmento do detector de voz pode carregar varias frases — fala corrida
/// sem pausa de 600 ms bate no teto de 8 s e chega inteira. Traduzir e exibir
/// isso como um bloco unico produz exatamente o paragrafo longo que a leitura
/// em tempo real nao suporta.
public enum SentenceSplitter {

    /// O que termina uma frase, em qualquer um dos idiomas do app.
    ///
    /// Existe como um conjunto só porque estava escrito `".!?…"` em três
    /// lugares — aqui, no agrupador de legendas e no acumulador do tempo real
    /// — e nenhum deles reconhecia `。`. Medido no vídeo de 9 minutos em
    /// japonês, com o reconhecimento da Apple: dos 99 fins de frase, **55
    /// ficavam no MEIO de uma legenda**, contra 5 de 52 no vídeo em inglês. A
    /// legenda emendava duas falas — quase sempre de duas pessoas — e só
    /// fechava quando batia no teto de 7 s.
    public static let sentenceEnders: Set<Character> = [
        ".", "!", "?", "…", "。", "！", "？",
    ]

    /// O que termina uma oração. Mesma história: `、` é a vírgula japonesa.
    public static let clauseEnders: Set<Character> = [
        ",", ";", ":", "—", "、", "，", "；", "：",
    ]

    /// Frases curtas demais viram fragmento sem sentido; abaixo disso a frase
    /// e grudada na seguinte.
    private static let minimumCharacters = 12

    /// Acima disso o bloco e longo demais para leitura em tempo real e e
    /// cortado de novo, agora na virgula.
    ///
    /// Esse segundo corte nao e refinamento: os reconhecedores pontuam fala
    /// corrida com virgula, quase nunca com ponto final. Sem ele, uma fala de
    /// oito segundos chega a tela como um paragrafo unico de 120 caracteres.
    private static let maximumCharacters = 90

    public static func split(_ text: String) -> [String] {
        let clean = tidy(text)
        guard !clean.isEmpty else { return [] }

        var sentences: [String] = []
        var current = ""

        for character in clean {
            current.append(character)
            if sentenceEnders.contains(character) {
                let candidate = tidy(current)
                // Nao corta em abreviacao nem em numero decimal: "3.5" e
                // "Dr." nao terminam frase.
                if candidate.count >= minimumCharacters {
                    sentences.append(candidate)
                    current = ""
                }
            }
        }

        let leftover = tidy(current)
        if !leftover.isEmpty {
            if leftover.count < minimumCharacters, var last = sentences.popLast() {
                last += " " + leftover
                sentences.append(tidy(last))
            } else {
                sentences.append(leftover)
            }
        }

        return sentences
            .flatMap(splitLongSentence)
            .filter(hasContent)
    }

    /// Corta na virgula (depois na conjuncao) ate os pedacos caberem.
    private static func splitLongSentence(_ sentence: String) -> [String] {
        guard sentence.count > maximumCharacters else { return [sentence] }

        var pieces: [String] = []
        var current = ""

        for chunk in sentence.split(separator: ",", omittingEmptySubsequences: false) {
            let piece = chunk.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }

            if current.isEmpty {
                current = piece
            } else if current.count + piece.count + 2 <= maximumCharacters {
                current += ", " + piece
            } else {
                pieces.append(current)
                current = piece
            }
        }
        if !current.isEmpty { pieces.append(current) }

        // Uma oracao unica sem virgula nenhuma continua longa: aceita assim,
        // porque cortar no meio dela quebraria o sentido. A quebra de linha
        // do LineBreaker cuida da exibicao.
        return pieces.isEmpty ? [sentence] : pieces
    }

    /// Verdadeiro so quando ha letra ou numero. Reconhecedores emitem
    /// segmentos de pontuacao pura em silencio e ruido — traduzir "." e
    /// mostrar isso como um bloco e ruido na tela.
    public static func hasContent(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// Tira pontuacao e espaco soltos do inicio.
    ///
    /// Publico porque a zona vermelha precisa do mesmo tratamento: o parcial
    /// costuma comecar no meio de uma palavra da frase anterior e chega como
    /// ".tor team reported...".
    public static func tidy(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = result.first, !first.isLetter, !first.isNumber, first != "¿", first != "¡" {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

/// Quebra de linha para leitura em tempo real.
///
/// Texto corrido longo e ilegivel quando esta mudando na tela. O corte
/// prefere pontuacao, depois conjuncao, e so entao o espaco mais proximo.
public enum LineBreaker {

    /// - Parameters:
    ///   - maximum: alvo de caracteres por linha
    ///   - maxLines: quantas linhas cabem confortavelmente na tela
    ///
    /// `maxLines` e um alvo, nao um teto rigido: empurrar todo o resto para a
    /// ultima linha produzia linhas de 78 caracteres, que e justamente o que
    /// esta funcao existe para evitar. Texto que nao cabe continua quebrando —
    /// quem limita o tamanho do bloco e o segmentador, la na origem.
    public static func wrap(_ text: String, maximum: Int = 58, maxLines: Int = 3) -> [String] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > maximum else { return clean.isEmpty ? [] : [clean] }

        var lines: [String] = []
        var rest = Substring(clean)

        while rest.count > maximum {
            let window = rest.prefix(maximum)
            // Um corte só vale se o que sobra ainda couber no mínimo de linhas
            // que o texto precisa. Sem isso a vírgula mais à esquerda ganhava:
            // "japoneses, os vegetais e frutas são geralmente vendidos em
            // pacotes." — 67 caracteres, cabe em duas de 42 — saía em quatro,
            // começando por "japoneses,".
            let needed = (rest.count + maximum - 1) / maximum
            let earliest = rest.count - maximum * (needed - 1)
            let cut = breakPoint(in: window, notBefore: earliest) ?? window.endIndex
            let line = String(rest[rest.startIndex..<cut]).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { break }
            lines.append(line)
            rest = rest[cut...].drop(while: { $0 == " " })
        }
        if !rest.isEmpty {
            lines.append(String(rest).trimmingCharacters(in: .whitespaces))
        }
        return lines.filter { !$0.isEmpty }
    }

    /// - Parameter earliest: menor posição (em caracteres) aceitável para o
    ///   corte. Pontuação e conjunção antes dela são ignoradas.
    private static func breakPoint(in window: Substring, notBefore earliest: Int) -> Substring.Index? {
        func allowed(_ index: Substring.Index) -> Bool {
            window.distance(from: window.startIndex, to: index) >= earliest
        }
        // 1. pontuacao: o corte mais natural
        if let index = window.lastIndex(where: { ",;:—".contains($0) }),
           allowed(window.index(after: index)) {
            return window.index(after: index)
        }
        // 2. conjuncao: quebra antes dela mantem a oracao inteira na linha
        let conjunctions = [" e ", " ou ", " mas ", " que ", " porque ", " quando ",
                            " and ", " or ", " but ", " that ", " because ", " when "]
        var best: Substring.Index?
        for conjunction in conjunctions {
            if let range = window.range(of: conjunction, options: .backwards),
               allowed(range.lowerBound) {
                if best == nil || range.lowerBound > best! { best = range.lowerBound }
            }
        }
        if let best { return best }
        // 3. ultimo espaco
        return window.lastIndex(of: " ")
    }
}
