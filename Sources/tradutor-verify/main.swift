import AppKit
import AudioCapture
import AVFoundation
import Foundation
import CryptoKit
import TradutorCore

// Portoes das fases 4 e 5. Roda sem captura de audio, entao nao depende da
// permissao do sistema.
//
//   tradutor-verify dialogo         teste de contexto de dialogo (fase 5)
//   tradutor-verify audio <wav>     transcricao + traducao ponta a ponta
//   tradutor-verify quebra          quebra de linha, sem baixar modelo

/// Contador e impressao dos gates.
///
/// Um gate roda por invocacao e sai por `exit`, entao o contador e unico.
/// Eram catorze copias identicas desta funcao, uma dentro de cada gate.
private var failures = 0

private func expect(_ condition: Bool, _ label: String) {
    print(condition ? "  ok    \(label)" : "  FALHA \(label)")
    if !condition { failures += 1 }
}

@main
struct Verify {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            print("""
            uso:
              tradutor-verify dialogo       teste de contexto de dialogo (fase 5)
              tradutor-verify audio <wav> [origem] [destino]
                                            transcricao + traducao ponta a ponta
              tradutor-verify quebra        quebra de linha, sem baixar modelo
              tradutor-verify modelos       confere que trocar de idioma nao recarrega
              tradutor-verify frases        corte em frases e filtro de ruido
              tradutor-verify lote          traducao em lote: ordem e ganho de tempo
              tradutor-verify prefixo       confirmacao de prefixo estavel
              tradutor-verify tempos        formatacao e agrupamento de legendas
              tradutor-verify formatos      arquivo sem extensao e formato recusado
              tradutor-verify legendas      leitura de arquivo .srt
              tradutor-verify imagem [<video> [idioma]] [--gabarito <txt>] [--oraculo] [--faixa 0.76,1.0]
                                            legenda desenhada no video: sem video, a montagem;
                                            com video, as legendas lidas, o gabarito e o instante
              tradutor-verify faixas        video com duas faixas: escolha pelo idioma
              tradutor-verify fonte <video> [idioma] [motor]
                                            imprime as falas reconhecidas, uma por linha
              tradutor-verify traduzir <arquivo> [origem] [destino]
                                            traduz um arquivo de linhas com o motor do sistema
              tradutor-verify lotes         mede qual tamanho de lote compensa
              tradutor-verify sobreposicao  mede se o contexto reenviado melhora a traducao
              tradutor-verify motores       limiar do Whisper e separacao dos motores
              tradutor-verify captura       so transcrever, e a exportacao da captura
              tradutor-verify locutores     identificacao de quem fala, sem modelo
              tradutor-verify deepl         reparticao em blocos e link do site, sem rede
              tradutor-verify prefixo-ab <video> [origem] [destino] [motor]
                                            traduz as mesmas falas com e sem "Locutor N:"
              tradutor-verify fronteiras <video> [idioma] [motor]
                                            quantas legendas tem duas vozes dentro
              tradutor-verify vozes <audio> [limiares]
                                            varre o limiar e conta quantas vozes saem
              tradutor-verify vivo <audio>  o que o VAD do tempo real deixa passar
              tradutor-verify repescagem <audio> [motor] [idioma]
                                            reconhece de novo, isolado, o que a primeira passada perdeu
              tradutor-verify srt <arquivo> [origem] [destino] [motor] [--locutores] [--cores]
                                            gera legenda .srt de um video
              tradutor-verify alinhamento <audio> [motor] [idioma]
                                            mede a legenda contra onde ha voz
              tradutor-verify cobertura [<video> [idioma] [motor]]
                                            sem video: teste da regua; com video: cobertura por voz
                --audio-referencia <video>  PCM original com a mesma duracao
                --referencia <json>         salva/reutiliza as mesmas faixas Sortformer
                --json <arquivo>           grava as medidas e transcricoes
            """)
            exit(1)
        }

        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        switch arguments[1] {
        case "cobertura":
            guard arguments.count >= 3 else { await coverageSelftest(); return }
            await coverageGate(path: arguments[2],
                               language: arguments.count >= 4 ? (Language(rawValue: arguments[3]) ?? .japanese) : .japanese,
                               engine: arguments.count >= 5 ? (RecognitionEngine(rawValue: arguments[4]) ?? .apple) : .apple,
                               referencePath: option("--audio-referencia"), cachePath: option("--referencia"), jsonPath: option("--json"))
        case "dialogo": await dialogueGate()
        case "gerar":
            // gerar <video> <origem> <destino> <motor> <tradutor> <saida.json> [--locutores] [--modelo m]
            // Rascunho (antes de traduzir) e legendas finais, com tempos e locutor.
            let origem = Language(rawValue: arguments[3]) ?? .japanese
            let destino = Language(rawValue: arguments[4]) ?? .portuguese
            let builder = SubtitleFileBuilder()
            if let m = option("--modelo").flatMap(SpeakerDiarizer.Model.init(rawValue:)) { builder.speakerModel = m }
            let comecou = Date()
            let cues: [Cue]
            do {
                cues = try await builder.generate(
                    from: URL(fileURLWithPath: arguments[2]), source: origem, target: destino,
                    engine: RecognitionEngine(rawValue: arguments[5]) ?? .apple,
                    translation: TranslationEngine(rawValue: arguments[6]) ?? .apple,
                    diarize: arguments.contains("--locutores"), progress: { _, _, _, _ in })
            } catch {
                print("FALHA: \(error.localizedDescription)"); exit(1)
            }
            func linha(_ c: Cue) -> [String: Any] {
                ["start": c.start, "end": c.end, "source": c.source, "translated": c.translated,
                 "speaker": c.speaker ?? ""]
            }
            let saida: [String: Any] = [
                "segundos": Date().timeIntervalSince(comecou),
                "reconhecimento": builder.recognitionName ?? "", "traducao": builder.translationName ?? "",
                "rascunho": builder.draft.map(linha), "legendas": cues.map(linha),
            ]
            try! JSONSerialization.data(withJSONObject: saida, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: arguments[7]))
            print("\(builder.draft.count) no rascunho, \(cues.count) legendas")
            // `--ab <saida2.json>`: o MESMO rascunho retraduzido legenda por
            // legenda, o jeito antigo. Tira a variação do reconhecedor da conta.
            if let outra = option("--ab") {
                builder.translatesBySentence = false
                let antigas = try! await builder.retranslate(
                    using: TranslationEngine(rawValue: arguments[6]) ?? .apple,
                    from: origem, to: destino, progress: { _, _, _, _ in })
                var copia = saida
                copia["legendas"] = antigas.map(linha)
                try! JSONSerialization.data(withJSONObject: copia, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: outra))
                print("por legenda: \(antigas.count) legendas")
            }
        case "referencia": await referenceGate(arguments: arguments, option: option)
        case "audio":
            guard arguments.count >= 3 else { print("falta o caminho do wav"); exit(1) }
            let source = arguments.count >= 4 ? (Language(rawValue: arguments[3]) ?? .english) : .english
            let target = arguments.count >= 5 ? (Language(rawValue: arguments[4]) ?? .portuguese) : .portuguese
            await audioGate(
                path: arguments[2], source: source, target: target,
                engine: arguments.count >= 6
                    ? (RecognitionEngine(rawValue: arguments[5]) ?? .whisper) : .whisper
            )
        case "quebra": lineBreakGate()
        case "japones": japaneseSubtitleGate()
        case "frase": await sentenceTranslationGate()
        case "modelos": await warmModelGate()
        case "frases": sentenceGate()
        case "lote": await batchGate()
        case "prefixo": stablePrefixGate()
        case "srt":
            guard arguments.count >= 3 else { print("falta o caminho do video"); exit(1) }
            let origem = arguments.count >= 4 ? (Language(rawValue: arguments[3]) ?? .english) : .english
            let destino = arguments.count >= 5 ? (Language(rawValue: arguments[4]) ?? .portuguese) : .portuguese
            let motor = arguments.count >= 6
                ? (RecognitionEngine(rawValue: arguments[5]) ?? .whisper) : .whisper
            await srtGate(
                path: arguments[2], source: origem, target: destino, engine: motor,
                diarize: arguments.contains("--locutores"),
                colors: arguments.contains("--cores")
            )
        case "alinhamento":
            guard arguments.count >= 3 else { print("falta o caminho do audio"); exit(1) }
            await alignmentGate(
                path: arguments[2],
                engine: arguments.count >= 4
                    ? (RecognitionEngine(rawValue: arguments[3]) ?? .whisper) : .whisper,
                language: arguments.count >= 5 ? (Language(rawValue: arguments[4]) ?? .english) : .english,
                referencePath: option("--audio-referencia")
            )
        case "tempos": await timecodeGate()
        case "formatos": await formatGate()
        case "legendas": legendaGate()
        case "imagem":
            guard arguments.count >= 3 else { burnedSubtitleGate(); return }
            // `--faixa a,b` é a área de largura inteira; `--area x,y,l,a` é a
            // desenhada, como a janela a lê.
            func numeros(_ texto: String) -> [Double] { texto.split(separator: ",").compactMap { Double($0) } }
            var faixa: CGRect?
            if let p = option("--faixa").map(numeros), p.count == 2, p[0] < p[1] {
                faixa = CGRect(x: 0, y: p[0], width: 1, height: p[1] - p[0])
            }
            var desenhada: CGRect?
            if let p = option("--area").map(numeros), p.count == 4, p[2] > 0, p[3] > 0 {
                desenhada = CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
            }
            await burnedSubtitleVideoGate(
                path: arguments[2],
                language: arguments.count >= 4 ? (Language(rawValue: arguments[3]) ?? .english) : .english,
                gabarito: option("--gabarito"), oracle: arguments.contains("--oraculo"),
                area: desenhada ?? faixa)
        case "faixas": await trackGate()
        case "fonte":
            guard arguments.count >= 3 else { print("falta o caminho do video"); exit(1) }
            await dumpSource(
                path: arguments[2],
                language: arguments.count >= 4 ? (Language(rawValue: arguments[3]) ?? .japanese) : .japanese,
                engine: arguments.count >= 5
                    ? (RecognitionEngine(rawValue: arguments[4]) ?? .whisper) : .whisper,
                jsonPath: option("--json")
            )
        case "traduzir":
            guard arguments.count >= 3 else { print("falta o arquivo de linhas"); exit(1) }
            await translateLines(
                path: arguments[2],
                source: arguments.count >= 4 ? (Language(rawValue: arguments[3]) ?? .japanese) : .japanese,
                target: arguments.count >= 5 ? (Language(rawValue: arguments[4]) ?? .portuguese) : .portuguese,
                engine: arguments.count >= 6
                    ? (TranslationEngine(rawValue: arguments[5]) ?? .apple) : .apple
            )
        case "lotes": await batchSizeGate()
        case "sobreposicao": await overlapGate()
        case "motores": await engineGate()
        case "captura": await captureGate()
        case "locutores": speakerGate()
        case "deepl": deepLGate()
        case "webapi": await webAPIGate()
        case "treslinhas":
            guard arguments.count >= 3 else { print("falta o caminho do video"); exit(1) }
            await threeLineHunt(path: arguments[2])
        case "prefixo-ab":
            guard arguments.count >= 3 else { print("falta o caminho do video"); exit(1) }
            await prefixABGate(
                path: arguments[2],
                language: arguments.count >= 4 ? (Language(rawValue: arguments[3]) ?? .japanese) : .japanese,
                target: arguments.count >= 5 ? (Language(rawValue: arguments[4]) ?? .portuguese) : .portuguese,
                engine: arguments.count >= 6 ? (RecognitionEngine(rawValue: arguments[5]) ?? .qwen) : .qwen
            )
        case "fronteiras":
            guard arguments.count >= 3 else { print("falta o caminho do video"); exit(1) }
            await speakerBoundaryGate(
                path: arguments[2],
                language: arguments.count >= 4 ? (Language(rawValue: arguments[3]) ?? .japanese) : .japanese,
                engine: arguments.count >= 5 ? (RecognitionEngine(rawValue: arguments[4]) ?? .qwen) : .qwen
            )
        case "gabarito":
            guard arguments.count >= 4 else {
                print("uso: gabarito <marcado.txt> <audio> [clustering|sortformer] [limiar]"); exit(1)
            }
            await groundTruthGate(
                marks: arguments[2], audio: arguments[3],
                model: arguments.count >= 5
                    ? (SpeakerDiarizer.Model(rawValue: arguments[4]) ?? .sortformer) : .sortformer,
                threshold: arguments.count >= 6 ? Float(arguments[5]) : nil)
        case "modelos-de-voz":
            guard arguments.count >= 3 else { print("faltam os caminhos dos audios"); exit(1) }
            await voiceModelGate(
                paths: Array(arguments.dropFirst(2)).filter { Float($0) == nil },
                threshold: arguments.dropFirst(2).compactMap { Float($0) }.first)
        case "vozes":
            guard arguments.count >= 3 else { print("falta o caminho do audio"); exit(1) }
            await voiceSweepGate(
                path: arguments[2],
                thresholds: arguments.count >= 4
                    ? arguments[3].split(separator: ",").compactMap { Float($0) }
                    : [0.5, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9]
            )
        case "repescagem":
            guard arguments.count >= 3 else { print("falta o caminho do audio"); exit(1) }
            await secondPassGate(
                path: arguments[2],
                engine: arguments.count >= 4 ? (RecognitionEngine(rawValue: arguments[3]) ?? .whisper) : .whisper,
                language: arguments.count >= 5 ? (Language(rawValue: arguments[4]) ?? .english) : .english,
                fallback: arguments.count >= 6 ? RecognitionEngine(rawValue: arguments[5]) : nil
            )
        case "vivo":
            guard arguments.count >= 3 else { print("falta o caminho do audio"); exit(1) }
            if arguments.count >= 4 {
                await liveRecognitionGate(
                    path: arguments[2],
                    engine: RecognitionEngine(rawValue: arguments[3]) ?? .apple,
                    language: arguments.count >= 5 ? (Language(rawValue: arguments[4]) ?? .japanese) : .japanese)
            }
            liveSegmentationGate(path: arguments[2])
        default: print("comando desconhecido"); exit(1)
        }
    }

    // MARK: Fase 5 — o teste que separa este app do concorrente

    static func dialogueGate() async {
        // Cada frase depende da anterior para ser traduzida direito. Sem
        // janela de contexto, "The engineer" vira masculino e "it" perde o
        // referente. O Apple Translation framework, que o Transcrybe usa,
        // falha exatamente aqui.
        let dialogue = [
            "Maria is our lead engineer on the payments team.",
            "She spent the last month rewriting the retry logic.",
            "The engineer walked us through every edge case.",
            "Nobody had questions, so she approved it herself.",
        ]

        print("Fase 5 — contexto de dialogo")
        print("carregando o tradutor do sistema...\n")

        let translator = TranslatorFactory.make(.apple)
        print("motor: \(translator.engineName)\n")

        var totalMs = 0
        for line in dialogue {
            let start = Date()
            let translated: String
            do {
                translated = try await translator.translate(line, from: .english, to: .portuguese)
            } catch {
                print("FALHA na traducao: \(error.localizedDescription)")
                exit(1)
            }
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            totalMs += elapsed
            print("  \(line)")
            print("  -> \(translated)   [\(elapsed) ms]\n")
        }

        print("media por linha: \(totalMs / dialogue.count) ms")
        print("""

        O que conferir na saida acima:
          - a terceira linha traduziu "The engineer" no feminino
            ("a engenheira"), coisa que so o historico permite saber
          - a quarta manteve o referente de "it"

        Se ambos passaram, a fase 5 esta feita.
        """)
    }

    // MARK: Fases 4 + 5 juntas

    static func audioGate(
        path: String, source: Language = .english, target: Language = .portuguese,
        engine: RecognitionEngine = .whisper
    ) async {
        guard let samples = load16kMono(path: path) else {
            print("nao consegui ler \(path)")
            exit(1)
        }
        let seconds = Double(samples.count) / 16_000
        print("audio: \(samples.count) amostras, \(String(format: "%.1f", seconds))s")
        print("idiomas: \(source.rawValue) -> \(target.rawValue)\n")

        // O detector de voz e o suspeito mais provavel quando nada chega a
        // tela apesar de o audio estar entrando.
        let segmenter = Segmenter()
        var segments = segmenter.feed(samples)
        if let last = segmenter.flush() { segments.append(last) }
        print("segmentos do VAD: \(segments.count)")
        for (index, segment) in segments.enumerated() {
            print(String(format: "  %d: %.2fs  %@", index + 1, segment.duration,
                         segment.closedBySilence ? "silencio" : "teto"))
        }
        if segments.isEmpty {
            print("  NENHUM. O VAD nao reconheceu fala neste audio.")
            var energy: Float = 0
            for sample in samples { energy += sample * sample }
            let rms = (energy / Float(samples.count)).squareRoot()
            print(String(format: "  rms do arquivo: %.5f", rms))
        }
        print("")

        let transcriber = TranscriberFactory.make(for: source, engine: engine)
        print("reconhecedor: \(transcriber.engineName)")
        do {
            try await transcriber.prepare { _, _ in }
        } catch {
            print("FALHA ao carregar o reconhecedor: \(error.localizedDescription)")
            exit(1)
        }

        let startASR = Date()
        let text: String
        do {
            text = try await transcriber.transcribe(samples)
        } catch {
            print("FALHA na transcricao: \(error.localizedDescription)")
            exit(1)
        }
        let asrMs = Int(Date().timeIntervalSince(startASR) * 1000)
        print("transcricao [\(asrMs) ms]: \(text)\n")

        guard !text.isEmpty else {
            print("FALHA: transcricao vazia")
            exit(1)
        }

        let translator = TranslatorFactory.make(.apple)
        do {
            try await translator.prepare { _, _ in }
        } catch {
            print("FALHA ao carregar o tradutor: \(error.localizedDescription)")
            exit(1)
        }

        let startMT = Date()
        let translated = (try? await translator.translate(text, from: source, to: target)) ?? ""
        let mtMs = Int(Date().timeIntervalSince(startMT) * 1000)
        print("traducao [\(mtMs) ms]: \(translated)\n")

        print("total do caminho: \(asrMs + mtMs) ms para \(String(format: "%.1f", seconds))s de audio")
        print("linhas na tela:")
        for line in LineBreaker.wrap(translated) {
            print("  | \(line)")
        }
    }

    // MARK: Modelos residentes

    /// Carregar o Parakeet custa segundos. Trocar entre dois idiomas que ele
    /// cobre nao pode custar nada — e o mesmo modelo. Este teste prova isso.
    static func warmModelGate() async {
        print("Modelos residentes\n")

        let engine = TranscriberFactory.make(for: .english)
        print("motor: \(engine.engineName)")
        print("preparado antes de carregar: \(engine.isPrepared)")

        let startLoad = Date()
        do {
            try await engine.prepare { _, _ in }
        } catch {
            print("FALHA ao carregar: \(error.localizedDescription)")
            exit(1)
        }
        let loadMs = Int(Date().timeIntervalSince(startLoad) * 1000)
        print("carga inicial: \(loadMs) ms")
        print("preparado depois: \(engine.isPrepared)\n")

        failures = 0

        // Troca de idioma dentro da cobertura do Parakeet.
        for language in [Language.portuguese, .spanish, .french, .english] {
            let sameEngine = TranscriberKind(for: language) == TranscriberKind(for: .english)
            engine.language = language
            if !engine.isPrepared {
                print("  FALHA: \(language.displayName) descarregou o modelo")
                failures += 1
            } else {
                print("  ok    \(language.displayName) reaproveita o modelo carregado (mesmo motor: \(sameEngine))")
            }
        }

        // Um idioma fora da cobertura tem que exigir OUTRO motor.
        let japanese = TranscriberKind(for: .japanese)
        if japanese == .whisper {
            print("  ok    Japonês roteia para o Whisper, como esperado")
        } else {
            print("  FALHA: Japonês deveria rotear para o Whisper")
            failures += 1
        }

        print("")
        print("disco usado pelos modelos: \(ByteCountFormatter.string(fromByteCount: ModelStorage.diskUsageBytes(), countStyle: .file))")
        print(failures == 0 ? "\nmodelos residentes ok" : "\n\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Tamanho de lote

    /// Mede quanto custa traduzir as mesmas legendas em lotes de tamanhos
    /// diferentes. Serve para escolher o numero com dado, nao com palpite.
    static func batchSizeGate() async {
        print("tamanho de lote\n")

        // Um dialogo de verdade, longo o bastante para o efeito aparecer.
        let base = [
            "Maria is our lead engineer on the payments team.",
            "She spent the last month rewriting the retry logic.",
            "The engineer walked us through every edge case.",
            "Nobody had questions, so she approved it herself.",
            "We shipped the change on Friday afternoon.",
            "It has been running in production ever since.",
            "There was not a single incident during the weekend.",
            "The support team reported no complaints at all.",
            "Latency dropped by about thirty percent.",
            "The database load is also noticeably lower.",
        ]
        // 160 falas: com 40 por requisicao sao 4 idas, e da para ver se
        // lote maior corta ida sem custar tempo.
        let frases = Array(repeating: base, count: 16).flatMap { $0 }
        print("legendas: \(frases.count)\n")

        let translator = TranslatorFactory.make(.apple)
        do { try await translator.prepare { _, _ in } } catch {
            print("FALHA: \(error.localizedDescription)"); exit(1)
        }
        _ = try? await translator.translate("warm up", from: .english, to: .portuguese)

        var melhor = (tamanho: 0, ms: Int.max)
        for tamanho in [10, 40, 80, 160] {
            let inicio = Date()
            var saida: [String] = []
            for comeco in stride(from: 0, to: frases.count, by: tamanho) {
                let fim = min(comeco + tamanho, frases.count)
                let lote = Array(frases[comeco..<fim])
                saida += (try? await translator.translate(
                    lote, from: .english, to: .portuguese)) ?? []
            }
            let ms = Int(Date().timeIntervalSince(inicio) * 1000)
            let completo = saida.count == frases.count && !saida.contains(where: \.isEmpty)
            print(String(format: "  lote de %2d: %5d ms   %@", tamanho, ms,
                         completo ? "completo" : "INCOMPLETO"))
            if completo, ms < melhor.ms { melhor = (tamanho, ms) }
        }

        print("")
        print("mais rapido: lote de \(melhor.tamanho) (\(melhor.ms) ms)")

        // O mesmo texto, repartido em mais pedacos: e o que a identificacao
        // de locutor provoca — mais legendas, mais curtas, mesmo conteudo.
        // Se o custo fosse so por caractere, os dois tempos seriam iguais.
        print("")
        print("mesmo texto, numero de pedacos diferente (lote de 40):")
        let inteiras = Array(repeating: base, count: 4).flatMap { $0 }   // 40 falas
        let picadas = inteiras.flatMap { fala -> [String] in
            let palavras = fala.split(separator: " ").map(String.init)
            let passo = max(1, palavras.count / 4)
            return stride(from: 0, to: palavras.count, by: passo).map {
                palavras[$0..<min($0 + passo, palavras.count)].joined(separator: " ")
            }
        }
        for (rotulo, corpus) in [("\(inteiras.count) falas inteiras", inteiras),
                                 ("\(picadas.count) pedacos", picadas)] {
            let caracteres = corpus.reduce(0) { $0 + $1.count }
            let inicio = Date()
            for comeco in stride(from: 0, to: corpus.count, by: 40) {
                let fim = min(comeco + 40, corpus.count)
                _ = try? await translator.translate(
                    Array(corpus[comeco..<fim]), from: .english, to: .portuguese
                )
            }
            print(String(format: "  %-22@ %6d ms  (%d caracteres)",
                         rotulo as NSString, Int(Date().timeIntervalSince(inicio) * 1000),
                         caracteres))
        }
        exit(0)
    }

    // MARK: Comparacao entre motores de traducao

    /// Imprime as falas reconhecidas, uma por linha.
    ///
    /// Serve de entrada para comparar motores de traducao: o mesmo texto de
    /// origem passa por cada um, e a diferenca fica isolada na traducao.
    static func dumpSource(
        path: String, language: Language, engine: RecognitionEngine = .whisper,
        jsonPath: String? = nil
    ) async {
        let started = Date()
        guard let samples = try? await SubtitleFileBuilder.extractAudio(
            from: URL(fileURLWithPath: path), preferring: language
        ) else {
            FileHandle.standardError.write(Data("nao consegui ler \(path)\n".utf8))
            exit(1)
        }
        let duration = Double(samples.count) / 16_000

        let transcriber = TranscriberFactory.make(for: language, engine: engine)
        do {
            try await transcriber.prepare { _, _ in }
        } catch {
            FileHandle.standardError.write(Data("FALHA: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        FileHandle.standardError.write(Data("motor: \(transcriber.engineName)\n".utf8))
        guard let timed = try? await transcriber.transcribeForSubtitles(samples), !timed.isEmpty else {
            FileHandle.standardError.write(Data("nenhuma fala reconhecida\n".utf8))
            exit(1)
        }

        let builder = SubtitleFileBuilder()
        let cues = builder.makeCues(from: timed, mediaDuration: duration)
        if let jsonPath {
            let report: [String: Any] = [
                "seconds": Date().timeIntervalSince(started), "duration": duration,
                "pieces": timed.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] },
                "srt": SRTWriter.render(cues, charactersPerLine: SubtitleFileBuilder.lineWidth(for: language))
            ]
            do {
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: jsonPath), options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("FALHA: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        for cue in cues where !cue.source.isEmpty {
            print(cue.source.replacingOccurrences(of: "\n", with: " "))
        }
        exit(0)
    }

    /// Traduz um arquivo de linhas com o motor do sistema, uma traducao por
    /// linha, na mesma ordem.
    static func translateLines(
        path: String, source: Language, target: Language, engine: TranslationEngine = .apple
    ) async {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data("nao consegui ler \(path)\n".utf8))
            exit(1)
        }
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { exit(0) }

        let translator = TranslatorFactory.make(engine)
        try? await translator.prepare { _, _ in }

        let started = Date()
        var output: [String] = []
        let step = translator.preferredBatchSize
        for begin in stride(from: 0, to: lines.count, by: step) {
            let end = min(begin + step, lines.count)
            let slice = Array(lines[begin..<end])
            // O erro vai para a tela: engolido, o lote que falhava aparecia
            // só como linhas em branco, sem dizer se foi tempo, formato ou
            // contagem.
            do {
                output += try await translator.translate(slice, from: source, to: target)
            } catch {
                FileHandle.standardError.write(Data(
                    "lote \(begin + 1)–\(end): \(error.localizedDescription)\n".utf8))
                output += Array(repeating: "", count: slice.count)
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)

        for line in output { print(line.replacingOccurrences(of: "\n", with: " ")) }
        FileHandle.standardError.write(Data(
            "\(translator.engineName): \(lines.count) linhas, \(output.count) traduzidas, \(ms) ms\n".utf8))
        if let aviso = translator.completionNotice {
            FileHandle.standardError.write(Data("\(aviso)\n".utf8))
        }
        translator.reset()
        exit(0)
    }

    // MARK: Leitura de .srt

    static func legendaGate() {
        failures = 0

        print("leitura de .srt\n")

        let arquivo = """
        1
        00:00:02,880 --> 00:00:07,300
        Olá a todos, este é um supermercado

        2
        00:00:09,100 --> 00:00:12,665
        Antes de fazer compras,
        tire as embalagens recicláveis

        3
        00:01:23,456 --> 00:01:25,000
        Depois de uma hora
        """

        let cues = SRTParser.parse(arquivo)
        expect(cues.count == 3, "le as tres legendas (deu \(cues.count))")
        expect(abs((cues.first?.start ?? 0) - 2.88) < 0.01, "converte o tempo de entrada")
        expect(abs((cues.first?.end ?? 0) - 7.30) < 0.01, "converte o tempo de saida")
        expect(cues[1].translated.contains("Antes") && cues[1].translated.contains("recicláveis"),
               "junta as duas linhas de um bloco")
        expect(abs((cues.last?.start ?? 0) - 83.456) < 0.01,
               "hora, minuto e milissegundo (deu \(cues.last?.start ?? 0))")

        // Ida e volta: o que o app grava, o app le de volta igual.
        let originais = [
            Cue(index: 1, start: 0, end: 2.1, source: "a", translated: "Olá."),
            Cue(index: 2, start: 3.5, end: 5.0, source: "b", translated: "Ninguém tinha perguntas."),
        ]
        let voltaram = SRTParser.parse(SRTWriter.render(originais))
        expect(voltaram.count == originais.count, "ida e volta preserva a quantidade")
        expect(zip(originais, voltaram).allSatisfy { abs($0.start - $1.start) < 0.01 },
               "ida e volta preserva os tempos")
        expect(voltaram.last?.translated == "Ninguém tinha perguntas.",
               "ida e volta preserva o texto")

        let japones = "今日は皆さんにお会いできてうれしいです。どうぞよろしくお願いします。"
        let ida = [Cue(index: 1, start: 1.001, end: 1.101, source: japones)]
        let volta = SRTParser.parse(SRTWriter.render(ida, charactersPerLine: 20))
        expect(volta.first?.translated == japones, "SRT japonês não ganha espaços na quebra de linha")
        expect(volta.first?.start == 1.001 && volta.first?.end == 1.101,
               "ida e volta preserva milissegundos e duração menor que 200 ms")
        expect(SRTWriter.timecode(59.9996) == "00:01:00,000", "arredondamento atravessa o minuto")
        expect(SRTParser.parse("1\n00:00:nan --> 00:01:02,000\nTexto").isEmpty,
               "tempo não finito é recusado")

        // Variacoes que aparecem na pratica.
        let comCRLF = SRTParser.parse("1\r\n00:00:01,000 --> 00:00:02,000\r\nTexto\r\n")
        expect(comCRLF.count == 1, "aceita quebra de linha do Windows")

        let semNumero = SRTParser.parse("00:00:01,000 --> 00:00:02,000\nTexto")
        expect(semNumero.count == 1, "aceita bloco sem numero")

        let comPonto = SRTParser.parse("1\n00:00:01.500 --> 00:00:02.500\nTexto")
        expect(abs((comPonto.first?.start ?? 0) - 1.5) < 0.01, "aceita ponto no decimal")

        let comTags = SRTParser.parse("1\n00:00:01,000 --> 00:00:02,000\n<i>Em italico</i>")
        expect(comTags.first?.translated == "Em italico", "tira as marcacoes de formatacao")

        expect(SRTParser.parse("isto nao e legenda nenhuma").isEmpty,
               "texto que nao e legenda nao vira legenda")

        // Linha separadora com espaco: o app nao grava assim, mas editor de
        // texto e outras ferramentas gravam. Os dois blocos viravam um, com o
        // numero e o timecode do segundo dentro do texto do primeiro —
        // arquivo aceito, legenda embaralhada. Auditoria de 12/09/2026.
        let comEspacos = SRTParser.parse(
            "1\n00:00:01,000 --> 00:00:02,000\nPrimeira.\n  \n"
            + "2\n00:00:02,000 --> 00:00:03,000\nSegunda."
        )
        expect(comEspacos.count == 2,
               "linha so de espacos separa dois blocos (deu \(comEspacos.count))")
        expect(comEspacos.first?.translated == "Primeira.",
               "o timecode do bloco seguinte nao entra no texto do anterior "
               + "(\"\(comEspacos.first?.translated ?? "")\")")
        expect(comEspacos.last?.translated == "Segunda.", "o segundo bloco chega inteiro")

        // O idioma de uma legenda importada sai do texto dela, não do seletor
        // de fala — que nasce em inglês e mandava o japonês ao tradutor como
        // inglês.
        expect(Language.detect(in: ["あっちもお願いしたいんですけど。", "大丈夫です。", "かわかつです。"]) == .japanese,
               "detecta legenda japonesa")
        expect(Language.detect(in: ["Olá a todos, este é um supermercado", "Antes de fazer compras"]) == .portuguese,
               "detecta legenda em portugues")
        expect(Language.detect(in: ["OK"]) == nil, "legenda de uma palavra nao decide sozinha")

        print("")
        print(failures == 0 ? "leitura de .srt ok" : "\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Legenda na imagem

    /// A montagem da legenda lida da imagem, sem vídeo e sem Vision: as linhas
    /// e as amostras são fabricadas com o que os vídeos de exemplo mostraram.
    static func burnedSubtitleGate() {
        failures = 0
        typealias Line = BurnedSubtitle.Line
        typealias Sample = BurnedSubtitle.Sample
        typealias Change = BurnedSubtitle.Change

        print("filtros de linha\n")
        // Video 2: duas linhas da fala e a marca d'agua na mesma faixa.
        let marca = Line(text: "©Eiichiro Oda/Shueisha, Toei Animation",
                         box: CGRect(x: 0.78, y: 0.83, width: 0.20, height: 0.11))
        let cima = Line(text: "I'm the one who'll become", box: CGRect(x: 0.32, y: 0.32, width: 0.36, height: 0.26))
        let baixo = Line(text: "the King of the Pirates!", box: CGRect(x: 0.34, y: 0.62, width: 0.31, height: 0.26))
        let fala = BurnedSubtitle.filter([baixo, marca, cima], for: .english)
        expect(fala.text == "I'm the one who'll become the King of the Pirates!",
               "duas linhas viram uma legenda, de cima para baixo (\"\(fala.text)\")")
        expect(!fala.text.contains("Oda"), "a marca d'agua fora do centro sai")

        // Video de 9 minutos: furigana, japones, romaji e ingles na mesma
        // legenda, e a placa de cardapio no canto.
        let furigana = Line(text: "いよ", box: CGRect(x: 0.36, y: 0.05, width: 0.03, height: 0.086))
        let japones = Line(text: "今、いそがしいの。", box: CGRect(x: 0.36, y: 0.16, width: 0.27, height: 0.309))
        let romaji = Line(text: "ima isogashii no", box: CGRect(x: 0.38, y: 0.50, width: 0.23, height: 0.262))
        let ingles = Line(text: "I'm busy right now.", box: CGRect(x: 0.39, y: 0.78, width: 0.22, height: 0.196))
        let placa = Line(text: "柒￥80", box: CGRect(x: 0.19, y: 0.40, width: 0.10, height: 0.30))
        let todas = [ingles, placa, romaji, furigana, japones]
        let emJapones = BurnedSubtitle.filter(todas, for: .japanese)
        expect(emJapones.text == "今、いそがしいの。",
               "japones escolhido: so a linha japonesa (\"\(emJapones.text)\")")
        expect(!emJapones.text.contains("いよ"), "furigana sai pela altura")
        expect(!emJapones.text.contains("80"), "a placa fora do centro sai")
        let emIngles = BurnedSubtitle.filter(todas, for: .english)
        expect(emIngles.text == "ima isogashii no I'm busy right now.",
               "ingles escolhido: as linhas latinas, que a escrita nao separa (\"\(emIngles.text)\")")
        let duas = BurnedSubtitle.filter([
            Line(text: "え、そんなことないよ。", box: CGRect(x: 0.32, y: 0.2, width: 0.34, height: 0.3)),
            Line(text: "本当に？", box: CGRect(x: 0.44, y: 0.6, width: 0.12, height: 0.3)),
        ], for: .japanese)
        expect(duas.text == "え、そんなことないよ。本当に？",
               "japones junta as linhas sem espaco (\"\(duas.text)\")")
        // "え？　同じです。": uma linha com um vao largo vem em duas caixas, e a
        // da direita um pixel acima. Cada metade sozinha fica fora do centro.
        let partida = BurnedSubtitle.filter([
            Line(text: "同じです。", box: CGRect(x: 0.46, y: 0.19, width: 0.16, height: 0.30)),
            Line(text: "え？", box: CGRect(x: 0.38, y: 0.20, width: 0.05, height: 0.29)),
        ], for: .japanese)
        expect(partida.text == "え？同じです。",
               "linha partida pelo vao: junta da esquerda para a direita (\"\(partida.text)\")")
        let placaNoMeio = Line(text: "1日 60", box: CGRect(x: 0.28, y: 0.60, width: 0.05, height: 0.12))
        expect(BurnedSubtitle.filter([placaNoMeio], for: .japanese).text.isEmpty,
               "a placa em 0,30 do centro sai (com 0,2 de folga ela virava legenda)")
        // A marca d'agua encosta na segunda linha da fala: nao pode entrar na
        // mesma linha visual, senao a fala sai do centro junto com ela.
        let encostada = Line(text: "©Eiichiro Oda/Shueisha, Toei Animation",
                             box: CGRect(x: 0.78, y: 0.80, width: 0.20, height: 0.11))
        let comMarca = BurnedSubtitle.filter([cima, baixo, encostada], for: .english)
        expect(comMarca.text == "I'm the one who'll become the King of the Pirates!",
               "a marca d'agua encostada na fala nao a leva junto (\"\(comMarca.text)\")")
        let trocado = BurnedSubtitle.filter([ingles], for: .japanese)
        expect(trocado.text.isEmpty && trocado.otherScript,
               "texto em outra escrita e marcado, para o erro dizer o motivo")
        expect(!BurnedSubtitle.filter([placa], for: .japanese).otherScript,
               "o que o filtro de centro tira nao conta como outra escrita")
        // Area desenhada: o centro que vale e o do quadro, nao o da area.
        // Caixas em coordenadas da area recortada.
        let torta = CGRect(x: 0.2, y: 0.76, width: 0.56, height: 0.24)  // meio do quadro em 0,536
        let noMeio = Line(text: "the King of the Pirates!", box: CGRect(x: 0.25, y: 0.3, width: 0.572, height: 0.3))
        let naBorda = Line(text: "Crunchyroll", box: CGRect(x: 0.80, y: 0.6, width: 0.18, height: 0.3))
        let desenhada = BurnedSubtitle.filter([noMeio, naBorda], for: .english, area: torta)
        expect(desenhada.text == "the King of the Pirates!",
               "area desenhada assimetrica: fica a fala no meio do quadro, sai a marca (\"\(desenhada.text)\")")
        let noCanto = CGRect(x: 0.0, y: 0.0, width: 0.3, height: 0.2)
        let aEsquerda = Line(text: "Left aligned line", box: CGRect(x: 0.02, y: 0.3, width: 0.5, height: 0.3))
        expect(BurnedSubtitle.filter([aEsquerda], for: .english).text.isEmpty,
               "na faixa padrao, linha a esquerda sai pelo centro")
        expect(BurnedSubtitle.filter([aEsquerda], for: .english, area: noCanto).text == "Left aligned line",
               "area desenhada sem o meio do quadro: legenda de canto fica")
        expect(BurnedSubtitle.filter([furigana, japones], for: .japanese, area: noCanto).text == "今、いそがしいの。",
               "na area de canto, furigana continua saindo pela altura")

        print("\nrecorte da area\n")
        // Plano Y 8x4 com o valor de cada pixel = 10*linha + coluna.
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        if let buffer {
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in 0..<4 { for x in 0..<8 { base[y * stride + x] = UInt8(10 * y + x) } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let recorte = BurnedSubtitle.copyBand(buffer, area: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5))
            expect(recorte?.width == 4 && recorte?.height == 2,
                   "recorte de 8x4 pela metade do meio vira 4x2 (\(recorte?.width ?? 0)x\(recorte?.height ?? 0))")
            expect(recorte?.pixels == [22, 23, 24, 25, 32, 33, 34, 35],
                   "o recorte comeca na coluna e na linha certas (\(recorte?.pixels ?? []))")
            let padrao = BurnedSubtitle.copyBand(buffer, area: BurnedSubtitle.defaultArea)
            expect(padrao?.width == 8, "a area padrao tem a largura inteira")
        } else {
            expect(false, "nao consegui criar o quadro de teste")
        }

        print("\nmesma legenda ou outra\n")
        expect(BurnedSubtitle.same("My name is...", "My name iS..."), "caixa e pontuacao nao fazem outra legenda")
        expect(BurnedSubtitle.same("Everyone...", "Everyone.."), "reticencia a menos nao faz outra legenda")
        expect(!BurnedSubtitle.same("He's so evil!", "He's as vicious as they say."),
               "falas diferentes sao outra legenda")
        expect(!BurnedSubtitle.same("", "Hello?!"), "vazio nao e igual a texto")
        expect(BurnedSubtitle.same("", ""), "vazio e igual a vazio")
        expect(!BurnedSubtitle.same("me!", "mel"),
               "texto curto com uma letra trocada passa da tolerancia: e o caso do tremor")

        print("\nmontagem\n")
        func a(_ time: Double, _ text: String) -> Sample { Sample(time: time, text: text) }
        let hello = "Hello?!"
        let inteira = BurnedSubtitle.assemble([a(0, hello), a(0.25, hello), a(0.5, hello)], changes: [:], end: 1)
        expect(inteira.count == 1 && inteira.first?.start == 0 && inteira.first?.end == 1,
               "texto do comeco ao fim: uma legenda, ate o fim do ultimo quadro")

        let refinada = BurnedSubtitle.assemble(
            [a(0, ""), a(0.25, hello), a(0.5, hello), a(0.75, "")],
            changes: [1: Change(previousEnds: 0.21, nextStarts: 0.21),
                      3: Change(previousEnds: 0.625, nextStarts: 0.625)],
            end: 1)
        expect(refinada.count == 1 && refinada.first?.start == 0.21 && refinada.first?.end == 0.625,
               "entrada e saida vem do refino, nao da amostra")

        let certo = "Help! Straw Hat's gonna kill me!"
        let tremor = BurnedSubtitle.assemble(
            [a(0, certo), a(0.25, certo), a(0.5, "Help! Straw Hat's gonna kill mel"), a(0.75, certo), a(1, certo)],
            changes: [2: Change(previousEnds: 0.5, nextStarts: 0.5),
                      3: Change(previousEnds: 0.75, nextStarts: 0.75)],
            end: 1.25)
        expect(tremor.count == 1 && tremor.first?.source == certo && tremor.first?.end == 1.25,
               "A A' A e uma legenda so, com o texto de A")

        let leituras = ["My name is...", "My name iS...", "My name is...",
                        "My name is...", "My name iS...", "My name is..."]
        let voto = BurnedSubtitle.assemble(
            leituras.enumerated().map { a(Double($0.offset) * 0.25, $0.element) }, changes: [:], end: 2)
        expect(voto.count == 1 && voto.first?.source == "My name is...", "o texto e o mais lido entre as amostras")

        let buraco = BurnedSubtitle.assemble(
            [a(0, hello), a(0.25, hello), a(0.5, ""), a(0.75, hello)],
            changes: [2: Change(previousEnds: 0.45, nextStarts: 0.45),
                      3: Change(previousEnds: 0.7, nextStarts: 0.7)],
            end: 1)
        expect(buraco.count == 2 && buraco.first?.end == 0.45 && buraco.last?.start == 0.7,
               "o mesmo texto depois de um vazio e outra legenda")

        let troca = BurnedSubtitle.assemble(
            [a(0, "He's so evil!"), a(0.25, "He's as vicious as they say.")],
            changes: [1: Change(previousEnds: 0.167, nextStarts: 0.167)], end: 0.5)
        expect(troca.count == 2 && troca.first?.end == 0.167 && troca.last?.start == 0.167,
               "troca sem vazio: uma fecha no quadro em que a outra abre")

        let vao = BurnedSubtitle.assemble(
            [a(0, "My name is..."), a(0.25, "...Monkey D. Luffy!")],
            changes: [1: Change(previousEnds: 0.042, nextStarts: 0.208)], end: 0.5)
        expect(vao.count == 2 && vao.first?.end == 0.042 && vao.last?.start == 0.208,
               "legenda, vazio e legenda no mesmo intervalo: dois instantes")

        let dissolve = BurnedSubtitle.assemble(
            [a(0, "Luffy, no!"), a(0.25, "Clank.")],
            changes: [1: Change(previousEnds: 0.21, nextStarts: 0.17)], end: 0.5)
        expect(dissolve.count == 2 && dissolve.first?.end == 0.17 && dissolve.last?.start == 0.17,
               "dissolucao: a nova manda a partir de quando fica legivel")

        expect(BurnedSubtitle.assemble([a(0, ""), a(0.25, ""), a(0.5, "")], changes: [:], end: 1).isEmpty,
               "faixa vazia o tempo todo nao vira legenda em branco")

        let curta = BurnedSubtitle.assemble([a(0, ""), a(0.25, "Clank."), a(0.5, "")], changes: [:], end: 1)
        expect(curta.count == 1 && curta.first?.start == 0.25 && curta.first?.end == 0.5,
               "legenda vista numa amostra so fica")
        expect(inteira.map(\.index) == [1] && buraco.map(\.index) == [1, 2], "indices contados de 1")

        print("\no quadro exato\n")
        // Faixa de 14 x 7: a letra e um retangulo claro (235) dentro de um
        // contorno escuro (16), como a legenda branca contornada de preto.
        func faixa(fundo: UInt8, letra: Bool, nucleo: UInt8 = 235, contorno: UInt8 = 16) -> BurnedSubtitle.Band {
            BurnedSubtitle.Band(width: 14, height: 7, pixels: (0..<98).map { posicao in
                let (x, y) = (posicao % 14, posicao / 14)
                guard letra, (2...11).contains(x), (1...5).contains(y) else { return fundo }
                return (3...10).contains(x) && (2...4).contains(y) ? nucleo : contorno
            })
        }
        let caixa = CGRect(x: 2.0 / 14, y: 1.0 / 7, width: 10.0 / 14, height: 5.0 / 7)
        let ceu = faixa(fundo: 190, letra: true)
        let letras = BurnedSubtitle.glyphs(of: ceu, in: [caixa])
        expect(BurnedSubtitle.shows(ceu, letras) == true, "a amostra mostra as proprias letras")
        // O caso medido: a legenda some e a cena corta 3 quadros depois.
        let corte = [faixa(fundo: 190, letra: false), faixa(fundo: 190, letra: false), faixa(fundo: 60, letra: false)]
        expect(corte.firstIndex { BurnedSubtitle.shows($0, letras) == false } == 0,
               "a legenda some no quadro em que some, nao no corte de cena seguinte")
        expect(BurnedSubtitle.shows(faixa(fundo: 60, letra: true), letras) == true,
               "corte de cena atras da legenda parada nao a tira da tela")
        expect(BurnedSubtitle.shows(faixa(fundo: 235, letra: false), letras) == false,
               "fundo claro nao imita a letra: o contorno escuro sumiu")
        expect(BurnedSubtitle.shows(faixa(fundo: 16, letra: false), letras) == false,
               "fundo escuro nao imita a letra: o nucleo claro sumiu")
        let fade = [(200, 60), (140, 100), (90, 115)].map { nucleo, contorno in
            faixa(fundo: 120, letra: true, nucleo: UInt8(nucleo), contorno: UInt8(contorno))
        }
        expect(fade.firstIndex { BurnedSubtitle.shows($0, letras) == false } == 1,
               "fade: some no quadro em que a letra passa da metade")
        let apagada = faixa(fundo: 120, letra: true, nucleo: 150, contorno: 100)
        expect(BurnedSubtitle.shows(apagada, BurnedSubtitle.glyphs(of: apagada, in: [caixa])) == nil,
               "sem contraste nao ha letra a seguir: o instante fica o da amostra")

        // Duas falas no mesmo lugar, numa caixa escura: a nova cobre 3/4 da
        // velha. Pela letra inteira a velha "continuava na tela".
        func caixaEscura(_ colunas: ClosedRange<Int>) -> BurnedSubtitle.Band {
            BurnedSubtitle.Band(width: 30, height: 9, pixels: (0..<270).map { posicao in
                let (x, y) = (posicao % 30, posicao / 30)
                return colunas.contains(x) && (3...5).contains(y) ? 235 : 40
            })
        }
        let velha = caixaEscura(3...26)
        let nova = caixaEscura(3...20)
        let faixaToda = CGRect(x: 0, y: 0, width: 1, height: 1)
        let todasDaVelha = BurnedSubtitle.glyphs(of: velha, in: [faixaToda])
        expect(BurnedSubtitle.shows(nova, todasDaVelha) == true,
               "a fala nova cobre a velha: pela letra inteira, a velha parece na tela")
        let soDaVelha = BurnedSubtitle.distinct(todasDaVelha, in: velha, against: nova)
        expect([velha, velha, nova, nova].firstIndex { BurnedSubtitle.shows($0, soDaVelha) == false } == 2,
               "pelo que a nova nao repete, a velha sai no quadro da troca")

        print("\nidiomas\n")
        expect(BurnedSubtitle.supportedLanguages.contains(.japanese)
               && BurnedSubtitle.supportedLanguages.contains(.english),
               "o leitor do sistema le japones e ingles (\(BurnedSubtitle.supportedLanguages.count) idiomas)")

        print("")
        print(failures == 0 ? "legenda na imagem ok" : "\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    /// A leitura de um vídeo de verdade: as legendas com tempo, o tempo de
    /// parede e, pedindo, o gabarito e o oráculo.
    ///
    /// Gabarito: uma fala por linha, na ordem, feita à mão contra o quadro.
    /// `# ate <s>` na primeira linha limita a conferência às legendas que
    /// começam antes disso — para gabarito de só um trecho do vídeo.
    static func burnedSubtitleVideoGate(
        path: String, language: Language, gabarito: String?, oracle: Bool, area: CGRect?
    ) async {
        failures = 0
        let url = URL(fileURLWithPath: path)
        let started = Date()
        let reading: BurnedSubtitle.Reading
        do {
            reading = try await BurnedSubtitle.read(from: url, language: language, area: area)
        } catch {
            print("falhou: \(error.localizedDescription)")
            exit(1)
        }
        let wall = Date().timeIntervalSince(started)
        for cue in reading.cues {
            print("\(String(format: "%3d", cue.index))  \(SRTWriter.timecode(cue.start)) --> "
                  + "\(SRTWriter.timecode(cue.end))  \(cue.source)")
        }
        print(String(format: "\n%d legendas, %d amostras, %d trocas; %.1f s para %.1f s de video (%.1fx o tempo real)",
                     reading.cues.count, reading.samples.count, reading.changes.count,
                     wall, reading.videoEnd, reading.videoEnd / max(wall, 0.001)))

        if let gabarito {
            let linhas = ((try? String(contentsOfFile: gabarito, encoding: .utf8)) ?? "")
                .components(separatedBy: .newlines)
            let limite = linhas.first.flatMap { primeira -> Double? in
                guard primeira.hasPrefix("# ate ") else { return nil }
                return Double(primeira.dropFirst(6).trimmingCharacters(in: .whitespaces))
            } ?? .infinity
            let esperadas = linhas.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            let lidas = reading.cues.filter { $0.start < limite }.map(\.source)
            var faltam: [String] = []
            var sobram: [String] = []
            for mudanca in lidas.difference(from: esperadas) {
                switch mudanca {
                case let .remove(_, fala, _): faltam.append(fala)
                case let .insert(_, fala, _): sobram.append(fala)
                }
            }
            print("\ngabarito: \(esperadas.count - faltam.count) de \(esperadas.count) literais")
            for fala in faltam { print("  esperada: \(fala)") }
            for fala in sobram { print("  lida:     \(fala)") }
            expect(!esperadas.isEmpty, "o gabarito tem falas")
            expect(faltam.isEmpty && sobram.isEmpty, "as falas lidas sao as do gabarito, literais e na ordem")
        }

        if oracle { await burnedSubtitleOracle(url: url, reading: reading, language: language,
                                                   area: area ?? BurnedSubtitle.defaultArea) }
        print("")
        exit(failures == 0 ? 0 : 1)
    }

    /// O instante de cada troca contra o OCR de todos os quadros entre as duas
    /// amostras: o primeiro quadro que já não lê o texto velho, e o primeiro a
    /// partir do qual só se lê o novo.
    ///
    /// Não serve para fade: o leitor deixa de ler antes do meio, e o refino
    /// cai no meio de propósito. Essas trocas se conferem olhando os quadros.
    static func burnedSubtitleOracle(
        url: URL, reading: BurnedSubtitle.Reading, language: Language, area: CGRect
    ) async {
        struct Janela { let troca: Int; let de: Double; let ate: Double }
        let amostras = reading.samples
        let janelas = reading.changes.keys.sorted().map {
            Janela(troca: $0, de: amostras[$0 - 1].time, ate: amostras[$0].time)
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else {
            print("oraculo: nao abriu o video")
            return
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }
        let request = BurnedSubtitle.recognizer(for: language)
        let fps = reading.framesPerSecond > 0 ? reading.framesPerSecond : 30

        var erros: [Int] = []
        var piores: [String] = []
        var atual = 0
        var quadros: [(Double, BurnedSubtitle.Band)] = []

        func avaliar(_ janela: Janela, _ quadros: [(Double, BurnedSubtitle.Band)]) async {
            let textos: [String] = await withTaskGroup(of: (Int, String).self) { grupo in
                for (posicao, quadro) in quadros.enumerated() {
                    guard let imagem = quadro.1.image else { continue }
                    grupo.addTask {
                        let linhas = (try? await BurnedSubtitle.recognize(imagem, with: request)) ?? []
                        return (posicao, BurnedSubtitle.filter(linhas, for: language, area: area).text)
                    }
                }
                var saida = [String](repeating: "", count: quadros.count)
                for await (posicao, texto) in grupo { saida[posicao] = texto }
                return saida
            }
            let velho = amostras[janela.troca - 1].text
            let novo = amostras[janela.troca].text
            guard let troca = reading.changes[janela.troca] else { return }
            func conta(_ lido: Double, _ verdade: Double, _ rotulo: String) {
                let erro = Int(((lido - verdade) * fps).rounded())
                erros.append(erro)
                if abs(erro) >= 2 {
                    piores.append(String(format: "  %+d quadros  %@ em %.3f s: %@ -> %@",
                                         erro, rotulo, verdade, String(velho.prefix(30)), String(novo.prefix(30))))
                }
            }
            if !velho.isEmpty {
                let fim = textos.indices.first { !BurnedSubtitle.same(textos[$0], velho) }
                conta(troca.previousEnds, fim.map { quadros[$0].0 } ?? janela.ate, "fim")
            }
            if !novo.isEmpty {
                var inicio = quadros.count
                while inicio > 0, BurnedSubtitle.same(textos[inicio - 1], novo) { inicio -= 1 }
                conta(troca.nextStarts, inicio < quadros.count ? quadros[inicio].0 : janela.ate, "inicio")
            }
        }

        while let buffer = output.copyNextSampleBuffer(), atual < janelas.count {
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let tempo = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            while atual < janelas.count, tempo > janelas[atual].ate + 1e-6 {
                await avaliar(janelas[atual], quadros)
                quadros = []
                atual += 1
            }
            guard atual < janelas.count, tempo > janelas[atual].de + 1e-6,
                  let faixa = BurnedSubtitle.copyBand(pixels, area: area) else { continue }
            quadros.append((tempo, faixa))
        }
        if atual < janelas.count { await avaliar(janelas[atual], quadros) }

        let exatos = erros.filter { $0 == 0 }.count
        let umQuadro = erros.filter { abs($0) == 1 }.count
        let doisQuadros = erros.filter { abs($0) == 2 }.count
        let mais = erros.filter { abs($0) >= 3 }.count
        print("\noraculo: \(erros.count) pontas de troca; no quadro exato \(exatos), a 1 quadro \(umQuadro), "
              + "a 2 \(doisQuadros), a 3 ou mais \(mais)")
        if !erros.isEmpty {
            print(String(format: "  exatas %.0f%%, ate 1 quadro %.0f%%",
                         Double(exatos) * 100 / Double(erros.count),
                         Double(exatos + umQuadro) * 100 / Double(erros.count)))
        }
        for linha in piores { print(linha) }
    }

    // MARK: Formatos de arquivo

    /// O seletor aceita qualquer arquivo; quem julga e a extracao, olhando os
    /// bytes. Este teste cobre os dois lados: o arquivo bom sem extensao no
    /// nome tem que passar, e o formato que o sistema nao le tem que ser
    /// recusado com uma mensagem que diz qual formato e.
    static func formatGate() async {
        failures = 0

        print("deteccao de container pelos bytes\n")

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradutor-formatos-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let original = URL(fileURLWithPath: "/tmp/video-teste.mp4")
        guard FileManager.default.fileExists(atPath: original.path) else {
            print("  (pulado: /tmp/video-teste.mp4 nao existe)")
            exit(0)
        }

        expect(MediaProbe.sniff(original) == "MP4", "reconhece MP4 pelos bytes")

        // O mesmo arquivo, sem extensao nenhuma no nome.
        let semExtensao = temporary.appendingPathComponent("gravacao")
        try? FileManager.default.copyItem(at: original, to: semExtensao)
        expect(MediaProbe.sniff(semExtensao) == "MP4",
               "reconhece o mesmo arquivo sem extensao no nome")

        // Extensao errada nao pode enganar a deteccao.
        let extensaoErrada = temporary.appendingPathComponent("arquivo.txt")
        try? FileManager.default.copyItem(at: original, to: extensaoErrada)
        expect(MediaProbe.sniff(extensaoErrada) == "MP4",
               "extensao errada nao muda o que os bytes dizem")

        // Formatos que o sistema nao abre.
        let mkv = temporary.appendingPathComponent("filme.mkv")
        try? Data([0x1A, 0x45, 0xDF, 0xA3] + [UInt8](repeating: 0, count: 64))
            .write(to: mkv)
        expect(MediaProbe.sniff(mkv) == "MKV", "reconhece Matroska")
        expect(!MediaProbe.isSupported("MKV"), "Matroska nao esta entre os aceitos")
        expect(MediaProbe.isSupported("MP4"), "MP4 esta entre os aceitos")

        let lixo = temporary.appendingPathComponent("qualquer-coisa")
        try? Data("isto nao e midia nenhuma, e so texto solto".utf8).write(to: lixo)
        expect(MediaProbe.sniff(lixo) == nil, "texto solto nao vira container")

        print("")
        print("extracao\n")

        // Cada tentativa pelo apelido .mp4 criava uma pasta tradutor-UUID e
        // so apagava o link dentro dela: 88 pastas vazias se acumularam.
        func pastasDeApelido() -> Int {
            let nomes = (try? FileManager.default.contentsOfDirectory(
                atPath: FileManager.default.temporaryDirectory.path)) ?? []
            return nomes.filter { $0.hasPrefix("tradutor-") && !$0.hasPrefix("tradutor-formatos-") }.count
        }
        let pastasAntes = pastasDeApelido()

        // O caso principal: arquivo bom, nome sem extensao.
        do {
            let samples = try await SubtitleFileBuilder.extractAudio(from: semExtensao)
            expect(samples.count > 16_000, "extrai audio de arquivo sem extensao (\(samples.count) amostras)")
        } catch {
            expect(false, "extrai audio de arquivo sem extensao — \(error.localizedDescription)")
        }

        // E o caso que tem que falhar com mensagem util.
        do {
            _ = try await SubtitleFileBuilder.extractAudio(from: mkv)
            expect(false, "formato nao suportado deveria falhar")
        } catch {
            let message = error.localizedDescription
            expect(message.contains("MKV"), "o erro diz qual formato e (MKV)")
            expect(message.contains("MP4"), "o erro lista os formatos aceitos")
            print("")
            for line in message.split(separator: "\n") { print("    \(line)") }
            print("")
        }

        expect(pastasDeApelido() == pastasAntes,
               "a extracao nao deixa pasta temporaria para tras")

        print(failures == 0 ? "formatos ok" : "\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Faixa de audio por idioma

    /// Video com mais de uma faixa de audio: a legenda tem que sair da faixa
    /// do idioma escolhido, nao da primeira que estiver no arquivo.
    ///
    /// Duas faixas de tom com amplitudes bem diferentes — da para saber qual
    /// delas foi lida so pelo nivel, sem depender de reconhecimento.
    static func trackGate() async {
        failures = 0

        print("faixa de audio por idioma\n")

        let pasta = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradutor-faixas-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)

        let video: URL
        do {
            let alto = pasta.appendingPathComponent("alto.wav")
            let baixo = pasta.appendingPathComponent("baixo.wav")
            try escreveTom(alto, amplitude: 0.5, frequencia: 440)
            try escreveTom(baixo, amplitude: 0.05, frequencia: 880)
            // A faixa do idioma pedido e a SEGUNDA de proposito: com a
            // primeira, o gate passaria mesmo sem o conserto.
            video = try await montaFaixas(
                [(alto, "eng"), (baixo, "jpn")],
                para: pasta.appendingPathComponent("duas-faixas.mov")
            )
        } catch {
            print("FALHA ao montar o arquivo de teste: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: pasta)
            exit(1)
        }

        func nivel(_ language: Language?) async -> Float {
            guard let samples = try? await SubtitleFileBuilder.extractAudio(
                from: video, preferring: language
            ), !samples.isEmpty else { return -1 }
            let energia = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
            return Float((energia / Double(samples.count)).squareRoot())
        }

        let japones = await nivel(.japanese)
        let ingles = await nivel(.english)
        let semPedido = await nivel(nil)
        let semFaixa = await nivel(.thai)
        print(String(format: "  niveis: ja=%.3f  en=%.3f  sem pedido=%.3f  sem faixa=%.3f\n",
                     japones, ingles, semPedido, semFaixa))

        expect(japones > 0 && japones < 0.1,
               "pedindo japones vem a faixa japonesa, que e a segunda")
        expect(ingles > 0.2, "pedindo ingles vem a faixa inglesa, que e a primeira")
        expect(semPedido > 0.2, "sem idioma nenhum a primeira faixa continua valendo")
        expect(semFaixa > 0.2, "idioma que nenhuma faixa declara cai na primeira")

        try? FileManager.default.removeItem(at: pasta)
        print("")
        print(failures == 0 ? "faixa por idioma ok" : "\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    /// Um tom senoidal em .wav, para o teste ter audio sem depender de arquivo
    /// externo.
    static func escreveTom(
        _ url: URL, amplitude: Float, frequencia: Double, segundos: Double = 2
    ) throws {
        let taxa = 44_100.0
        guard let formato = AVAudioFormat(standardFormatWithSampleRate: taxa, channels: 1)
        else { throw NSError(domain: "faixas", code: 1) }
        let arquivo = try AVAudioFile(forWriting: url, settings: formato.settings)
        let quadros = AVAudioFrameCount(taxa * segundos)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: quadros)
        else { throw NSError(domain: "faixas", code: 2) }
        buffer.frameLength = quadros
        let canal = buffer.floatChannelData![0]
        for quadro in 0..<Int(quadros) {
            canal[quadro] = amplitude * Float(sin(2 * .pi * frequencia * Double(quadro) / taxa))
        }
        try arquivo.write(from: buffer)
    }

    /// Junta varios audios num arquivo so, uma faixa cada, com o idioma
    /// declarado — que e como chega um video com dublagem.
    static func montaFaixas(_ faixas: [(URL, String)], para destino: URL) async throws -> URL {
        let composicao = AVMutableComposition()
        for (url, idioma) in faixas {
            let asset = AVURLAsset(url: url)
            guard let origem = try await asset.loadTracks(withMediaType: .audio).first,
                  let trilha = composicao.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let duracao = try await asset.load(.duration)
            try trilha.insertTimeRange(
                CMTimeRange(start: .zero, duration: duracao), of: origem, at: .zero)
            trilha.languageCode = idioma
        }
        guard let exportacao = AVAssetExportSession(
            asset: composicao, presetName: AVAssetExportPresetPassthrough)
        else { throw NSError(domain: "faixas", code: 3) }
        try? FileManager.default.removeItem(at: destino)
        try await exportacao.export(to: destino, as: .mov)
        return destino
    }

    // MARK: Legenda de arquivo

    static func srtGate(
        path: String, source: Language, target: Language,
        engine: RecognitionEngine = .whisper, diarize: Bool = false, colors: Bool = false
    ) async {
        let url = URL(fileURLWithPath: path)
        print("arquivo: \(url.lastPathComponent)")
        print("idiomas: \(source.rawValue) -> \(target.rawValue)\n")

        let started = Date()
        print("extraindo audio...")
        let samples: [Float]
        do {
            samples = try await SubtitleFileBuilder.extractAudio(from: url)
        } catch {
            print("FALHA: \(error.localizedDescription)")
            exit(1)
        }
        let duration = Double(samples.count) / 16_000
        print(String(format: "  %.1fs de audio em %.1fs\n", duration, Date().timeIntervalSince(started)))

        let transcriber = TranscriberFactory.make(for: source, engine: engine)
        // O mesmo que o `generate` faz: locutores primeiro, fronteiras para o
        // reconhecedor.
        var turnsPrevias: [SpeakerDiarizer.Turn] = []
        if diarize {
            let modeloEscolhido = ProcessInfo.processInfo.environment["MODELO_LOCUTOR"]
                .flatMap { SpeakerDiarizer.Model(rawValue: $0) } ?? SubtitleFileBuilder().speakerModel
            let comecou = Date()
            turnsPrevias = (try? await SpeakerDiarizer.turns(in: samples, model: modeloEscolhido)) ?? []
            transcriber.speakerBoundaries = SpeakerDiarizer.boundaries(of: turnsPrevias)
            print(String(format: "locutores por %@: %d vozes, %d faixas, %.1fs",
                         modeloEscolhido.displayName,
                         Set(turnsPrevias.map(\.speaker)).count, turnsPrevias.count,
                         Date().timeIntervalSince(comecou)))
        }
        print("reconhecendo com \(transcriber.engineName)...")
        do {
            try await transcriber.prepare { _, _ in }
        } catch {
            print("FALHA ao carregar: \(error.localizedDescription)")
            exit(1)
        }

        let asrStart = Date()
        let timed: [TimedText]
        do {
            timed = try await transcriber.transcribeForSubtitles(samples)
        } catch {
            print("FALHA na transcricao: \(error.localizedDescription)")
            exit(1)
        }
        print(String(format: "  %d trechos em %.1fs (%.0fx tempo real)\n",
                     timed.count, Date().timeIntervalSince(asrStart),
                     duration / max(Date().timeIntervalSince(asrStart), 0.001)))

        guard !timed.isEmpty else {
            print("FALHA: nenhuma fala reconhecida")
            exit(1)
        }

        let builder = SubtitleFileBuilder()
        // Medicao: SOBREPOSICAO troca as legendas reenviadas como contexto.
        if let valor = ProcessInfo.processInfo.environment["SOBREPOSICAO"], let n = Int(valor) {
            builder.contextOverlap = n
            print("sobreposicao: \(n) legendas")
        }
        let pieces = turnsPrevias.isEmpty
            ? timed
            : SpeakerDiarizer.renumber(SpeakerDiarizer.assign(timed, to: turnsPrevias))

        let cues = builder.makeCues(from: pieces, mediaDuration: duration)
        print("legendas: \(cues.count)")
        if diarize {
            let marcadas = cues.filter { $0.speaker != nil }.count
            print("legendas com locutor: \(marcadas) de \(cues.count)")
        }

        let translator = TranslatorFactory.make(.apple)
        do {
            try await translator.prepare { _, _ in }
        } catch {
            print("FALHA ao carregar tradutor: \(error.localizedDescription)")
            exit(1)
        }
        print("traduzindo com \(translator.engineName)...")

        let mtStart = Date()
        let translated = await builder.translate(
            cues, using: translator, from: source, to: target
        ) { progress in
            FileHandle.standardError.write(Data("  \(progress.label)\r".utf8))
        }
        print(String(format: "  %.1fs\n", Date().timeIntervalSince(mtStart)))

        let output = url.deletingPathExtension().appendingPathExtension("\(target.rawValue).srt")
        let text = SRTWriter.render(
            translated, colorBySpeaker: diarize && colors,
            charactersPerLine: builder.charactersPerLine
        )
        do {
            try text.write(to: output, atomically: true, encoding: .utf8)
        } catch {
            print("FALHA ao gravar: \(error.localizedDescription)")
            exit(1)
        }

        print("gravado em \(output.path)")
        print(String(format: "total: %.1fs para %.1fs de video\n", Date().timeIntervalSince(started), duration))
        if diarize {
            // Confere o travessão contra o locutor de cada legenda: ele tem
            // de aparecer exatamente onde a voz troca, e em nenhum outro
            // lugar.
            print("")
            print("locutor por legenda (× = travessão no arquivo):")
            // Compara o arquivo com a lista de locutores, na mesma ordem: só
            // entram as legendas que o escritor de fato escreve.
            let escritas = translated.filter {
                SentenceSplitter.hasContent($0.translated.isEmpty ? $0.source : $0.translated)
            }
            let blocos = SRTWriter.render(translated, colorBySpeaker: false)
                .components(separatedBy: "\n\n")
                .filter { $0.contains("-->") }
            var anterior: String?
            var fora = 0
            for (index, cue) in escritas.enumerated() where index < blocos.count {
                let devia = cue.speaker != nil && cue.speaker != anterior
                let corpo = blocos[index].components(separatedBy: "\n").dropFirst(2).joined(separator: " ")
                let tem = corpo.hasPrefix("— ")
                if devia != tem { fora += 1 }
                if index < 16 {
                    print(String(format: "  %@ %-12@ %@ %@",
                                 tem ? "×" : " ",
                                 (cue.speaker ?? "—") as NSString,
                                 devia == tem ? "ok  " : "ERRO",
                                 String(corpo.prefix(44))))
                }
                anterior = cue.speaker
            }
            print("travessoes fora de lugar: \(fora) de \(min(escritas.count, blocos.count))")
        }

        print("primeiras legendas:")
        print(text.split(separator: "\n\n").prefix(4).joined(separator: "\n\n"))
    }

    /// Formatacao e agrupamento, sem depender de arquivo nem de modelo.
    /// Um tradutor que sempre falha, e outro que devolve menos linhas do que
    /// recebeu. Os dois defeitos que o `.srt` não denunciava sozinho.
    private final class TradutorQuebrado: Translator, @unchecked Sendable {
        enum Falha: Error { case sempre }
        let engineName = "quebrado"
        /// Quando falso, devolve uma tradução a menos do que recebeu.
        let lanca: Bool
        init(lanca: Bool) { self.lanca = lanca }
        func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
        func translate(_ text: String, from: Language, to: Language) async throws -> String {
            throw Falha.sempre
        }
        func translate(
            _ texts: [String], from: Language, to: Language
        ) async throws -> [String] {
            if lanca { throw Falha.sempre }
            return Array(texts.dropLast()).map { "[\($0)]" }
        }
        func reset() {}
    }

    static func timecodeGate() async {
        failures = 0

        print("a legenda nao apaga a tela no meio da fala\n")
        do {
            // A queixa real, em japones com o Whisper: a legenda aparece e
            // some com a pessoa ainda falando. O agrupamento esta certo — o
            // reconhecedor pontua cada fala curta e o agrupador fecha legenda
            // na pontuacao —, o que faltava era segurar a legenda ate a
            // seguinte. Medido no video de 9 minutos: 38 buracos abaixo de
            // 1 s somando 25,5 s de tela apagada viraram 4,4 s.
            let builder = SubtitleFileBuilder()
            let perto = builder.makeCues(from: [
                TimedText(text: "Primeira fala aqui.", start: 0, end: 2.0),
                TimedText(text: "Segunda fala aqui.", start: 2.6, end: 4.5),
            ])
            expect(perto.count == 2, "duas falas, duas legendas (deu \(perto.count))")
            if perto.count == 2 {
                let buraco = perto[1].start - perto[0].end
                expect(buraco > 0 && buraco <= builder.minimumGap + 0.001,
                       String(format: "buraco curto e preenchido, com respiro (deu %.3fs)", buraco))
            }

            // Buraco longo e pausa de verdade: nao se preenche.
            let longe = builder.makeCues(from: [
                TimedText(text: "Primeira fala aqui.", start: 0, end: 2.0),
                TimedText(text: "Segunda fala aqui.", start: 6.0, end: 8.0),
            ])
            if longe.count == 2 {
                expect(longe[1].start - longe[0].end > 1.0,
                       "buraco longo continua sendo silencio na tela")
            }

            // E o teto de leitura manda: preencher nao pode esticar a legenda
            // alem de `maximumDuration`.
            let esticada = builder.makeCues(from: [
                TimedText(text: "Uma fala longa que ocupa quase todo o teto.", start: 0, end: 6.8),
                TimedText(text: "A seguinte.", start: 7.6, end: 9.0),
            ])
            expect(esticada.allSatisfy { $0.end - $0.start <= builder.maximumDuration + 0.001 },
                   "preencher o buraco nao passa do teto de 7 s")
        }
        print("")

        let silence = [Float](repeating: 0, count: 1_600)
        expect(SubtitleFileBuilder.boostQuietAudio(silence) == silence,
               "normalizacao nao transforma silencio em sinal")
        for level: Float in [0.1, 0.01, 0.003, 0.000001] {
            let audio = [level, -level, level, -level]
            expect(SubtitleFileBuilder.boostQuietAudio(audio) == audio,
                   "nivel normal, moderado ou residual fica intacto: \(level)")
        }
        let quiet: [Float] = [0.001, -0.001, 0.002, -0.002]
        let louder = SubtitleFileBuilder.boostQuietAudio(quiet)
        let measuredGain = louder[0] / quiet[0]
        expect(measuredGain > 1 && measuredGain <= 20
               && louder.count == quiet.count && zip(louder, quiet).allSatisfy {
            abs($0.0 - $0.1 * measuredGain) < 0.000001
        }, "ganho recupera audio muito baixo sem alterar tempo, polaridade ou forma")
        var transient = [Float](repeating: 0.0001, count: 100_000)
        transient[0] = 0.8
        expect((SubtitleFileBuilder.boostQuietAudio(transient).map { abs($0) }.max() ?? 1) <= 0.951,
               "pico isolado limita o ganho, sem clipping")

        print("")
        print("silêncio como fronteira de legenda\n")
        do {
            let construtor = SubtitleFileBuilder()
            // Dois trechos colados, com silêncio real entre as falas: é o que
            // a Apple entrega em japonês, porque ela embute o silêncio na
            // duração do caractere e os trechos saem contíguos. Sem olhar o
            // áudio, o agrupador não vê pausa nenhuma e junta as duas pessoas.
            let colados = [
                TimedText(text: "お疲れ様あれさん", start: 221.09, end: 225.12),
                TimedText(text: "お疲れ様です。", start: 225.12, end: 227.34),
            ]
            expect(construtor.makeCues(from: colados).count == 1,
                   "sem o silêncio, dois trechos colados viram uma legenda só")
            construtor.silences = [225.0...226.0]
            let partidas = construtor.makeCues(from: colados)
            expect(partidas.count == 2,
                   "o silêncio medido separa as duas falas (deu \(partidas.count))")
            // O silêncio precisa casar pelo INTERVALO: o reconhecedor corta
            // onde a palavra cruza a fronteira, não onde o silêncio está, e
            // comparar ponto com ponto nunca casa.
            construtor.silences = [226.5...227.0]
            expect(construtor.makeCues(from: colados).count == 1,
                   "silêncio fora da junção não parte a legenda")
        }

        print("")
        print("nivelamento de fala baixa\n")
        do {
            // Fala sintetica: rajadas de 0,25 s separadas por fundo baixo, e
            // a segunda metade 30 dB abaixo da primeira — que e o caso medido
            // (alguem que fala baixo no meio de quem fala alto).
            let taxa = 16_000
            let total = taxa * 40
            var audio = [Float](repeating: 0, count: total)
            for indice in 0..<total {
                let segundo = Double(indice) / Double(taxa)
                let falando = Int(segundo / 0.25) % 2 == 0
                let fundo = Float.random(in: -0.0008...0.0008)
                let voz = falando
                    ? Float(sin(2 * .pi * 180 * segundo)) * 0.2 : 0
                audio[indice] = (voz + fundo) * (segundo > 20 ? 0.0316 : 1)
            }
            func rms(_ trecho: ArraySlice<Float>) -> Float {
                let energia = trecho.reduce(0.0) { $0 + Double($1) * Double($1) }
                return Float((energia / Double(trecho.count)).squareRoot())
            }
            let nivelado = SubtitleFileBuilder.levelQuietSpeech(audio)
            let antes = rms(audio[0..<(taxa * 20)]) / rms(audio[(taxa * 20)...])
            let depois = rms(nivelado[0..<(taxa * 20)]) / rms(nivelado[(taxa * 20)...])
            print(String(format: "  metade alta / metade baixa: %.0fx antes, %.1fx depois",
                         antes, depois))
            expect(antes > 20, "o caso de teste tem mesmo as duas metades separadas")
            expect(depois < 3, "a metade baixa sobe ate perto da alta (deu \(Int(depois))x)")
            expect(nivelado.count == audio.count, "nivelar nao muda a duracao")
            expect((nivelado.map { abs($0) }.max() ?? 1) <= 0.99, "nivelar nao satura")

            // Nivel parelho nao e mexido: material bem gravado sai identico.
            let parelho = (0..<(taxa * 10)).map { indice -> Float in
                Float(sin(2 * .pi * 180 * Double(indice) / Double(taxa))) * 0.2
            }
            expect(SubtitleFileBuilder.levelQuietSpeech(parelho) == parelho,
                   "audio de nivel parelho passa intacto")

            // Ruido de fundo sozinho nao vira sinal. Com piso absoluto isso
            // falhava: o fundo de um dos videos subia 20x e o detector de
            // energia passava a ver fala onde nao havia — 196 trechos contra
            // 186 no mesmo arquivo.
            let so_ruido = (0..<(taxa * 10)).map { _ in Float.random(in: -0.002...0.002) }
            let ruidoNivelado = SubtitleFileBuilder.levelQuietSpeech(so_ruido)
            let ganhoDoRuido = rms(ruidoNivelado[...]) / rms(so_ruido[...])
            expect(ganhoDoRuido < 1.2,
                   String(format: "ruido de fundo sozinho nao e amplificado (deu %.1fx)", ganhoDoRuido))
        }

        print("codigo de tempo\n")
        expect(SRTWriter.timecode(0) == "00:00:00,000", "zero")
        expect(SRTWriter.timecode(83.456) == "00:01:23,456", "minutos e milissegundos")
        expect(SRTWriter.timecode(3661.5) == "01:01:01,500", "passa de uma hora")
        expect(SRTWriter.timecode(-3) == "00:00:00,000", "tempo negativo nao vira lixo")

        print("")
        print("agrupamento em legendas")
        let builder = SubtitleFileBuilder()
        let words = [
            ("The", 0.0, 0.2), ("engineer", 0.2, 0.8), ("walked", 0.8, 1.2),
            ("us", 1.2, 1.4), ("through", 1.4, 1.8), ("it.", 1.8, 2.1),
            ("Nobody", 3.5, 4.0), ("had", 4.0, 4.2), ("questions.", 4.2, 5.0),
        ].map { TimedText(text: $0.0, start: $0.1, end: $0.2) }

        let cues = builder.makeCues(from: words)
        expect(cues.count == 2, "duas frases viram duas legendas (deu \(cues.count))")
        expect(cues.first?.source == "The engineer walked us through it.",
               "as palavras remontam a frase")
        // A legenda entra um pouco antes da fala; no comeco do arquivo o
        // recuo para em zero.
        expect((cues.first?.start ?? -1) == 0.0, "no inicio do arquivo o recuo para em zero")
        expect(
            (cues.last?.start ?? 0) < 3.5 && (cues.last?.start ?? 0) >= (cues.first?.end ?? 0),
            "a legenda seguinte entra antes da fala sem invadir a anterior (\(cues.last?.start ?? 0))"
        )
        expect(abs((cues.first?.end ?? 0) - 2.1) < 0.01, "termina no tempo da ultima")
        // A pausa continua separando; a legenda so entra 0,25 s antes da fala.
        expect((cues.last?.start ?? 0) >= 3.2 && (cues.last?.start ?? 0) < 3.6,
               "a pausa de 1,4s separa as legendas (deu \(cues.last?.start ?? 0))")

        // Tempos desordenados e invertidos: o que produzia
        // "00:00:31,189 --> 00:00:27,220" no arquivo real.
        let bagunca = builder.makeCues(from: [
            TimedText(text: "terceira.", start: 26.3, end: 31.2),
            TimedText(text: "primeira.", start: 2.8, end: 7.3),
            TimedText(text: "segunda.", start: 27.2, end: 28.1),
        ])
        expect(bagunca.allSatisfy { $0.end > $0.start },
               "nenhuma legenda termina antes de comecar")
        var emOrdem = true
        for index in 1..<max(bagunca.count, 1) {
            if bagunca[index].start < bagunca[index - 1].end { emOrdem = false }
            if bagunca[index].start < bagunca[index - 1].start { emOrdem = false }
        }
        expect(emOrdem, "tempos desordenados na entrada saem em ordem e sem sobreposicao")
        expect(bagunca.first?.source.contains("primeira") == true,
               "a legenda mais antiga vem primeiro")
        for cue in bagunca {
            print("    \(SRTWriter.timecode(cue.start)) → \(SRTWriter.timecode(cue.end))  \(cue.source)")
        }

        // Fragmento solto tipo "etc." nao pode virar legenda de meio segundo.
        let fragmento = builder.makeCues(from: [
            TimedText(text: "Antes", start: 9.1, end: 10.0),
            TimedText(text: "de", start: 10.0, end: 10.4),
            TimedText(text: "fazer", start: 10.4, end: 11.0),
            TimedText(text: "compras.", start: 11.0, end: 14.4),
            TimedText(text: "etc.", start: 14.46, end: 14.92),
        ])
        expect(fragmento.allSatisfy { $0.end - $0.start >= 0.6 },
               "nenhuma legenda fica curta demais para ler")
        expect(!fragmento.contains { $0.source == "etc." },
               "fragmento solto e juntado a vizinha")

        // Resposta curta de OUTRA pessoa nao e sobra de corte: juntar desfazia
        // o trabalho das fronteiras de voz e punha a fala dela na boca de
        // quem perguntou. Auditoria de 12/09/2026.
        let respostaCurta = builder.makeCues(from: [
            TimedText(text: "Você entregou o relatório?", start: 0.0, end: 3.0,
                      speaker: "Locutor 1"),
            TimedText(text: "Sim.", start: 3.05, end: 3.8, speaker: "Locutor 2"),
        ])
        expect(respostaCurta.count == 2,
               "resposta curta de outra voz nao e juntada (deu \(respostaCurta.count))")
        expect(respostaCurta.last?.speaker == "Locutor 2",
               "a resposta continua sendo de quem respondeu")
        // Sobra da MESMA pessoa continua sendo juntada: e para isso que a
        // juncao existe.
        let sobraDoMesmo = builder.makeCues(from: [
            TimedText(text: "Antes de fazer compras.", start: 0.0, end: 3.0,
                      speaker: "Locutor 1"),
            TimedText(text: "etc.", start: 3.05, end: 3.5, speaker: "Locutor 1"),
        ])
        expect(sobraDoMesmo.count == 1,
               "sobra da mesma voz continua sendo juntada (deu \(sobraDoMesmo.count))")

        // A juncao roda DEPOIS do corte de duracao e voltava a passar do teto:
        // 9,481 s na legenda 12 do video com musica, em 12/09/2026.
        let juncaoLonga = builder.makeCues(from: [
            TimedText(text: "Uma fala que ocupa quase a tela inteira.", start: 0.0, end: 6.4),
            TimedText(text: "本", start: 7.1, end: 9.4),
        ])
        expect(juncaoLonga.allSatisfy { $0.end - $0.start <= 7.01 },
               "juntar nao faz a legenda passar de 7s (maior: "
               + "\(String(format: "%.2f", juncaoLonga.map { $0.end - $0.start }.max() ?? 0))s)")
        expect(juncaoLonga.count == 2 && juncaoLonga.last?.source == "本"
               && (juncaoLonga.last?.end ?? 0) >= 9.4,
               "o teto nao apaga o tempo da fala posterior: conserva 7,1–9,4s")

        // Nada pode cair fora do video nem ficar tempo demais na tela: no
        // video de 18 min saiu uma legenda comecando 3 s depois do fim e
        // durando 20 s, com teto de 7.
        let atravessaTeto = builder.makeCues(from: [
            TimedText(text: "これは長い説明の前半です", start: 0, end: 6.8),
            TimedText(text: "そして説明は九秒まで続きます。", start: 6.8, end: 9),
        ], mediaDuration: 10)
        expect(atravessaTeto.count == 2
               && abs((atravessaTeto.last?.end ?? 0) - 9) < 0.001
               && atravessaTeto.allSatisfy { $0.end - $0.start <= builder.maximumDuration }
               && atravessaTeto.map(\.source).joined() == "これは長い説明の前半ですそして説明は九秒まで続きます。",
               "fecha antes do teto sem perder texto nem o fim da fala")

        let antecipada = builder.makeCues(from: [
            TimedText(text: "A fala cabe no teto.", start: 10, end: 16.9),
        ], mediaDuration: 20)
        expect(abs((antecipada.last?.end ?? 0) - 16.9) < 0.001
               && antecipada.allSatisfy { $0.end - $0.start <= builder.maximumDuration + 0.001 },
               "antecipação cede espaço sem cortar a fala")

        let foraDoVideo = builder.makeCues(from: [
            TimedText(text: "dentro do video.", start: 5.0, end: 8.0),
            TimedText(text: "longa demais na tela.", start: 20.0, end: 44.0),
            TimedText(text: "depois do fim.", start: 62.0, end: 80.0),
        ], mediaDuration: 60.0)
        expect(!foraDoVideo.contains { $0.source.contains("depois do fim") },
               "legenda que comeca depois do fim do video e descartada")
        expect(foraDoVideo.allSatisfy { $0.end <= 60.01 },
               "nenhuma legenda passa do fim do video")
        expect(foraDoVideo.allSatisfy { $0.end - $0.start <= 7.01 },
               "nenhuma legenda fica mais que 7s na tela (maior: \(String(format: "%.1f", foraDoVideo.map { $0.end - $0.start }.max() ?? 0))s)")
        expect(foraDoVideo.contains { $0.source.contains("dentro") },
               "o que esta dentro do video fica")

        // Sem duracao conhecida, so o teto de tela vale.
        let semDuracao = builder.makeCues(from: [
            TimedText(text: "muito longa.", start: 0, end: 30),
        ])
        expect(semDuracao.allSatisfy { $0.end - $0.start <= 7.01 },
               "o teto de tela vale mesmo sem saber a duracao do video")

        // Legendas nao podem se sobrepor.
        let tight = builder.makeCues(from: [
            TimedText(text: "um.", start: 0.0, end: 0.3),
            TimedText(text: "dois.", start: 0.4, end: 0.6),
        ])
        var overlapping = false
        for index in 1..<max(tight.count, 1) where tight[index].start < tight[index - 1].end {
            overlapping = true
        }
        expect(!overlapping, "legendas nao se sobrepoem no tempo")
        expect(tight.allSatisfy { $0.end > $0.start }, "toda legenda tem duracao positiva")

        print("")
        print("limite de duas linhas")
        // A traducao cresce em relacao ao original, entao uma legenda que
        // cabia em duas linhas em ingles pode estourar em portugues. Nao da
        // para saber isso na hora de cortar o original.
        let longo = Cue(
            index: 1, start: 10, end: 16,
            source: "long source",
            translated: "A engenheira nos explicou todos os casos extremos, ninguém teve dúvidas, então ela aprovou tudo sozinha na sexta."
        )
        let divididas = builder.enforceLineLimit([longo])
        expect(divididas.count > 1, "legenda longa demais e dividida (deu \(divididas.count))")
        expect(divididas.allSatisfy {
            LineBreaker.wrap($0.translated, maximum: 42).count <= 2
        }, "nenhuma legenda passa de duas linhas")
        expect(divididas.allSatisfy { $0.end > $0.start }, "toda parte tem duracao positiva")
        // A sobra que virava "etc." piscando por meio segundo.
        expect(divididas.allSatisfy { $0.end - $0.start >= 0.65 },
               "nenhuma parte pisca na tela (menor: \(String(format: "%.2f", divididas.map { $0.end - $0.start }.min() ?? 0))s)")
        let tamanhos = divididas.map(\.translated.count)
        expect((tamanhos.max() ?? 0) <= (tamanhos.min() ?? 1) * 3,
               "as partes ficam de tamanho parecido (\(tamanhos))")

        // Original em japones nao pode ser cortado no meio da palavra: sem
        // espaco entre palavras, um corte por caractere parte "など" ao meio.
        let japones = Cue(
            index: 1, start: 0, end: 8,
            source: "買い物の前に牛乳パックなどリサイクルのものを出します",
            translated: "Antes de fazer compras, tire as embalagens de leite recicláveis e outros materiais reciclaveis para fora."
        )
        let partesJa = builder.enforceLineLimit([japones])
        expect(partesJa.count > 1, "a legenda japonesa longa e dividida")
        expect(partesJa.first?.source == japones.source,
               "sem fronteira natural, o original fica inteiro na primeira parte")
        expect(partesJa.dropFirst().allSatisfy { $0.source.isEmpty },
               "as partes seguintes ficam sem original em vez de com metade de uma palavra")

        let traducaoComprida = Array(repeating: "teste", count: 18).joined(separator: " ")
        for duracao in [0.3, 1.0, 1.25, 6.0] {
            let partes = builder.enforceLineLimit([
                Cue(index: 1, start: 6, end: 6 + duracao, source: "Original.",
                    translated: traducaoComprida, speaker: "Locutor 1"),
            ])
            expect(partes.count > 1
                   && partes.first?.start == 6
                   && abs((partes.last?.end ?? 0) - (6 + duracao)) < 0.001
                   && partes.allSatisfy { $0.end > $0.start && $0.speaker == "Locutor 1" }
                   && zip(partes, partes.dropFirst()).allSatisfy { abs($0.end - $1.start) < 0.001 }
                   && partes.map(\.translated).joined(separator: " ") == traducaoComprida,
                   "divisão respeita os \(duracao) s disponíveis e preserva texto e locutor")
        }

        var ultima = builder.makeCues(from: [
            TimedText(text: "Esta fala termina no último quadro.", start: 6, end: 7),
        ], mediaDuration: 7)
        for i in ultima.indices { ultima[i].translated = traducaoComprida }
        let ultimaRepartida = builder.enforceLineLimit(ultima)
        expect(ultimaRepartida.count > 1 && abs((ultimaRepartida.last?.end ?? 0) - 7) < 0.001,
               "gerar e repartir mantém o fim do vídeo")

        // Com pontuacao japonesa, aí sim divide.
        let comPontuacao = Cue(
            index: 1, start: 0, end: 8,
            source: "みなさんこんにちは、ここはスーパーです。今日は買い物をします",
            translated: "Olá a todos, este é um supermercado e hoje vamos fazer compras aqui dentro dele com calma."
        )
        let partesPont = builder.enforceLineLimit([comPontuacao])
        expect(partesPont.map(\.source).joined() == comPontuacao.source,
               "repartir preserva pontuação japonesa sem inserir espaços")
        for original in [
            "Are you sure? Yes, really! Wait; please: don't go.",
            "São quinze? Não, cinquenta! Espere; por favor: não feche.",
        ] {
            let partes = builder.enforceLineLimit([
                Cue(index: 1, start: 0, end: 6, source: original, translated: traducaoComprida),
            ])
            expect(partes.count > 1 && partes.map(\.source).joined(separator: " ") == original,
                   "repartir conserva palavras, pontuação e espaços do original")
        }
        if partesPont.count > 1 {
            expect(partesPont.allSatisfy { !$0.source.contains("、、") },
                   "a pontuacao japonesa serve de fronteira")
            for parte in partesPont { print("    | \(parte.source)  →  \(parte.translated)") }
        }
        expect(abs((divididas.first?.start ?? 0) - 10) < 0.01, "a primeira comeca no tempo original")
        expect((divididas.last?.end ?? 0) <= 16.01, "a ultima nao passa do tempo original")
        var cresce = true
        for index in 1..<divididas.count where divididas[index].start < divididas[index - 1].start {
            cresce = false
        }
        expect(cresce, "as partes ficam em ordem no tempo")
        for cue in divididas {
            print("    \(SRTWriter.timecode(cue.start)) → \(SRTWriter.timecode(cue.end))  \(cue.translated)")
        }

        print("")
        print("arquivo SRT")
        let rendered = SRTWriter.render([
            Cue(index: 1, start: 0, end: 2.1, source: "Hello there.", translated: "Olá."),
            Cue(index: 2, start: 3.5, end: 5, source: "Nobody had questions.", translated: "Ninguém tinha perguntas."),
        ])
        expect(rendered.hasPrefix("1\n00:00:00,000 --> 00:00:02,100\nOlá."),
               "primeiro bloco no formato SubRip")
        expect(rendered.contains("2\n00:00:03,500 --> 00:00:05,000"), "segundo bloco numerado")
        expect(!rendered.contains("Hello there."), "o original nao entra por padrao")
        for line in rendered.split(separator: "\n").prefix(7) { print("    \(line)") }

        // Lote que falha nao pode passar por geracao completa: o `.srt` sai
        // com aquele pedaco no idioma de origem e o arquivo fica plausivel e
        // errado. Auditoria de 12/09/2026.
        print("")
        print("lote que falha")
        let entradas = [
            Cue(index: 1, start: 0, end: 2, source: "This is English.", translated: ""),
            Cue(index: 2, start: 2, end: 4, source: "So is this.", translated: ""),
        ]
        let comFalha = SubtitleFileBuilder()
        let semTraducao = await comFalha.translate(
            entradas, using: TradutorQuebrado(lanca: true), from: .english, to: .portuguese
        )
        expect(semTraducao.allSatisfy { $0.translated.isEmpty },
               "o lote que falhou nao inventa traducao")
        expect(comFalha.translationNotice != nil,
               "a falha vira aviso na tela: \(comFalha.translationNotice ?? "nenhum")")
        // E, no caminho de quem gera legenda, vira erro: `translateDraft` lê
        // este contador e lança em vez de entregar meio arquivo traduzido.
        // Nenhum tradutor de reserva entra no lugar — pedido do usuário em
        // 14/09/2026.
        expect(comFalha.failedBatches == 1,
               "o lote perdido fica contado para a geracao poder falhar (\(comFalha.failedBatches))")
        expect(SubtitleFileError.translationFailed("x").errorDescription?.contains("falhou") == true,
               "o erro diz que foi a traducao que falhou")
        // O `.srt` cai no original — e por isso que o aviso precisa existir.
        expect(SRTWriter.render(semTraducao).contains("This is English."),
               "sem traducao, o arquivo sai no idioma de origem")

        // Resposta com contagem diferente da entrada e o defeito que nao
        // devolve erro: a legenda 2 receberia o texto da 1.
        let curto = SubtitleFileBuilder()
        let desalinhado = await curto.translate(
            entradas, using: TradutorQuebrado(lanca: false), from: .english, to: .portuguese
        )
        expect(desalinhado.allSatisfy { $0.translated.isEmpty },
               "resposta com contagem errada e descartada inteira")
        expect(curto.translationNotice != nil, "a contagem errada tambem avisa")

        // E o caminho normal continua normal: sem falha, sem aviso.
        let semAviso = SubtitleFileBuilder()
        _ = await semAviso.translate(
            [], using: TradutorQuebrado(lanca: true), from: .english, to: .portuguese
        )
        expect(semAviso.translationNotice == nil, "sem lote nenhum, sem aviso")

        print("")
        print(failures == 0 ? "legenda de arquivo ok" : "\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Prefixo estavel

    /// A politica LocalAgreement-2: so vai para a tela o prefixo em que duas
    /// passadas consecutivas do reconhecedor concordam.
    static func stablePrefixGate() {
        failures = 0

        print("confirmacao de prefixo estavel\n")

        // Comparação fina sem destruir os espaços dos outros idiomas nem
        // as palavras de nomes latinos dentro de uma frase japonesa.
        for text in ["今日は晴れです。明日は雨です。", "你好，世界。",
                     "今日はSan Franciscoに行きます。", "안녕하세요 오늘 날씨가 좋습니다.",
                     "Hello！ How are you?", "the engineer walked us through it."] {
            expect(Tokens.join(Tokens.split(text)) == text,
                   "tokenizar e reunir preserva: \(text)")
        }
        var japanese = StablePrefixTracker()
        _ = japanese.feed("今日は晴れです。明日は雨です。")
        let stableJapanese = japanese.feed("今日は晴れです。明日は雪です。")
        expect(Tokens.join(stableJapanese).hasPrefix("今日は晴れです。"),
               "confirma a frase japonesa anterior enquanto a seguinte oscila")
        var japanesePhrases = PhraseAccumulator()
        expect(japanesePhrases.append(stableJapanese).first == "今日は晴れです。",
               "frase japonesa confirmada chega inteira ao tradutor")
        expect(Tokens.split("오늘 날씨가 좋습니다.").count == 3,
               "coreano continua comparando palavras, sem remover espacos")

        // O reconhecedor da Apple devolve `ですか ？` e `です。 頑張ろうね。`, e
        // esse espaço seguia para o tradutor e para o arquivo. Eram 22 no
        // video de 9 minutos; juntar os trechos pela regra da escrita tirou
        // 10 e este conserto tirou mais 7.
        for (entrada, esperado) in [
            ("ですか ？", "ですか？"),
            ("よかったです。 頑張ろうね。", "よかったです。頑張ろうね。"),
            ("今 20歳です", "今 20歳です"),
            ("the engineer walked us through it.", "the engineer walked us through it."),
            ("dois  espacos  ficam", "dois  espacos  ficam"),
            ("今日は San Francisco", "今日は San Francisco"),
        ] {
            let saida = Tokens.tightenDense(entrada)
            expect(saida == esperado,
                   "espaco entre densos: \"\(entrada)\" -> \"\(saida)\"")
        }

        var tracker = StablePrefixTracker()

        // Passada 1: nada a comparar ainda, nada confirma.
        expect(tracker.feed("the engineer walked").isEmpty,
               "a primeira passada nao confirma nada")

        // Passada 2 concorda no prefixo e estende.
        let second = tracker.feed("the engineer walked us through")
        expect(second == ["the", "engineer", "walked"],
               "confirma o prefixo em que as duas passadas concordam (deu \(second))")
        expect(tracker.pending == ["us", "through"],
               "o resto fica pendente, na zona vermelha (deu \(tracker.pending))")

        // O reconhecedor corrige o fim: o que ainda nao foi confirmado pode
        // mudar livremente, e e exatamente por isso que ele espera.
        let third = tracker.feed("the engineer walked us through every")
        expect(third == ["us", "through"], "a correcao do fim nao reescreve o que ja saiu")

        // Mudanca de pontuacao nao pode travar a confirmacao.
        var punct = StablePrefixTracker()
        _ = punct.feed("nobody had questions")
        let afterPunct = punct.feed("nobody had questions, so she")
        // Confirma com a pontuacao da passada mais recente, que e a mais
        // informada — "questions," e nao "questions".
        expect(afterPunct == ["nobody", "had", "questions,"],
               "pontuacao diferente nao trava a confirmacao (deu \(afterPunct))")

        // Pausa real: tudo que restou vira definitivo.
        var closing = StablePrefixTracker()
        _ = closing.feed("we shipped the change")
        _ = closing.feed("we shipped the change on Friday")
        let flushed = closing.flush()
        expect(flushed == ["on", "Friday"], "a pausa confirma o que estava pendente")
        expect(closing.pending.isEmpty, "nada fica pendente depois da pausa")

        // O caso que produziu "running in been running in production": o
        // reconhecedor reescreve o passado e o indice de confirmacao desalinha.
        var revised = StablePrefixTracker()
        _ = revised.feed("we shipped it on Friday running in")
        // A segunda passada confirma o prefixo inteiro em que as duas
        // concordam — a primeira nao tinha com o que comparar.
        let before = revised.feed("we shipped it on Friday running in production")
        expect(before == ["we", "shipped", "it", "on", "Friday", "running", "in"],
               "confirma o prefixo acordado enquanto o passado bate (deu \(before.count) palavras)")
        let rewritten = revised.feed("we shipped it on Friday it has been running in production")
        expect(rewritten.isEmpty,
               "passada que reescreve o passado nao confirma nada (deu \(rewritten))")
        expect(revised.confirmed == ["we", "shipped", "it", "on", "Friday", "running", "in"],
               "o que ja saiu na tela nao e reescrito nem duplicado")

        print("")
        print("acumulador de frases")
        var phrases = PhraseAccumulator()
        let closed = phrases.append(["the", "engineer", "walked", "us", "through", "it."])
        expect(closed == ["the engineer walked us through it."],
               "fecha na pontuacao (deu \(closed))")

        var long = PhraseAccumulator()
        let many = (0..<30).map { "palavra\($0)" }
        let chunks = long.append(many)
        expect(!chunks.isEmpty, "fala corrida sem pontuacao ainda fecha por tamanho")
        expect(chunks.allSatisfy { $0.count <= 90 },
               "nenhum pedaco cresce sem limite (maior: \(chunks.map(\.count).max() ?? 0))")

        // Fechar num numero fixo de caracteres partia a oracao ao meio e o
        // tradutor recebia fragmento sem sujeito.
        var clause = PhraseAccumulator()
        let byComma = clause.append(
            "the engineer walked us through every edge case, nobody had questions, so she approved."
                .split(separator: " ").map(String.init)
        )
        expect(byComma.count >= 2, "fecha nas virgulas (deu \(byComma.count))")
        expect(byComma.allSatisfy { piece in
            piece.last.map { ".!?…,;:—".contains($0) } ?? false
        }, "todo pedaco termina em pontuacao, nunca no meio da oracao")
        for piece in byComma { print("    | \(piece)") }

        // Virgula cedo demais nao vale: "Bem, ..." nao e uma oracao util.
        var early = PhraseAccumulator()
        let short = early.append(["Well,", "the", "engineer", "said", "something", "long", "enough."])
        expect(short.count == 1, "virgula logo no comeco nao fecha um fragmento (deu \(short))")

        print("")
        print(failures == 0 ? "prefixo estavel ok" : "\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Traducao em lote

    /// Um segmento rende tres ou quatro frases. Em serie sao tres ou quatro
    /// idas e voltas; o lote faz uma so. O risco do lote e a resposta chegar
    /// fora de ordem — legenda embaralhada seria pior que legenda lenta.
    static func batchGate() async {
        print("traducao em lote\n")

        let sentences = [
            "The engineer walked us through every edge case.",
            "Nobody had questions.",
            "We shipped the change on Friday afternoon.",
            "It has been running in production ever since.",
        ]

        let translator = TranslatorFactory.make(.apple)
        print("motor: \(translator.engineName)")
        do {
            try await translator.prepare { _, _ in }
        } catch {
            print("FALHA ao preparar: \(error.localizedDescription)")
            exit(1)
        }

        // Aquece o par de idiomas para nao medir a criacao da sessao.
        _ = try? await translator.translate("warm up", from: .english, to: .portuguese)

        let serialStart = Date()
        var serial: [String] = []
        for sentence in sentences {
            serial.append((try? await translator.translate(
                sentence, from: .english, to: .portuguese)) ?? "")
        }
        let serialMs = Int(Date().timeIntervalSince(serialStart) * 1000)

        let batchStart = Date()
        let batch = (try? await translator.translate(
            sentences, from: .english, to: .portuguese)) ?? []
        let batchMs = Int(Date().timeIntervalSince(batchStart) * 1000)

        failures = 0

        expect(batch.count == sentences.count, "o lote devolve uma traducao por frase")
        expect(!batch.contains(where: \.isEmpty), "nenhuma traducao volta vazia")
        expect(batch == serial, "o lote preserva a ordem original das frases")

        for (original, translated) in zip(sentences, batch) {
            print("    \(original.prefix(46))")
            print("    -> \(translated)")
        }

        print("")
        print("  em serie: \(serialMs) ms")
        print("  em lote : \(batchMs) ms")
        if serialMs > 0 {
            print("  ganho   : \(Int((1 - Double(batchMs) / Double(serialMs)) * 100))%")
        }

        print(failures == 0 ? "\ntraducao em lote ok" : "\n\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Corte em frases

    static func sentenceGate() {
        failures = 0

        print("tokens especiais do Whisper")
        do {
            // A regressao: com os pipes sem escape, o padrao virava alternancia
            // e apagava a transcricao inteira. Whisper voltava vazio sempre.
            let cases: [(String, String)] = [
                ("<|ja|><|transcribe|><|notimestamps|>こんにちは", "こんにちは"),
                ("<|en|>Hello there", "Hello there"),
                ("Nenhum token aqui", "Nenhum token aqui"),
                ("<|startoftranscript|>", ""),
                ("Antes <|pt|> depois", "Antes  depois"),
            ]
            for (input, want) in cases {
                let got = WhisperTranscriber.stripSpecialTokens(input)
                let ok = got.trimmingCharacters(in: .whitespaces) == want.trimmingCharacters(in: .whitespaces)
                print(ok ? "  ok    \"\(input.prefix(34))\"" : "  FALHA \"\(input)\" -> \"\(got)\" (esperado \"\(want)\")")
                if !ok { failures += 1 }
            }
        }
        print("")

        print("sobreposicao entre blocos")
        do {
            // O caso real do teste ao vivo: o corte por teto repete a cauda
            // do audio, entao a palavra reaparece transcrita no bloco seguinte.
            let cases: [(String, String, String)] = [
                ("we shipped the change on Friday afternoon.",
                 "afternoon, it has been running in production ever since.",
                 "it has been running in production ever since."),
                ("nobody had questions",
                 "so she approved it herself",
                 "so she approved it herself"),
                ("the support team reported no",
                 "no complaints at all",
                 "complaints at all"),
                ("", "primeiro bloco da sessao", "primeiro bloco da sessao"),
                ("これは", "はじめまして。", "はじめまして。"),
                ("今天", "天气很好。", "天气很好。"),
                ("昨日は東京", "東京に行きました。", "に行きました。"),
            ]
            for (previous, incoming, want) in cases {
                let got = OverlapTrimmer.dropRepeatedPrefix(incoming, after: previous)
                let ok = got == want
                print(ok ? "  ok    \"\(incoming.prefix(38))\"" 
                         : "  FALHA \"\(incoming)\" -> \"\(got)\" (esperado \"\(want)\")")
                if !ok { failures += 1 }
            }

            // Nao pode comer texto legitimo que so por acaso repete palavra.
            let unrelated = OverlapTrimmer.dropRepeatedPrefix(
                "the meeting starts at noon", after: "we discussed the budget")
            print(unrelated == "the meeting starts at noon"
                  ? "  ok    texto sem sobreposicao real fica intacto"
                  : "  FALHA cortou texto legitimo -> \"\(unrelated)\"")
            if unrelated != "the meeting starts at noon" { failures += 1 }
        }
        print("")

        print("largura da linha pelo idioma de destino\n")
        do {
            // Medido gerando ingles -> japones num video de 161 s: com os 42
            // latinos, 18 das 49 linhas passavam de 20 caracteres e a mais
            // longa tinha 42 — o dobro do que a legenda em japones admite.
            expect(SubtitleFileBuilder.lineWidth(for: .japanese) == 20,
                   "japones usa 20 por linha")
            expect(SubtitleFileBuilder.lineWidth(for: .chinese) == 20,
                   "chines usa 20 por linha")
            for idioma: Language in [.portuguese, .english, .korean, .russian] {
                expect(SubtitleFileBuilder.lineWidth(for: idioma) == 42,
                       "\(idioma.rawValue) continua em 42")
            }
        }
        print("")

        print("pontuacao japonesa fecha legenda\n")
        do {
            // A regressao, medida no video de 9 minutos em japones com o
            // reconhecimento da Apple: `endsSentence` so conhecia ".!?…", e
            // `。` passava direto. Dos 99 fins de frase, 55 ficavam no MEIO de
            // uma legenda — que so fechava no teto de 7 s, emendando duas
            // falas de duas pessoas. Depois do conserto, 8. No ingles, nada
            // mudou (5 antes, 5 depois).
            let builder = SubtitleFileBuilder()
            let japones = builder.makeCues(from: [
                TimedText(text: "おはようございます。", start: 0, end: 1.5),
                TimedText(text: "おはようございます。", start: 1.5, end: 3.0),
                TimedText(text: "新人さんですか？", start: 3.0, end: 4.5),
            ])
            expect(japones.count == 3,
                   "tres falas japonesas viram tres legendas (deu \(japones.count))")

            // O outro lado: sem pontuacao nenhuma elas continuam juntas, que e
            // o comportamento de sempre — o conserto e a pontuacao, nao um
            // corte novo.
            let semPonto = builder.makeCues(from: [
                TimedText(text: "おはようございます", start: 0, end: 1.5),
                TimedText(text: "おはようございます", start: 1.5, end: 3.0),
            ])
            expect(semPonto.count == 1,
                   "sem pontuacao segue junto (deu \(semPonto.count))")

            // Juntar duas legendas curtas nao pode inventar espaco em japones.
            // `mergeTinyCues` colava com `" " + cue.source`, e era o ultimo
            // lugar que devolvia "よかったです。 頑張ろうね。" — os outros dois
            // eram o agrupador e o texto do proprio run.
            let curtas = builder.makeCues(from: [
                TimedText(text: "よかったです。", start: 0, end: 0.6),
                TimedText(text: "頑張ろうね。", start: 1.9, end: 2.6),
            ])
            expect(curtas.count == 1 && curtas[0].source == "よかったです。頑張ろうね。",
                   "juntar legendas curtas em japones nao insere espaco (deu \(curtas.map(\.source)))")
            // A legenda curta e a SEGUNDA: `mergeTinyCues` junta com a
            // anterior, nao com a seguinte.
            let curtasLatinas = builder.makeCues(from: [
                TimedText(text: "Let us go.", start: 0, end: 0.6),
                TimedText(text: "Right.", start: 1.9, end: 2.6),
            ])
            expect(curtasLatinas.count == 1 && curtasLatinas[0].source == "Let us go. Right.",
                   "em ingles o espaco continua (deu \(curtasLatinas.map(\.source)))")

            // E a virgula japonesa fecha oracao no tempo real, como a latina.
            var acumulador = PhraseAccumulator()
            let fechadas = acumulador.append(["今日はとてもいい天気ですね、明日も晴れるといいですね。"])
            expect(fechadas.count == 1,
                   "`。` fecha a frase no tempo real (deu \(fechadas.count))")
        }
        print("")

        print("corte em frases\n")

        let long = "We shipped the change on Friday afternoon. It has been running in production ever since. Nobody noticed a thing."
        let parts = SentenceSplitter.split(long)
        expect(parts.count == 3, "tres frases viram tres blocos (deu \(parts.count))")
        expect(parts.allSatisfy { $0.count < 70 }, "nenhum bloco fica longo demais")

        // O caso que apareceu no teste ao vivo: pontuacao solta virando bloco.
        expect(SentenceSplitter.split(".").isEmpty, "\".\" sozinho nao vira bloco")
        expect(SentenceSplitter.split("  ...  ").isEmpty, "reticencias soltas nao viram bloco")
        expect(SentenceSplitter.split("").isEmpty, "vazio nao vira bloco")

        // E o prefixo de pontuacao que sobrou colado na frase.
        let dirty = SentenceSplitter.split(". We shipped the change on Friday.")
        expect(dirty.first?.hasPrefix("We") == true,
               "pontuacao no inicio e removida (deu \"\(dirty.first ?? "")\")")

        // Fragmento curto nao pode virar bloco solto.
        let fragment = SentenceSplitter.split("This is a complete sentence. Yes.")
        expect(fragment.count == 1, "fragmento curto gruda na frase anterior (deu \(fragment.count))")

        // O caso real: o reconhecedor pontua fala corrida com virgula, nunca
        // com ponto. Sem o corte secundario isso chega como um bloco so.
        let commas = "rewriting the retry logic, the engineer walked us through every edge case, nobody had questions, so she approved it herself."
        let cut = SentenceSplitter.split(commas)
        expect(cut.count >= 2, "fala pontuada so com virgula e cortada (deu \(cut.count))")
        expect(cut.allSatisfy { $0.count <= 92 },
               "nenhum pedaco passa de 90 caracteres (maior: \(cut.map(\.count).max() ?? 0))")
        for piece in cut { print("    | \(piece)  (\(piece.count))") }

        // O parcial da zona vermelha comeca no meio da palavra anterior.
        expect(SentenceSplitter.tidy(".tor team reported no complaints.") == "tor team reported no complaints.",
               "parcial perde a pontuacao solta do inicio")

        expect(!SentenceSplitter.hasContent("..."), "so pontuacao nao tem conteudo")
        expect(SentenceSplitter.hasContent("oi"), "letra tem conteudo")

        print("")
        print("lote de traducao")
        let builder = SubtitleFileBuilder()
        // A sobreposicao de contexto saiu, e saiu medida: `tradutor-verify
        // sobreposicao` planta o caso na borda do lote e as duas traducoes
        // saem identicas, erradas no genero nas duas. Custava 15% do tempo.
        // Quem quiser trazer de volta precisa refazer essa medicao.
        expect(builder.contextOverlap == 0, "nao se reenvia legenda como contexto")
        expect(builder.maximumCharacters > 100,
               "o corte antes de traduzir segue a frase, nao o tamanho da legenda (\(builder.maximumCharacters))")

        for part in parts { print("    | \(part)") }
        print("")
        print(failures == 0 ? "corte em frases ok" : "\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Alinhamento das legendas com a fala

    /// Mede onde as legendas entram e saem contra onde há voz no áudio.
    ///
    /// A régua é a energia do som (`SpeechEnergy.regions`), não outro
    /// reconhecedor. Para cada trecho de fala compara o começo e o fim do que
    /// o reconhecedor marcou e das legendas prontas (`makeCues`, já com a
    /// entrada antecipada). Negativo: cedo demais.
    static func alignmentGate(path: String, engine: RecognitionEngine, language: Language, referencePath: String? = nil) async {
        do {
            let audio = try await MeasurementAudio.load(URL(fileURLWithPath: path), language: language,
                                                       reference: referencePath.map { URL(fileURLWithPath: $0) })
            let samples = audio.samples
            let duration = Double(samples.count) / 16_000
            let transcriber = TranscriberFactory.make(for: language, engine: engine)
            try await transcriber.prepare { _, _ in }
            // Sonda: `TRADUTOR_PAUSA_MINIMA=0.8` liga o corte por silêncio.
            if let valor = ProcessInfo.processInfo.environment["TRADUTOR_PAUSA_MINIMA"],
               let minima = Double(valor) {
                transcriber.pauseBoundaries = SpeechEnergy.pauseBoundaries(
                    samples, minimumPause: minima)
            }
            let pieces = try await transcriber.transcribeForSubtitles(samples) { _ in }
            let construtor = SubtitleFileBuilder()
            if let valor = ProcessInfo.processInfo.environment["TRADUTOR_PAUSA_MINIMA"],
               let minima = Double(valor) {
                construtor.silences = SpeechEnergy.silences(samples, minimumPause: minima)
            }
            let cues = construtor.makeCues(from: pieces, mediaDuration: duration)
            if ProcessInfo.processInfo.environment["TRADUTOR_MOSTRA_CUES"] != nil {
                for cue in cues { print(String(format: "[cue] %7.2f–%7.2f  %@",
                                               cue.start, cue.end, cue.source)) }
            }
            let regions = audio.regions

            print(audio.description)
            print("motor: \(transcriber.engineName)  ·  \(regions.count) trechos de fala  ·  \(pieces.count) trechos reconhecidos\n")
            print("fala (s)          reconhecido Δini  Δfim    legenda Δini  Δfim")

            var recognized: [(Double, Double)] = []
            var subtitles: [(Double, Double)] = []
            for region in regions {
                // O que tem o meio dentro do trecho de fala pertence a ele.
                func span(_ items: [(start: Double, end: Double)]) -> (Double, Double)? {
                    let inside = items.filter { region.contains(($0.start + $0.end) / 2) }
                    guard let first = inside.first, let last = inside.last else { return nil }
                    return (first.start - region.lowerBound, last.end - region.upperBound)
                }
                let r = span(pieces.map { (start: $0.start, end: $0.end) })
                let c = span(cues.map { (start: $0.start, end: $0.end) })
                if let r { recognized.append(r) }
                if let c { subtitles.append(c) }
                func show(_ pair: (Double, Double)?) -> String {
                    guard let pair else { return "      —      —" }
                    return String(format: "%+6.2f %+6.2f", pair.0, pair.1)
                }
                print(String(format: "%6.2f–%6.2f   ", region.lowerBound, region.upperBound)
                      + "      " + show(r) + "       " + show(c))
            }

            // Nenhum trecho pode passar do teto duro do agrupador: acima
            // dele a legenda sai mais longa que `maximumDuration` e nada
            // adiante reparte legenda por duração. Conferir o teto só depois
            // de acrescentar o run deixava o trecho estourar pelo tamanho do
            // run — 5 trechos e 7,98 s no vídeo de 9 minutos.
            if engine == .apple, #available(macOS 26.0, *) {
                let teto = AppleSpeechTranscriber.hardCeiling
                let acima = pieces.filter { $0.end - $0.start > teto + 0.001 }
                print(acima.isEmpty
                      ? String(format: "\nok    nenhum trecho passa do teto de %.0f s", teto)
                      : String(format: "\nFALHA %d trechos passam do teto de %.0f s (maior: %.2f s)",
                               acima.count, teto, acima.map { $0.end - $0.start }.max() ?? 0))
                for piece in acima.prefix(5) {
                    print(String(format: "      %6.2f–%6.2f  %@", piece.start, piece.end, piece.text))
                }
            }

            // Quanto tempo há voz na tela sem legenda nenhuma.
            //
            // É a medida que corresponde à queixa "a legenda some e a pessoa
            // ainda está falando". A comparação por região de fala engana:
            // uma região junta falas separadas por menos de 0,5 s, então uma
            // região de 8 s pode ter três legendas e mesmo assim acusar
            // "legenda acaba 5 s antes".
            var descoberto: [(Double, Double)] = []
            for region in regions {
                var cursor = region.lowerBound
                for cue in cues.sorted(by: { $0.start < $1.start })
                where cue.end > cursor && cue.start < region.upperBound {
                    if cue.start > cursor { descoberto.append((cursor, min(cue.start, region.upperBound))) }
                    cursor = max(cursor, cue.end)
                    if cursor >= region.upperBound { break }
                }
                if cursor < region.upperBound { descoberto.append((cursor, region.upperBound)) }
            }
            let vozTotal = regions.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
            let semLegenda = descoberto.reduce(0.0) { $0 + ($1.1 - $1.0) }
            print(String(format: "\nfala sem legenda na tela: %.1f s de %.1f s (%.0f%%)",
                         semLegenda, vozTotal, vozTotal > 0 ? semLegenda / vozTotal * 100 : 0))
            for buraco in descoberto.filter({ $0.1 - $0.0 >= 1.0 })
                .sorted(by: { ($0.1 - $0.0) > ($1.1 - $1.0) }).prefix(8) {
                print(String(format: "   %6.2f–%6.2f  %.1f s de voz sem legenda",
                             buraco.0, buraco.1, buraco.1 - buraco.0))
            }

            print("\ntrechos reconhecidos:")
            // Todos, nao os 40 primeiros: e daqui que sai a medicao de corte
            // no meio da palavra, e ela precisa do arquivo inteiro.
            for piece in pieces {
                print(String(format: "  %6.2f–%6.2f  ", piece.start, piece.end) + piece.text)
            }

            func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
            print("")
            print(String(format: "média reconhecido: início %+.2f s, fim %+.2f s",
                         mean(recognized.map(\.0)), mean(recognized.map(\.1))))
            print(String(format: "média legenda:     início %+.2f s, fim %+.2f s",
                         mean(subtitles.map(\.0)), mean(subtitles.map(\.1))))
            exit(0)
        } catch {
            print("FALHA: \(error.localizedDescription)")
            exit(1)
        }
    }

    // MARK: Fronteira de locutor dentro da legenda

    /// Quantas legendas contêm fala de mais de uma pessoa.
    ///
    /// Hoje `makeCues` quebra na troca de locutor, então duas vozes só caem
    /// na mesma legenda quando a fronteira está **dentro de um trecho do
    /// reconhecedor** — e trecho é indivisível: `assign` dá a ele o locutor
    /// que mais o cobre, e a palavra da outra pessoa vai junto.
    ///
    /// Este gate mede o tamanho do problema antes de alguém programar o
    /// corte por palavra: conta as fronteiras no trecho e na legenda, e
    /// quanto tempo a voz minoritária ocupa.
    static func speakerBoundaryGate(
        path: String, language: Language, engine: RecognitionEngine
    ) async {
        guard let samples = try? await SubtitleFileBuilder.extractAudio(
            from: URL(fileURLWithPath: path)
        ) else {
            print("nao consegui ler \(path)")
            exit(1)
        }
        let duration = Double(samples.count) / 16_000
        let transcriber = TranscriberFactory.make(for: language, engine: engine)
        do { try await transcriber.prepare { _, _ in } } catch {
            print("FALHA ao carregar: \(error.localizedDescription)")
            exit(1)
        }
        let builder = SubtitleFileBuilder()
        for modelo in SpeakerDiarizer.Model.allCases {
            guard let turns = try? await SpeakerDiarizer.turns(in: samples, model: modelo) else {
                print("FALHA nos locutores (\(modelo.displayName))"); continue
            }
            // Duas passadas: sem as fronteiras e com elas. A diferença é o
            // que o conserto compra.
            var medidas: [(String, [TimedText])] = []
            for comFronteiras in [false, true] {
                transcriber.speakerBoundaries = comFronteiras
                    ? SpeakerDiarizer.boundaries(of: turns)
                    : []
                guard let timed = try? await transcriber.transcribeForSubtitles(samples) else {
                    print("FALHA no reconhecimento"); exit(1)
                }
                medidas.append((comFronteiras ? "com fronteiras" : "sem fronteiras", timed))
            }
            transcriber.speakerBoundaries = []

            print("")
            print("\(modelo.displayName): \(Set(turns.map(\.speaker)).count) vozes, \(turns.count) faixas")

            for (rotulo, timed) in medidas {
            let pieces = SpeakerDiarizer.renumber(SpeakerDiarizer.assign(timed, to: turns))
            let cues = builder.makeCues(from: pieces, mediaDuration: duration)

            /// Quanto cada voz fala dentro de um intervalo.
            func share(_ start: Double, _ end: Double) -> [String: Double] {
                var total: [String: Double] = [:]
                for turn in turns {
                    let overlap = min(end, turn.end) - max(start, turn.start)
                    if overlap > 0 { total[turn.speaker, default: 0] += overlap }
                }
                return total
            }

            /// Uma fronteira conta quando a segunda voz tem tempo que se veja.
            func divided(_ start: Double, _ end: Double, floor: Double) -> Double? {
                let partes = share(start, end).values.sorted(by: >)
                guard partes.count >= 2, partes[1] >= floor else { return nil }
                return partes[1]
            }

            // Varre o piso: uma palavra dura 0,2 a 0,4 s, e um piso de 0,3 s
            // esconde justamente o caso de "a ultima palavra e de outra
            // pessoa".
            var porPiso: [(Double, Int, Double)] = []
            for piso in [0.10, 0.15, 0.20, 0.30, 0.50] {
                var quantos = 0
                var tempo = 0.0
                for piece in timed {
                    if let minoria = divided(piece.start, piece.end, floor: piso) {
                        quantos += 1
                        tempo += minoria
                    }
                }
                porPiso.append((piso, quantos, tempo))
            }
            let trechosDivididos = porPiso.first { $0.0 == 0.3 }?.1 ?? 0
            let tempoMinoritario = porPiso.first { $0.0 == 0.3 }?.2 ?? 0

            var legendasDivididas = 0
            var cortaveis = 0
            for cue in cues {
                guard let minoria = divided(cue.start, cue.end, floor: 0.3) else { continue }
                legendasDivididas += 1
                // Só vale cortar se os dois lados aguentam virar legenda: o
                // piso de tela é 1 s, e abaixo disso `mergeTinyCues` cola de
                // volta e o corte não serve para nada.
                let total = cue.end - cue.start
                if minoria >= builder.minimumDuration, total - minoria >= builder.minimumDuration {
                    cortaveis += 1
                }
            }

            print("  \(rotulo):")
            print("    trechos com duas vozes  : \(trechosDivididos) de \(timed.count)"
                  + String(format: " (%.0f%%)", 100 * Double(trechosDivididos) / Double(max(timed.count, 1))))
            print("    legendas                : \(legendasDivididas) de \(cues.count)"
                  + String(format: " (%.0f%%)", 100 * Double(legendasDivididas) / Double(max(cues.count, 1))))
            print(String(format: "    tempo da voz minoritaria: %.1fs", tempoMinoritario))
            print("    legendas com locutor    : \(cues.filter { $0.speaker != nil }.count) de \(cues.count)")
            _ = cortaveis
            _ = porPiso
            }
        }
        exit(0)
    }

    // MARK: Sobreposicao de contexto — vale o que custa?

    /// Mede se reenviar legendas do lote anterior melhora a traducao.
    ///
    /// A sobreposicao so pode agir na **borda do lote**: com 40 por
    /// requisicao, a legenda 41 e a primeira sem nada atras dela. Este gate
    /// planta o caso classico exatamente ali — uma pessoa apresentada com
    /// genero antes da borda e referida depois dela — e compara a traducao
    /// com sobreposicao 10 e com 0.
    ///
    /// O custo medido esta no CLAUDE.md: 17% do tempo total.
    static func overlapGate() async {
        print("sobreposicao de contexto\n")

        // Recheio até a borda do lote. Frases neutras, sem genero, para nao
        // dar pista de graca.
        var falas = (1...36).map { "Item number \($0) was reviewed and closed without changes." }
        // Antes da borda: quem e a pessoa, com genero explicito.
        falas += [
            "Marina joined the payments team four years ago.",
            "She is the lead engineer for the retry logic.",
            "Her last change removed three thousand lines of code.",
            "Everyone on the team trusts her judgement.",
        ]
        // Depois da borda (legenda 41 em diante): referencias que dependem do
        // que veio antes. "The engineer" e "the lead" nao tem genero em ingles.
        let dependentes = [
            "The engineer walked us through every edge case.",
            "Nobody had questions, so the lead approved it alone.",
            "The engineer said the rollout would take two days.",
            "We asked the lead to write the postmortem.",
            "The engineer is on vacation until the end of the month.",
        ]
        falas += dependentes
        let bordas = (falas.count - dependentes.count)..<falas.count

        let translator = TranslatorFactory.make(.apple)
        do { try await translator.prepare { _, _ in } } catch {
            print("FALHA: \(error.localizedDescription)"); exit(1)
        }
        _ = try? await translator.translate("warm up", from: .english, to: .portuguese)

        let cues = falas.enumerated().map {
            Cue(index: $0.offset + 1, start: Double($0.offset), end: Double($0.offset) + 1,
                source: $0.element)
        }

        var resultados: [Int: [String]] = [:]
        for sobreposicao in [10, 0] {
            let builder = SubtitleFileBuilder()
            builder.contextOverlap = sobreposicao
            let inicio = Date()
            let saida = await builder.translate(
                cues, using: translator, from: .english, to: .portuguese
            )
            let ms = Int(Date().timeIntervalSince(inicio) * 1000)
            resultados[sobreposicao] = saida.map(\.translated)
            print("  sobreposicao \(sobreposicao): \(ms) ms")
        }

        guard let com = resultados[10], let sem = resultados[0] else { exit(1) }
        print("")
        print("as \(bordas.count) falas depois da borda do lote:")
        var diferentes = 0
        for index in bordas where index < com.count && index < sem.count {
            let a = com[index], b = sem[index]
            let marca = a == b ? " " : "×"
            if a != b { diferentes += 1 }
            print("  \(marca) \(falas[index])")
            print("      com 10: \(a)")
            print("      com  0: \(b)")
        }
        let mudaram = zip(com, sem).filter { $0 != $1 }.count
        print("")
        print("mudaram: \(diferentes) das \(bordas.count) na borda, \(mudaram) de \(com.count) no total")
        // Genero certo e "a engenheira"/"a lider"; errado e o masculino.
        func feminino(_ textos: [String]) -> Int {
            bordas.filter { index in
                let t = textos[index].lowercased()
                return t.contains("a engenheira") || t.contains("a líder") || t.contains("a lider")
            }.count
        }
        print("genero feminino acertado na borda: com 10 = \(feminino(com)), com 0 = \(feminino(sem))")
        exit(0)
    }

    // MARK: Prefixo de locutor na traducao — A/B

    /// Traduz as mesmas falas duas vezes: como estao, e prefixadas com
    /// "Locutor N:".
    ///
    /// A pergunta e se dizer ao tradutor quem fala melhora genero e
    /// referente — o erro que sobra no par japones -> portugues. O tradutor
    /// da Apple nao tem API de metadados, entao o unico canal e o texto.
    ///
    /// Os dois lados usam o MESMO lote (40 com 10 de sobreposicao), pelo
    /// mesmo `SubtitleFileBuilder.translate`, para a unica diferenca ser o
    /// prefixo.
    static func prefixABGate(
        path: String, language: Language, target: Language, engine: RecognitionEngine
    ) async {
        guard let samples = try? await SubtitleFileBuilder.extractAudio(
            from: URL(fileURLWithPath: path)
        ) else {
            print("nao consegui ler \(path)")
            exit(1)
        }
        let duration = Double(samples.count) / 16_000
        let transcriber = TranscriberFactory.make(for: language, engine: engine)
        do { try await transcriber.prepare { _, _ in } } catch {
            print("FALHA ao carregar: \(error.localizedDescription)")
            exit(1)
        }
        guard let timed = try? await transcriber.transcribeForSubtitles(samples) else {
            print("FALHA no reconhecimento"); exit(1)
        }
        guard let turns = try? await SpeakerDiarizer.turns(in: samples) else {
            print("FALHA nos locutores"); exit(1)
        }
        let pieces = SpeakerDiarizer.renumber(SpeakerDiarizer.assign(timed, to: turns))
        let builder = SubtitleFileBuilder()
        let cues = builder.makeCues(from: pieces, mediaDuration: duration)
        let comLocutor = cues.filter { $0.speaker != nil }
        print("motor: \(transcriber.engineName)  ·  \(cues.count) legendas, "
            + "\(comLocutor.count) com locutor  ·  "
            + "\(Set(cues.compactMap(\.speaker)).count) vozes\n")

        let translator = TranslatorFactory.make(.apple)
        try? await translator.prepare { _, _ in }

        /// Lado A: o texto como esta hoje.
        let semPrefixo = await builder.translate(cues, using: translator, from: language, to: target)
        /// Lado B: o mesmo, com "Locutor N: " colado no original.
        func prefixando(_ rotulo: @escaping (Cue) -> String?) -> [Cue] {
            cues.map { cue in
                guard let prefixo = rotulo(cue) else { return cue }
                var copia = cue
                copia.source = prefixo + cue.source
                return copia
            }
        }
        let comPrefixo = await builder.translate(
            prefixando { $0.speaker.map { "\($0): " } },
            using: translator, from: language, to: target
        )
        /// Lado C: prefixo neutro. Controle para saber se o ganho vem de
        /// saber QUEM fala ou so de a linha parecer comeco de fala.
        let comTravessao = await builder.translate(
            prefixando { $0.speaker == nil ? nil : "— " },
            using: translator, from: language, to: target
        )

        /// O rotulo traduzido volta para fora do texto, para comparar so a fala.
        func limpa(_ text: String) -> String {
            guard let colon = text.firstIndex(of: ":") else { return text }
            let head = text[text.startIndex..<colon]
            // Só corta se o que vem antes dos dois-pontos parecer o rótulo.
            guard head.count <= 24, head.rangeOfCharacter(from: .decimalDigits) != nil else {
                return text
            }
            return String(text[text.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }

        func semTravessao(_ text: String) -> String {
            text.hasPrefix("— ") ? String(text.dropFirst(2)) : text
        }

        var linhas: [(cue: Cue, a: String, b: String, c: String)] = []
        var perderamRotulo = 0
        for (index, cue) in cues.enumerated() {
            let bruto = comPrefixo[index].translated.trimmingCharacters(in: .whitespaces)
            let b = limpa(bruto)
            if cue.speaker != nil, bruto == b { perderamRotulo += 1 }
            linhas.append((
                cue,
                semPrefixo[index].translated.trimmingCharacters(in: .whitespaces),
                b,
                semTravessao(comTravessao[index].translated.trimmingCharacters(in: .whitespaces))
            ))
        }

        for linha in linhas where linha.a != linha.b || linha.a != linha.c {
            print("[\(linha.cue.speaker ?? "sem locutor")]  \(linha.cue.source)")
            print("   A sem prefixo  \(linha.a)")
            print("   B Locutor N:   \(linha.b)")
            print("   C travessao    \(linha.c)")
        }

        /// Proxies objetivos: o que muda sem depender de julgamento.
        func maiuscula(_ textos: [String]) -> Int {
            textos.filter { $0.first?.isUppercase == true }.count
        }
        func pontuado(_ textos: [String]) -> Int {
            textos.filter { ".!?…".contains($0.last ?? " ") }.count
        }
        let marcadas = linhas.filter { $0.cue.speaker != nil }
        let a = marcadas.map(\.a), b = marcadas.map(\.b), c = marcadas.map(\.c)
        print("")
        print("sobre as \(marcadas.count) legendas com locutor:")
        print("                    comeca com maiuscula   termina pontuada   difere de A")
        print(String(format: "  A sem prefixo          %3d              %3d               —",
                     maiuscula(a), pontuado(a)))
        print(String(format: "  B Locutor N:           %3d              %3d             %3d",
                     maiuscula(b), pontuado(b), zip(a, b).filter { $0 != $1 }.count))
        print(String(format: "  C travessao            %3d              %3d             %3d",
                     maiuscula(c), pontuado(c), zip(a, c).filter { $0 != $1 }.count))
        print(String(format: "\nB e C diferem entre si em %d das %d",
                     zip(b, c).filter { $0 != $1 }.count, marcadas.count))
        print("\(perderamRotulo) das \(comLocutor.count) prefixadas voltaram sem o rotulo no texto")
        exit(0)
    }

    // MARK: Repescagem das falas perdidas

    /// Mede se re-reconhecer, isolado, um trecho que a primeira passada
    /// perdeu recupera texto.
    ///
    /// A perda medida e sempre de fala curta: abaixo de 0,6 s, os motores
    /// reconhecem entre 5% e 32% dos trechos. A pergunta que este gate
    /// responde e se a culpa e do trecho ser curto ou de estar no meio de
    /// uma passada longa.
    static func secondPassGate(
        path: String, engine: RecognitionEngine, language: Language,
        fallback: RecognitionEngine? = nil
    ) async {
        guard let samples = try? await SubtitleFileBuilder.extractAudio(
            from: URL(fileURLWithPath: path)
        ) else {
            print("nao consegui ler \(path)")
            exit(1)
        }
        let rate = 16_000.0
        let transcriber = TranscriberFactory.make(for: language, engine: engine)
        do {
            try await transcriber.prepare { _, _ in }
        } catch {
            print("FALHA ao carregar: \(error.localizedDescription)")
            exit(1)
        }
        guard let pieces = try? await transcriber.transcribeForSubtitles(samples) else {
            print("FALHA na primeira passada")
            exit(1)
        }
        let regions = SpeechEnergy.regions(samples, minimumPause: 0.5)
        let missed = regions.filter { region in
            !pieces.contains { $0.start < region.upperBound && $0.end > region.lowerBound }
        }
        print("motor: \(transcriber.engineName)  ·  \(regions.count) trechos de fala  ·  "
              + "\(pieces.count) pecas na 1a passada  ·  \(missed.count) trechos sem texto\n")

        // Opcional: a segunda passada com OUTRO motor. O que um perde o
        // outro as vezes pega — e isso e diferente de "o trecho e curto
        // demais para qualquer modelo".
        var second: Transcriber?
        if let fallback {
            let other = TranscriberFactory.make(for: language, engine: fallback)
            do {
                try await other.prepare { _, _ in }
                second = other
                print("segunda passada com \(other.engineName)\n")
            } catch {
                print("FALHA ao carregar o segundo motor: \(error.localizedDescription)")
                exit(1)
            }
        }

        var recuperados = 0
        var segundos = 0.0
        let started = Date()
        for region in missed {
            // Contexto dos dois lados: o modelo precisa de mais que a palavra
            // solta, e o FluidAudio recusa audio abaixo de 0,3 s.
            let padding = 0.25
            var from = max(0, region.lowerBound - padding)
            var to = min(Double(samples.count) / rate, region.upperBound + padding)
            if to - from < 1.0 {
                let falta = (1.0 - (to - from)) / 2
                from = max(0, from - falta)
                to = min(Double(samples.count) / rate, to + falta)
            }
            let slice = Array(samples[Int(from * rate)..<Int(to * rate)])
            let text = ((try? await (second ?? transcriber).transcribe(slice)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let duration = region.upperBound - region.lowerBound
            if !text.isEmpty, !Hallucinations.isIsolatedFiller(text) {
                recuperados += 1
                segundos += duration
                print(String(format: "  %6.2f–%6.2f (%.2fs)  %@",
                             region.lowerBound, region.upperBound, duration, text))
            } else {
                print(String(format: "  %6.2f–%6.2f (%.2fs)  —",
                             region.lowerBound, region.upperBound, duration))
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        print("")
        print("recuperados: \(recuperados) de \(missed.count) trechos, "
              + String(format: "%.1fs de fala, em %.1fs de processamento", segundos, elapsed))
        exit(0)
    }

    // MARK: Segmentacao do tempo real, sem modelo

    /// Mede o que o `Segmenter` do caminho ao vivo entrega, contra onde ha voz.
    ///
    /// No arquivo o reconhecedor ve o audio inteiro; ao vivo ele so ve o que o
    /// VAD abrir e fechar. Fala curta e o caso de risco: `minimumDuration`
    /// descarta o trecho inteiro, e `framesToOpen` exige quadros seguidos
    /// acima do limiar para sequer abrir.
    /// O caminho ao vivo, segmento a segmento, com e sem o nivelador.
    ///
    /// O gate irmão (`vivo` sem motor) só olha o recorte do VAD. Este
    /// reconhece o que sai de cada segmento, que é o que chega às zonas — e
    /// é a única forma de saber se levantar a fala baixa ao vivo compra
    /// alguma coisa.
    static func liveRecognitionGate(path: String, engine: RecognitionEngine, language: Language) async {
        guard let samples = load16kMono(path: path) else {
            print("nao consegui ler \(path)"); exit(1)
        }
        let transcriber = TranscriberFactory.make(for: language, engine: engine)
        do { try await transcriber.prepare { _, _ in } } catch {
            print("FALHA ao carregar: \(error.localizedDescription)"); exit(1)
        }
        print("caminho ao vivo · \(transcriber.engineName) · \(language.rawValue)\n")

        for modo in ["desligado", "nivelado"] {
            let segmenter = Segmenter()
            var texto = ""
            var contagem = 0
            var index = 0
            let block = 800  // 50 ms, o mesmo passo do laço do pipeline
            var fechados: [[Float]] = []
            while index < samples.count {
                let end = min(index + block, samples.count)
                fechados.append(contentsOf: segmenter.feed(Array(samples[index..<end])).map(\.samples))
                index = end
            }
            if let last = segmenter.flush() { fechados.append(last.samples) }

            for bruto in fechados {
                // O nivelamento dos modos de vídeo, aplicado ao segmento que
                // o VAD fechou — que é o que o tempo real manda ao motor.
                let enviado = modo == "nivelado"
                    ? SubtitleFileBuilder.levelQuietSpeech(bruto) : bruto
                if let hipotese = try? await transcriber.transcribe(enviado) {
                    texto += hipotese
                    contagem += 1
                }
            }
            let caracteres = texto.filter { !$0.isWhitespace }.count
            print(String(format: "  %-10@ · %d segmentos · %d caracteres",
                         modo as NSString, contagem, caracteres))
        }
        print("")
    }

    static func liveSegmentationGate(path: String) {
        guard let samples = load16kMono(path: path) else {
            print("nao consegui ler \(path)")
            exit(1)
        }
        let duration = Double(samples.count) / 16_000
        let regions = SpeechEnergy.regions(samples, minimumPause: 0.5)
        let voiced = regions.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        print(String(format: "audio: %.0fs · %d trechos de fala · %.0fs de voz\n",
                     duration, regions.count, voiced))

        /// Roda o segmentador e devolve onde cada trecho comecou e terminou.
        func run(_ configuration: Segmenter.Configuration) -> [ClosedRange<Double>] {
            let segmenter = Segmenter(configuration: configuration)
            var spans: [ClosedRange<Double>] = []
            var fed = 0
            let block = 800  // 50 ms, o mesmo passo do laco do pipeline
            var index = 0
            while index < samples.count {
                let end = min(index + block, samples.count)
                let closed = segmenter.feed(Array(samples[index..<end]))
                fed = end
                for segment in closed {
                    let start = Double(fed - segment.samples.count) / 16_000
                    spans.append(start...(Double(fed) / 16_000))
                }
                index = end
            }
            if let last = segmenter.flush() {
                let start = Double(fed - last.samples.count) / 16_000
                spans.append(start...(Double(fed) / 16_000))
            }
            return spans
        }

        func report(_ label: String, _ configuration: Segmenter.Configuration) -> Int {
            let spans = run(configuration)
            let captured = spans.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
            // Um trecho de fala esta coberto quando algum segmento o alcanca.
            var covered = 0
            var missedShort = 0
            var shortTotal = 0
            for region in regions {
                let hit = spans.contains { $0.overlaps(region) }
                if hit { covered += 1 }
                if region.upperBound - region.lowerBound < 0.6 {
                    shortTotal += 1
                    if !hit { missedShort += 1 }
                }
            }
            print(String(
                format: "%-34@ %2d segmentos · %5.1fs capturados · %2d/%2d trechos · curtos perdidos %d/%d",
                label as NSString, spans.count, captured, covered, regions.count,
                missedShort, shortTotal
            ))
            return covered
        }

        var padrao = Segmenter.Configuration()
        _ = report("como esta hoje (0,4s · 3 quadros)", padrao)

        var curto = Segmenter.Configuration()
        curto.minimumDuration = 0.15
        _ = report("minimumDuration 0,15s", curto)

        var abre = Segmenter.Configuration()
        abre.framesToOpen = 2
        _ = report("framesToOpen 2", abre)

        var ambos = Segmenter.Configuration()
        ambos.minimumDuration = 0.15
        ambos.framesToOpen = 2
        _ = report("os dois juntos", ambos)

        padrao.minimumDuration = 0.15
        padrao.framesToOpen = 1
        _ = report("limite: 0,15s · 1 quadro", padrao)
        exit(0)
    }

    // MARK: Quem fala, sem modelo

    /// A atribuicao de locutor e o efeito dela na legenda.
    ///
    /// O modelo que descobre as vozes e outro (`SpeakerDiarizer.turns`, do
    /// FluidAudio) e precisa de audio; o que este gate cobre e o que fazemos
    /// com o resultado dele — atribuir, renumerar, quebrar a legenda na troca
    /// e marcar o travessao.
    /// Caça a legenda de tres linhas que escapa para o arquivo.
    ///
    /// Roda o mesmo `generate` do item de menu e confere a saida. Existe
    /// porque `enforceLineLimit` reparte esse texto corretamente quando
    /// chamado isolado, e mesmo assim o `.srt` do app saiu com tres linhas.
    static func threeLineHunt(path: String) async {
        let builder = SubtitleFileBuilder()
        print("gerando com a Apple: \(URL(fileURLWithPath: path).lastPathComponent)")
        do {
            let cues = try await builder.generate(
                from: URL(fileURLWithPath: path),
                source: .japanese, target: .portuguese,
                engine: .apple, translation: .apple, diarize: false,
                progress: { _, _, _, _ in }
            )
            print("\(cues.count) legendas")
            var achadas = 0
            for cue in cues {
                let texto = cue.translated.isEmpty ? cue.source : cue.translated
                let linhas = LineBreaker.wrap(texto, maximum: builder.charactersPerLine)
                guard linhas.count > builder.maximumLines else { continue }
                achadas += 1
                print("  \(linhas.count) linhas, \(texto.count) caracteres, "
                      + "\(SRTWriter.timecode(cue.start))")
                print("    \(texto)")
                // O mesmo texto, sozinho, passa por onde deveria ter passado.
                let repartida = builder.enforceLineLimit([cue])
                print("    enforceLineLimit isolado devolve \(repartida.count) legenda(s)")
            }
            print(achadas == 0 ? "nenhuma legenda de tres linhas" : "\(achadas) encontradas")
        } catch {
            print("falhou: \(error.localizedDescription)")
        }
        exit(0)
    }

    /// O que dá para conferir do DeepL sem rede e sem janela.
    ///
    /// A parte que fala com o site fica de fora de propósito: ela depende de
    /// um HTML que não é nosso, e um teste que precisa de internet não é
    /// teste, é notícia. O que está aqui é o que, quebrando, desalinha a
    /// legenda — a repartição em blocos e a montagem do link.
    // MARK: Tradutores de rede que falam JSON

    /// O que é nosso no motor Google: repartição, código de idioma e escape.
    /// O JSON alheio não vira teste; a conta que desalinha legenda, sim.
    static func webAPIGate() async {
        failures = 0

        print("tradutor de rede (Google)\n")

        // Repartição do Google: por bytes de URL, sem perder nem trocar fala.
        let curtas = (1...50).map { "fala número \($0)" }
        let umBloco = GoogleWebTranslator.blocos(curtas, source: .japanese, target: .portuguese)
        expect(umBloco.count == 1, "50 falas curtas cabem numa requisição")
        expect(umBloco.flatMap { $0 } == Array(curtas.indices),
               "a repartição preserva ordem e índices")

        // Japonês escapado custa 9 bytes por caractere: 300 falas de 40
        // caracteres passam de 100 KB e têm de virar vários blocos.
        let longas = (1...300).map { _ in String(repeating: "あ", count: 40) }
        let muitos = GoogleWebTranslator.blocos(longas, source: .japanese, target: .portuguese)
        expect(muitos.count > 1, "texto longo vira mais de uma requisição")
        expect(muitos.flatMap { $0 } == Array(longas.indices),
               "repartido em vários, nenhuma fala se perde")
        let base = "https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=ja&tl=pt"
        let maior = muitos.map { bloco in
            bloco.reduce(base.utf8.count) { $0 + WebAPI.escapar(longas[$1]).utf8.count + 3 }
        }.max() ?? 0
        expect(maior <= GoogleWebTranslator.urlBudget,
               "nenhuma requisição passa do teto de URL (maior: \(maior))")

        // Fala sozinha maior que o teto vai sozinha, e não some.
        let gigante = [String(repeating: "あ", count: 2000)]
        let sozinha = GoogleWebTranslator.blocos(gigante, source: .japanese, target: .portuguese)
        expect(sozinha == [[0]], "fala maior que o teto vai sozinha em vez de sumir")

        expect(GoogleWebTranslator.code(for: .portuguese) == "pt",
               "no Google, pt já é o brasileiro")
        expect(GoogleWebTranslator.code(for: .chinese) == "zh-CN", "chinês no Google é zh-CN")

        // Escape: legenda tem & + # e ?, e os quatro mudam de sentido dentro
        // de uma consulta. Um escape frouxo parte a fala em duas.
        let sujo = "a & b + c # d ? e/f"
        let escapado = WebAPI.escapar(sujo)
        expect(!escapado.contains("&") && !escapado.contains("+")
               && !escapado.contains("#") && !escapado.contains("?")
               && !escapado.contains("/"),
               "o escape não deixa passar separador de consulta")
        expect(escapado.removingPercentEncoding == sujo, "e volta igual ao que entrou")

        // Nenhum tradutor de reserva: bloco que falha derruba a tradução em
        // vez de deixar metade do arquivo com outra qualidade dentro.
        struct BlocoQuebrado: Error {}
        var chamadas = 0
        do {
            _ = try await WebAPI.porBlocos(
                ["uma", "outra"],
                blocos: { falas in falas.indices.map { [$0] } },
                traduzir: { _ in chamadas += 1; throw BlocoQuebrado() }
            )
            expect(false, "bloco que falha propaga o erro")
        } catch is BlocoQuebrado {
            expect(true, "bloco que falha propaga o erro")
            expect(chamadas == 1, "e para no primeiro, sem tentar os seguintes (\(chamadas))")
        } catch {
            expect(false, "o erro que sai é o do bloco, não \(error)")
        }

        // Manda texto para fora, e ao vivo tem de avisar o preço.
        for motor in [TranslationEngine.google] {
            expect(motor.leavesTheMachine, "\(motor.displayName) manda o texto para fora")
            expect(motor.liveCostNote != nil, "\(motor.displayName) avisa o custo ao vivo")
            expect(motor.isAvailable, "\(motor.displayName) está disponível")
            expect(motor.costPerSecondOfVideo > 0, "\(motor.displayName) tem custo estimado")
            expect(motor.supports(.japanese, .portuguese), "\(motor.displayName) cobre ja → pt")
        }

        print(failures == 0 ? "\ntudo certo" : "\n\(failures) falha(s)")
        exit(failures == 0 ? 0 : 1)
    }

    /// So transcrever (sem traduzir) e a exportacao do painel ao vivo.
    @MainActor
    static func captureGate() async {
        failures = 0

        print("So transcrever, e a captura exportada\n")

        // O tradutor identidade devolve o que recebeu — inclusive a contagem,
        // que e o que o `translate` do builder confere antes de aceitar o lote.
        let identidade = IdentityTranslator()
        let entrada = ["Bom dia.", "こんにちは。", ""]
        let saida = (try? await identidade.translate(entrada, from: .japanese, to: .portuguese)) ?? []
        expect(saida == entrada, "o tradutor identidade devolve o texto como veio")

        // O destino real: sem traducao a legenda sai no idioma falado, e e
        // disso que dependem a largura da linha e o sufixo do arquivo.
        expect(TranslationEngine.transcriptionOnly.destination(from: .japanese, to: .portuguese)
               == .japanese, "so transcrever escreve no idioma falado")
        expect(TranslationEngine.apple.destination(from: .japanese, to: .portuguese)
               == .portuguese, "com traducao o destino continua sendo o escolhido")
        expect(SubtitleFileBuilder.lineWidth(
            for: TranslationEngine.transcriptionOnly.destination(from: .japanese, to: .portuguese))
            == 20, "transcricao em japones usa a linha estreita")
        expect(TranslationEngine.transcriptionOnly.liveCostNote == nil,
               "so transcrever nao custa nada ao vivo")
        expect(!TranslationEngine.transcriptionOnly.leavesTheMachine,
               "sem traducao nada sai da maquina")
        expect(TranslationEngine.transcriptionOnly.isAvailable,
               "so transcrever existe em qualquer maquina")

        // O historico da tela tem teto porque rola; a exportacao nao pode ter,
        // senao uma reuniao longa sai pela metade e sem nada acusar.
        let store = SubtitleStore()
        store.historyLimit = 3
        for numero in 1...10 {
            store.commit(SubtitleBlock(source: "fala \(numero)", translated: "linha \(numero)"))
        }
        expect(store.history.count == 3, "o historico da tela para no teto")
        expect(store.transcript.count == 10, "a exportacao guarda a sessao inteira")
        store.clear()
        expect(store.transcript.isEmpty && store.history.isEmpty && store.current == nil,
               "limpar apaga tela e registro")

        // O formato exportado: uma marca de dia e hora por fala.
        let instante = Date(timeIntervalSince1970: 1_757_880_000)
        let comTraducao = CaptureExport.text(
            [SubtitleBlock(source: "こんにちは。", translated: "Olá.", at: instante)],
            from: .japanese, to: .portuguese)
        expect(comTraducao.contains("Japonês → Português"), "o cabecalho diz o par")
        expect(comTraducao.contains("こんにちは。") && comTraducao.contains("Olá."),
               "original e traducao saem os dois")
        expect(comTraducao.range(of: #"\[\d\d/\d\d/\d{4} \d\d:\d\d:\d\d\]"#,
                                 options: .regularExpression) != nil,
               "cada fala leva dia e hora")

        let soTexto = CaptureExport.text(
            [SubtitleBlock(source: "こんにちは。", translated: "こんにちは。", at: instante)],
            from: .japanese, to: nil)
        expect(!soTexto.contains("→"), "sem traducao o cabecalho nao promete um destino")
        expect(soTexto.components(separatedBy: "こんにちは。").count - 1 == 1,
               "sem traducao a fala nao aparece duas vezes")
        expect(CaptureExport.suggestedName(at: instante).hasSuffix(".txt"),
               "o nome sugerido e um .txt")
        store.beginTranslating()
        store.endTranslating()
        expect(!store.isTranslating, "traducao que falha tira o \"traduzindo\" da tela")

        // Ao vivo passa qualquer motor, mas quem custa tem de dizer quanto.
        for motor in TranslationEngine.allCases where motor.leavesTheMachine {
            expect(motor.liveCostNote != nil,
                   "\(motor.displayName) avisa o que custa ao vivo")
            expect(!motor.isInstantaneous,
                   "\(motor.displayName) nao fica carregado entre sessoes")
        }
        expect(!TranslationEngine.hunyuan.isInstantaneous,
               "o Hunyuan nao e carregado na abertura do app")
        expect(TranslationEngine.apple.isInstantaneous
               && TranslationEngine.transcriptionOnly.isInstantaneous,
               "Apple e so-transcrever ficam carregados, que e de graca")

        // A lista de captura: so nome de aplicativo, nunca bundle ID nem pid.
        //
        // O usuario via `com.apple.WebKit.GPU`, `pid:57939` e o proprio app no
        // seletor — linhas que ele nao reconhece e nao tem por que escolher.
        let apps = (try? AudioProcessList.all()) ?? []
        print("  (\(apps.count) aplicativos: \(apps.map(\.name).joined(separator: ", ")))")
        expect(!apps.contains { $0.name.hasPrefix("com.") || $0.name.hasPrefix("org.") },
               "nenhum bundle ID passa por nome")
        expect(!apps.contains { $0.name.hasPrefix("pid:") || $0.name.hasPrefix("exec:") },
               "nenhuma chave interna passa por nome")
        expect(!apps.contains { $0.name.trimmingCharacters(in: .whitespaces).isEmpty },
               "nenhum nome vazio")
        // Agente de sistema so entra se estiver tocando som agora.
        expect(apps.allSatisfy { app in
            app.isPlaying || app.pids.contains { pid in
                guard let running = NSRunningApplication(processIdentifier: pid),
                      let caminho = running.bundleURL?.path else { return false }
                return running.activationPolicy != .prohibited
                    && !caminho.hasPrefix("/System/Library/")
            }
        }, "so aplicativo escolhivel entra na lista")
        expect(AudioProcess.microphone.isMicrophone
               && !AudioProcess.microphone.isSystemWide,
               "o microfone e uma escolha propria, nao o tap global")
        expect(!AudioProcess.systemWide.isMicrophone,
               "e o tap global nao e o microfone")

        // Entradas: so o que capta de verdade, e com nome legivel.
        let entradas = AudioInputList.all()
        print("  (\(entradas.count) entradas: \(entradas.map(\.name).joined(separator: ", ")))")
        expect(entradas.allSatisfy { !$0.name.isEmpty }, "toda entrada tem nome")
        expect(!entradas.contains { $0.name.hasPrefix("Tradutor") },
               "o aggregate device do proprio tap nao e oferecido como microfone")
        if let padrao = AudioInputList.systemDefault {
            expect(entradas.contains(padrao), "o padrao do sistema esta na lista")
        }

        print("")
        print(failures == 0 ? "tudo certo" : "\(failures) falha(s)")
        exit(failures == 0 ? 0 : 1)
    }

    static func deepLGate() {
        failures = 0

        print("DeepL: blocos e link\n")

        // Repartição: nenhum bloco pode passar do limite, e nenhuma fala pode
        // se perder ou trocar de lugar — é disso que depende o alinhamento.
        let falas = (1...50).map { String(repeating: "あ", count: 40) + "\($0)" }
        let blocos = DeepLWeb.chunks(of: falas)
        expect(blocos.count > 1, "50 falas de 40 caracteres passam de um bloco")
        expect(blocos.allSatisfy { bloco in
            bloco.reduce(0) { $0 + falas[$1].count + 1 } <= DeepLWeb.characterLimit
        }, "nenhum bloco passa do limite de caracteres")
        expect(blocos.flatMap { $0 } == Array(falas.indices),
               "os indices saem todos, na ordem, sem repetir")

        // Fala sozinha maior que o limite: vai sozinha, em vez de sumir.
        let gigante = String(repeating: "あ", count: DeepLWeb.characterLimit + 200)
        let comGigante = DeepLWeb.chunks(of: ["curta", gigante, "outra"])
        expect(comGigante.contains { $0 == [1] }, "fala maior que o limite vai sozinha")
        expect(comGigante.flatMap { $0 } == [0, 1, 2], "e as vizinhas continuam inteiras")

        // Uma fala só não pode virar dois blocos.
        expect(DeepLWeb.chunks(of: ["oi"]) == [[0]], "uma fala da um bloco")
        expect(DeepLWeb.chunks(of: []).isEmpty, "sem falas, sem bloco")

        // O link. O fragmento e o que leva o texto; o parametro de consulta e
        // o que forca carga nova e identifica a pagina na volta.
        let url = DeepLWeb.url(for: ["あ", "い"], from: .japanese, to: .portuguese, nonce: 7)
        let texto = url?.absoluteString ?? ""
        expect(texto.contains("?bloco=7"), "o link leva o numero do bloco")
        expect(texto.contains("#ja/pt-BR/"), "origem e destino no fragmento, destino com variante")
        expect(texto.contains("%0A"), "a quebra de linha entre as falas vai codificada")
        expect(!texto.contains("#ja/pt-BR/あ"), "o texto vai codificado, nao cru")

        // O texto vai para dentro de um script de colagem. Escape errado
        // quebra o script, e quebrar significa cair calado para a Apple —
        // legenda tem aspas, barra invertida e reticencias o tempo todo.
        expect(DeepLWeb.jsLiteral("oi") == "\"oi\"", "texto simples vira literal")
        expect(DeepLWeb.jsLiteral("diz \"oi\"") == "\"diz \\\"oi\\\"\"",
               "aspas sao escapadas")
        expect(DeepLWeb.jsLiteral("a\\b") == "\"a\\\\b\"", "barra invertida e escapada")
        expect(DeepLWeb.jsLiteral("uma\nduas") == "\"uma\\nduas\"",
               "quebra de linha vira \\n, e e ela que separa as falas")
        expect(DeepLWeb.jsLiteral("こんにちは") == "\"こんにちは\"",
               "japones passa inteiro, sem escape")

        // A leitura da tradução: o site as vezes devolve o bloco inteiro num
        // paragrafo so, com as quebras dentro. Separar so vale quando a conta
        // fecha exata — partir por chute desalinha a legenda, que e o defeito
        // que este caminho inteiro existe para evitar.
        expect(DeepLWeb.separar(["um\ndois\ntres"], esperadas: 3) == ["um", "dois", "tres"],
               "paragrafo unico com as quebras certas vira tres linhas")
        expect(DeepLWeb.separar(["um\ndois"], esperadas: 3) == ["um\ndois"],
               "se a conta nao fecha, nao separa")
        expect(DeepLWeb.separar(["um", "dois"], esperadas: 2) == ["um", "dois"],
               "o que ja vem separado passa intacto")
        expect(DeepLWeb.separar(["um\ndois"], esperadas: 1) == ["um\ndois"],
               "uma fala so nao e partida pela quebra que o site devolveu")

        // A leitura atrasada: por ~600 ms depois de o texto novo entrar, o
        // site ainda mostra a traducao do bloco ANTERIOR — completa, estavel e
        // plausivel. Medido no site em 12/09/2026; o que denuncia e o botao de
        // volume do destino, que some enquanto ele traduz.
        let anterior = ["Bom dia.", "Tudo bem?"]
        let novo = ["Boa noite.", "Ate amanha."]
        expect(!DeepLWeb.aceitavel(destino: anterior, falante: true,
                                   viuTrabalhar: false, anterior: anterior),
               "o texto do bloco anterior, sem ter visto o site trabalhar, e recusado")
        expect(DeepLWeb.aceitavel(destino: novo, falante: true,
                                  viuTrabalhar: false, anterior: anterior),
               "texto diferente do bloco anterior e aceito")
        expect(DeepLWeb.aceitavel(destino: anterior, falante: true,
                                  viuTrabalhar: true, anterior: anterior),
               "depois de ver o site trabalhar, ate traducao igual a anterior vale")
        expect(!DeepLWeb.aceitavel(destino: novo, falante: false,
                                   viuTrabalhar: true, anterior: anterior),
               "sem o botao de volume do destino, o site ainda esta traduzindo")
        expect(DeepLWeb.aceitavel(destino: novo, falante: true,
                                  viuTrabalhar: false, anterior: nil),
               "no primeiro bloco nao ha anterior para confundir")
        expect(!DeepLWeb.jsLiteral("fim\u{2028}novo").contains("\u{2028}"),
               "separador de linha invisivel nao sobra no literal")

        // Portugues so vira pt-BR como destino: como origem o site quer "pt".
        expect(DeepLWeb.code(for: .portuguese, target: true) == "pt-BR",
               "destino portugues e brasileiro")
        expect(DeepLWeb.code(for: .portuguese, target: false) == "pt",
               "origem portugues e generico")
        expect(DeepLWeb.code(for: .hindi, target: true) == nil,
               "idioma nao verificado fica de fora")
        expect(!DeepLWeb.supports(.japanese, .hindi), "par com idioma de fora nao passa")
        expect(DeepLWeb.supports(.japanese, .portuguese), "japones para portugues passa")
        expect(!DeepLWeb.supportedLanguages.contains(.thai),
               "a lista de idiomas nao inventa cobertura")

        // Ao vivo vale qualquer motor, a pedido — mas quem custa tem de
        // dizer quanto custa, senao o usuario descobre pelo atraso.
        expect(TranslationEngine.deepl.liveCostNote != nil, "DeepL avisa o atraso ao vivo")
        expect(TranslationEngine.apple.liveCostNote == nil, "a Apple nao tem o que avisar")

        // A estimativa da janela tem de sair do motor escolhido, e nao de uma
        // constante. Medidos, Apple e DeepL ficam perto — o que nao pode e a
        // conta ignorar quem vai fazer o trabalho.
        for motor in TranslationEngine.allCases {
            let esperado = 600 * motor.costPerSecondOfVideo
            let texto = TranslatorFactory.estimate(forVideoOf: 600, using: motor)
            let esperadoTexto = esperado < 90
                ? "≈ \(Int(esperado.rounded())) s"
                : "≈ \(Int((esperado / 60).rounded())) min"
            expect(texto == esperadoTexto,
                   "a estimativa de \(motor.rawValue) sai do custo dele (\(texto))")
        }
        expect(TranslationEngine.deepl.costPerSecondOfVideo > 0,
               "todo motor tem custo declarado")

        // Os outros motores de traducao. Ficam aqui porque este e o gate da
        // traducao; o Hunyuan nao tem teste proprio porque tudo nele depende
        // de um ambiente Python de 4,5 GB que nao existe em toda maquina.
        expect(TranslationEngine.hunyuan.liveCostNote != nil, "o Hunyuan avisa o custo ao vivo")
        expect(TranslationEngine.deepl.leavesTheMachine, "o DeepL manda o texto para fora")
        expect(!TranslationEngine.apple.leavesTheMachine
               && !TranslationEngine.hunyuan.leavesTheMachine,
               "Apple e Hunyuan sao locais")
        expect(TranslationEngine.apple.isAvailable && TranslationEngine.deepl.isAvailable,
               "Apple e DeepL existem em qualquer maquina")
        expect(TranslationEngine.hunyuan.isAvailable == HunyuanTranslator.isInstalled,
               "o Hunyuan so aparece quando instalado")
        expect(HunyuanTranslator.englishName(.japanese) == "Japanese"
               && HunyuanTranslator.englishName(.portuguese) == "Portuguese",
               "o prompt do Hunyuan recebe o idioma em ingles")
        expect(Language.allCases.allSatisfy { !HunyuanTranslator.englishName($0).isEmpty },
               "todo idioma do app tem nome em ingles")

        // Fala de uma palavra nao vai para o modelo: e nela que ele comenta a
        // tarefa em vez de traduzir. O criterio e tamanho porque japones nao
        // separa palavra por espaco.
        expect(HunyuanTranslator.tooShort("あ"), "interjeicao de um caractere e curta demais")
        expect(HunyuanTranslator.tooShort("はい"), "duas silabas tambem")
        expect(!HunyuanTranslator.tooShort("お疲れ様です"), "fala de verdade vai para o modelo")
        expect(!HunyuanTranslator.tooShort("Bom dia"),
               "duas palavras curtas nao sao uma palavra so")
        // Vazio tambem conta como curto, e nao faz diferenca: `translate`
        // devolve antes de chegar aqui.
        expect(HunyuanTranslator.tooShort(""), "vazio nem chega ao modelo")

        print("")
        print(failures == 0 ? "blocos e link ok" : "\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    static func speakerGate() {
        failures = 0

        print("Identificacao de quem fala\n")

        let turns = [
            SpeakerDiarizer.Turn(speaker: "speaker_2", start: 0.0, end: 2.0),
            SpeakerDiarizer.Turn(speaker: "speaker_0", start: 2.2, end: 4.0),
        ]
        let pieces = [
            TimedText(text: "Bom dia.", start: 0.1, end: 1.0),
            TimedText(text: "Tudo bem?", start: 1.1, end: 1.9),
            TimedText(text: "Bom dia.", start: 2.3, end: 3.2),
            TimedText(text: "Fora de qualquer faixa.", start: 9.0, end: 9.5),
        ]
        let marked = SpeakerDiarizer.renumber(SpeakerDiarizer.assign(pieces, to: turns))

        expect(marked[0].speaker == "Locutor 1" && marked[1].speaker == "Locutor 1",
               "trechos dentro da mesma faixa ficam com o mesmo locutor")
        expect(marked[2].speaker == "Locutor 2",
               "a faixa seguinte vira outro locutor")
        // Travessão: a regra é uma só para a janela e para o arquivo, e o
        // trecho sem dono no meio não é troca de pessoa. `pruneTinyVoices`
        // produz esse buraco de propósito, e marcá-lo diria ao leitor que
        // apareceu gente nova.
        expect(SpeakerMark.decorate("Oi", speaker: "Locutor 1", previous: nil) == "— Oi",
               "primeira fala de alguem leva travessao")
        expect(SpeakerMark.decorate("Oi", speaker: "Locutor 1", previous: "Locutor 1") == "Oi",
               "mesma pessoa seguindo nao leva")
        expect(SpeakerMark.decorate("Oi", speaker: nil, previous: "Locutor 1") == "Oi",
               "trecho sem locutor nao leva")
        expect(SpeakerMark.advance("Locutor 1", with: nil) == "Locutor 1",
               "trecho sem locutor nao apaga quem falava")
        expect(SpeakerMark.advance("Locutor 1", with: "Locutor 2") == "Locutor 2",
               "troca de verdade atualiza")

        // Fim a fim, que é onde o defeito aparecia: Locutor 1, trecho sem
        // dono, Locutor 1 de volta dava dois travessões para a mesma pessoa.
        let comBuraco = [
            Cue(index: 1, start: 0, end: 1, source: "", translated: "Bom dia.", speaker: "Locutor 1"),
            Cue(index: 2, start: 1, end: 2, source: "", translated: "Hum.", speaker: nil),
            Cue(index: 3, start: 2, end: 3, source: "", translated: "Tudo bem?", speaker: "Locutor 1"),
            Cue(index: 4, start: 3, end: 4, source: "", translated: "Tudo.", speaker: "Locutor 2"),
        ]
        let arquivo = SRTWriter.render(comBuraco)
        expect(arquivo.components(separatedBy: "— ").count - 1 == 2,
               "dois travessoes: a abertura e a troca, nao o buraco")
        expect(arquivo.contains("— Tudo."), "a troca de verdade ganha travessao")
        expect(!arquivo.contains("— Tudo bem?"), "a mesma pessoa voltando nao ganha")

        // Cor: rótulo sem número é "não sei", não a primeira cor.
        expect(SpeakerPalette.index(for: "Locutor 2") == 1, "Locutor 2 cai na segunda cor")
        expect(SpeakerPalette.index(for: nil) == nil, "sem locutor, sem cor")
        expect(SpeakerPalette.index(for: "speaker_desconhecido") == nil,
               "rotulo sem numero nao vira a primeira cor")

        expect(marked[3].speaker == nil,
               "trecho fora de qualquer faixa fica sem locutor, nao com o errado")
        // A numeracao segue quem falou primeiro, nao o nome que o modelo deu:
        // "speaker_2" falou antes e por isso e o Locutor 1.
        expect(marked.compactMap(\.speaker).first == "Locutor 1",
               "a numeracao segue a ordem da fala, nao o id do modelo")

        // Sobreposicao parcial: vale a faixa que cobre mais do trecho.
        let ambiguo = [TimedText(text: "Na fronteira.", start: 1.8, end: 2.6)]
        let escolhido = SpeakerDiarizer.assign(ambiguo, to: turns).first?.speaker
        expect(escolhido == "speaker_0", "empate de fronteira fica com quem cobre mais")

        // Vale a VOZ que cobre mais, somando as faixas dela — nao a maior
        // faixa isolada. Trecho largo com ida e volta dentro e justamente o
        // que a Apple produz. Auditoria de 12/09/2026.
        let idaEVolta = [
            SpeakerDiarizer.Turn(speaker: "speaker_a", start: 0, end: 3),
            SpeakerDiarizer.Turn(speaker: "speaker_b", start: 3, end: 7),
            SpeakerDiarizer.Turn(speaker: "speaker_a", start: 7, end: 10),
        ]
        let largo = [TimedText(text: "Trecho largo.", start: 0, end: 10)]
        expect(SpeakerDiarizer.assign(largo, to: idaEVolta).first?.speaker == "speaker_a",
               "6s em duas faixas ganham de 4s numa faixa so")
        // Empate resolvido pela ordem, para a saida nao mudar de execucao
        // para execucao.
        let empate = [
            SpeakerDiarizer.Turn(speaker: "speaker_x", start: 0, end: 2),
            SpeakerDiarizer.Turn(speaker: "speaker_y", start: 2, end: 4),
        ]
        let iguais = (0..<8).map { _ in
            SpeakerDiarizer.assign(
                [TimedText(text: "Empate.", start: 0, end: 4)], to: empate
            ).first?.speaker
        }
        expect(Set(iguais).count == 1 && iguais.first == "speaker_x",
               "empate fica com quem falou primeiro, sempre igual")

        // As fronteiras que vao para o reconhecedor: só onde a voz troca.
        let faixas = [
            SpeakerDiarizer.Turn(speaker: "speaker_0", start: 0, end: 10),
            SpeakerDiarizer.Turn(speaker: "speaker_0", start: 10.5, end: 20),
            SpeakerDiarizer.Turn(speaker: "speaker_1", start: 21, end: 30),
        ]
        // Sem adiantar: aqui o que se testa é QUAIS instantes viram fronteira.
        // O adiantamento tem verificação própria mais abaixo.
        let limites = SpeakerDiarizer.boundaries(of: faixas, shift: 0)
        expect(limites.contains(0) && limites.contains(21) && limites.contains(30),
               "o começo de cada voz e o fim da ultima sao fronteira")
        expect(!limites.contains(10.5),
               "duas faixas seguidas da mesma voz nao viram fronteira")
        expect(limites.contains(20), "o fim da fala de uma voz e fronteira")
        expect(limites == limites.sorted(), "as fronteiras saem em ordem")
        expect(SpeakerDiarizer.boundaries(of: []).isEmpty, "sem faixas, sem fronteiras")

        // A ordem dos passos importa: quem fala vem ANTES de reconhecer,
        // porque as fronteiras entram no reconhecimento.
        let passos = GenerationStep.allCases
        if let locutor = passos.firstIndex(of: .diarizing),
           let fala = passos.firstIndex(of: .transcribing) {
            expect(locutor < fala, "identificar quem fala vem antes de reconhecer")
            expect(GenerationStep.diarizing.share.upperBound
                   <= GenerationStep.transcribing.share.lowerBound,
                   "a barra de progresso segue a mesma ordem")
        }

        // Voz que soma quase nada e resto de agrupamento, nao pessoa: o
        // trecho dela fica SEM locutor, nunca com o do vizinho.
        let comResto = [
            SpeakerDiarizer.Turn(speaker: "speaker_0", start: 0, end: 30),
            SpeakerDiarizer.Turn(speaker: "speaker_1", start: 31, end: 50),
            SpeakerDiarizer.Turn(speaker: "speaker_9", start: 51, end: 51.8),
        ]
        let limpas = SpeakerDiarizer.pruneTinyVoices(comResto)
        expect(Set(limpas.map(\.speaker)) == ["speaker_0", "speaker_1"],
               "voz de menos de 2s e descartada")
        expect(limpas.count == 2, "as faixas da voz descartada saem junto")
        // Todas pequenas: nao sobra ninguem para atribuir, e ai e melhor
        // manter o que veio do que devolver vazio.
        let todasPequenas = [
            SpeakerDiarizer.Turn(speaker: "speaker_0", start: 0, end: 1),
            SpeakerDiarizer.Turn(speaker: "speaker_1", start: 2, end: 3),
        ]
        expect(SpeakerDiarizer.pruneTinyVoices(todasPequenas).count == 2,
               "se todas as vozes sao curtas, nenhuma e descartada")

        // Sem faixa nenhuma, nada muda — o caminho de quem nao pediu locutor.
        expect(SpeakerDiarizer.assign(pieces, to: []).allSatisfy { $0.speaker == nil },
               "sem faixas, os trechos continuam sem locutor")

        // A troca de locutor quebra a legenda, mesmo sem pausa longa.
        let builder = SubtitleFileBuilder()
        let cues = builder.makeCues(from: marked)
        expect(cues.count >= 3, "a troca de locutor abre legenda nova (\(cues.count) legendas)")
        expect(cues.first?.speaker == "Locutor 1", "a legenda carrega quem fala")
        let doMesmo = builder.makeCues(from: [
            TimedText(text: "Primeira parte,", start: 0.0, end: 1.0, speaker: "Locutor 1"),
            TimedText(text: "segunda parte,", start: 1.05, end: 2.0, speaker: "Locutor 1"),
        ])
        expect(doMesmo.count == 1, "o mesmo locutor continua na mesma legenda")

        // No arquivo, a troca ganha travessao — e so a troca.
        let texto = SRTWriter.render([
            Cue(index: 1, start: 0, end: 1, source: "", translated: "Bom dia.", speaker: "Locutor 1"),
            Cue(index: 2, start: 1, end: 2, source: "", translated: "Tudo bem?", speaker: "Locutor 1"),
            Cue(index: 3, start: 2, end: 3, source: "", translated: "Bom dia.", speaker: "Locutor 2"),
        ])
        expect(texto.contains("— Bom dia."), "a primeira fala de um locutor leva travessao")
        expect(!texto.contains("— Tudo bem?"), "seguir falando nao leva travessao")
        expect(texto.components(separatedBy: "— ").count == 3, "dois travessoes em tres legendas")
        let semLocutor = SRTWriter.render([
            Cue(index: 1, start: 0, end: 1, source: "", translated: "Bom dia.")
        ])
        expect(!semLocutor.contains("—"), "sem locutor, a legenda sai como sempre saiu")

        // Uma cor por locutor, as mesmas da legenda oculta de TV, e a mesma
        // cor na janela e no arquivo.
        expect(SpeakerPalette.index(for: "Locutor 1") == 0, "o primeiro locutor pega a primeira cor")
        expect(SpeakerPalette.index(for: "Locutor 3") == 2, "o terceiro pega a terceira")
        expect(SpeakerPalette.index(for: "Locutor 5") == 0, "passando de quatro, a paleta volta ao inicio")
        expect(SpeakerPalette.index(for: nil) == nil, "sem locutor, sem cor")
        expect(SpeakerPalette.hexes.count == SpeakerPalette.components.count,
               "o hexadecimal do arquivo e a cor da tela vem da mesma lista")

        let coloridas = SRTWriter.render([
            Cue(index: 1, start: 0, end: 1, source: "", translated: "Bom dia.", speaker: "Locutor 1"),
            Cue(index: 2, start: 1, end: 2, source: "", translated: "Bom dia.", speaker: "Locutor 2"),
        ], colorBySpeaker: true)
        expect(coloridas.contains("<font color=\"#FFFFFF\">"), "o primeiro locutor sai branco")
        expect(coloridas.contains("<font color=\"#FFFF54\">"), "o segundo sai amarelo")
        expect(coloridas.components(separatedBy: "</font>").count == 3, "cada legenda fecha a sua tag")
        expect(!SRTWriter.render([
            Cue(index: 1, start: 0, end: 1, source: "", translated: "Bom dia.", speaker: "Locutor 1")
        ]).contains("<font"), "sem pedir cor, nenhuma tag entra no arquivo")

        print("")
        print("fronteiras de voz adiantadas\n")
        // O modelo marca a troca depois de ela acontecer, e o corte atrasado
        // leva a primeira palavra de quem entrou para a legenda de quem saiu.
        // Medido contra gabarito humano: 12 de 43 legendas juntavam duas
        // pessoas com as fronteiras cruas, 2 de 43 adiantando.
        let duasVozes: [SpeakerDiarizer.Turn] = [
            .init(speaker: "A", start: 0, end: 10),
            .init(speaker: "B", start: 10, end: 20),
        ]
        let cruas = SpeakerDiarizer.boundaries(of: duasVozes, shift: 0)
        let adiantadas = SpeakerDiarizer.boundaries(of: duasVozes)
        expect(cruas == [0, 10, 20], "sem adiantar, a fronteira é o instante do modelo")
        expect(adiantadas == [0, 10 - SpeakerDiarizer.boundaryLead, 20 - SpeakerDiarizer.boundaryLead],
               "adiantar desloca todas menos a que ficaria antes do zero")
        expect(SpeakerDiarizer.boundaryLead >= 0.5 && SpeakerDiarizer.boundaryLead <= 1.0,
               "o adiantamento fica na faixa medida (0,50 a 1,00 s)")
        expect(SpeakerDiarizer.boundaries(of: [
            .init(speaker: "A", start: 0, end: 5), .init(speaker: "A", start: 5, end: 9),
        ]) == [0, 9 - SpeakerDiarizer.boundaryLead],
               "duas faixas da mesma pessoa nao abrem fronteira no meio")
        // O leitor do proprio app tem de ler de volta o que ele escreveu.
        let devolta = SRTParser.parse(coloridas)
        expect(devolta.count == 2 && devolta[0].translated == "— Bom dia.",
               "o .srt colorido volta a ser lido sem as tags")

        print("")
        print("fusão de identificadores da mesma voz\n")
        // Sem modelo: os embeddings sao dados. A e C sao a mesma voz, B e
        // outra, e D vem por encadeamento — parecido com C, longe de A.
        let vozA: [Float] = [1, 0, 0, 0]
        let vozB: [Float] = [0, 1, 0, 0]
        let vozC: [Float] = [0.95, 0.31, 0, 0]
        let vozD: [Float] = [0.80, 0.60, 0, 0]
        let quando: [String: TimeInterval] = ["s0": 0, "s1": 5, "s2": 10, "s3": 20]
        let grupos = SpeakerDiarizer.groupSameVoice(
            ["s0": vozA, "s1": vozB, "s2": vozC, "s3": vozD], firstHeard: quando, threshold: 0.20)
        expect(grupos["s0"] == "s0" && grupos["s2"] == "s0",
               "voz parecida entra no grupo de quem falou primeiro")
        expect(grupos["s1"] == "s1", "voz diferente nao e fundida")
        expect(grupos["s3"] == "s0",
               "encadeamento: parecido com o parecido entra no mesmo grupo")
        expect(Set(grupos.values).count == 2, "quatro identificadores viram duas vozes")
        // Limiar baixo nao funde nada, e a saida nao pode depender da ordem
        // do dicionario: quem falou primeiro nomeia o grupo.
        let separados = SpeakerDiarizer.groupSameVoice(
            ["s0": vozA, "s1": vozB, "s2": vozC], firstHeard: quando, threshold: 0.001)
        expect(Set(separados.values).count == 3, "limiar apertado deixa cada um no seu")
        expect(SpeakerDiarizer.cosineDistance(vozA, vozA) < 0.0001, "voz igual tem distancia zero")
        expect(SpeakerDiarizer.cosineDistance(vozA, vozB) > 0.9, "vozes ortogonais ficam longe")
        expect(SpeakerDiarizer.cosineDistance([], []) == 2, "vetor vazio nao vira semelhanca")

        print("")
        print(failures == 0 ? "PASSOU" : "\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    /// Varre o limiar de agrupamento e conta quantas vozes cada valor devolve.
    ///
    /// Nao precisa de reconhecedor: quem identifica locutor e outro modelo,
    /// sobre o mesmo audio. O numero certo e o que voce sabe do arquivo.
    /// Pontua a identificação de vozes contra um gabarito feito à mão.
    ///
    /// O arquivo tem uma linha por legenda, com o tempo e quem fala entre
    /// colchetes — `[1]`, ou `[6, 5, 7]` quando há mais de uma pessoa dentro
    /// da mesma legenda. É a única verdade que existe nestes vídeos: sem ela
    /// toda comparação entre modelos é indício.
    static func groundTruthGate(marks: String, audio: String,
                                model: SpeakerDiarizer.Model, threshold: Float?) async {
        struct Marca { let numero: Int; let inicio: Double; let fim: Double; let quem: [String] }
        guard let texto = try? String(contentsOfFile: marks, encoding: .utf8) else {
            print("nao consegui ler \(marks)"); exit(1)
        }
        var marcas: [Marca] = []
        for linha in texto.split(separator: "\n") {
            let padrao = #"(\d+)\s+(\d+):(\d+):(\d+),(\d+)\s*-->\s*(\d+):(\d+):(\d+),(\d+)\s+\[([^\]]+)\]"#
            guard let m = try? NSRegularExpression(pattern: padrao),
                  let r = m.firstMatch(in: String(linha), range: NSRange(linha.startIndex..., in: linha))
            else { continue }
            func campo(_ i: Int) -> String {
                guard let faixa = Range(r.range(at: i), in: linha) else { return "" }
                return String(linha[faixa])
            }
            func segundos(_ base: Int) -> Double {
                (Double(campo(base)) ?? 0) * 3600 + (Double(campo(base + 1)) ?? 0) * 60
                    + (Double(campo(base + 2)) ?? 0) + (Double(campo(base + 3)) ?? 0) / 1000
            }
            marcas.append(Marca(numero: Int(campo(1)) ?? 0, inicio: segundos(2), fim: segundos(6),
                                quem: campo(10).split(separator: ",").map {
                                    $0.trimmingCharacters(in: .whitespaces) }))
        }
        guard !marcas.isEmpty else { print("nenhuma marcacao reconhecida em \(marks)"); exit(1) }
        guard let samples = load16kMono(path: audio) else { print("nao consegui ler \(audio)"); exit(1) }

        let pessoas = Set(marcas.flatMap(\.quem))
        let multiplas = marcas.filter { $0.quem.count > 1 }.count
        print("gabarito: \(marcas.count) legendas · \(pessoas.count) pessoas · \(multiplas) com mais de uma voz dentro")

        guard var turns = try? await SpeakerDiarizer.turns(
            in: samples, model: model, threshold: threshold) else {
            print("FALHA na identificacao"); exit(1)
        }
        if ProcessInfo.processInfo.environment["TRADUTOR_SEM_FUSAO"] == nil {
            turns = (try? await SpeakerDiarizer.mergeSameVoice(turns, in: samples)) ?? turns
        }

        // Quem o modelo põe em cada legenda: o rótulo que mais a cobre.
        var escolha: [Int: String] = [:]
        for marca in marcas {
            var cobertura: [String: Double] = [:]
            for turn in turns {
                let sobre = min(marca.fim, turn.end) - max(marca.inicio, turn.start)
                if sobre > 0 { cobertura[turn.speaker, default: 0] += sobre }
            }
            escolha[marca.numero] = cobertura.max { $0.value < $1.value }?.key ?? "nenhum"
        }
        // Cada rótulo vira a pessoa que ele mais acompanha: sem isso a
        // comparação puniria o modelo por chamar de "speaker_2" quem o
        // gabarito chama de "3".
        var votos: [String: [String: Int]] = [:]
        for marca in marcas {
            let rotulo = escolha[marca.numero] ?? "nenhum"
            votos[rotulo, default: [:]][marca.quem[0], default: 0] += 1
        }
        let mapa = votos.compactMapValues { $0.max { $0.value < $1.value }?.key }
        let acertos = marcas.filter { marca in
            guard let pessoa = mapa[escolha[marca.numero] ?? ""] else { return false }
            return marca.quem.contains(pessoa)
        }.count
        // A métrica que importa mais que acertar quantas pessoas há: quantas
        // legendas saem com fala de mais de uma pessoa dentro. Errar o número
        // de vozes deixa a cor estranha; juntar duas falas numa legenda
        // estraga a leitura e a tradução.
        //
        // Os pontos de troca que o gabarito conhece de verdade: onde uma
        // legenda de uma pessoa termina e a seguinte, de outra, começa. Uma
        // legenda gerada que passe por cima de um desses pontos está juntando
        // duas pessoas.
        //
        // Repartir em partes iguais o intervalo marcado com várias pessoas foi
        // tentado antes e não serve: o gabarito não diz onde a voz troca lá
        // dentro, e a divisão inventada punia justamente o corte mais fino —
        // legenda mais curta encosta em mais faixas imaginárias. Aqui esses
        // intervalos entram só pelas bordas, que são firmes.
        var trocas: [Double] = []
        for (anterior, seguinte) in zip(marcas, marcas.dropFirst())
        where Set(anterior.quem) != Set(seguinte.quem) {
            trocas.append((anterior.fim + seguinte.inicio) / 2)
        }
        func contaminadas(_ cues: [Cue]) -> Int {
            cues.filter { cue in
                trocas.contains { troca in cue.start + 0.2 < troca && troca < cue.end - 0.2 }
            }.count
        }

        let transcriber = TranscriberFactory.make(for: Language(rawValue: ProcessInfo.processInfo.environment["TRADUTOR_IDIOMA"] ?? "ja") ?? .japanese, engine: .apple)
        if (try? await transcriber.prepare { _, _ in }) != nil {
            let builder = SubtitleFileBuilder()
            let duracao = Double(samples.count) / 16_000
            print("")
            print("legendas que passam por cima de uma troca de pessoa conhecida:")
            let vozes = SpeakerDiarizer.boundaries(of: turns)
            let variantes: [(String, [TimeInterval], Double?)] = [
                ("sem nada       ", [], nil),
                ("só voz         ", vozes, nil),
                ("só pausa 0,8 s ", [], 0.8),
                ("voz + pausa 0,6", vozes, 0.6),
                ("voz + pausa 0,8", vozes, 0.8),
                ("voz + pausa 1,2", vozes, 1.2),
            ]
            for (nome, fronteiras, minimaPausa) in variantes {
                transcriber.speakerBoundaries = fronteiras
                let pausas = minimaPausa.map {
                    SpeechEnergy.pauseBoundaries(samples, minimumPause: $0) } ?? []
                transcriber.pauseBoundaries = pausas
                builder.silences = minimaPausa.map {
                    SpeechEnergy.silences(samples, minimumPause: $0) } ?? []
                guard let pieces = try? await transcriber.transcribeForSubtitles(samples, progress: { _ in })
                else { continue }
                let marcados = SpeakerDiarizer.assign(pieces, to: turns)
                let cues = SpeakerDiarizer.renumber(marcados).isEmpty
                    ? builder.makeCues(from: marcados, mediaDuration: duracao)
                    : builder.makeCues(from: marcados, mediaDuration: duracao)
                // O outro lado da moeda: sem cortar na troca, o trecho com
                // duas pessoas recebe um rótulo só. Isto conta quantas
                // legendas saem com o locutor certo, pelo mesmo mapeamento
                // por maioria usado acima.
                var votosLegenda: [String: [String: Int]] = [:]
                for cue in cues {
                    guard let dono = cue.speaker else { continue }
                    let pessoas = marcas.filter {
                        min(cue.end, $0.fim) - max(cue.start, $0.inicio) > 0.15
                    }.flatMap(\.quem)
                    guard let pessoa = pessoas.first else { continue }
                    votosLegenda[dono, default: [:]][pessoa, default: 0] += 1
                }
                let mapaLegenda = votosLegenda.compactMapValues { $0.max { $0.value < $1.value }?.key }
                let comDono = cues.filter { $0.speaker != nil }.count
                let certos = cues.filter { cue in
                    guard let dono = cue.speaker, let pessoa = mapaLegenda[dono] else { return false }
                    return marcas.contains {
                        min(cue.end, $0.fim) - max(cue.start, $0.inicio) > 0.15 && $0.quem.contains(pessoa)
                    }
                }.count
                print(String(format: "  %@ (%3d+%3d): %2d de %3d cruzam troca · locutor certo em %d de %d",
                             nome as NSString, fronteiras.count, pausas.count,
                             contaminadas(cues), cues.count, certos, comDono))
                if ProcessInfo.processInfo.environment["TRADUTOR_MOSTRA_CRUZAMENTO"] != nil {
                    for cue in cues {
                        let cruzou = trocas.filter { cue.start + 0.2 < $0 && $0 < cue.end - 0.2 }
                        guard !cruzou.isEmpty else { continue }
                        print(String(format: "      %6.2f–%6.2f  troca em %@  [%@]  %@",
                                     cue.start, cue.end,
                                     cruzou.map { String(format: "%.2f", $0) }.joined(separator: ",") as NSString,
                                     (cue.speaker ?? "—") as NSString, cue.source as NSString))
                    }
                }
            }
        }

        let rotulos = Set(escolha.values)
        print(String(format: "%@%@: %d rótulos · acerto %d de %d (%.0f%%)",
                     model.rawValue as NSString,
                     threshold.map { String(format: " limiar %.2f", $0) } ?? "" as String as NSString,
                     rotulos.count, acertos, marcas.count,
                     Double(acertos) / Double(marcas.count) * 100))
        for marca in marcas {
            let rotulo = escolha[marca.numero] ?? "nenhum"
            let pessoa = mapa[rotulo] ?? "?"
            let certo = marca.quem.contains(pessoa)
            print(String(format: "  %2d  %@ %-11@ → pessoa %-3@  gabarito %@",
                         marca.numero, certo ? "ok  " : "erro", rotulo as NSString,
                         pessoa as NSString, marca.quem.joined(separator: "+") as NSString))
        }
        exit(0)
    }

    /// Agrupamento contra Sortformer, com o mesmo instrumento e no mesmo
    /// áudio: quantas vozes cada um acha, quanto custa, se repete, e o que
    /// muda depois da fusão por embedding.
    static func voiceModelGate(paths: [String], threshold: Float? = nil) async {
        print("modelo · vozes (2 execuções) · faixas · tempo · vozes depois da fusão\n")
        for path in paths {
            guard let samples = load16kMono(path: path) else {
                print("nao consegui ler \(path)"); continue
            }
            print(URL(fileURLWithPath: path).lastPathComponent)
            for model in [SpeakerDiarizer.Model.clustering, .sortformer] {
                var vozes: [Int] = []
                var faixas = 0
                var fundidas = 0
                var segundos = 0.0
                for execucao in 0..<2 {
                    let inicio = Date()
                    guard let turns = try? await SpeakerDiarizer.turns(
                        in: samples, model: model,
                        threshold: model == .clustering ? threshold : nil)
                    else { print("  \(model.rawValue): FALHOU"); break }
                    segundos = max(segundos, Date().timeIntervalSince(inicio))
                    vozes.append(Set(turns.map(\.speaker)).count)
                    if execucao == 0 {
                        faixas = turns.count
                        let juntas = (try? await SpeakerDiarizer.mergeSameVoice(turns, in: samples)) ?? turns
                        fundidas = Set(juntas.map(\.speaker)).count
                    }
                }
                print(String(format: "  %-11@ %@ vozes · %3d faixas · %.1fs · %d depois da fusão",
                             model.rawValue as NSString,
                             vozes.map(String.init).joined(separator: " e ") as NSString,
                             faixas, segundos, fundidas))
            }
            print("")
        }
        exit(0)
    }

    static func voiceSweepGate(path: String, thresholds: [Float]) async {
        guard let samples = try? await SubtitleFileBuilder.extractAudio(
            from: URL(fileURLWithPath: path)
        ) else {
            print("nao consegui ler \(path)")
            exit(1)
        }
        print(String(format: "audio: %.0fs\n", Double(samples.count) / 16_000))
        print("limiar  vozes  faixas  tempo   por voz (s)")

        let falaMinima = ProcessInfo.processInfo.environment["FALA_MINIMA"].flatMap { Float($0) }
        let modelo = ProcessInfo.processInfo.environment["MODELO_LOCUTOR"]
            .flatMap { SpeakerDiarizer.Model(rawValue: $0) } ?? .clustering
        print("modelo: \(modelo.displayName)")
        if let falaMinima { print("fala minima: \(falaMinima)s\n") }
        for threshold in thresholds {
            let started = Date()
            do {
                let turns = try await SpeakerDiarizer.turns(
                    in: samples, model: modelo, threshold: threshold, minimumSpeech: falaMinima
                )
                var byVoice: [String: Double] = [:]
                for turn in turns {
                    byVoice[turn.speaker, default: 0] += turn.end - turn.start
                }
                let reparto = byVoice.values.sorted(by: >)
                    .map { String(format: "%.0f", $0) }
                    .joined(separator: " ")
                print(String(format: "%5.2f   %4d   %5d  %5.1fs   %@",
                             threshold, byVoice.count, turns.count,
                             Date().timeIntervalSince(started), reparto as NSString))
            } catch {
                print(String(format: "%5.2f   FALHA: %@", threshold, error.localizedDescription))
            }
        }
        exit(0)
    }

    // MARK: Motores de reconhecimento, sem modelo

    static func engineGate() async {
        failures = 0

        print("Motores de reconhecimento\n")

        // Lista de frases suspeitas não prova ausência de fala.
        expect(Hallucinations.isConfirmed("おやすみなさい。", by: "おやすみなさい"),
               "confirma uma despedida japonesa realmente falada")
        expect(Hallucinations.isConfirmed("Thank you for watching.", by: "THANK YOU for watching!"),
               "conferência ignora caixa, espaços e pontuação")
        expect(!Hallucinations.isConfirmed("Thank you for watching.", by: "Thank you."),
               "uma parte da frase não confirma o restante")
        expect(!Hallucinations.isConfirmed("ご視聴ありがとうございました", by: "。"),
               "ruído sem palavras não confirma uma alucinação")
        expect(!Hallucinations.isConfirmed("", by: "fala"), "texto vazio não é confirmação")
        let outside = [TimedText(text: "おやすみなさい", start: 2, end: 3),
                       TimedText(text: "Thank you for watching.", start: .infinity, end: .infinity),
                       TimedText(text: "fala válida", start: 0, end: 0.5)]
        let filtered = try? await Hallucinations.filter(outside, samples: [Float](repeating: 0, count: 16000), language: .japanese)
        expect(filtered?.map(\.text) == ["fala válida"],
               "tempos inválidos ou depois do arquivo não enviam recorte vazio à Apple")
        let fallback = try? await Hallucinations.filter(outside, samples: [], language: .arabic)
        expect(fallback?.map(\.text) == ["fala válida"], "idioma sem conferência mantém o descarte anterior")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await Hallucinations.filter([], samples: [], language: .japanese)
                return false
            } catch is CancellationError { return true } catch { return false }
        }
        expect(await cancelled.value, "cancelamento da conferência é propagado")
        let unloaded = WhisperTranscriber(language: .english)
        let silent = try? await unloaded.transcribeForSubtitles([Float](repeating: 0, count: 48000))
        expect(silent?.isEmpty == true && !unloaded.isPrepared,
               "silêncio digital não inventa agradecimento nem carrega modelo")
        let emptyAudio = try? await unloaded.transcribeForSubtitles([])
        expect(emptyAudio?.isEmpty == true, "áudio vazio não chega ao reconhecedor")

        // O numero que fazia a legenda mudar a cada execucao. Com o padrao do
        // WhisperKit (-1,5) o mesmo video dava 9, 20, 25 ou 34 trechos, e uma
        // execucao em cada tres perdia os primeiros 32 s. Ver o comentario em
        // `WhisperTranscriber.firstTokenLogProbThreshold` antes de mexer.
        expect(WhisperTranscriber.firstTokenLogProbThreshold <= -3.0,
               "o limiar do primeiro token nao voltou ao padrao do WhisperKit")

        // A pausa que nao aparece como intervalo. Em japones a Apple emite um
        // caractere por run e embute o silencio na duracao do caractere
        // seguinte; a mediana do run e 0,120 s e o limiar fica em 2,0 s, que
        // dispara em 7 runs de 1490 no video de 9 minutos. Baixar para 1,0 s
        // dispararia em 82 (5,5%) e picaria a legenda sem motivo — medir antes
        // de mexer. Ver `AppleSpeechTranscriber.longRunIsPause`.
        if #available(macOS 26.0, *) {
            expect(AppleSpeechTranscriber.longRunIsPause >= 2.0,
                   "o limiar de run longo nao desceu a ponto de picar a legenda")
            expect(AppleSpeechTranscriber.hardCeiling <= 7.0,
                   "o teto duro do trecho nao passou do teto da legenda")
        }

        // Parakeet e Whisper sao dois modelos, e o seletor mostra os dois.
        // Cada um so oferece os idiomas que cobre.
        let parakeet = RecognitionEngine.parakeet.supportedLanguages
        expect(parakeet?.contains(.portuguese) == true, "o Parakeet oferece portugues")
        expect(parakeet?.contains(.japanese) == false, "o Parakeet nao oferece japones")
        expect(RecognitionEngine.whisper.supportedLanguages == nil, "o Whisper nao limita idioma")
        expect(RecognitionEngine.allCases.filter(\.isAvailable).count >= 3,
               "o seletor lista todas as familias disponiveis")

        // O Qwen roda fora do processo e nao serve ao vivo; os dois tamanhos
        // seguem a mesma regra, e o ao vivo cai num motor que serve.
        // Nada de mascarar palavrao: legenda e transcricao do que foi dito.
        // A unica opcao do sistema que faz isso e `.etiquetteReplacements`, e
        // ela nao entra. Os outros motores nao tem filtro de palavra nenhum —
        // confirmado por busca no WhisperKit, no FluidAudio e no pacote do
        // Qwen; o unico filtro de texto do app e o de alucinacao, que olha
        // frase de cortesia isolada.
        if #available(macOS 26.0, *) {
            expect(AppleSpeechTranscriber.transcriptionOptions.isEmpty,
                   "o reconhecimento da Apple nao mascara palavra nenhuma")
        }

        // O "0.6B nao pontua em ingles" era o SRT do pacote jogando a
        // pontuacao fora; lendo o JSON, 66 sinais em 161 s (1.7B: 72).
        expect(RecognitionEngine.qwen.supportedLanguages?.contains(.english) == true,
               "o Qwen 0.6B oferece ingles de novo")
        expect(RecognitionEngine.qwenLarge.supportedLanguages?.contains(.english) == true,
               "o Qwen 1.7B oferece ingles, que ele pontua")
        expect(RecognitionEngine.qwen.supportedLanguages?.contains(.japanese) == true,
               "o Qwen 0.6B continua oferecendo japones")

        for motor in [RecognitionEngine.qwen, .qwenLarge] {
            expect(!motor.supportsLive, "\(motor.displayName) nao entra no ao vivo")
            expect(motor.forLive.supportsLive, "\(motor.displayName) cai num motor que serve ao vivo")
            expect(motor.supportedLanguages?.contains(.japanese) == true,
                   "\(motor.displayName) oferece japones")
            expect(motor.supportedLanguages?.contains(.thai) == false,
                   "\(motor.displayName) nao oferece tailandes")
        }
        for motor in [RecognitionEngine.apple, .parakeet, .whisper] {
            expect(motor.forLive == motor, "\(motor.displayName) ao vivo continua sendo ele mesmo")
        }

        // A repeticao do Whisper quando a passada sai pobre. O criterio e
        // ALCANCE — quantos trechos de fala receberam algum texto —, e nao
        // tempo coberto: o Whisper corta fino de proposito, e contar segundos
        // faria o video de 9 minutos repetir tres vezes a toa (52% de tempo
        // coberto contra 96% de alcance).
        let fala = [0.0...1.0, 2.0...3.0, 4.0...5.0, 6.0...7.0]
        expect(WhisperTranscriber.reached(fala, by: []) == 0,
               "passada vazia nao alcanca nada")
        expect(WhisperTranscriber.reached([], by: []) == 1,
               "sem trecho de fala, nao ha o que alcancar")
        expect(WhisperTranscriber.reached(fala, by: [
            .init(text: "a", start: 0.2, end: 0.5), .init(text: "b", start: 4.1, end: 4.9),
        ]) == 0.5, "dois de quatro trechos alcancados sao 50%")
        expect(WhisperTranscriber.reached(fala, by: [
            .init(text: "x", start: 1.2, end: 1.8),
        ]) == 0, "texto que cai no silencio nao alcanca trecho nenhum")
        expect(WhisperTranscriber.reached(fala, by: [
            .init(text: "tudo", start: 0, end: 7),
        ]) == 1, "um trecho longo alcanca todos")
        expect(WhisperTranscriber.maximumAttempts >= 2 && WhisperTranscriber.maximumAttempts <= 4,
               "o teto de tentativas fica entre 2 e 4")
        expect(WhisperTranscriber.coverageFloor > 0.5 && WhisperTranscriber.coverageFloor < 1,
               "o piso de alcance fica entre 50% e 100%")

        // A retentativa do Neural Engine: uma falha e recuperada, duas sobem,
        // e cancelamento nao e retentado.
        struct Falhou: Error {}
        var tentativas = 0
        let recuperado = try? await AneRetry.once { isRetry -> String in
            tentativas += 1
            if !isRetry { throw Falhou() }
            return "ok"
        }
        expect(recuperado == "ok" && tentativas == 2,
               "uma falha no Neural Engine e recuperada na segunda tentativa")

        var insistentes = 0
        let semSucesso = try? await AneRetry.once { _ -> String in
            insistentes += 1
            throw Falhou()
        }
        expect(semSucesso == nil && insistentes == 2,
               "duas falhas seguidas sobem o erro, sem terceira tentativa")

        var cancelou = 0
        let cancelado = try? await AneRetry.once { _ -> String in
            cancelou += 1
            throw CancellationError()
        }
        expect(cancelado == nil && cancelou == 1,
               "cancelamento nao e retentado")

        // Escolha do usuario mandando: nada de um motor virar outro pelas
        // costas, exceto a rede de seguranca do idioma nao coberto.
        expect(TranscriberKind(for: .portuguese, engine: .parakeet) == .parakeet,
               "Parakeet escolhido roda no portugues")
        expect(TranscriberKind(for: .portuguese, engine: .whisper) == .whisper,
               "Whisper escolhido roda no portugues, sem virar Parakeet")
        expect(TranscriberKind(for: .japanese, engine: .parakeet) == .whisper,
               "Parakeet com idioma que ele nao cobre cai no Whisper")
        expect(TranscriberKind(for: .english, engine: .apple) == .apple,
               "Apple escolhida vale para ingles")

        print("")
        print(failures == 0 ? "PASSOU" : "\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Quebra de linha, sem modelo

    static func lineBreakGate() {
        // O contador nasce aqui, e nao no meio: as sondas de tres linhas
        // imprimiam FALHA sem mexer nele, e o gate saia com codigo 0 mesmo
        // reprovando. Auditoria de 12/09/2026.
        failures = 0
        // A legenda de tres linhas que escapou para o arquivo em 12/09/2026,
        // no video de 9 minutos. Aqui, isolada, `enforceLineLimit` reparte
        // como deve — o defeito esta no caminho, nao nesta funcao, e isto fica
        // como rede para o dia em que a funcao tambem parar de repartir.
        let teimosa = "Depois, desculpe, como você faz os músculos triângulos? Eu não entendo muito bem."
        let sonda = SubtitleFileBuilder()
        let quebrada = LineBreaker.wrap(teimosa, maximum: 42)
        print("sonda da legenda de tres linhas (\(teimosa.count) caracteres)")
        print("  wrap devolve \(quebrada.count) linhas: \(quebrada.map { "[\($0.count)]" }.joined(separator: " "))")
        let repartida = sonda.enforceLineLimit([
            Cue(index: 1, start: 10, end: 14, source: "", translated: teimosa)
        ])
        print("  enforceLineLimit devolve \(repartida.count) legenda(s)")
        // O caso real, que era a causa: uma legenda de 159 caracteres virava
        // duas de ~80, e a segunda saía com tres linhas. A conta por
        // caracteres supunha que toda linha chega aos 42; ela nao chega.
        let longa = "Não, tudo bem, tudo bem, estou realmente vindo, então estou um pouco "
            + "à frente. Depois, desculpe, como você faz os músculos triângulos? "
            + "Eu não entendo muito bem."
        let partes = sonda.enforceLineLimit([
            Cue(index: 1, start: 10, end: 20, source: "", translated: longa)
        ])
        print("  legenda de \(longa.count) caracteres → \(partes.count) legendas")
        var maiorParte = 0
        for cue in partes {
            let linhas = LineBreaker.wrap(cue.translated, maximum: 42)
            maiorParte = max(maiorParte, linhas.count)
            print("    \(linhas.count) linha(s): \(cue.translated)")
        }
        if maiorParte > 2 {
            print("  FALHA a reparticao deixou uma parte com \(maiorParte) linhas")
            failures += 1
        }

        var sondaFalhou = false
        for cue in repartida {
            let linhas = LineBreaker.wrap(cue.translated, maximum: 42)
            print("    \(linhas.count) linha(s): \(cue.translated)")
            if linhas.count > 2 { sondaFalhou = true }
        }
        if repartida.count < 2 || sondaFalhou {
            print("  FALHA enforceLineLimit deixou passar legenda de tres linhas")
            failures += 1
        }
        print("")

        let cases = [
            "esse número não é definitivo, ainda podemos reduzi-lo bastante se cortarmos a segunda fase do projeto",
            "curto",
            "uma frase sem nenhuma pontuação que precisa ser quebrada mesmo assim porque passa do limite de caracteres",
            "Maria é nossa engenheira principal na equipe de pagamentos. Ela passou o último mês escrevendo a lógica de tentativa. A engenheira nos explicou todos os casos extremos.",
        ]
        for text in cases {
            let lines = LineBreaker.wrap(text, maximum: 58)
            print("\"\(text.prefix(40))...\"")
            for line in lines { print("  | \(line)  (\(line.count))") }
            if lines.contains(where: { $0.count > 66 }) {
                print("  FALHA: linha longa demais")
                failures += 1
            }

            if lines.joined(separator: " ").replacingOccurrences(of: "  ", with: " ").count
                < text.count - 4 {
                print("  FALHA: perdeu texto na quebra")
                failures += 1
            }
            print("")
        }

        // Texto que cabe em duas linhas tem que sair em duas. A virgula mais
        // a esquerda ganhava sempre, e este saia em quatro, comecando por
        // "japoneses," — uma legenda de tres linhas cobre o video.
        let cabeEmDuas = "japoneses, os vegetais e frutas são geralmente vendidos em pacotes."
        let linhas = LineBreaker.wrap(cabeEmDuas, maximum: 42)
        for line in linhas { print("  | \(line)  (\(line.count))") }
        if linhas.count > 2 || linhas.contains(where: { $0.count > 42 }) {
            print("  FALHA: 67 caracteres cabem em duas linhas de 42, sairam \(linhas.count)")
            failures += 1
        }
        print("")

        // Maiuscula no comeco de frase, que o tradutor nao devolve.
        print("")
        print("maiuscula de comeco de frase")
        func cue(_ text: String) -> Cue {
            Cue(index: 0, start: 0, end: 1, source: "", translated: text)
        }
        let capitalizadas = SubtitleFileBuilder.capitalizeSentences([
            cue("bom dia."),
            cue("você é novo aqui?"),
            cue("essa frase foi cortada no meio,"),
            cue("e continua aqui."),
            cue("Já vem com maiuscula."),
            cue(""),
            cue("depois da vazia."),
        ]).map(\.translated)
        expect(capitalizadas[0] == "Bom dia.", "a primeira legenda comeca com maiuscula")
        expect(capitalizadas[1] == "Você é novo aqui?", "depois de ponto, maiuscula")
        expect(capitalizadas[2] == "Essa frase foi cortada no meio,", "comeco de frase apos '?' sobe")
        expect(capitalizadas[3] == "e continua aqui.",
               "metade de frase partida continua minuscula")
        expect(capitalizadas[4] == "Já vem com maiuscula.", "o que ja estava certo nao muda")
        expect(capitalizadas[5].isEmpty, "legenda vazia nao quebra a conta")
        expect(capitalizadas[6] == "Depois da vazia.", "legenda vazia nao engole a frase seguinte")

        // O travessao entra na renderizacao, DEPOIS da reparticao, e ocupa
        // duas colunas. Medir sem ele deixava passar legenda de tres linhas no
        // arquivo — job-en-dialogo-whisper-sortformer, legenda 30, em
        // 12/09/2026. Aqui: corpo que cabe em duas linhas, troca de locutor.
        print("")
        print("travessao de troca de locutor")
        let corpo = Array(repeating: "teste", count: 14).joined(separator: " ")
        let comTroca = sonda.enforceLineLimit([
            Cue(index: 1, start: 0, end: 3, source: "", translated: "Antes.",
                speaker: "Locutor 1"),
            Cue(index: 2, start: 3, end: 9, source: "", translated: corpo,
                speaker: "Locutor 2"),
        ])
        let renderizado = SRTWriter.render(comTroca)
        var maiorNoArquivo = 0
        for bloco in renderizado.components(separatedBy: "\n\n") {
            let linhas = bloco.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard linhas.count > 2 else { continue }
            maiorNoArquivo = max(maiorNoArquivo, linhas.count - 2)
        }
        expect(LineBreaker.wrap(corpo, maximum: 42).count == 2,
               "o corpo sozinho cabe em duas linhas")
        expect(maiorNoArquivo <= 2,
               "com travessao o SRT continua em duas linhas (deu \(maiorNoArquivo))")

        // Repartir nao muda quem fala: sem isto a legenda longa identificada
        // virava varias sem dono, sem cor na janela e sem travessao no arquivo.
        let longaDeAlguem = Cue(
            index: 1, start: 0, end: 12, source: "",
            translated: "Não, tudo bem, tudo bem, estou realmente vindo, então estou um pouco "
                + "à frente. Depois, desculpe, como você faz os músculos triângulos? "
                + "Eu não entendo muito bem.",
            speaker: "Locutor 2"
        )
        let partesDoLocutor = sonda.enforceLineLimit([longaDeAlguem])
        expect(partesDoLocutor.count > 1,
               "a legenda longa e repartida (deu \(partesDoLocutor.count))")
        expect(partesDoLocutor.allSatisfy { $0.speaker == "Locutor 2" },
               "todas as partes continuam do mesmo locutor "
               + "(\(partesDoLocutor.filter { $0.speaker != nil }.count) de \(partesDoLocutor.count))")
        // E uma parte so leva travessao: o resto e a mesma pessoa falando.
        let travessoes = SRTWriter.render(partesDoLocutor)
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix(SpeakerMark.dash) }
            .count
        expect(travessoes == 1, "so a primeira parte leva travessao (deu \(travessoes))")

        print("")
        print(failures == 0 ? "quebra de linha ok" : "\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    static func load16kMono(path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else { return nil }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              )
        else { return nil }
        try? file.read(into: input)

        let ratio = 16_000 / file.processingFormat.sampleRate
        guard let output = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        ) else { return nil }

        var done = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// A régua vem do PCM original: tratar o áudio não pode mudar o denominador.
struct MeasurementAudio {
    let original: [Float]
    let samples: [Float]
    let referencePath: String
    var regions: [ClosedRange<Double>] { SpeechEnergy.regions(original, minimumPause: 0.5) }
    var hash: String { original.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() } }

    static func load(_ url: URL, language: Language, reference: URL? = nil) async throws -> Self {
        let raw = try await SubtitleFileBuilder.extractAudio(from: url, preferring: language, processing: false)
        let referenceURL = reference ?? url
        let original = referenceURL == url ? raw : try await SubtitleFileBuilder.extractAudio(
            from: referenceURL, preferring: language, processing: false)
        guard original.count == raw.count else {
            throw NSError(domain: "medição", code: 1, userInfo: [NSLocalizedDescriptionKey: "A referência e o áudio medido precisam ter a mesma duração."])
        }
        return Self(original: original, samples: SubtitleFileBuilder.prepareAudio(raw), referencePath: referenceURL.path)
    }

    var description: String {
        "referência: PCM original, sem ganho nem nivelamento · \(referencePath) · SHA256 \(hash)"
    }
}

struct VoiceReference: Codable {
    struct Interval: Codable {
        let speaker: String
        let start: Double
        let end: Double
        var turn: SpeakerDiarizer.Turn { .init(speaker: speaker, start: start, end: end) }
    }
    let hash: String
    let path: String
    let model: String
    let intervals: [Interval]

    static func load(_ audio: MeasurementAudio, cache: URL?) async throws -> Self {
        if let cache, FileManager.default.fileExists(atPath: cache.path) {
            let saved = try JSONDecoder().decode(Self.self, from: Data(contentsOf: cache))
            guard saved.hash == audio.hash, saved.model == "sortformer" else {
                throw NSError(domain: "medição", code: 2, userInfo: [NSLocalizedDescriptionKey: "As faixas salvas pertencem a outro áudio ou modelo."])
            }
            guard saved.intervals.allSatisfy({
                !$0.speaker.isEmpty && $0.start.isFinite && $0.end.isFinite
                    && $0.start >= 0 && $0.end > $0.start
                    && $0.end <= Double(audio.original.count) / 16_000
            }) else {
                throw NSError(domain: "medição", code: 3, userInfo: [NSLocalizedDescriptionKey: "A referência contém faixas inválidas ou fora do áudio."])
            }
            return saved
        }
        // Mesmo PCM não garante a mesma diarização em duas inferências. O
        // arquivo de referência congela também as faixas e seus identificadores.
        let turns = try await SpeakerDiarizer.turns(in: audio.original, model: .sortformer)
        // O Sortformer trabalha em blocos e a última faixa costuma passar do
        // fim do áudio. Sem aparar aqui, o arquivo gravado é recusado pela
        // validação de cima na execução seguinte — a guarda disparava contra o
        // dado que ela mesma tinha acabado de gravar.
        let duration = Double(audio.original.count) / 16_000
        let reference = Self(hash: audio.hash, path: audio.referencePath, model: "sortformer",
                             intervals: turns.compactMap {
                                 let end = min($0.end, duration)
                                 guard end > $0.start else { return nil }
                                 return Interval(speaker: $0.speaker, start: $0.start, end: end)
                             })
        if let cache { try JSONEncoder().encode(reference).write(to: cache, options: .atomic) }
        return reference
    }
}

struct VoiceCoverage: Codable {
    let speaker: String
    let speechSeconds: Double
    let recognizedSeconds: Double
    let pieces: Int
    let characters: Int
    let firstSecond: Double

    /// União, não soma: sobreposições da mesma voz não aumentam o denominador.
    static func duration(_ ranges: [ClosedRange<Double>]) -> Double {
        var end = -Double.infinity
        var total = 0.0
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            total += max(0, range.upperBound - max(end, range.lowerBound))
            end = max(end, range.upperBound)
        }
        return total
    }

    static func measure(_ pieces: [TimedText], turns: [SpeakerDiarizer.Turn]) -> [Self] {
        let assigned = SpeakerDiarizer.assign(pieces, to: turns)
        let names = Set(turns.map(\.speaker)).sorted()
        return names.map { name in
            let voice = turns.filter { $0.speaker == name }
            let recognized = assigned.filter { $0.speaker == name }
            let covered = voice.flatMap { turn in
                recognized.compactMap { piece -> ClosedRange<Double>? in
                    let start = max(turn.start, piece.start), end = min(turn.end, piece.end)
                    return end > start ? start...end : nil
                }
            }
            return Self(speaker: name,
                        speechSeconds: duration(voice.map { $0.start...$0.end }),
                        recognizedSeconds: duration(covered), pieces: recognized.count,
                        characters: recognized.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count },
                        firstSecond: voice.map(\.start).min() ?? 0)
        }.sorted { $0.firstSecond == $1.firstSecond ? $0.speaker < $1.speaker : $0.firstSecond < $1.firstSecond }
    }
}

extension Verify {
    static func coverageGate(path: String, language: Language, engine: RecognitionEngine,
                             referencePath: String?, cachePath: String?, jsonPath: String?) async {
        do {
            let audio = try await MeasurementAudio.load(URL(fileURLWithPath: path), language: language,
                                                       reference: referencePath.map { URL(fileURLWithPath: $0) })
            let reference = try await VoiceReference.load(audio, cache: cachePath.map { URL(fileURLWithPath: $0) })
            var turns = reference.intervals.map(\.turn)
            if ProcessInfo.processInfo.environment["TRADUTOR_SEM_FUSAO"] == nil {
                let limiar = ProcessInfo.processInfo.environment["TRADUTOR_FUSAO_LIMIAR"]
                    .flatMap(Float.init) ?? SpeakerDiarizer.sameVoiceThreshold
                let antes = Set(turns.map(\.speaker)).count
                turns = (try? await SpeakerDiarizer.mergeSameVoice(
                    turns, in: audio.original, threshold: limiar)) ?? turns
                print("fusão de vozes: \(antes) identificadores → \(Set(turns.map(\.speaker)).count) (limiar \(limiar))")
            }
            let transcriber = TranscriberFactory.make(for: language, engine: engine)
            try await transcriber.prepare { _, _ in }
            // A mesma fronteira nas duas pontas evita atribuir um bloco com
            // duas pessoas inteiro a quem só falou por mais tempo.
            transcriber.speakerBoundaries = SpeakerDiarizer.boundaries(of: turns)
            let pieces = try await transcriber.transcribeForSubtitles(audio.samples) { _ in }
            let rows = VoiceCoverage.measure(pieces, turns: turns)
            print(audio.description)
            print("motor: \(transcriber.engineName) · referência de vozes: Sortformer · nivelamento: \(ProcessInfo.processInfo.environment["TRADUTOR_SEM_NIVELAMENTO"] == nil ? "ligado" : "desligado")")
            print("locutor | primeira fala | voz (s) | reconhecido (s) | trechos | caracteres sem espaços")
            for row in rows {
                print(String(format: "%@ | %.2f | %.2f | %.2f | %d | %d", row.speaker, row.firstSecond,
                             row.speechSeconds, row.recognizedSeconds, row.pieces, row.characters))
            }
            let assigned = SpeakerDiarizer.assign(pieces, to: turns)
            let missing = assigned.filter { $0.speaker == nil }
            print("sem locutor: \(missing.count) trechos · \(missing.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count }) caracteres")
            print("Contagem de trechos/caracteres não mede acurácia nem identifica gênero.")
            if let jsonPath {
                struct Report: Encodable {
                    let reference: VoiceReference
                    let rows: [VoiceCoverage]
                    let engine: String
                    let leveling: Bool
                    let pieces: [VoiceReference.Interval]
                    let texts: [String]
                }
                let report = Report(reference: reference, rows: rows, engine: transcriber.engineName,
                                    leveling: ProcessInfo.processInfo.environment["TRADUTOR_SEM_NIVELAMENTO"] == nil,
                                    pieces: assigned.map { .init(speaker: $0.speaker ?? "sem locutor", start: $0.start, end: $0.end) },
                                    texts: assigned.map(\.text))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: URL(fileURLWithPath: jsonPath), options: .atomic)
            }
        } catch { print("FALHA: \(error.localizedDescription)"); exit(1) }
    }

    /// Sem modelos: prova a atribuição e que a régua não recebe nivelamento.
    static func coverageSelftest() async {
        failures = 0
        let turns: [SpeakerDiarizer.Turn] = [.init(speaker: "A", start: 0, end: 1),
            .init(speaker: "B", start: 1, end: 2), .init(speaker: "A", start: 2, end: 3),
            .init(speaker: "A", start: 0.5, end: 0.8)]
        let rows = VoiceCoverage.measure([.init(text: "あ い", start: 0, end: 0.9),
            .init(text: "うえお", start: 1, end: 2), .init(text: "外", start: 4, end: 5)], turns: turns)
        expect(rows.count == 2 && rows[0].speechSeconds == 2 && rows[1].speechSeconds == 1, "denominador por voz une faixas sobrepostas")
        expect(rows[0].pieces == 1 && rows[0].characters == 2 && rows[1].characters == 3, "caracteres são atribuídos uma vez, sem contar espaços")
        expect(abs(rows[0].recognizedSeconds - 0.9) < 0.001, "cobertura temporal não conta duas vezes")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("regua-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("alternado.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160000)!
            pcm.frameLength = 160000
            for i in 0..<160000 {
                let amplitude: Float = (i / 32000) % 2 == 0 ? 0.2 : 0.002
                pcm.floatChannelData![0][i] = i % 8000 < 1200 ? 0 : amplitude * Float(sin(2 * .pi * 220 * Double(i) / 16000))
            }
            func save() throws {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: pcm)
            }
            try save()
            let raw = Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: 160000))
            let audio = try await MeasurementAudio.load(url, language: .japanese)
            expect(audio.original == raw, "referência contém as amostras originais, sem ganho nem nivelamento")
            expect(audio.regions == SpeechEnergy.regions(raw, minimumPause: 0.5), "regiões e denominador vêm do áudio original")
            expect(audio.samples != raw && audio.regions != SpeechEnergy.regions(audio.samples, minimumPause: 0.5), "o caso exercita o denominador que mudava com o nivelamento")
            // A segunda execução precisa reutilizar as mesmas faixas, sem
            // chamar o modelo de novo e deixar seus rótulos oscilarem.
            let cache = directory.appendingPathComponent("vozes.json")
            let reference = VoiceReference(hash: audio.hash, path: url.path, model: "sortformer",
                                           intervals: [.init(speaker: "A", start: 1, end: 2)])
            try JSONEncoder().encode(reference).write(to: cache)
            let saved = try await VoiceReference.load(audio, cache: cache)
            expect(saved.intervals.count == 1 && saved.intervals[0].speaker == "A"
                   && saved.intervals[0].start == 1 && saved.intervals[0].end == 2,
                   "a referência salva congela faixas e identificadores")
            let other = MeasurementAudio(original: [Float](repeating: 0, count: raw.count),
                                         samples: raw, referencePath: url.path)
            do {
                _ = try await VoiceReference.load(other, cache: cache)
                expect(false, "referência de outro PCM é recusada")
            } catch { expect(true, "referência de outro PCM é recusada") }
            let invalid = VoiceReference(hash: audio.hash, path: url.path, model: "sortformer",
                                         intervals: [.init(speaker: "A", start: 2, end: 1)])
            try JSONEncoder().encode(invalid).write(to: cache)
            do {
                _ = try await VoiceReference.load(audio, cache: cache)
                expect(false, "faixa invertida é recusada antes da medição")
            } catch { expect(true, "faixa invertida é recusada antes da medição") }
        } catch { expect(false, error.localizedDescription) }
        exit(failures == 0 ? 0 : 1)
    }
}

// MARK: - Contra uma legenda de referencia

/// A legenda gerada contra uma legenda feita por gente, do mesmo vídeo.
///
/// Nasceu da palestra TEDxWasedaU (16 min, japonês, legenda oficial do TED):
/// medir se o que sai do app chega perto do que um legendador escreve —
/// texto, onde a frase quebra e quando a legenda entra.
///
/// O texto é comparado **sem pontuação nem espaço**: a legenda do TED em
/// japonês separa oração com espaço e não usa `。`, e o app escreve `。` e
/// `、`. Essa diferença é convenção, não erro, e entra na conta das
/// fronteiras, não na do texto.
extension Verify {

    /// Um caractere comparável e o que vem depois dele.
    struct RefChar {
        var char: Character
        /// Instante estimado, interpolado dentro da legenda.
        var time: Double
        /// Depois dele há espaço ou pontuação: fim de oração.
        var clauseEnd = false
        /// Último caractere da legenda.
        var cueEnd = false
        /// Primeiro caractere da legenda.
        var cueStart = false
    }

    static let boundaryMarks: Set<Character> = [
        " ", "　", "。", "、", "，", "．", "？", "！", "?", "!", ".", ",", "…", "・", "—", "〜", "～",
    ]

    /// Os caracteres comparáveis de um texto, marcando as fronteiras.
    static func referenceChars(_ cues: [(start: Double, end: Double, text: String)]) -> [RefChar] {
        var all: [RefChar] = []
        for cue in cues {
            let text = cue.text.precomposedStringWithCompatibilityMapping.lowercased()
            var chars: [RefChar] = []
            for character in text {
                if character.isLetter || character.isNumber {
                    chars.append(RefChar(char: character, time: 0))
                } else if boundaryMarks.contains(character) || character.isWhitespace, !chars.isEmpty {
                    chars[chars.count - 1].clauseEnd = true
                }
            }
            guard !chars.isEmpty else { continue }
            for index in chars.indices {
                chars[index].time = cue.start + (cue.end - cue.start) * (Double(index) + 0.5) / Double(chars.count)
            }
            chars[0].cueStart = true
            chars[chars.count - 1].cueEnd = true
            // Fim de legenda também é fim de oração.
            chars[chars.count - 1].clauseEnd = true
            all += chars
        }
        return all
    }

    enum EditOp: UInt8 { case match, substitute, delete, insert }

    /// Alinhamento por distância de edição, com o caminho.
    ///
    /// - Returns: para cada caractere da referência, o índice do caractere
    ///   da hipótese com que foi casado (igual ou trocado), e as contagens.
    static func align(_ ref: [Character], _ hyp: [Character])
        -> (map: [Int?], hits: Int, subs: Int, dels: Int, ins: Int, insertions: [Int])
    {
        let n = ref.count, m = hyp.count
        var previous = [Int](0...m)
        var current = [Int](repeating: 0, count: m + 1)
        var trace = [UInt8](repeating: 0, count: (n + 1) * (m + 1))
        for j in 1...max(m, 1) where j <= m { trace[j] = EditOp.insert.rawValue }
        for i in 1...max(n, 1) where i <= n {
            current[0] = i
            trace[i * (m + 1)] = EditOp.delete.rawValue
            for j in stride(from: 1, through: m, by: 1) {
                let same = ref[i - 1] == hyp[j - 1]
                let diagonal = previous[j - 1] + (same ? 0 : 1)
                let up = previous[j] + 1
                let left = current[j - 1] + 1
                if diagonal <= up && diagonal <= left {
                    current[j] = diagonal
                    trace[i * (m + 1) + j] = (same ? EditOp.match : EditOp.substitute).rawValue
                } else if up <= left {
                    current[j] = up
                    trace[i * (m + 1) + j] = EditOp.delete.rawValue
                } else {
                    current[j] = left
                    trace[i * (m + 1) + j] = EditOp.insert.rawValue
                }
            }
            swap(&previous, &current)
        }
        var map = [Int?](repeating: nil, count: n)
        var hits = 0, subs = 0, dels = 0, ins = 0
        var insertions: [Int] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            switch EditOp(rawValue: trace[i * (m + 1) + j])! {
            case .match: map[i - 1] = j - 1; hits += 1; i -= 1; j -= 1
            case .substitute: map[i - 1] = j - 1; subs += 1; i -= 1; j -= 1
            case .delete: dels += 1; i -= 1
            case .insert: ins += 1; insertions.append(j - 1); j -= 1
            }
        }
        return (map, hits, subs, dels, ins, insertions.reversed())
    }

    /// Precisão e cobertura de fronteiras: a da hipótese casa com a da
    /// referência quando cai a até `slack` caracteres do lugar alinhado.
    static func boundaryScore(ref: [RefChar], hyp: [RefChar], map: [Int?],
                              refIs: (RefChar) -> Bool, hypIs: (RefChar) -> Bool,
                              slack: Int = 2) -> (precision: Double, recall: Double, refCount: Int, hypCount: Int) {
        let hypBoundaries = hyp.indices.filter { hypIs(hyp[$0]) }
        let hypSet = Set(hypBoundaries)
        var mapped: [Int] = []
        for index in ref.indices where refIs(ref[index]) {
            // O caractere pode ter sido apagado: vale o último casado antes.
            var k = index
            while k >= 0, map[k] == nil { k -= 1 }
            if k >= 0, let j = map[k] { mapped.append(j) }
        }
        let recallHits = mapped.filter { j in (j - slack...j + slack).contains { hypSet.contains($0) } }.count
        let mappedSet = Set(mapped)
        let precisionHits = hypBoundaries.filter { j in (j - slack...j + slack).contains { mappedSet.contains($0) } }.count
        return (Double(precisionHits) / Double(max(hypBoundaries.count, 1)),
                Double(recallHits) / Double(max(mapped.count, 1)),
                mapped.count, hypBoundaries.count)
    }

    static func unionLength(_ intervals: [(Double, Double)]) -> Double {
        var total = 0.0
        var current: (Double, Double)?
        for interval in intervals.sorted(by: { $0.0 < $1.0 }) {
            if let open = current, interval.0 <= open.1 {
                current = (open.0, max(open.1, interval.1))
            } else {
                if let open = current { total += open.1 - open.0 }
                current = interval
            }
        }
        if let open = current { total += open.1 - open.0 }
        return total
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    struct ReferenceReport: Codable {
        var engine: String
        var seconds: Double
        var referenceChars: Int
        var hypothesisChars: Int
        var cer: Double
        var substitutions: Int
        var deletions: Int
        var insertions: Int
        var clausePrecision: Double
        var clauseRecall: Double
        var cuePrecision: Double
        var cueRecall: Double
        var timeRecall: Double
        var timePrecision: Double
        var medianOffset: Double
        var within500ms: Double
        var cueStartMedian: Double
        var cues: Int
        var referenceCues: Int
        var medianCueChars: Double
        var maxCueChars: Int
        var medianCueSeconds: Double
    }

    /// Compara uma legenda com a de referência e imprime a conta.
    static func compareWithReference(hypothesis: [Cue], reference: [Cue], label: String, seconds: Double,
                                     showDiff: Bool, rawLines: String? = nil) -> ReferenceReport {
        // A linha de crédito do legendador não é fala.
        let refCues = reference.filter { !$0.translated.contains("字幕:") && !$0.translated.contains("校正:") }
            .map { (start: $0.start, end: $0.end, text: $0.translated) }
        let hypCues = hypothesis.map {
            (start: $0.start, end: $0.end,
             text: ($0.translated.isEmpty ? $0.source : $0.translated).replacingOccurrences(of: "\n", with: ""))
        }
        let ref = referenceChars(refCues)
        let hyp = referenceChars(hypCues)
        let result = align(ref.map(\.char), hyp.map(\.char))
        let errors = result.subs + result.dels + result.ins
        let cer = Double(errors) / Double(max(ref.count, 1))

        // Pela leitura: `喋る` e `しゃべる`, `良い` e `いい` são a mesma
        // palavra escrita de outro jeito, e o CER acima conta isso como erro.
        let readingRef = reading(refCues.map(\.text).joined(separator: " "))
        let readingHyp = reading(hypCues.map(\.text).joined(separator: " "))
        let readingAlign = align(readingRef, readingHyp)
        let readingCER = Double(readingAlign.subs + readingAlign.dels + readingAlign.ins) / Double(max(readingRef.count, 1))
        let clause = boundaryScore(ref: ref, hyp: hyp, map: result.map, refIs: \.clauseEnd, hypIs: \.clauseEnd)
        let cue = boundaryScore(ref: ref, hyp: hyp, map: result.map, refIs: \.cueEnd, hypIs: \.cueEnd)

        // Tempo: onde a hipótese põe cada caractere casado.
        var offsets: [Double] = []
        var startOffsets: [Double] = []
        for (index, match) in result.map.enumerated() {
            guard let j = match, ref[index].char == hyp[j].char else { continue }
            offsets.append(hyp[j].time - ref[index].time)
        }
        // Começo de legenda: a legenda da hipótese que contém o 1º caractere
        // casado da legenda de referência.
        var hypCueOf = [Int](repeating: 0, count: hyp.count)
        var hypCueStarts: [Double] = []
        var cueIndex = -1
        for (index, char) in hyp.enumerated() {
            if char.cueStart { cueIndex += 1 }
            hypCueOf[index] = cueIndex
        }
        for cue in hypCues where referenceChars([cue]).count > 0 { hypCueStarts.append(cue.start) }
        var refCueIndex = -1
        let refCuesWithText = refCues.filter { referenceChars([$0]).count > 0 }
        for (index, char) in ref.enumerated() where char.cueStart {
            refCueIndex += 1
            guard let j = result.map[index], hyp[j].cueStart, hypCueOf[j] < hypCueStarts.count else { continue }
            startOffsets.append(hypCueStarts[hypCueOf[j]] - refCuesWithText[refCueIndex].start)
        }

        let refUnion = unionLength(refCues.map { ($0.start, $0.end) })
        let hypUnion = unionLength(hypCues.map { ($0.start, $0.end) })
        let both = unionLength(refCues.map { ($0.start, $0.end) }) + unionLength(hypCues.map { ($0.start, $0.end) })
            - unionLength(refCues.map { ($0.start, $0.end) } + hypCues.map { ($0.start, $0.end) })

        let lengths = hypCues.map { referenceChars([$0]).count }
        let report = ReferenceReport(
            engine: label, seconds: seconds,
            referenceChars: ref.count, hypothesisChars: hyp.count, cer: cer,
            substitutions: result.subs, deletions: result.dels, insertions: result.ins,
            clausePrecision: clause.precision, clauseRecall: clause.recall,
            cuePrecision: cue.precision, cueRecall: cue.recall,
            timeRecall: both / max(refUnion, 0.001), timePrecision: both / max(hypUnion, 0.001),
            medianOffset: median(offsets),
            within500ms: Double(offsets.filter { abs($0) <= 0.5 }.count) / Double(max(offsets.count, 1)),
            cueStartMedian: median(startOffsets),
            cues: hypCues.count, referenceCues: refCues.count,
            medianCueChars: median(lengths.map(Double.init)), maxCueChars: lengths.max() ?? 0,
            medianCueSeconds: median(hypCues.map { $0.end - $0.start })
        )

        print("\n== \(label) ==")
        print(String(format: "texto        CER %.1f%%  (%d trocas, %d faltando, %d a mais; ref %d, hip %d caracteres)",
                     cer * 100, result.subs, result.dels, result.ins, ref.count, hyp.count))
        print(String(format: "leitura      CER %.1f%% (romaji: a diferenca de escrita kanji/kana nao conta)", readingCER * 100))
        print(String(format: "oracao       precisao %.0f%%  cobertura %.0f%%  (ref %d, hip %d fronteiras)",
                     clause.precision * 100, clause.recall * 100, clause.refCount, clause.hypCount))
        print(String(format: "legenda      precisao %.0f%%  cobertura %.0f%%  (ref %d, hip %d legendas)",
                     cue.precision * 100, cue.recall * 100, refCues.count, hypCues.count))
        print(String(format: "tempo        voz coberta %.0f%%, legenda sobre voz %.0f%%, desvio mediano %+.2fs, %.0f%% a 0,5s, inicio %+.2fs (%d)",
                     report.timeRecall * 100, report.timePrecision * 100, report.medianOffset,
                     report.within500ms * 100, report.cueStartMedian, startOffsets.count))
        print(String(format: "tamanho      mediana %.0f caracteres (max %d), %.1fs",
                     report.medianCueChars, report.maxCueChars, report.medianCueSeconds))

        let (cortesLegenda, _, costuras) = splitWordCount(hypothesis)
        let (refLegenda, _, refCosturas) = splitWordCount(reference)
        let cortesLinha = rawLines.map(lineSplitCount) ?? 0
        print(String(format: "palavra      partida entre legendas %d de %d, entre linhas %d (referencia: %d de %d)",
                     cortesLegenda, costuras, cortesLinha, refLegenda, refCosturas))

        if showDiff {
            // Os trechos a mais e a menos mais frequentes: é onde a
            // hesitação ("えー", "あの") e a troca de escrita aparecem.
            var extra: [String: Int] = [:]
            var run = ""
            var last = -2
            for j in result.insertions {
                if j == last + 1 { run.append(hyp[j].char) } else {
                    if !run.isEmpty { extra[run, default: 0] += 1 }
                    run = String(hyp[j].char)
                }
                last = j
            }
            if !run.isEmpty { extra[run, default: 0] += 1 }
            let top = extra.sorted { $0.value * $0.key.count > $1.value * $1.key.count }.prefix(15)
            print("a mais (hipotese): " + top.map { "\($0.key)×\($0.value)" }.joined(separator: " "))
            var missing: [String: Int] = [:]
            run = ""
            var previousMissing = -2
            for index in ref.indices where result.map[index] == nil {
                if index == previousMissing + 1 { run.append(ref[index].char) } else {
                    if !run.isEmpty { missing[run, default: 0] += 1 }
                    run = String(ref[index].char)
                }
                previousMissing = index
            }
            if !run.isEmpty { missing[run, default: 0] += 1 }
            let topMissing = missing.sorted { $0.value * $0.key.count > $1.value * $1.key.count }.prefix(15)
            print("faltando (ref):    " + topMissing.map { "\($0.key)×\($0.value)" }.joined(separator: " "))
        }
        return report
    }

    /// O que a palestra do TEDxWasedaU ensinou sobre legenda japonesa, sem
    /// modelo nem áudio: cada caso é um defeito que saiu no `.srt` dela.
    static func japaneseSubtitleGate() {
        failures = 0
        print("pedacos de palavra\n")
        let frase = "私はこのようにカメラの前で一人でブツブツ陰気に喋るという"
        expect(Tokens.phrases(frase).joined() == frase, "os pedacos somam o texto exato")
        expect(!Tokens.phrases(frase).contains { $0.hasPrefix("を") || $0.hasPrefix("に") || $0.hasPrefix("て") },
               "particula nao abre pedaco (\(Tokens.phrases(frase).joined(separator: "|")))")
        expect(Tokens.phrases("このテッドックスに関して").contains("テッドックスに"),
               "katakana seguido e uma palavra so (\(Tokens.phrases("このテッドックスに関して").joined(separator: "|")))")
        expect(Tokens.phrases("今回はTED Talksそのもの").contains { $0.hasPrefix("TED Talks") },
               "nome latino com espaco fica inteiro")
        expect(Tokens.phrases("ことをお話ししてみたい").contains { $0.hasPrefix("お話し") },
               "o prefixo de cortesia vai com a palavra seguinte")
        expect(Tokens.phrases("権力をカバにしてやがる。").contains { $0.hasSuffix("してやがる。") },
               "auxiliar depois de te nao abre pedaco (\(Tokens.phrases("権力をカバにしてやがる。").joined(separator: "|")))")

        print("\nquebra de linha em 20\n")
        for texto in [
            "楽しそうに、そしてすごくいい話をするとそういうイメージがあるかもしれません。",
            "まあもともと私はちょっとこのテッドックスに関して気になることはあったので、",
            "つまり言ってみれば今回の挑修はTED Talksそのものです。",
            "私はこのようにカメラの前で一人でブツブツインキンに喋るというそういう設定に",
        ] {
            let linhas = LineBreaker.wrap(texto, maximum: 20)
            let partidas = zip(linhas, linhas.dropFirst()).filter { par in
                var soma = 0
                let cortes = Set(Tokens.phrases(par.0 + par.1).map { soma += $0.count; return soma })
                return !cortes.contains(par.0.count)
            }
            expect(partidas.isEmpty && linhas.allSatisfy { $0.count <= 20 },
                   "nenhuma linha parte palavra: \(linhas.joined(separator: " / "))")
        }
        let latino = "a single English line that has to wrap somewhere near here"
        let latinas = LineBreaker.wrap(latino, maximum: 20)
        expect(latinas.joined(separator: " ") == latino && latinas.allSatisfy { $0.count <= 20 },
               "texto latino continua quebrando no espaco (\(latinas.joined(separator: " / ")))")

        print("\ntrecho cortado no meio da palavra\n")
        func t(_ texto: String, _ inicio: Double, _ fim: Double) -> TimedText {
            TimedText(text: texto, start: inicio, end: fim)
        }
        let emenda = SubtitleFileBuilder.mendSplitWords([t("そういうふうに思っていま", 0, 6.9), t("す。", 7, 7.3)])
        expect(emenda.map(\.text) == ["そういうふうに思っています。"] && emenda.first?.end == 7.3,
               "o trecho que era so o fim da palavra se junta ao anterior (\(emenda.map(\.text)))")
        let ida = SubtitleFileBuilder.mendSplitWords([t("カメラの前で一人でブ", 0, 5), t("ツブツ陰気に喋る", 5, 8)])
        expect(ida.map(\.text) == ["カメラの前で一人で", "ブツブツ陰気に喋る"] && ida[0].end < 5,
               "o pedaco menor muda de lado, com o tempo junto (\(ida.map(\.text)))")
        let ingles = [t("I was thinking", 0, 1), t("about it", 1, 2)]
        expect(SubtitleFileBuilder.mendSplitWords(ingles).map(\.text) == ingles.map(\.text), "texto latino passa intacto")
        let vozes = [TimedText(text: "一人でブ", start: 0, end: 1, speaker: "A"),
                     TimedText(text: "ツブツ", start: 1, end: 2, speaker: "B")]
        let costura = SubtitleFileBuilder.mendSplitWords(vozes)
        expect(costura.map(\.text) == ["一人で", "ブツブツ"] && costura.map(\.speaker) == ["A", "B"],
               "fronteira de voz no meio da palavra: o pedaco vai com o resto dela (\(costura.map(\.text)))")
        let resto = SubtitleFileBuilder.mendSplitWords([
            TimedText(text: "何すればいいです", start: 0, end: 2, speaker: "A"),
            TimedText(text: "か。", start: 2, end: 2.3, speaker: "B")])
        expect(resto.map(\.text) == ["何すればいいですか。"] && resto.first?.speaker == "A",
               "o trecho que era so o fim da palavra fica com quem disse a palavra")

        print("\na frase vai inteira ao tradutor\n")
        let builder = SubtitleFileBuilder()
        let pecas = [t("私の父親はもともと商社に勤めていて、", 0, 3), t("長らく北米のいくつかの都市で", 3, 5.5),
                     t("勤務をしていました。", 5.5, 6.8)]
        let agrupadas = builder.makeCues(from: pecas)
        // Um teto de 40 caracteres antes da tradução foi medido e desfeito:
        // em japonês o verbo vem no fim, e a metade sem ele era traduzida
        // sozinha ("…é Ambos provavelmente"). Às cegas, 16 x 12 sem o teto.
        expect(agrupadas.count == 1, "a frase nao e partida antes de traduzir (\(agrupadas.map(\.source)))")
        builder.charactersPerLine = 20
        let repartida = builder.enforceLineLimit([Cue(index: 1, start: 0, end: 6,
            source: "私の父親はもともと商社に勤めていて、長らく北米のいくつかの都市で勤務をしていました。")])
        expect(repartida.first.map { ($0.translated.isEmpty ? $0.source : $0.translated).hasSuffix("勤めていて、") } == true,
               "a reparticao prefere a virgula perto do meio (\(repartida.map { $0.translated.isEmpty ? $0.source : $0.translated }))")

        print("\nhesitacao\n")
        for (entrada, saida) in [
            ("まあノリノリのお客さんに支えられて、", "ノリノリのお客さんに支えられて、"),
            ("その気になることをまあ今回のイベントで", "その気になることを今回のイベントで"),
            ("すけれども、あのまあ喋れと言われて", "すけれども、喋れと言われて"),
            ("あのー、えーと、それはですね。", "それはですね。"),
            ("あの人はまあまあ上手です。", "あの人はまあまあ上手です。"),
            ("人が良すぎて、まあまだまだひよっこだな", "人が良すぎて、まだまだひよっこだな"),
            ("ただあの私が勝手に喋って", "ただあの私が勝手に喋って"),
            ("ええ、そうです。", "ええ、そうです。"),
        ] {
            let got = Hesitations.stripJapanese(entrada)
            expect(got == saida, "\(entrada) -> \(got)")
        }
        for (entrada, saida) in [
            ("Um, so we started.", "So we started."),
            ("I was, uh, thinking about it.", "I was thinking about it."),
            ("Uh-huh, that's right.", "Uh-huh, that's right."),
            ("The drum sounds good.", "The drum sounds good."),
        ] {
            let got = Hesitations.stripEnglish(entrada)
            expect(got == saida, "\(entrada) -> \(got)")
        }

        print("\nQwen: pontuacao de volta e agrupamento\n")
        typealias S = QwenTranscriber.Segment
        let segmentos = [S(text: "皆", start: 1.0, end: 1.2), S(text: "さん", start: 1.2, end: 1.4),
                         S(text: "こんにちは", start: 1.4, end: 2.0), S(text: "TEDTalks", start: 2.6, end: 3.2),
                         S(text: "という", start: 3.2, end: 3.5), S(text: "と", start: 3.5, end: 3.6),
                         S(text: "楽しそう", start: 4.4, end: 5.0)]
        let pontuados = QwenTranscriber.punctuated(segmentos, text: "皆さんこんにちは。TED Talksというと、楽しそう")
        expect(pontuados.map(\.text).joined() == "皆さんこんにちは。TEDTalksというと、楽しそう",
               "o espaco dentro de TED Talks nao derruba a pontuacao do resto (\(pontuados.map(\.text).joined()))")
        let trechos = QwenTranscriber.phrases(pontuados)
        expect(trechos.map(\.text) == ["皆さんこんにちは。", "TEDTalksというと、", "楽しそう"],
               "fecha no ponto e na pausa de meio segundo (\(trechos.map(\.text)))")
        let comVoz = QwenTranscriber.phrases(pontuados.prefix(3).map { $0 }, boundaries: [1.3])
        expect(comVoz.count == 2, "fronteira de voz fecha o trecho")

        print(failures == 0 ? "\nlegenda japonesa ok" : "\n\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    /// Tradutor de teste: devolve o que estiver no dicionário e guarda o que
    /// recebeu, para o gate conferir as unidades que foram mandadas.
    final class ProbeTranslator: Translator, @unchecked Sendable {
        let engineName = "sonda"
        let answers: [String: String]
        var received: [String] = []
        init(_ answers: [String: String]) { self.answers = answers }
        func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
        func reset() {}
        func translate(_ text: String, from: Language, to: Language) async throws -> String {
            received.append(text)
            return answers[text] ?? "[\(text)]"
        }
    }

    /// A frase partida na pausa vai inteira ao tradutor, e a tradução volta
    /// repartida pelas legendas dela, com os tempos de antes.
    static func sentenceTranslationGate() async {
        failures = 0
        func cue(_ i: Int, _ a: Double, _ b: Double, _ texto: String, _ quem: String? = nil) -> Cue {
            Cue(index: i, start: a, end: b, source: texto, speaker: quem)
        }
        let frase = [
            cue(1, 18.1, 20.6, "Once these kids wake up, I'll"),
            cue(2, 20.7, 22.5, "have them give you a report."),
            cue(3, 22.6, 25.0, "You'd better not be doing a sloppy job."),
        ]
        let sonda = ProbeTranslator([
            "Once these kids wake up, I'll have them give you a report.":
                "Assim que essas crianças acordarem, vou pedir que te entreguem um relatório.",
            "You'd better not be doing a sloppy job.": "É melhor não estar fazendo um trabalho malfeito.",
        ])
        let builder = SubtitleFileBuilder()
        let saida = await builder.translate(frase, using: sonda, from: .english, to: .portuguese)
        expect(sonda.received == ["Once these kids wake up, I'll have them give you a report.",
                                  "You'd better not be doing a sloppy job."],
               "a frase partida vai inteira, a que fecha com ponto vai sozinha (\(sonda.received))")
        expect(saida.count == 3, "a traducao volta para as tres legendas (\(saida.count))")
        expect(saida.count == 3 && saida[0].translated.hasSuffix(",") && !saida[1].translated.isEmpty,
               "a reparticao corta na virgula (\(saida.map(\.translated)))")
        expect(saida.count == 3 && abs(saida[0].start - 18.1) < 0.01 && abs(saida[1].start - 20.7) < 0.01,
               "os tempos da pausa ficam")
        expect(saida.count == 3 && saida[0].source == "Once these kids wake up, I'll",
               "cada legenda guarda o proprio original")

        // Japonês: a primeira metade ia sozinha, sem o verbo.
        let ja = [cue(1, 246.5, 249.0, "例えば英語"), cue(2, 250.0, 253.4, "ペラペラになったらいいよねっていうような考えは")]
        let sondaJa = ProbeTranslator([
            "例えば英語ペラペラになったらいいよねっていうような考えは":
                "Por exemplo, a ideia de que seria bom falar inglês fluentemente",
        ])
        let saidaJa = await SubtitleFileBuilder().translate(ja, using: sondaJa, from: .japanese, to: .portuguese)
        expect(sondaJa.received.count == 1, "japones: a frase partida na pausa vai inteira")
        expect(saidaJa.count == 2 && saidaJa.allSatisfy { !$0.translated.isEmpty && $0.translated.first != "[" },
               "japones: as duas legendas recebem pedaco da traducao (\(saidaJa.map(\.translated)))")

        // O que não se junta.
        let vozes = [cue(1, 0, 2, "Did you hand in the", "A"), cue(2, 2.1, 3, "Yes", "B")]
        let sondaVozes = ProbeTranslator([:])
        _ = await SubtitleFileBuilder().translate(vozes, using: sondaVozes, from: .english, to: .portuguese)
        expect(sondaVozes.received.count == 2, "troca de locutor nao junta")
        let longe = [cue(1, 0, 2, "and then I went"), cue(2, 4, 5, "to the market")]
        let sondaLonge = ProbeTranslator([:])
        _ = await SubtitleFileBuilder().translate(longe, using: sondaLonge, from: .english, to: .portuguese)
        expect(sondaLonge.received.count == 2, "pausa acima de 1,5 s nao junta")
        let fixa = ProbeTranslator([:])
        _ = await SubtitleFileBuilder().translate(frase, using: fixa, from: .english, to: .portuguese,
                                                  preserveCueTiming: true)
        expect(fixa.received.count == 3, "faixa de tempo fixo traduz legenda por legenda")
        let igual = ProbeTranslator([:])
        _ = await SubtitleFileBuilder().translate(ja, using: igual, from: .japanese, to: .japanese)
        expect(igual.received.count == 2, "sem traducao nao ha o que juntar")

        // Tradução curta demais para repartir: as legendas viram uma só, em
        // vez de uma delas ficar vazia e mostrar o original.
        let curta = [cue(1, 0, 1.5, "Well, I"), cue(2, 1.6, 3.0, "guess")]
        let sondaCurta = ProbeTranslator(["Well, I guess": "Acho"])
        let saidaCurta = await SubtitleFileBuilder().translate(curta, using: sondaCurta, from: .english, to: .portuguese)
        expect(saidaCurta.count == 1 && saidaCurta[0].translated == "Acho" && abs(saidaCurta[0].end - 3.0) < 0.01,
               "traducao curta: uma legenda cobrindo as duas (\(saidaCurta.map(\.translated)))")

        print(failures == 0 ? "\ntraducao por frase ok" : "\n\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    /// O texto como se lê, em romaji, pelo tokenizador do sistema.
    static func reading(_ text: String) -> [Character] {
        let string = text as CFString
        guard let tokenizer = CFStringTokenizerCreate(
            nil, string, CFRange(location: 0, length: CFStringGetLength(string)),
            kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale) else { return [] }
        var out = ""
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                out += latin
            } else if let piece = CFStringCreateWithSubstring(nil, string, range) {
                out += piece as String
            }
        }
        return Array(out.precomposedStringWithCompatibilityMapping.lowercased()
            .filter { $0.isLetter || $0.isNumber })
    }

    /// Quantas costuras caem no meio de uma palavra de escrita densa: entre
    /// legendas seguidas (a menos de 1 s) e entre as linhas de 20 que a
    /// legenda japonesa ganha no arquivo.
    static func splitWordCount(_ cues: [Cue]) -> (cues: Int, lines: Int, seams: Int) {
        func midWord(_ left: String, _ right: String) -> Bool {
            guard let tail = left.last, let head = right.first, tail.isLetter, head.isLetter,
                  Tokens.isDense(tail), Tokens.isDense(head) else { return false }
            var offset = 0
            var cuts = Set<Int>()
            for phrase in Tokens.phrases(left + right) { offset += phrase.count; cuts.insert(offset) }
            return !cuts.contains(left.count)
        }
        let texts = cues.map { ($0.translated.isEmpty ? $0.source : $0.translated).replacingOccurrences(of: "\n", with: "") }
        var cueSplits = 0, lineSplits = 0, seams = 0
        for index in texts.indices {
            let lines = LineBreaker.wrap(texts[index], maximum: 20)
            for pair in zip(lines, lines.dropFirst()) where midWord(pair.0, pair.1) { lineSplits += 1 }
            guard index > 0, cues[index].start - cues[index - 1].end < 1 else { continue }
            seams += 1
            if midWord(texts[index - 1], texts[index]) { cueSplits += 1 }
        }
        return (cueSplits, lineSplits, seams)
    }

    /// Linhas seguidas do mesmo bloco que partem palavra, lidas do `.srt`
    /// como ele está escrito.
    static func lineSplitCount(_ srt: String) -> Int {
        var count = 0
        for block in srt.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard lines.count > 3 else { continue }
            let body = Array(lines.dropFirst(2))
            for pair in zip(body, body.dropFirst()) {
                let cue = { (text: String) in Cue(index: 1, start: 0, end: 1, source: text) }
                // Duas "legendas" coladas: a mesma conta da costura.
                var a = cue(pair.0), b = cue(pair.1)
                a.end = 1; b.start = 1
                if splitWordCount([a, b]).cues > 0 { count += 1 }
            }
        }
        return count
    }

    /// `referencia <video> <legenda.srt> [idioma] [motor]` gera pelo caminho
    /// do app, sem tradução, e compara. `referencia --srt <gerada.srt>
    /// <legenda.srt>` só compara.
    static func referenceGate(arguments: [String], option: (String) -> String?) async {
        let showDiff = arguments.contains("--diff")
        if arguments.count >= 5, arguments[2] == "--srt" {
            guard let hyp = try? SRTParser.parse(contentsOf: URL(fileURLWithPath: arguments[3])),
                  let ref = try? SRTParser.parse(contentsOf: URL(fileURLWithPath: arguments[4])) else {
                print("FALHA: nao consegui ler as legendas"); exit(1)
            }
            _ = compareWithReference(hypothesis: hyp, reference: ref,
                                     label: URL(fileURLWithPath: arguments[3]).lastPathComponent,
                                     seconds: 0, showDiff: showDiff,
                                     rawLines: try? String(contentsOfFile: arguments[3], encoding: .utf8))
            return
        }
        guard arguments.count >= 4 else {
            print("uso: referencia <video> <legenda.srt> [idioma] [motor] [--saida <srt>] [--json <arquivo>] [--diff]")
            exit(1)
        }
        let video = URL(fileURLWithPath: arguments[2])
        guard let ref = try? SRTParser.parse(contentsOf: URL(fileURLWithPath: arguments[3])) else {
            print("FALHA: nao consegui ler \(arguments[3])"); exit(1)
        }
        let language = arguments.count >= 5 ? (Language(rawValue: arguments[4]) ?? .japanese) : .japanese
        let engine = arguments.count >= 6 ? (RecognitionEngine(rawValue: arguments[5]) ?? .apple) : .apple

        let builder = SubtitleFileBuilder()
        let started = Date()
        let cues: [Cue]
        do {
            cues = try await builder.generate(
                from: video, source: language, target: language, engine: engine,
                translation: .transcriptionOnly, progress: { _, _, _, _ in })
        } catch {
            print("FALHA: \(error.localizedDescription)"); exit(1)
        }
        let seconds = Date().timeIntervalSince(started)
        print(String(format: "%@: %d legendas em %.1fs", builder.recognitionName ?? engine.rawValue, cues.count, seconds))
        let srt = SRTWriter.render(cues, charactersPerLine: SubtitleFileBuilder.lineWidth(for: language))
        if let path = option("--saida") {
            try? srt.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let report = compareWithReference(hypothesis: cues, reference: ref,
                                          label: builder.recognitionName ?? engine.rawValue,
                                          seconds: seconds, showDiff: showDiff, rawLines: srt)
        if let path = option("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: URL(fileURLWithPath: path))
        }
    }
}
