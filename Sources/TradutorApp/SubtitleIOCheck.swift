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

            // O caso relatado em 22/09/2026: a janela nasce com o seletor de
            // fala em inglês, e o `.srt` japonês importado ia ao tradutor
            // como inglês.
            let outraJanela = SubtitleStudioModel(preferences: nil)
            outraJanela.sourceLanguage = .english
            outraJanela.loadSubtitles(from: original, as: .original)
            expect(outraJanela.subtitleLanguage(for: .original) == .japanese
                   && outraJanela.suggestedSRTName(for: .original) == "legenda.ja.srt",
                   "original importado leva o idioma do texto, não o do seletor de fala")

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
            expect(model.canRetranslate && model.canExport(.original) && model.canExport(.translation),
                   "importar tradução preserva o original e permite exportar as duas faixas")
            expect(model.writtenLanguage == .portuguese && model.cues.first?.source == japanese,
                   "tradução importada usa destino mesmo com Só transcrever selecionado")
            expect(model.cues.first?.translated == "Olá, como vai?" && model.cues.count == 4,
                   "original e tradução aparecem juntos mesmo com quantidades diferentes")
            expect(model.cues[1].source.isEmpty && model.cues[1].start == 1.101
                   && model.cues[1].end == 2.003 && model.cues[1].translated == "Olá, como vai?",
                   "cada faixa respeita os próprios intervalos de silêncio")
            expect(model.cues.last?.source == "ありがとうございます。" && model.cues.last?.translated == ""
                   && model.cues.last?.start == 3.009 && model.cues.last?.end == 4.007,
                   "original continua visível depois de a tradução terminar")
            model.targetLanguage = .japanese
            model.export(to: output, track: .translation)
            let exportedTranslation = try SRTParser.parse(contentsOf: output)
            expect(model.suggestedSRTName(for: .translation) == "legenda.pt.srt"
                   && exportedTranslation.first?.translated == "Olá, como vai?"
                   && exportedTranslation.count == 1 && exportedTranslation.first?.end == 3.009,
                   "exportar tradução mantém texto e idioma carregados")
            model.export(to: output, track: .original)
            expect(try Data(contentsOf: output) == saved, "exportar original mantém seus blocos após importar tradução")

            let reverse = SubtitleStudioModel()
            reverse.sourceLanguage = .japanese
            reverse.targetLanguage = .portuguese
            reverse.loadSubtitles(from: translated, as: .translation)
            expect(!reverse.canRetranslate && !reverse.canExport(.original)
                   && reverse.cues.allSatisfy { $0.source.isEmpty }, "importar só tradução não inventa original")
            reverse.loadSubtitles(from: original, as: .original)
            expect(reverse.cues.count == model.cues.count && zip(reverse.cues, model.cues).allSatisfy {
                $0.start == $1.start && $0.end == $1.end && $0.source == $1.source && $0.translated == $1.translated
            }, "importar na ordem inversa produz as mesmas duas faixas")
            reverse.loadSubtitles(from: original, as: .original)
            expect(reverse.translatedCues.count == 1 && reverse.originalCues.count == 2,
                   "substituir original mantém a tradução sem duplicar blocos")
            reverse.loadSubtitles(from: translated, as: .translation)
            expect(reverse.cues.count == 4 && reverse.originalCues.count == 2,
                   "substituir tradução mantém o original sem duplicar blocos")
            reverse.translationEngine = .transcriptionOnly
            reverse.retranslate()
            let translationDeadline = Date().addingTimeInterval(5)
            while reverse.isWorking && Date() < translationDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            expect(reverse.translatedCues.count == 2 && reverse.translatedCues.first?.translated == japanese,
                   "tradução explícita substitui a faixa importada e mantém o original")
            reverse.export(to: output, track: .translation)
            expect(try SRTParser.parse(contentsOf: output).count == 2,
                   "exportação usa a nova tradução após retraduzir")
            reverse.stop()

            let separated = SubtitleStudioModel.combineTracks(
                original: [Cue(index: 1, start: 5, end: 6, source: "Original")],
                translation: [Cue(index: 1, start: 1, end: 2, source: "", translated: "Tradução")]
            )
            expect(separated.count == 2 && separated[0].source.isEmpty && separated[1].translated.isEmpty,
                   "faixas sem sobreposição não são pareadas pelo número")
            let delayed = folder.appendingPathComponent("atrasada.pt.srt")
            try "1\n00:00:06,000 --> 00:00:07,000\nSó depois.\n".write(
                to: delayed, atomically: true, encoding: .utf8)
            model.targetLanguage = .portuguese
            model.loadSubtitles(from: delayed, as: .translation)
            expect(model.displayLines(at: 0).allSatisfy { $0.count <= 20 },
                   "original sem tradução naquele instante mantém largura do japonês")

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
