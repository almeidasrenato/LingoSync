import Foundation

/// Uma cor por locutor.
///
/// As quatro cores são as da legenda oculta da TV americana (CEA-608), na
/// mesma ordem: branco, amarelo, ciano, verde. Não é gosto — é o conjunto que
/// décadas de legenda mostraram legível sobre qualquer imagem, e que o
/// telespectador já associa a "outra pessoa falando".
///
/// A ordem segue quem falou primeiro, como a numeração dos locutores, então a
/// cor de cada um é a mesma no arquivo e na janela.
public enum SpeakerPalette {

    /// Hexadecimal como o `.srt` espera, na tag `<font color="#RRGGBB">`.
    public static let hexes = ["#FFFFFF", "#FFFF54", "#54FFFF", "#54FF54"]

    /// Componentes de 0 a 1, para quem desenha na tela.
    public static let components: [(red: Double, green: Double, blue: Double)] = [
        (1.00, 1.00, 1.00),
        (1.00, 1.00, 0.33),
        (0.33, 1.00, 1.00),
        (0.33, 1.00, 0.33),
    ]

    /// Qual das cores é de cada locutor.
    ///
    /// `"Locutor 2"` cai na segunda cor. Quem vier além da quarta volta ao
    /// começo — com mais de quatro vozes a cor deixa de identificar, mas
    /// continua marcando a troca.
    /// Rótulo sem número devolve `nil`, e não a primeira cor: pintar de
    /// branco um locutor que não se sabe qual é seria inventar identidade.
    /// Hoje `renumber` sempre entrega "Locutor N"; isto vale para o dia em que
    /// alguém mostrar o identificador cru do modelo.
    public static func index(for speaker: String?) -> Int? {
        guard let speaker, let number = Int(speaker.filter(\.isNumber)) else { return nil }
        return max(0, number - 1) % hexes.count
    }

    public static func hex(for speaker: String?) -> String? {
        index(for: speaker).map { hexes[$0] }
    }
}
