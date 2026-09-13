import AppKit
import AudioCapture
import CoreGraphics
import Foundation

// Modo executado quando o probe e aberto como .app, sem argumentos.
//
// Existe por um motivo especifico: a permissao de captura de audio e concedida
// por identidade de codigo, e um binario solto no terminal herda a atribuicao
// do processo pai. Sem bundle assinado, o sistema nega em silencio -- entrega
// quadros zerados no ritmo certo, sem erro nenhum. Aberto com `open`, o app
// tem identidade propria e o macOS finalmente mostra o pedido de permissao.

/// Prova que a selecao de aplicativo e respeitada.
///
/// O sintoma relatado era o app capturar audio "em geral", independente da
/// escolha. Este teste grava DUAS vezes: uma apontando para um aplicativo que
/// esta em silencio enquanto outro toca, e outra apontando para quem toca.
/// A primeira tem que vir zerada; a segunda, com sinal.
func runIsolationTest() -> Never {
    let reportPath = "/tmp/tradutor-isolamento.txt"
    var lines: [String] = []
    func report(_ text: String) {
        lines.append(text)
        try? lines.joined(separator: "\n").write(
            toFile: reportPath, atomically: true, encoding: .utf8
        )
    }

    report("teste de isolamento  \(Date().formatted(date: .abbreviated, time: .standard))")

    let all = (try? AudioProcessList.all()) ?? []
    guard let loud = all.first(where: { $0.isPlaying && !$0.isSystemWide }) else {
        report("FALHA: nenhum app tocando som. Comece um audio antes.")
        exit(1)
    }
    // Um aplicativo real, em silencio, diferente do que esta tocando.
    guard let quiet = all.first(where: {
        !$0.isPlaying && !$0.isSystemWide && $0.id != loud.id && $0.id != Bundle.main.bundleIdentifier
    }) else {
        report("FALHA: nenhum app em silencio para servir de controle.")
        exit(1)
    }

    report("tocando : \(loud.name)  pids \(loud.pids.map(String.init).joined(separator: ", "))")
    report("silencio: \(quiet.name)  pids \(quiet.pids.map(String.init).joined(separator: ", "))")
    report("")

    func measure(_ target: AudioProcess, seconds: Double) -> Float {
        let ring = RingBuffer()
        let tap = ProcessTap(process: target)
        guard (try? tap.start(onSamples: { ring.write($0) })) != nil else { return -1 }
        defer { tap.stop() }

        guard let resampler = try? Resampler(inputSampleRate: tap.format?.mSampleRate ?? 48_000) else {
            return -1
        }
        var collected: [Float] = []
        var scratch = [Float](repeating: 0, count: 48_000)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            let count = ring.read(into: &scratch, maximum: scratch.count)
            if count > 0 {
                collected.append(contentsOf: (try? resampler.resample(Array(scratch[0..<count]))) ?? [])
            }
        }
        guard !collected.isEmpty else { return 0 }
        var energy: Float = 0
        for sample in collected { energy += sample * sample }
        return (energy / Float(collected.count)).squareRoot()
    }

    let quietRMS = measure(quiet, seconds: 4)
    report(String(format: "rms capturando \"%@\" (em silencio): %.5f", quiet.name, quietRMS))

    let loudRMS = measure(loud, seconds: 4)
    report(String(format: "rms capturando \"%@\" (tocando)    : %.5f", loud.name, loudRMS))
    report("")

    var failures = 0
    if quietRMS > 0.001 {
        report("FALHA: o app em silencio devolveu audio — a selecao esta sendo ignorada")
        failures += 1
    } else {
        report("ok  app em silencio devolve silencio: a selecao e respeitada")
    }
    if loudRMS <= 0.001 {
        report("FALHA: o app que estava tocando devolveu silencio")
        failures += 1
    } else {
        report("ok  app que toca devolve audio")
    }

    report(failures == 0 ? "\nPASSOU" : "\nFALHOU")
    showResult(
        title: failures == 0 ? "Seleção respeitada" : "Seleção sendo ignorada",
        body: """
        Tocando: \(loud.name) — RMS \(String(format: "%.5f", loudRMS))
        Em silêncio: \(quiet.name) — RMS \(String(format: "%.5f", quietRMS))
        """,
        ok: failures == 0,
        filePath: reportPath
    )
}

