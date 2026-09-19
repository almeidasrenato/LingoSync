import AppKit
import AVFoundation
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

// MARK: - Duas capturas ao mesmo tempo

/// Uma medida de um lado da captura.
private struct Medida {
    var amostras = 0
    var esperadas = 0
    var pico: Float = 0
    var rms: Float = 0
    /// Taxa lida ao iniciar, e de novo no fim.
    var taxa: Double = 0
    var taxaFinal: Double = 0
    /// Quanto demorou até a primeira amostra chegar. Bluetooth troca de perfil
    /// ao abrir o microfone e o primeiro segundo pode vir vazio.
    var primeiraMs: Int = -1
    /// Frequência dominante por cruzamento de zero. O professor sintético é um
    /// tom de 220 Hz: se sair perto de 73 Hz, o áudio chegou a 16 kHz e foi
    /// reamostrado como se fosse 48 kHz — taxa velha, não perda de dados.
    var freq: Double = 0
    /// Quantas vezes a fonte trocou de taxa durante a medição.
    var trocas = 0
    var estouros = 0
}

private func frequencia(_ samples: [Float]) -> Double {
    guard samples.count > 1 else { return 0 }
    var cruzamentos = 0
    for indice in 1..<samples.count
    where (samples[indice - 1] < 0) != (samples[indice] < 0) { cruzamentos += 1 }
    return Double(cruzamentos) / 2 / (Double(samples.count) / 16_000)
}

private struct Duplo {
    var tap = Medida()
    var mic = Medida()
    /// Entradas que o sistema oferecia enquanto o tap estava de pé. O próprio
    /// aggregate device aparece aqui e tem que ser filtrado, senão a prática
    /// capturaria a si mesma.
    var entradas: [String] = []
    var diagnostico: String?
    var erro: String?
}

private func estatistica(_ samples: [Float]) -> (pico: Float, rms: Float) {
    guard !samples.isEmpty else { return (0, 0) }
    var energia: Float = 0
    var pico: Float = 0
    for amostra in samples {
        energia += amostra * amostra
        pico = Swift.max(pico, Swift.abs(amostra))
    }
    return (pico, (energia / Float(samples.count)).squareRoot())
}

