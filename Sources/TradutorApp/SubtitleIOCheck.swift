import AppKit
import TradutorCore

/// Sem vídeo, modelo ou rede: exercita o mesmo estado usado pela janela.
@MainActor
enum SubtitleIOCheck {
    static func run() async {
        var failures = 0
        var report = "Importação e exportação de SRT\n"
        func expect(_ condition: Bool, _ label: String) {
            report += "\(condition ? "OK" : "FALHA") \(label)\n"
            if !condition { failures += 1 }
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradutor-srt-\(UUID().uuidString)")
        let model = SubtitleStudioModel()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let original = folder.appendingPathComponent("original.ja.srt")
            let translated = folder.appendingPathComponent("traducao.pt.srt")
            let output = folder.appendingPathComponent("exportada.srt")
            let japanese = "今日は皆さんにお会いできてうれしいです。どうぞよろしくお願いします。"
            try SRTWriter.render([
                Cue(index: 1, start: 1.001, end: 1.101, source: japanese),
                Cue(index: 2, start: 2.003, end: 4.007, source: "ありがとうございます。")
            ], charactersPerLine: 20).write(to: original, atomically: true, encoding: .utf8)
            try "1\n00:00:01,001 --> 00:00:03,009\nOlá, como vai?\n".write(
                to: translated, atomically: true, encoding: .utf8)

            model.sourceLanguage = .japanese
            model.targetLanguage = .portuguese
            model.translationEngine = .google
            model.loadSubtitles(from: original, as: .original)
            try await Task.sleep(for: .milliseconds(200))
            expect(model.stage == .done && !model.isWorking && model.origin == nil,
                   "importar original não inicia tradutor")
            expect(model.cues.first?.source == japanese && model.cues.allSatisfy { $0.translated.isEmpty },
                   "original japonês preservado, sem espaços criados pela quebra de linha")
            expect(model.canRetranslate && model.canExport(.original) && !model.canExport(.translation),
                   "só a faixa existente pode ser exportada; tradução fica disponível por clique")
            expect(model.charactersPerLine == 20, "original usa a largura do japonês")
            model.sourceLanguage = .english
            model.targetLanguage = .french
            expect(model.suggestedSRTName(for: .original) == "legenda.ja.srt",
                   "mudar seletores não renomeia o conteúdo importado")
            model.export(to: output, track: .original)
            let roundtrip = try SRTParser.parse(contentsOf: output)
            expect(roundtrip.map(\.translated) == model.cues.map(\.source), "exportar original preserva todas as falas")
            expect(roundtrip.first?.start == 1.001 && roundtrip.first?.end == 1.101,
                   "ida e volta preserva milissegundos e legendas menores que 200 ms")
            let saved = try Data(contentsOf: output)
            model.export(to: output, track: .translation)
            let unchanged = try Data(contentsOf: output)
            expect(model.exportError != nil && unchanged == saved,
                   "faixa ausente não sobrescreve o arquivo com outro idioma")

            model.translationEngine = .transcriptionOnly
            model.retranslate()
            let deadline = Date().addingTimeInterval(5)
            while model.isWorking && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            expect(model.stage == .done && model.cues.map(\.translated) == roundtrip.map(\.translated),
                   "tradução explícita usa o original sem reconhecer áudio")
            expect(model.cues.first?.start == 1.001 && model.cues.first?.end == 1.101,
                   "tradução explícita preserva tempos importados")
            expect(model.writtenLanguage == .japanese, "só transcrever usa o idioma da faixa original")

            model.targetLanguage = .portuguese
            model.loadSubtitles(from: translated, as: .translation)
            expect(!model.canRetranslate && !model.canExport(.original) && model.canExport(.translation),
                   "importar tradução remove o rascunho anterior")
            expect(model.writtenLanguage == .portuguese && model.cues.first?.source == "",
                   "tradução importada usa destino mesmo com Só transcrever selecionado")
            model.targetLanguage = .japanese
            model.export(to: output, track: .translation)
            let exportedTranslation = try SRTParser.parse(contentsOf: output)
            expect(model.suggestedSRTName(for: .translation) == "legenda.pt.srt"
                   && exportedTranslation.first?.translated == "Olá, como vai?",
                   "exportar tradução mantém texto e idioma carregados")
            model.export(to: output, track: .original)
            expect(model.exportError != nil, "tradução nunca é exportada como original")

            model.loadSubtitles(from: original, as: .original)
            model.translationEngine = .transcriptionOnly
            model.retranslate()
            model.loadSubtitles(from: translated, as: .translation)
            try await Task.sleep(for: .milliseconds(200))
            expect(model.stage == .done && model.cues.first?.translated == "Olá, como vai?",
                   "trabalho cancelado não sobrescreve nova importação")
        } catch {
            expect(false, error.localizedDescription)
        }
        model.stop()
        try? FileManager.default.removeItem(at: folder)
        report += "\(failures) falhas\n"
        try? report.write(toFile: "/tmp/tradutor-srt.txt", atomically: true, encoding: .utf8)
        print(report)
        exit(failures == 0 ? 0 : 1)
    }
}
