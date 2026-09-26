import AppKit
import SwiftUI

// MARK: - Cor

/// A paleta do app: verde sálvia em tom pastel, sobre neutros levemente
/// quentes.
///
/// Era violeta-índigo, tirado do ícone, e saiu por ser o tom mais repetido
/// em produto de IA — somado ao degradê e às sombras, a interface parecia
/// gerada, não desenhada. Sálvia porque é calmo e lembra "sinal bom, ao
/// vivo", e porque nada na categoria usa.
///
/// Sem degradê e sem sombra: a profundidade vem do contraste entre o fundo
/// e o cartão, e de um fio de 1 px.
///
/// Cada cor tem um papel, não um nome de tinta, e cada papel tem um valor
/// para o claro e outro para o escuro — o escuro não é o claro invertido.
/// Contrastes medidos (WCAG) ao lado de cada par; texto abaixo de 4,5:1 e
/// ícone abaixo de 3:1 não entram. O botão principal é sálvia com texto
/// verde-musgo (8,2:1), não com texto branco, que num pastel não se lê.
extension Color {
    /// Fundo da janela.
    static let canvas = dynamic(light: 0xF5F6F2, dark: 0x1A1C19)
    /// Cartões sobre o fundo.
    static let card = dynamic(light: 0xFFFFFF, dark: 0x232621)
    /// Campo dos menus e trilho dos controles.
    static let field = dynamic(light: 0xEEF0EA, dark: 0x2E322C)
    /// O mesmo campo com o ponteiro em cima.
    static let fieldHover = dynamic(light: 0xE4E8DF, dark: 0x383D35)
    /// Fio de 1 px que separa cartão do fundo e contorna os secundários.
    static let hairline = dynamic(light: 0xE2E6DC, dark: 0x363B33)

    /// Texto principal: 12,7:1 sobre o campo.
    static let ink = dynamic(light: 0x262A24, dark: 0xE6E9E2)
    /// Texto secundário: 5,1:1 sobre o fundo claro, 6,4:1 sobre o cartão escuro.
    static let inkSoft = dynamic(light: 0x626B5F, dark: 0xA3AA9F)

    /// Preenchimento do botão principal.
    static let brand = dynamic(light: 0xBFD8C2, dark: 0xA9CBAE)
    /// Texto sobre `brand`: 8,2:1 no claro, 7:1 no escuro.
    static let onBrand = dynamic(light: 0x1E3A26, dark: 0x1E3A26)
    /// Texto, ícone e traço da marca: 4,9:1 até sobre a linha selecionada,
    /// 8,4:1 no escuro.
    static let brandInk = dynamic(light: 0x37704A, dark: 0x9BCBA5)
    /// Fundo da linha selecionada e do círculo da seta dos menus.
    static let brandSoft = dynamic(light: 0xE3EFE4, dark: 0x2C3D30)

    /// Um tom por seção do painel, só no ladrilho do ícone: sálvia, areia e
    /// argila, da mesma família quente. O ícone passa de 4,3:1 sobre o
    /// próprio ladrilho nos dois temas.
    enum Tint {
        case sage, sand, clay

        var tile: Color {
            switch self {
            case .sage: Color.dynamic(light: 0xE3EFE4, dark: 0x2C3D30)
            case .sand: Color.dynamic(light: 0xF3EBD6, dark: 0x3D3726)
            case .clay: Color.dynamic(light: 0xF6E4DA, dark: 0x44302A)
            }
        }

        var icon: Color {
            switch self {
            case .sage: Color.dynamic(light: 0x3E7A52, dark: 0x9BCBA5)
            case .sand: Color.dynamic(light: 0x7A6326, dark: 0xE0C987)
            case .clay: Color.dynamic(light: 0x9A5236, dark: 0xEDB39A)
            }
        }
    }

    init(hex: UInt32) {
        self.init(nsColor: .hex(hex))
    }

    fileprivate static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .hex(dark) : .hex(light)
        })
    }
}

private extension NSColor {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
    }
}

// MARK: - Tipografia

/// Dois tipos, cada um com um trabalho só.
///
/// New York — a serifada do próprio sistema — nos títulos: é o que dá o ar
/// mais refinado, e vem com o macOS, sem arquivo de fonte para carregar.
/// SF Pro em todo o resto, porque controle, número e legenda precisam ler
/// rápido em corpo pequeno, e é para isso que ela foi desenhada.
///
/// Escala curta de propósito — 17 · 14 · 13 · 11 · 10 —, com o piso em 10.
/// Havia texto em 8 e 8,5 pt, pequeno demais para ler sem esforço.
extension Font {
    /// Nome do app no topo do painel.
    static let display = Font.system(size: 17, weight: .semibold, design: .serif)
    /// Título de seção e de lista.
    static let heading = Font.system(size: 14, weight: .semibold, design: .serif)
    /// Texto de controle e de lista.
    static let control = Font.system(size: 13)
    static let controlStrong = Font.system(size: 13, weight: .medium)
    /// Rótulo sobre um controle e nota explicativa.
    static let caption = Font.system(size: 11)
    static let captionStrong = Font.system(size: 11, weight: .medium)
    /// Tempo, contagem, estado. O menor corpo do app.
    static let meta = Font.system(size: 10)
}

// MARK: - Superfícies

extension View {
    /// Cartão chapado com fio de 1 px. Sem sombra: era ela, somada ao
    /// degradê, que dava à interface o ar de retângulo flutuando.
    func cardSurface(radius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(Color.card, in: shape)
            .overlay(shape.strokeBorder(Color.hairline, lineWidth: 1))
    }
}