/// Liga os dois lados e mede os dois ao mesmo tempo.
///
/// `tapPrimeiro` existe porque a ordem importa em Core Audio: o tap cria um
/// aggregate device e o `AVAudioEngine` lê o formato da entrada ao iniciar.
/// Se só uma das ordens funcionar, é melhor saber agora.
private func medirJuntos(
    process: AudioProcess, tapPrimeiro: Bool, segundos: Double,
    usarTap: Bool = true, usarMic: Bool = true, dispositivo: AudioInputDevice? = nil
) -> Duplo {
    var resultado = Duplo()

    let anelApp = RingBuffer()
    let anelMic = RingBuffer()
    let tap = ProcessTap(process: process)
    let mic = MicrophoneTap(device: dispositivo)
    var tapLigado = false
    var micLigado = false
    defer {
        if tapLigado { tap.stop() }
        if micLigado { mic.stop() }
    }

    func ligarTap() -> String? {
        do {
            try tap.start { amostras in anelApp.write(amostras) }
            tapLigado = true
            return nil
        } catch {
            return "tap do app falhou: \(error.localizedDescription)"
        }
    }
    func ligarMic() -> String? {
        do {
            try mic.start { amostras in anelMic.write(amostras) }
            micLigado = true
            return nil
        } catch {
            return "microfone falhou: \(error.localizedDescription)"
        }
    }

    var ordem: [() -> String?] = []
    if usarTap { ordem.append(ligarTap) }
    if usarMic { ordem.append(ligarMic) }
    if !tapPrimeiro { ordem.reverse() }
    for ligar in ordem {
        if let erro = ligar() {
            resultado.erro = erro
            return resultado
        }
    }

    let taxaApp = tapLigado ? (tap.format?.mSampleRate ?? 48_000) : 0
    let taxaMic = micLigado ? (mic.sampleRate ?? 48_000) : 0
    resultado.tap.taxa = taxaApp
    resultado.mic.taxa = taxaMic
    resultado.entradas = AudioInputList.all().map(\.name)

    var converteApp = tapLigado ? try? Resampler(inputSampleRate: taxaApp) : nil
    var converteMic = micLigado ? try? Resampler(inputSampleRate: taxaMic) : nil
    if (tapLigado && converteApp == nil) || (micLigado && converteMic == nil) {
        resultado.erro = "resampler recusou as taxas \(Int(taxaApp)) / \(Int(taxaMic))"
        return resultado
    }

    var doApp: [Float] = []
    var doMic: [Float] = []
    var scratch = [Float](repeating: 0, count: 48_000)
    let inicio = Date()
    let fim = inicio.addingTimeInterval(segundos)
    while Date() < fim {
        Thread.sleep(forTimeInterval: 0.05)
        // A fonte troca de taxa em serviço; reamostrar com a razão velha
        // acelera a fala sem dar erro. É o defeito que este gate achou.
        if tapLigado, let atual = tap.currentSampleRate, atual > 0,
           let atualConversor = converteApp, abs(atual - atualConversor.inputSampleRate) > 1,
           let novo = try? Resampler(inputSampleRate: atual) {
            converteApp = novo
            resultado.tap.trocas += 1
        }
        if micLigado, let atual = mic.sampleRate, atual > 0,
           let atualConversor = converteMic, abs(atual - atualConversor.inputSampleRate) > 1,
           let novo = try? Resampler(inputSampleRate: atual) {
            converteMic = novo
            resultado.mic.trocas += 1
        }

        if let converteApp {
            let lidoApp = anelApp.read(into: &scratch, maximum: scratch.count)
            if lidoApp > 0 {
                if resultado.tap.primeiraMs < 0 {
                    resultado.tap.primeiraMs = Int(Date().timeIntervalSince(inicio) * 1000)
                }
                doApp.append(contentsOf: (try? converteApp.resample(Array(scratch[0..<lidoApp]))) ?? [])
            }
        }
        if let converteMic {
            let lidoMic = anelMic.read(into: &scratch, maximum: scratch.count)
            if lidoMic > 0 {
                if resultado.mic.primeiraMs < 0 {
                    resultado.mic.primeiraMs = Int(Date().timeIntervalSince(inicio) * 1000)
                }
                doMic.append(contentsOf: (try? converteMic.resample(Array(scratch[0..<lidoMic]))) ?? [])
            }
        }
    }

    // As duas leituras lado a lado: qual delas acompanha a troca de perfil.
    if tapLigado {
        resultado.diagnostico = String(
            format: "taxas do tap no fim: formato %.0f · aggregate %.0f",
            tap.tapFormatSampleRate ?? 0, tap.aggregateSampleRate ?? 0
        )
    }
    resultado.tap.taxaFinal = tapLigado ? (tap.format?.mSampleRate ?? 0) : 0
    resultado.mic.taxaFinal = micLigado ? (mic.sampleRate ?? 0) : 0

    let esperadas = Int(segundos * 16_000)
    let estatApp = estatistica(doApp)
    let estatMic = estatistica(doMic)
    resultado.tap.amostras = doApp.count
    resultado.tap.esperadas = esperadas
    resultado.tap.pico = estatApp.pico
    resultado.tap.rms = estatApp.rms
    resultado.tap.freq = frequencia(doApp)
    resultado.tap.estouros = anelApp.overflows
    resultado.mic.amostras = doMic.count
    resultado.mic.esperadas = esperadas
    resultado.mic.pico = estatMic.pico
    resultado.mic.rms = estatMic.rms
    resultado.mic.freq = frequencia(doMic)
    resultado.mic.estouros = anelMic.overflows
    return resultado
}

/// Pede o microfone sem travar o laço principal.
///
/// A caixa do sistema não aparece com a thread principal bloqueada num
/// semáforo — o pedido fica pendente e o teste "falha" por permissão que
/// ninguém chegou a recusar.
private func pedirMicrofone() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return true
    case .notDetermined:
        var concedido = false
        var respondeu = false
        AVCaptureDevice.requestAccess(for: .audio) { permitido in
            concedido = permitido
            respondeu = true
        }
        // `before: .distantFuture` trava: a resposta chega em outra thread e
        // nada acorda o laço. Espera curta e repetida, com teto.
        let limite = Date().addingTimeInterval(60)
        while !respondeu, Date() < limite {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return concedido
    default:
        return false
    }
}