/// Mostra o resultado na tela.
///
/// Antes o diagnostico so escrevia num arquivo em /tmp e saia — clicar no app
/// nao produzia nada visivel, o que e um jeito pessimo de entregar um
/// diagnostico para alguem.
func showResult(title: String, body: String, ok: Bool, filePath: String) -> Never {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    application.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = body
    alert.alertStyle = ok ? .informational : .warning
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Mostrar relatório")

    if alert.runModal() == .alertSecondButtonReturn {
        NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: "")
    }
    exit(ok ? 0 : 1)
}

/// Testa a captura de "Todo o audio do sistema".
///
/// Esse caminho usa `initStereoGlobalTapButExcludeProcesses:`, cuja lista e de
/// EXCLUSAO. Fixar `isExclusive = false` depois do inicializador transformava
/// o tap global em um tap inclusivo de lista vazia — capture nada.
func runSystemWideTest() -> Never {
    let reportPath = "/tmp/tradutor-geral.txt"
    var lines: [String] = []
    func report(_ text: String) {
        lines.append(text)
        try? lines.joined(separator: "\n").write(
            toFile: reportPath, atomically: true, encoding: .utf8
        )
    }

    report("tap global  \(Date().formatted(date: .abbreviated, time: .standard))")

    let ring = RingBuffer()
    let tap = ProcessTap(process: .systemWide)
    do {
        try tap.start { samples in ring.write(samples) }
    } catch {
        report("FALHA ao iniciar: \(error.localizedDescription)")
        showResult(title: "Tap global falhou", body: error.localizedDescription,
                   ok: false, filePath: reportPath)
    }
    defer { tap.stop() }

    report("formato: \(Int(tap.format?.mSampleRate ?? 0)) Hz, \(tap.format?.mChannelsPerFrame ?? 0) canais")

    let resampler = try! Resampler(inputSampleRate: tap.format?.mSampleRate ?? 48_000)
    var collected: [Float] = []
    var scratch = [Float](repeating: 0, count: 48_000)
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
        let count = ring.read(into: &scratch, maximum: scratch.count)
        if count > 0 {
            collected.append(contentsOf: (try? resampler.resample(Array(scratch[0..<count]))) ?? [])
        }
    }
    tap.stop()

    let peak = collected.reduce(Float(0)) { Swift.max($0, Swift.abs($1)) }
    var energy: Float = 0
    for sample in collected { energy += sample * sample }
    let rms = collected.isEmpty ? 0 : (energy / Float(collected.count)).squareRoot()

    report(String(format: "pico: %.5f   rms: %.5f", peak, rms))
    let ok = rms > 0.0001
    report(ok ? "\nPASSOU. O tap global captura." : "\nSILENCIO. O tap global nao capturou nada.")

    showResult(
        title: ok ? "Áudio do sistema capturado" : "Tap global em silêncio",
        body: ok
            ? "Pico \(String(format: "%.3f", peak)), RMS \(String(format: "%.3f", rms))."
            : "Nada foi capturado. Confirme que há som tocando e que a permissão está concedida.",
        ok: ok,
        filePath: reportPath
    )
}

