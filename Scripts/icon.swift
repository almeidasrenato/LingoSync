// Desenha o ícone do app em vetor e grava um PNG de 1024 px.
//
//   swift Scripts/icon.swift <saida.png>
//
// Grade padrão do macOS: o quadrado arredondado ocupa 824 de 1024 px, com
// cantos contínuos e fundo transparente em volta. Chapado de propósito — sem
// degradê e sem sombra, na mesma paleta sálvia da interface (Brand.swift).
import AppKit
import SwiftUI

struct Icon: View {
    var body: some View {
        let side: CGFloat = 824
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                .fill(Color(red: 0xBF / 255, green: 0xD8 / 255, blue: 0xC2 / 255))
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                .strokeBorder(Color(red: 0xA9 / 255, green: 0xCB / 255, blue: 0xAE / 255), lineWidth: 6)
            Canvas { context, size in
                let s = size.width
                let paper = Color(red: 0xFB / 255, green: 0xFB / 255, blue: 0xF7 / 255)
                let moss = Color(red: 0x1E / 255, green: 0x3A / 255, blue: 0x26 / 255)
                let bubble = CGRect(x: s * 0.154, y: s * 0.218, width: s * 0.689, height: s * 0.478)
                context.fill(Path(roundedRect: bubble, cornerRadius: s * 0.152, style: .continuous),
                             with: .color(paper))
                var tail = Path()
                tail.move(to: CGPoint(x: s * 0.29, y: s * 0.69))
                tail.addLine(to: CGPoint(x: s * 0.248, y: s * 0.804))
                tail.addLine(to: CGPoint(x: s * 0.41, y: s * 0.69))
                tail.closeSubpath()
                context.fill(tail, with: .color(paper))
                let h = s * 0.0625
                for (end, y) in [(0.631, 0.349), (0.536, 0.448), (0.452, 0.545)] {
                    let line = CGRect(x: s * 0.234, y: s * y - h / 2, width: s * (end - 0.234), height: h)
                    context.fill(Path(roundedRect: line, cornerRadius: h / 2), with: .color(moss))
                }
            }
        }
        .frame(width: side, height: side)
        .frame(width: 1024, height: 1024)
    }
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let image = renderer.cgImage,
          let dest = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)
    else { fatalError("não consegui desenhar o ícone") }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