/// As duas capturas convivem?
///
/// O modo de prática ouve o aplicativo (tap do Core Audio, por aggregate
/// device) e o microfone (`AVAudioEngine`) ao mesmo tempo. Nada no app faz
/// isso hoje: `Pipeline.start` escolhe UMA fonte. Sem essa convivência não há
/// feature nenhuma, então ela é medida antes de qualquer interface.
func runDualCaptureTest() -> Never {
    let reportPath = "/tmp/tradutor-duplo.txt"
    var lines: [String] = []
    func report(_ text: String) {
        lines.append(text)
        try? lines.joined(separator: "\n").write(
            toFile: reportPath, atomically: true, encoding: .utf8
        )
    }

    report("duas capturas ao mesmo tempo  \(Date().formatted(date: .abbreviated, time: .standard))")
    report("")

    let todos = (try? AudioProcessList.all()) ?? []
    guard let tocando = todos.first(where: {
        $0.isPlaying && !$0.isSystemWide && !$0.isMicrophone
            && $0.id != Bundle.main.bundleIdentifier
    }) else {
        report("FALHA: nenhum aplicativo tocando som.")
        report("Comece um áudio (navegador, Música, o que for) e rode de novo —")
        report("sem som, silêncio do tap não se distingue de tap quebrado.")
        showResult(
            title: "Nenhum app tocando som",
            body: "Comece um áudio em algum aplicativo e rode o teste de novo.",
            ok: false,
            filePath: reportPath
        )
    }

    report("professor: \(tocando.name)  pids \(tocando.pids.map(String.init).joined(separator: ", "))")

    guard pedirMicrofone() else {
        report("FALHA: acesso ao microfone negado.")
        showResult(
            title: "Microfone negado",
            body: "Ajustes do Sistema › Privacidade e Segurança › Microfone.",
            ok: false,
            filePath: reportPath
        )
    }
    report("microfone: \(AudioInputList.systemDefault?.name ?? "padrão do sistema")")
    report("")

    func relatar(_ titulo: String, _ resultado: Duplo) {
        report(titulo)
        if let erro = resultado.erro {
            report("  FALHA: \(erro)")
            return
        }
        for (lado, medida) in [("app", resultado.tap), ("mic", resultado.mic)] {
            report(String(
                format: "  %@  %5d Hz%@  %6d/%6d amostras  1ª em %@  pico %.5f  rms %.5f%@",
                lado.padding(toLength: 4, withPad: " ", startingAt: 0),
                Int(medida.taxa),
                medida.taxaFinal != medida.taxa
                    ? " -> \(Int(medida.taxaFinal)) Hz NO FIM" : "",
                medida.amostras,
                medida.esperadas,
                medida.primeiraMs < 0 ? "nunca" : "\(medida.primeiraMs) ms",
                medida.pico,
                medida.rms,
                medida.amostras > 0
                    ? String(format: "  %.0f Hz", medida.freq)
                        + (medida.trocas > 0 ? "  \(medida.trocas) troca(s) de taxa" : "")
                        + (medida.estouros > 0 ? "  \(medida.estouros) estouros" : "")
                    : ""
            ))
        }
        if let diagnostico = resultado.diagnostico { report("  " + diagnostico) }
    }

    // Controle do tap sozinho: a régua contra a qual as fases são lidas.
    let soTap = medirJuntos(process: tocando, tapPrimeiro: true, segundos: 4, usarMic: false)
    relatar("controle — só o tap do app (4 s)", soTap)
    report("")

    // Cada entrada é medida sozinha e acompanhada. O fone Bluetooth troca de
    // perfil (A2DP 48 kHz -> HFP 16 kHz) quando o microfone abre, e a suspeita
    // é que o tap do app vá junto — com o formato lido no início, já velho.
    var candidatos: [(AudioInputDevice?, String)] = []
    if let interno = AudioInputList.builtIn { candidatos.append((interno, interno.name)) }
    candidatos.append((nil, "padrão do sistema"))

    var juntos: [(String, Duplo)] = []
    for (dispositivo, nome) in candidatos {
        let soMic = medirJuntos(
            process: tocando, tapPrimeiro: false, segundos: 4,
            usarTap: false, dispositivo: dispositivo
        )
        relatar("só o microfone — \(nome) (4 s)", soMic)

        let acompanhado = medirJuntos(
            process: tocando, tapPrimeiro: true, segundos: 6, dispositivo: dispositivo
        )
        relatar("tap + microfone — \(nome) (6 s)", acompanhado)
        report("")
        juntos.append((nome, acompanhado))
    }

    // O aggregate device do tap aparece como entrada enquanto ele está de pé.
    // `AudioInputList` o descarta pelo prefixo do nome; oferecê-lo seria
    // capturar a si mesmo.
    let entradas = soTap.entradas
    report("entradas visíveis com o tap de pé: \(entradas.joined(separator: ", "))")
    let vazou = entradas.contains { $0.hasPrefix("Tradutor") }
    report("")

    var falhas: [String] = []

    func porSegundo(_ medida: Medida) -> Double {
        medida.esperadas > 0 ? Double(medida.amostras) / (Double(medida.esperadas) / 16_000) : 0
    }
    let refTap = porSegundo(soTap.tap)
    let refFreq = soTap.tap.freq
    report(String(format: "referência do tap sozinho: %.0f amostras/s · %.0f Hz", refTap, refFreq))
    report("")

    if let erro = soTap.erro { falhas.append("controle do tap: \(erro)") }
    if soTap.tap.rms <= 0.0001 {
        falhas.append("controle: o tap veio em silêncio (permissão de Gravação de Tela?)")
    }

    for (nome, fase) in juntos {
        if let erro = fase.erro {
            falhas.append("\(nome): \(erro)")
            continue
        }
        if fase.mic.amostras == 0 {
            falhas.append("\(nome): o microfone não entregou amostra nenhuma")
        } else if fase.mic.pico == 0 {
            falhas.append("\(nome): o microfone veio com zero exato (permissão negada)")
        }
        if fase.tap.amostras == 0 {
            falhas.append("\(nome): o tap não entregou amostra nenhuma")
        } else if refTap > 0, porSegundo(fase.tap) < refTap * 0.7 {
            // Menos amostras com a MESMA fala dentro delas quer dizer taxa
            // trocada, não áudio perdido: a frequência do tom sobe junto.
            let trocou = refFreq > 0 && fase.tap.freq > refFreq * 1.5
            falhas.append(String(
                format: "%@: o tap caiu para %.0f amostras/s (sozinho: %.0f)%@",
                nome, porSegundo(fase.tap), refTap,
                trocou
                    ? String(format: " e o tom subiu de %.0f para %.0f Hz — a TAXA do tap mudou com o microfone aberto",
                             refFreq, fase.tap.freq)
                    : " sem mudar o tom — áudio perdido de verdade"))
        }
    }
    if vazou { falhas.append("o aggregate device do tap está sendo oferecido como microfone") }

    if falhas.isEmpty {
        report("PASSOU. As duas capturas convivem nas duas ordens.")
    } else {
        report("FALHOU:")
        for falha in falhas { report("  " + falha) }
    }

    // Não é critério de aprovação — é leitura de eco. Com fone o microfone
    // fica no ruído de fundo; no alto-falante ele sobe junto com o professor.
    report("")
    report(String(
        format: "eco: rms do microfone com o professor tocando = %.5f%@",
        juntos.first?.1.mic.rms ?? 0,
        (juntos.first?.1.mic.rms ?? 0) > 0.01 ? "  (alto — provável alto-falante, não fone)" : "  (baixo)"
    ))

    showResult(
        title: falhas.isEmpty ? "As duas capturas convivem" : "Captura dupla falhou",
        body: falhas.isEmpty
            ? "Tap e microfone entregaram áudio juntos em \(juntos.count) entrada(s)."

            : falhas.joined(separator: "\n"),
        ok: falhas.isEmpty,
        filePath: reportPath
    )
}