func runBundledDiagnostic() -> Never {
    let reportPath = "/tmp/tradutor-diag.txt"
    var lines: [String] = []

    func report(_ text: String) {
        lines.append(text)
        try? lines.joined(separator: "\n").write(
            toFile: reportPath, atomically: true, encoding: .utf8
        )
    }

    report("diagnostico do tradutor  \(Date().formatted(date: .abbreviated, time: .standard))")
    report("bundle: \(Bundle.main.bundleIdentifier ?? "nenhum")")

    // Em macOS 15+ o process tap e gated pela permissao de gravacao de tela e
    // audio do sistema. Negada, ela nao devolve erro: o tap abre, o IOProc
    // dispara na cadencia certa e os quadros vem zerados. Por isso a checagem
    // vem antes de qualquer conclusao sobre o audio.
    // Atencao: `CGPreflightScreenCaptureAccess` cobre apenas o servico de
    // gravacao de tela. O painel do sistema tem DUAS listas, e a segunda
    // ("Apenas Gravacao do Audio do Sistema") e um servico separado que este
    // preflight nao enxerga. Ou seja: falso aqui nao prova nada sobre o tap.
    // Por isso a captura e tentada de qualquer jeito — quem decide sao as
    // amostras, nao o preflight.
    let screenAccess = CGPreflightScreenCaptureAccess()
    report("preflight de gravacao de tela: \(screenAccess ? "concedido" : "ausente")")
    report("(indicativo apenas; o tap depende da lista de audio do sistema)")
    report("")

    let candidates: [AudioProcess]
    do {
        candidates = try AudioProcessList.playing()
    } catch {
        report("FALHA ao listar processos: \(error.localizedDescription)")
        exit(1)
    }

    guard let target = candidates.first else {
        report("nenhum app tocando som agora.")
        report("deixe um video ou musica tocando e abra este app de novo.")
        exit(1)
    }

    report("alvo: \(target.name)  pid \(target.pid)")

    let ring = RingBuffer()
    let tap = ProcessTap(process: target)
    do {
        try tap.start { samples in ring.write(samples) }
    } catch {
        report("FALHA ao iniciar o tap: \(error.localizedDescription)")
        exit(1)
    }
    defer { tap.stop() }

    let inputRate = tap.format?.mSampleRate ?? 48_000
    report("formato do tap: \(Int(inputRate)) Hz, \(tap.format?.mChannelsPerFrame ?? 0) canais")

    let resampler = try! Resampler(inputSampleRate: inputRate)
    var collected: [Float] = []
    var scratch = [Float](repeating: 0, count: 48_000)
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
        let count = ring.read(into: &scratch, maximum: scratch.count)
        if count > 0 {
            collected.append(contentsOf: (try? resampler.resample(Array(scratch[0..<count]))) ?? [])
        }
    }
    tap.stop()

    let peak = collected.reduce(Float(0)) { Swift.max($0, Swift.abs($1)) }
    var energy: Float = 0
    for sample in collected { energy += sample * sample }
    let rms = collected.isEmpty ? 0 : (energy / Float(collected.count)).squareRoot()

    report("amostras: \(collected.count)   esperado: 80000")
    report(String(format: "pico: %.5f   rms: %.5f", peak, rms))
    report("")

    if rms > 0.0001 {
        let wav = "/tmp/tradutor-diag.wav"
        try? writeWAV(collected, sampleRate: 16_000, to: wav)
        report("PASSOU. Audio capturado de \(target.name).")
        report("gravado em \(wav)")
        showResult(
            title: "Captura funcionando",
            body: """
            Áudio capturado de \(target.name).

            Pico \(String(format: "%.3f", peak)), RMS \(String(format: "%.3f", rms)).
            Gravado em \(wav).
            """,
            ok: true,
            filePath: reportPath
        )
    } else {
        report("SILENCIO. Quadros chegaram no ritmo certo mas todos zerados.")
        report("")
        report("Causas, em ordem de probabilidade:")
        report("  1. o app escolhido nao estava emitindo som durante os 5 s")
        report("  2. permissao ausente nas DUAS listas de Ajustes do Sistema >")
        report("     Privacidade e Seguranca > Gravacao do Audio do Sistema e da Tela")
        report("  3. o app foi recompilado depois de a permissao ser concedida:")
        report("     assinatura ad-hoc muda a cada build e o TCC deixa de casar.")
        report("     Remova a entrada com o botao - e adicione de novo.")
        showResult(
            title: "Silêncio: nada foi capturado",
            body: """
            O tap abriu em \(target.name) e os quadros chegaram no ritmo certo,             mas todos vieram zerados.

            Causas, em ordem:
            1. o aplicativo não estava emitindo som durante os 5 segundos
            2. falta permissão em Ajustes do Sistema > Privacidade e Segurança >             Gravação do Áudio do Sistema e da Tela (as DUAS listas)
            3. o app foi recompilado depois de a permissão ser dada: a assinatura             ad-hoc muda a cada build e o sistema deixa de reconhecê-la.             Remova a entrada com o botão − e adicione de novo.
            """,
            ok: false,
            filePath: reportPath
        )
    }
    exit(rms > 0.0001 ? 0 : 1)
}
