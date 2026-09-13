import AudioCapture
import Foundation

// Command Line Tools nao traz Testing nem XCTest, entao as verificacoes vivem
// no proprio binario:  tradutor-probe selftest
//
// Cobrem os dois lugares onde um erro passa despercebido em producao: o ring
// buffer, que entrega audio embaralhado, e o segmentador, que entrega frases
// cortadas no meio.

private var failures = 0
private var checks = 0

private func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("  ok    \(label)")
    } else {
        failures += 1
        print("  FALHA \(label)")
    }
}

private let rate = 16_000

private func tone(
    _ seconds: Double,
    frequency: Float = 200,
    amplitude: Float = 0.3,
    sampleRate: Int = rate
) -> [Float] {
    (0..<Int(Double(sampleRate) * seconds)).map {
        sin(2 * Float.pi * frequency * Float($0) / Float(sampleRate)) * amplitude
    }
}

private func silence(_ seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(Double(rate) * seconds))
}

func runSelfTest() -> Never {
    print("ring buffer")
    do {
        let ring = RingBuffer(seconds: 1, sampleRate: 1000)
        let input = (0..<500).map { Float($0) }
        input.withUnsafeBufferPointer { ring.write($0) }
        var output = [Float](repeating: 0, count: 500)
        let count = ring.read(into: &output, maximum: 500)
        expect(count == 500, "le tudo que foi escrito")
        expect(Array(output[0..<500]) == input, "preserva a ordem das amostras")
        expect(ring.overflows == 0, "nao reporta estouro sem motivo")
    }
    do {
        let ring = RingBuffer(seconds: 1, sampleRate: 100)
        let input = (0..<250).map { Float($0) }
        input.withUnsafeBufferPointer { ring.write($0) }
        expect(ring.overflows == 1, "reporta estouro quando o consumidor fica para tras")
        var output = [Float](repeating: 0, count: 200)
        let count = ring.read(into: &output, maximum: 200)
        expect(count == 100, "entrega so o que cabe")
        expect(
            Array(output[0..<100]) == Array(input[150..<250]),
            "no estouro entrega o audio recente em ordem, nao um embaralhado"
        )
    }

    print("agrupamento de processos")
    do {
        // O bug do Chrome: o audio vive no helper de renderizacao, nunca no
        // processo principal. Escolher "Google Chrome" e capturar so ele
        // produz silencio absoluto, sem erro nenhum.
        let chromeMain = AudioProcessList.groupKey(
            for: "com.google.Chrome", executable: nil, pid: 1)
        let chromeHelper = AudioProcessList.groupKey(
            for: "com.google.Chrome.helper", executable: nil, pid: 2)
        let chromeRenderer = AudioProcessList.groupKey(
            for: "com.google.Chrome.helper.renderer", executable: nil, pid: 3)

        expect(chromeMain == "com.google.Chrome", "Chrome principal vira com.google.Chrome")
        expect(chromeHelper == chromeMain, "helper do Chrome cai no mesmo grupo")
        expect(chromeRenderer == chromeMain, "renderer do Chrome cai no mesmo grupo")

        // Aplicativos diferentes nao podem colidir.
        let safari = AudioProcessList.groupKey(for: "com.apple.Safari", executable: nil, pid: 4)
        expect(safari != chromeMain, "Safari nao cai no grupo do Chrome")

        // Sem bundle ID, cai no executavel.
        let cli = AudioProcessList.groupKey(for: nil, executable: "afplay", pid: 5)
        let cliAgain = AudioProcessList.groupKey(for: "", executable: "afplay", pid: 6)
        expect(cli == cliAgain, "processo sem bundle agrupa pelo executavel")

        // Identidade estavel: dois valores do mesmo app com isPlaying
        // diferente tem que continuar iguais, senao a selecao do Picker
        // e descartada assim que o app comeca a tocar.
        let parado = AudioProcess(id: "com.x", name: "X", objectIDs: [1], pids: [1], isPlaying: false)
        let tocando = AudioProcess(id: "com.x", name: "X", objectIDs: [1, 2], pids: [1, 2], isPlaying: true)
        expect(parado == tocando, "isPlaying nao quebra a identidade do aplicativo")
        expect([parado].contains(tocando), "selecao sobrevive ao app comecar a tocar")
    }

    print("resampler")
    do {
        let resampler = try! Resampler(inputSampleRate: 48_000)
        // Um segundo de seno gerado a 48 kHz, que e o que o tap entrega.
        let input = tone(1.0, frequency: 440, amplitude: 0.5, sampleRate: 48_000)
        expect(input.count == 48_000, "entrada de teste tem 1s a 48 kHz")
        let output = try! resampler.resample(input)
        expect(
            abs(output.count - 16_000) < 200,
            "48 kHz -> 16 kHz na razao 3:1 (saida \(output.count))"
        )
        var energy: Float = 0
        for sample in output { energy += sample * sample }
        let rms = (energy / Float(output.count)).squareRoot()
        expect(rms > 0.3 && rms < 0.4, "o filtro nao come o sinal (rms \(String(format: "%.3f", rms)))")
    }

    do {
        // O pipeline real chama resample() em blocos pequenos e sucessivos.
        // Se o conversor truncar em silencio, o audio some sem nenhum erro.
        let resampler = try! Resampler(inputSampleRate: 48_000)
        let input = tone(2.0, frequency: 440, amplitude: 0.5, sampleRate: 48_000)
        var total = 0
        for start in stride(from: 0, to: input.count, by: 4800) {
            let end = min(start + 4800, input.count)
            total += try! resampler.resample(Array(input[start..<end])).count
        }
        expect(
            abs(total - 32_000) < 400,
            "fluxo em blocos de 100 ms nao perde audio (saida \(total) para 32000)"
        )
    }

    print("segmentador")
    do {
        let segmenter = Segmenter()
        var closed = segmenter.feed(tone(1.5))
        expect(closed.isEmpty, "nao fecha enquanto ha fala")
        closed = segmenter.feed(silence(0.3))
        expect(closed.isEmpty, "pausa de 0,3s nao fecha o segmento")
        closed = segmenter.feed(silence(0.5))
        expect(closed.count == 1, "pausa acima de 0,6s fecha")
        expect(closed.first?.closedBySilence == true, "marca que fechou no silencio")
        expect((closed.first?.duration ?? 0) > 1.4, "nao perde o comeco da fala")
    }
    do {
        // Fala continua, sem nenhuma pausa. O texto agora sai por confirmacao
        // de prefixo estavel, sem cortar audio, entao o segmentador NAO deve
        // fechar nada aqui — ele so acumula.
        let segmenter = Segmenter()
        let closed = segmenter.feed(tone(10.0))
        expect(closed.isEmpty, "10s de fala continua nao forcam corte (deu \(closed.count))")
        expect(segmenter.isSpeaking, "o trecho continua em andamento")
        expect(
            abs(Double(segmenter.inFlight.count) / 16_000 - 10.0) < 0.5,
            "o audio fica inteiro em voo para ser re-reconhecido (\(String(format: "%.1f", Double(segmenter.inFlight.count) / 16_000))s)"
        )
    }

    do {
        // O teto de 12 s existe so como rede de seguranca contra alguem que
        // fale muito tempo sem respirar.
        let segmenter = Segmenter()
        let closed = segmenter.feed(tone(14.0))
        expect(!closed.isEmpty, "o teto de seguranca acaba disparando")
        expect(closed.first?.closedBySilence == false, "marca que foi o teto, nao silencio")
        expect(
            closed.allSatisfy { $0.duration <= 12.1 },
            "nada passa do teto de 12s (maior: \(String(format: "%.1f", closed.map(\.duration).max() ?? 0))s)"
        )
    }

    do {
        // Quando o teto dispara, o corte tem que cair num trecho quieto.
        var signal: [Float] = []
        for _ in 0..<8 {
            signal += tone(1.85, frequency: 200, amplitude: 0.3)
            signal += tone(0.15, frequency: 200, amplitude: 0.004)
        }

        let segmenter = Segmenter()
        let closed = segmenter.feed(signal)

        func rms(_ samples: ArraySlice<Float>) -> Float {
            guard !samples.isEmpty else { return 1 }
            var energy: Float = 0
            for sample in samples { energy += sample * sample }
            return (energy / Float(samples.count)).squareRoot()
        }

        let byCeiling = closed.filter { !$0.closedBySilence }
        expect(!byCeiling.isEmpty, "16s de sinal disparam o teto")
        let quietCuts = byCeiling.filter {
            rms($0.samples.suffix(Segmenter.frameSize)[...]) < 0.02
        }.count
        expect(
            quietCuts == byCeiling.count,
            "todo corte por teto cai no trecho quieto (\(quietCuts)/\(byCeiling.count))"
        )

        var carried = closed.reduce(0) { $0 + $1.samples.count }
        carried += segmenter.inFlight.count
        expect(
            carried >= signal.count - 16_000 / 5,
            "nada e duplicado nem perdido no corte (\(carried) de \(signal.count))"
        )
    }

    do {
        let segmenter = Segmenter()
        var samples = silence(1.0)
        samples[8000] = 0.9
        expect(segmenter.feed(samples).isEmpty, "um estalo isolado nao abre segmento")
    }

    do {
        // Fala baixa: o piso absoluto antigo (0,006) ficava acima dela e o
        // trecho nunca abria — a fala inteira sumia da tela.
        let segmenter = Segmenter()
        var closed = segmenter.feed(tone(2.0, amplitude: 0.012))
        expect(closed.isEmpty && segmenter.isSpeaking, "fala baixa abre trecho")
        closed = segmenter.feed(silence(0.8))
        expect(closed.count == 1, "fala baixa fecha normalmente na pausa")
        expect((closed.first?.duration ?? 0) > 1.8, "a fala baixa vem inteira")
    }

    do {
        // Histerese: a voz caindo no fim da frase nao pode fechar o trecho no
        // meio. Com um limiar so, o trecho fechava ali e o resto se perdia.
        let segmenter = Segmenter()
        var closed = segmenter.feed(tone(1.0, amplitude: 0.30))
        closed += segmenter.feed(tone(1.2, amplitude: 0.020))
        expect(closed.isEmpty, "voz que baixa no fim da frase nao fecha o trecho")
        expect(segmenter.isSpeaking, "o trecho continua aberto durante a queda")
        closed += segmenter.feed(silence(0.8))
        expect(closed.count == 1, "so a pausa de verdade fecha")
        expect(
            (closed.first?.duration ?? 0) > 2.0,
            "o trecho traz fala normal e fala baixa juntas (\(String(format: "%.1f", closed.first?.duration ?? 0))s)"
        )
    }

    print("")
    if failures == 0 {
        print("\(checks) verificacoes, tudo passou")
        exit(0)
    } else {
        print("\(failures) de \(checks) verificacoes falharam")
        exit(1)
    }
}
