import SwiftUI

// Os controles desenhados pelo app: menu em pílula, botões pastel, seletor
// segmentado e ladrilho de ícone. O macOS não deixa reestilizar `Picker` por
// fora (não há `PickerStyle` público), então o menu é um `Menu` com o
// `Picker` do sistema dentro: a lista que abre continua sendo a nativa, com
// marca de seleção e teclado, e só o campo fechado é nosso.

// MARK: - Menu em pílula

struct PillPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    /// Largura fixa; `.infinity` ocupa a linha inteira; `nil` acompanha o texto.
    var width: CGFloat?

    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(label(selection))
                    .font(controlSize == .small ? .caption : .control)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if width != nil { Spacer(minLength: 0) }
                Image(systemName: "chevron.down")
                    .font(.system(size: controlSize == .small ? 7.5 : 8.5, weight: .bold))
                    .foregroundStyle(Color.brandInk)
                    .frame(width: chevronSize, height: chevronSize)
                    .background(Color.brandSoft, in: Circle())
            }
            .padding(.leading, controlSize == .small ? 9 : 11)
            .padding(.trailing, 5)
            .frame(height: height)
            .frame(width: fills ? nil : width)
            .frame(maxWidth: fills ? .infinity : nil)
            .background(hovered ? Color.fieldHover : Color.field,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !fills, vertical: true)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(label(selection))
    }

    private var fills: Bool { width == .infinity }
    private var height: CGFloat { controlSize == .small ? 24 : controlSize == .large ? 32 : 28 }
    private var chevronSize: CGFloat { controlSize == .small ? 15 : 18 }
}

// MARK: - Botões

/// Principal: lavanda com texto marinho. Secundário: cartão com fio fino e o
/// ícone na cor da marca. O tamanho segue o `controlSize`, como os do sistema.
struct PastelButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, prominent: prominent)
    }

    private struct Styled: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.controlSize) private var controlSize
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .labelStyle(PastelLabelStyle(iconColor: prominent ? .onBrand : .brandInk))
                .font(controlSize == .small ? .captionStrong : .controlStrong)
                .foregroundStyle(prominent ? Color.onBrand : Color.ink)
                .padding(.horizontal, controlSize == .small ? 10 : 13)
                .frame(minHeight: height)
                .background(fill, in: shape)
                .overlay(prominent ? nil : shape.strokeBorder(Color.hairline, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(shape)
                .onHover { hovered = $0 }
        }

        private var fill: Color {
            if prominent {
                return configuration.isPressed ? .brand.opacity(0.8) : hovered ? .brand.opacity(0.9) : .brand
            }
            return configuration.isPressed ? .fieldHover : hovered ? .field : .card
        }

        private var height: CGFloat { controlSize == .small ? 24 : controlSize == .large ? 34 : 28 }
        private var radius: CGFloat { controlSize == .large ? 11 : 9 }
    }
}

/// Ícone na cor pedida e texto na cor do botão, com o espaço de sempre.
struct PastelLabelStyle: LabelStyle {
    var iconColor: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .foregroundStyle(iconColor)
                .imageScale(.medium)
            configuration.title
        }
    }
}

/// Botão redondo e suave da reprodução; o principal é maior e cheio.
struct CircleButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, prominent: prominent)
    }

    private struct Styled: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(prominent ? Color.onBrand : Color.brandInk)
                .frame(width: prominent ? 44 : 34, height: prominent ? 44 : 34)
                .background(fill, in: Circle())
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Circle())
                .onHover { hovered = $0 }
        }

        private var fill: Color {
            if prominent { return configuration.isPressed ? .brand.opacity(0.8) : .brand }
            return configuration.isPressed || hovered ? .fieldHover : .field
        }
    }
}

// MARK: - Seletor segmentado

/// Trilho em pílula com o escolhido num marcador branco.
struct PillSegmented<Value: Hashable & Identifiable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    @Environment(\.isEnabled) private var isEnabled
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let chosen = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(chosen ? .controlStrong : .control)
                        .foregroundStyle(chosen ? Color.ink : Color.inkSoft)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background {
                            if chosen {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.card)
                                    .strokeBorder(Color.hairline, lineWidth: 1)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Ladrilho de ícone

/// O ícone de uma seção num quadrado arredondado do tom dela.
struct IconTile: View {
    let symbol: String
    let tint: Color.Tint
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(tint.icon)
            .frame(width: size, height: size)
            .background(tint.tile, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}
