import Foundation

/// Tira a hesitação da legenda: `まあ`, `えーと`, "um".
///
/// Legenda de arquivo segue a convenção de legendagem, que omite hesitação —
/// a legenda oficial do TEDxWasedaU não tem nenhum `えー` e guarda 3 dos 46
/// `まあ` que a Apple escreveu. Medido nela, alinhando caractere a caractere:
///
///     Apple       まあ 41 de 46 a mais · あの 23 de 25 · こう 14 de 21
///     Qwen 1.7B   まあ 50 de 55 a mais · あの 21 de 22 · こう 15 de 22
///     Whisper     まあ  2 de  2 — o modelo já não escreve hesitação
///
/// Só sai o que é hesitação pela forma. `あの` também é "aquele" (`あの人`),
/// e antes de substantivo as duas leituras têm a mesma cara (`あの練習` era
/// hesitação, `あの時` não seria) — então sai só seguido de pausa ou de
/// outra hesitação. `こう` ("assim") e `その` ficam: 67% e 6% de acerto não
/// pagam o que se perderia.
///
/// Só no caminho de arquivo (`transcribeForSubtitles`). O painel ao vivo mostra
/// o que foi dito.
public enum Hesitations {

    /// Hesitação japonesa pela forma, por padrão de texto: o `NLTokenizer`
    /// só às vezes devolve `まあ` como palavra (`ことをまあ` sai `を|ま|あ`).
    /// `まあまあ` ("mais ou menos") não casa; `まあまだまだ` casa — a primeira
    /// versão barrava qualquer `ま` depois e deixava passar este. `あの` sai prolongado (`あのー`),
    /// ou seguido de pausa ou de outra hesitação.
    static let japanesePattern = try! NSRegularExpression(pattern: [
        "(?<!ま[あぁ])ま[あぁ]ー*(?!ま[あぁ])",
        "えー+っ?と?", "えっと", "ええっ?と",
        "うー+ん", "んー+",
        "あの[ーぉ]+",
        "あの(?=[、。？！ 　]|$|ま[あぁ]|えー|えっと|うーん)",
    ].joined(separator: "|"))

    /// Inglês: só o que não é palavra. "like" e "you know" ficam.
    static let englishPattern = try! NSRegularExpression(
        pattern: #"(?i)(^|(?<=[\s,.!?]))(u+h+m*|u+m+|e+r+m+|h+m+)[,.]?(?=\s|$)\s*"#)
    /// "I was, uh, thinking": as duas vírgulas eram da hesitação.
    static let englishBetweenCommas = try! NSRegularExpression(
        pattern: #"(?i),\s+(u+h+m*|u+m+|e+r+m+|h+m+),(?=\s)"#)

    public static func strip(_ pieces: [TimedText], language: Language) -> [TimedText] {
        guard language == .japanese || language == .english else { return pieces }
        return pieces.compactMap { piece in
            let text = language == .japanese ? stripJapanese(piece.text) : stripEnglish(piece.text)
            guard SentenceSplitter.hasContent(text) else { return nil }
            return TimedText(text: text, start: piece.start, end: piece.end, speaker: piece.speaker)
        }
    }

    public static func stripJapanese(_ text: String) -> String {
        let whole = NSRange(text.startIndex..., in: text)
        let matches = japanesePattern.matches(in: text, range: whole)
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text), range.lowerBound >= cursor else { continue }
            result += text[cursor..<range.lowerBound]
            cursor = range.upperBound
            if cursor < text.endIndex, "、 　".contains(text[cursor]) { cursor = text.index(after: cursor) }
        }
        result += text[cursor...]
        return tidyJapanese(result)
    }

    /// O que a remoção deixa para trás: `、。`, `、、`, `、` no começo.
    static func tidyJapanese(_ text: String) -> String {
        var result = text
        for (from, to) in [("、、", "、"), ("、。", "。"), ("、？", "？"), ("、！", "！")] {
            while result.contains(from) { result = result.replacingOccurrences(of: from, with: to) }
        }
        while let first = result.first, "、 　".contains(first) { result.removeFirst() }
        return result
    }

    public static func stripEnglish(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let inner = englishBetweenCommas.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        let stripped = englishPattern.stringByReplacingMatches(
            in: inner, range: NSRange(inner.startIndex..., in: inner), withTemplate: "")
        guard stripped != text else { return text }
        var result = stripped.replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .trimmingCharacters(in: .whitespaces)
        while let first = result.first, first == "," { result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces) }
        // A frase começava pela hesitação: a maiúscula passa para a seguinte.
        if let first = result.first, first.isLowercase, text.first?.isUppercase == true {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }
}
