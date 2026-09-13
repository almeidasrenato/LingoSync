import AudioCapture
import AVFoundation
import Foundation
import TradutorCore

// Portoes das fases 4 e 5. Roda sem captura de audio, entao nao depende da
// permissao do sistema.
//
//   tradutor-verify dialogo         teste de contexto de dialogo (fase 5)
//   tradutor-verify audio <wav>     transcricao + traducao ponta a ponta
//   tradutor-verify quebra          quebra de linha, sem baixar modelo

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
              tradutor-verify glossario     lista de termos e janela de contexto
              tradutor-verify fonte <video> [idioma] [motor]
                                            imprime as falas reconhecidas, uma por linha
              tradutor-verify traduzir <arquivo> [origem] [destino]
                                            traduz um arquivo de linhas com o motor do sistema
              tradutor-verify lotes         mede qual tamanho de lote compensa
              tradutor-verify sobreposicao  mede se o contexto reenviado melhora a traducao
              tradutor-verify motores       limiar do Whisper e separacao dos motores
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
            """)
            exit(1)
        }

        switch arguments[1] {
        case "dialogo": await dialogueGate()
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
                language: arguments.count >= 5 ? (Language(rawValue: arguments[4]) ?? .english) : .english
            )
        case "tempos": await timecodeGate()
        case "formatos": await formatGate()
        case "legendas": legendaGate()
        case "glossario": glossaryGate()
        case "fonte":
            guard arguments.count >= 3 else { print("falta o caminho do video"); exit(1) }
            await dumpSource(
                path: arguments[2],
                language: arguments.count >= 4 ? (Language(rawValue: arguments[3]) ?? .japanese) : .japanese,
                engine: arguments.count >= 5
                    ? (RecognitionEngine(rawValue: arguments[4]) ?? .whisper) : .whisper
            )
        case "traduzir":
            guard arguments.count >= 3 else { print("falta o arquivo de linhas"); exit(1) }
            await translateLines(
                path: arguments[2],
                source: arguments.count >= 4 ? (Language(rawValue: arguments[3]) ?? .japanese) : .japanese,
                target: arguments.count >= 5 ? (Language(rawValue: arguments[4]) ?? .portuguese) : .portuguese
            )
        case "lotes": await batchSizeGate()
        case "sobreposicao": await overlapGate()
        case "motores": await engineGate()
        case "locutores": speakerGate()
        case "deepl": deepLGate()
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

        var failures = 0

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

    // MARK: Lista de termos e contexto

    static func glossaryGate() {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print(condition ? "  ok    \(label)" : "  FALHA \(label)")
            if !condition { failures += 1 }
        }

        print("lista de termos\n")

        // Pasta temporaria: a lista real do usuario nao pode ser tocada por
        // um teste. `exit()` no fim do gate nao executa `defer`, entao
        // "salvar e restaurar" nao funciona aqui.
        let pasta = FileManager.default.temporaryDirectory
            .appendingPathComponent("glossario-teste-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pasta) }

        let glossario = Glossary(source: .japanese, target: .portuguese, directory: pasta)
        glossario.replaceAll(with: [
            Term(source: "もやし", target: "broto de feijão"),
            Term(source: "納豆", target: "natto"),
            Term(source: "山梨", target: "Yamanashi"),
            Term(source: "山梨県", target: "província de Yamanashi"),
            Term(source: "水菜", target: "mizuna", enabled: false),
        ])

        expect(glossario.apply(to: "もやしは安い野菜です").contains("broto de feijão"),
               "substitui o termo no original")
        expect(!glossario.apply(to: "もやしは安い野菜です").contains("もやし"),
               "o termo original sai do texto")

        // O mais longo primeiro: com a ordem errada, 山梨 comeria o começo de
        // 山梨県 e sobraria um 県 solto.
        let comarca = glossario.apply(to: "山梨県で採れた野菜")
        expect(comarca.contains("província de Yamanashi"),
               "o termo mais longo ganha do mais curto (deu \"\(comarca)\")")
        expect(!comarca.contains("県"), "nao sobra caractere solto do termo longo")

        expect(glossario.apply(to: "水菜も買います").contains("水菜"),
               "termo desligado nao e aplicado")
        expect(glossario.apply(to: "卵も買います") == "卵も買います",
               "texto sem termo nenhum fica intacto")
        expect(glossario.activeCount == 4, "conta so os termos ligados")

        print("")
        print("persistencia")
        let relido = Glossary(source: .japanese, target: .portuguese, directory: pasta)
        expect(relido.all.count == 5, "a lista sobrevive a reabertura (deu \(relido.all.count))")
        expect(relido.apply(to: "納豆は健康です").contains("natto"), "os termos voltam funcionando")

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

        // Limpa antes de sair, porque `exit` nao roda `defer`.
        try? FileManager.default.removeItem(at: pasta)

        print("")
        print(failures == 0 ? "lista de termos ok" : "\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Comparacao entre motores de traducao

    /// Imprime as falas reconhecidas, uma por linha.
    ///
    /// Serve de entrada para comparar motores de traducao: o mesmo texto de
    /// origem passa por cada um, e a diferenca fica isolada na traducao.
    static func dumpSource(
        path: String, language: Language, engine: RecognitionEngine = .whisper
    ) async {
        guard let samples = try? await SubtitleFileBuilder.extractAudio(
            from: URL(fileURLWithPath: path)
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
        guard let timed = try? await transcriber.transcribeTimed(samples), !timed.isEmpty else {
            FileHandle.standardError.write(Data("nenhuma fala reconhecida\n".utf8))
            exit(1)
        }

        let cues = SubtitleFileBuilder().makeCues(from: timed, mediaDuration: duration)
        for cue in cues where !cue.source.isEmpty {
            print(cue.source.replacingOccurrences(of: "\n", with: " "))
        }
        exit(0)
    }

    /// Traduz um arquivo de linhas com o motor do sistema, uma traducao por
    /// linha, na mesma ordem.
    static func translateLines(path: String, source: Language, target: Language) async {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data("nao consegui ler \(path)\n".utf8))
            exit(1)
        }
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { exit(0) }

        let translator = TranslatorFactory.make(.apple)
        try? await translator.prepare { _, _ in }

        let started = Date()
        var output: [String] = []
        let step = translator.preferredBatchSize
        for begin in stride(from: 0, to: lines.count, by: step) {
            let end = min(begin + step, lines.count)
            let slice = Array(lines[begin..<end])
            output += (try? await translator.translate(slice, from: source, to: target))
                ?? Array(repeating: "", count: slice.count)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)

        for line in output { print(line.replacingOccurrences(of: "\n", with: " ")) }
        FileHandle.standardError.write(Data("\(lines.count) linhas em \(ms) ms\n".utf8))
        exit(0)
    }

    // MARK: Leitura de .srt

    static func legendaGate() {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print(condition ? "  ok    \(label)" : "  FALHA \(label)")
            if !condition { failures += 1 }
        }

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

        print("")
        print(failures == 0 ? "leitura de .srt ok" : "\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Formatos de arquivo

    /// O seletor aceita qualquer arquivo; quem julga e a extracao, olhando os
    /// bytes. Este teste cobre os dois lados: o arquivo bom sem extensao no
    /// nome tem que passar, e o formato que o sistema nao le tem que ser
    /// recusado com uma mensagem que diz qual formato e.
    static func formatGate() async {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print(condition ? "  ok    \(label)" : "  FALHA \(label)")
            if !condition { failures += 1 }
        }

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
            timed = try await transcriber.transcribeTimed(samples)
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
        builder.glossary = Glossary(source: source, target: target)
        // Medicao: SOBREPOSICAO troca as legendas reenviadas como contexto.
        if let valor = ProcessInfo.processInfo.environment["SOBREPOSICAO"], let n = Int(valor) {
            builder.contextOverlap = n
            print("sobreposicao: \(n) legendas")
        }
        let ativos = builder.glossary?.activeCount ?? 0
        if ativos > 0 { print("glossario: \(ativos) termos ativos") }

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
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print(condition ? "  ok    \(label)" : "  FALHA \(label)")
            if !condition { failures += 1 }
        }

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

        // Com pontuacao japonesa, aí sim divide.
        let comPontuacao = Cue(
            index: 1, start: 0, end: 8,
            source: "みなさんこんにちは、ここはスーパーです。今日は買い物をします",
            translated: "Olá a todos, este é um supermercado e hoje vamos fazer compras aqui dentro dele com calma."
        )
        let partesPont = builder.enforceLineLimit([comPontuacao])
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
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print(condition ? "  ok    \(label)" : "  FALHA \(label)")
            if !condition { failures += 1 }
        }

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

        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print(condition ? "  ok    \(label)" : "  FALHA \(label)")
            if !condition { failures += 1 }
        }

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
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print(condition ? "  ok    \(label)" : "  FALHA \(label)")
            if !condition { failures += 1 }
        }

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
    static func alignmentGate(path: String, engine: RecognitionEngine, language: Language) async {
        do {
            let samples = try await SubtitleFileBuilder.extractAudio(from: URL(fileURLWithPath: path))
            let duration = Double(samples.count) / 16_000
            let transcriber = TranscriberFactory.make(for: language, engine: engine)
            try await transcriber.prepare { _, _ in }
            let pieces = try await transcriber.transcribeTimed(samples) { _ in }
            let cues = SubtitleFileBuilder().makeCues(from: pieces, mediaDuration: duration)
            let regions = SpeechEnergy.regions(samples, minimumPause: 0.5)

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
                guard let timed = try? await transcriber.transcribeTimed(samples) else {
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
        guard let timed = try? await transcriber.transcribeTimed(samples) else {
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
        guard let pieces = try? await transcriber.transcribeTimed(samples) else {
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
    static func deepLGate() {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print(condition ? "  ok    \(label)" : "  FALHA \(label)")
            if !condition { failures += 1 }
        }

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

        // Ao vivo nunca e o DeepL: uma carga de pagina por bloco nao cabe em
        // um trecho re-reconhecido a cada 0,6 s.
        expect(TranslationEngine.deepl.supportsLive == false, "DeepL nao serve ao vivo")
        expect(TranslationEngine.apple.supportsLive, "Apple serve ao vivo")

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
        expect(TranslationEngine.hunyuan.supportsLive == false, "Hunyuan nao serve ao vivo")
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
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print(condition ? "  ok    \(label)" : "  FALHA \(label)")
            if !condition { failures += 1 }
        }

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
        let limites = SpeakerDiarizer.boundaries(of: faixas)
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
        // O leitor do proprio app tem de ler de volta o que ele escreveu.
        let devolta = SRTParser.parse(coloridas)
        expect(devolta.count == 2 && devolta[0].translated == "— Bom dia.",
               "o .srt colorido volta a ser lido sem as tags")

        print("")
        print(failures == 0 ? "PASSOU" : "\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }

    /// Varre o limiar de agrupamento e conta quantas vozes cada valor devolve.
    ///
    /// Nao precisa de reconhecedor: quem identifica locutor e outro modelo,
    /// sobre o mesmo audio. O numero certo e o que voce sabe do arquivo.
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
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print(condition ? "  ok    \(label)" : "  FALHA \(label)")
            if !condition { failures += 1 }
        }

        print("Motores de reconhecimento\n")

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

        // O 0.6B nao pontua em ingles: zero sinais em 161 s medidos, contra
        // 63 do Parakeet. Sem ponto o agrupador perde a fronteira de frase.
        expect(RecognitionEngine.qwen.supportedLanguages?.contains(.english) == false,
               "o Qwen 0.6B nao oferece ingles")
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

        // A lista de termos tambem alimenta o reconhecimento: o Whisper pelo
        // prompt de prefill, o Qwen pelo `--context`. Pasta temporaria, nunca
        // a lista do usuario.
        let pasta = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradutor-teste-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pasta) }
        let lista = Glossary(source: .japanese, target: .portuguese, directory: pasta)
        lista.replaceAll(with: [
            Term(source: "上村玲香", target: "Reika Uemura"),
            Term(source: "納豆", target: "natto", enabled: false),
        ])
        expect(lista.activeSources == ["上村玲香"],
               "so os termos ligados vao para o reconhecedor")
        let motorComLista = TranscriberFactory.make(for: .japanese, engine: .whisper)
        motorComLista.vocabularyHint = lista.activeSources
        expect(motorComLista.vocabularyHint == ["上村玲香"],
               "o motor guarda a lista que recebeu")
        let motorSemLista = TranscriberFactory.make(for: .japanese, engine: .apple)
        motorSemLista.vocabularyHint = lista.activeSources
        expect(motorSemLista.vocabularyHint.isEmpty,
               "motor que nao usa a lista ignora sem reclamar")

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
        var failures = 0
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
        func expect(_ condition: Bool, _ label: String) {
            print(condition ? "  ok    \(label)" : "  FALHA \(label)")
            if !condition { failures += 1 }
        }
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
