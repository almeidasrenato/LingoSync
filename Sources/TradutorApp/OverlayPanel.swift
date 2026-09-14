import AppKit
import SwiftUI
import TradutorCore

/// O painel flutuante.
///
/// Uma janela comum nao serve para este caso: ela rouba o foco ao ser clicada,
/// some quando o video entra em tela cheia e nao acompanha a troca de desktop.
/// A combinacao de estilo e comportamento abaixo resolve os tres.
@MainActor
final class OverlayPanel: NSPanel {

    /// Nome sob o qual o AppKit guarda posicao e tamanho entre execucoes.
    private static let frameAutosaveName = "TradutorOverlayFrame"

    static let minimumOpacity = 0.82
    static let defaultSize = NSSize(width: 620, height: 300)
    static let minimumSize = NSSize(width: 380, height: 160)

    init(pipeline: Pipeline, onClose: @escaping () -> Void) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            // .nonactivatingPanel: clicar no painel nao tira o foco do video.
            styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .floating
        alphaValue = Self.minimumOpacity
        collectionBehavior = [
            .canJoinAllSpaces,      // segue o usuario entre desktops
            .stationary,            // nao desliza no Mission Control
            .fullScreenAuxiliary,   // aparece por cima de video em tela cheia
        ]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow

        // Tamanho fixo definido pelo usuario, nao pelo conteudo. Sem isto o
        // painel cresceria e encolheria a cada bloco novo, que e desconfortavel
        // de ler e faz o texto pular de posicao.
        contentMinSize = Self.minimumSize
        contentMaxSize = NSSize(width: 1400, height: 900)

        let hosting = NSHostingView(
            rootView: OverlayView(
                pipeline: pipeline,
                onClose: onClose,
                onOpacityChange: { [weak self] value in self?.alphaValue = value }
            )
        )
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        // Restaura o que o usuario deixou da ultima vez; so posiciona no
        // padrao quando nao ha nada guardado.
        if !setFrameUsingName(Self.frameAutosaveName) {
            setContentSize(Self.defaultSize)
            positionAtBottomCenter()
        }
        setFrameAutosaveName(Self.frameAutosaveName)
    }

    /// Volta ao tamanho de fabrica. Ligado ao botao nas preferencias, para o
    /// caso de o painel acabar arrastado para fora da tela ou pequeno demais.
    func resetToDefaultSize() {
        setContentSize(Self.defaultSize)
        positionAtBottomCenter()
        saveFrame(usingName: Self.frameAutosaveName)
    }

    /// Painel sem barra de titulo precisa disso para poder ser arrastado e
    /// receber teclado sem virar a janela principal do app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Painel sem barra de titulo nao mostra alcas de redimensionamento, mas
    /// as bordas continuam arrastaveis por causa de `.resizable`.
    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.12
        ))
    }
}
