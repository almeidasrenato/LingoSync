import AppKit
import TradutorCore
import WebKit

/// Sem modelos nem captura; --online mede dois lotes na mesma sessão do site.
/// --batch40 acrescenta um lote cheio para verificar o limite usado em vídeo.
@MainActor
enum GeminiCheck {
    static func run() async {
        NSApp.setActivationPolicy(.accessory)
        let path = "/tmp/tradutor-gemini-check.txt"
        var report = "Gemini\n"
        var failures = 0
        func record(_ text: String) {
            report += text + "\n"
            print(text)
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        func check(_ value: Bool, _ label: String) {
            if !value { failures += 1 }
            record("\(value ? "OK" : "FALHOU") \(label)")
        }
        if CommandLine.arguments.contains("--online") {
            let translator = GeminiWebTranslator()
            var batches: [[String]] = [
                ["今日は二人とも忙しいです。", "彼女は昨日ここに来ました。",
                 "私は明日の午後三時に戻ります。", "この店には玲香さんが二人いるんですか？",
                 "助けて！", "それは私の仕事です。"],
                ["I will return tomorrow at three in the afternoon.", "She arrived here yesterday.",
                 "You are both tired.", "Are there two people named Reika at this store?",
                 "Help me!", "That is my job."]
            ]
            if CommandLine.arguments.contains("--batch40") {
                batches.append((0..<40).map { batches[1][$0 % batches[1].count] })
            }
            do {
                for (index, lines) in batches.enumerated() {
                    let start = Date()
                    let output = try await translator.translate(
                        lines, from: index == 0 ? .japanese : .english, to: .portuguese
                    )
                    record("Lote \(index + 1): \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
                    check(output.count == lines.count && output.allSatisfy { !$0.isEmpty }, "todas as falas presentes")
                    for (source, translated) in zip(lines, output) { record("\(source) → \(translated)") }
                }
            } catch {
                failures += 1
                record("ERRO: \(error.localizedDescription)")
            }
            translator.reset()
        } else {
            check(GeminiWeb.parse("2::Olá\n1::Oi", expected: 2) == ["Oi", "Olá"], "ordem dos itens")
            check(GeminiWeb.parse("1::Oi\n1::Outro\n2::Olá", expected: 2) == nil, "recusa item duplicado")
            check(GeminiWeb.parse("1::  \n2::Olá", expected: 2) == nil, "recusa tradução vazia")
            check(GeminiWeb.parse("1::Oi", expected: 2) == nil, "recusa item faltante")
            check(GeminiWeb.parse("1::Oi\n2::Olá\n3::Extra", expected: 2) == nil, "recusa item extra")
            check(GeminiWeb.parse("0::Oi\n2::Olá", expected: 2) == nil, "recusa índice inválido")
            check(GeminiWeb.parse("1::He said: \"Hi\"!\r\n2::A::B", expected: 2)
                  == ["He said: \"Hi\"!", "A::B"], "preserva aspas, pontuação e dois-pontos")
            check(GeminiWeb.parse("1::Oi\n1::Oi\n2::Olá", expected: 2) == ["Oi", "Olá"],
                  "aceita duplicado idêntico")
            let ja = ["今日は二人とも忙しいです。", "私は明日の午後三時に戻ります。"]
            let en = ["We are both busy today.", "I will come back tomorrow."]
            check(GeminiWeb.pareceIntocado(source: ja, translated: ja), "detecta japonês sem tradução")
            check(GeminiWeb.pareceIntocado(source: en, translated: en), "detecta inglês sem tradução")
            check(!GeminiWeb.pareceIntocado(source: ja, translated: ["Hoje ambos estão ocupados.", "Volto amanhã às três."]), "aceita tradução de japonês")
            check(!GeminiWeb.pareceIntocado(source: ja, translated: [ja[0], "Volto amanhã às três."]), "exige maioria intocada")
            let names = ["佐藤雄二", "上村玲香", "Hmm?", "OK!"]
            check(!GeminiWeb.pareceIntocado(source: names, translated: names), "não confunde nomes e interjeições")
            check(!GeminiWeb.pareceIntocado(source: [en[0]], translated: [en[0]]), "mantém proteção para fala isolada")
            // Lote meio traduzido: a maioria continuava traduzida e a versão
            // antiga deixava passar, com essas falas indo para o `.srt` no
            // idioma falado.
            let parcial = ["We are both busy today.", "I will come back tomorrow.",
                           "She arrived here yesterday.", "That is my job today, you know."]
            check(GeminiWeb.pareceIntocado(
                source: parcial,
                translated: [parcial[0], "Volto amanhã.", "Ela chegou aqui ontem.", parcial[3]]
            ), "detecta lote meio traduzido")
            // Ao vivo o lote é de uma frase só: `pares.count >= 2` nunca se
            // formava e a rede nunca disparava.
            let aoVivo = "I will come back here tomorrow at three in the afternoon."
            check(GeminiWeb.pareceIntocado(source: [aoVivo], translated: [aoVivo]),
                  "detecta fala isolada longa sem tradução")
            // Eco com a pontuação trocada é tão não-traduzido quanto o idêntico.
            check(GeminiWeb.pareceIntocado(
                source: en, translated: [en[0].replacingOccurrences(of: ".", with: "!"), en[1] + " "]
            ), "detecta eco quase idêntico")
            let view = WKWebView()
            view.loadHTMLString("""
                <div id="response"><p><span>1::Ela</span><span style="display:none"> </span><span>veio ontem.</span></p><p>2::Volto às três.<br>3::Olá!</p></div>
                <div id="editor" contenteditable="true"><p>linha um</p><p>linha dois</p><p><br></p><p>Items:</p></div>
                <style>.x{color:red}</style><script>function nada(){return 1}</script>
                """, baseURL: nil)
            var extracted: String?
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(20))
                extracted = (try? await view.evaluateJavaScript(
                    "(\(GeminiWeb.responseTextScript))(document.querySelector('#response'))"
                )) as? String
                if extracted?.isEmpty == false { break }
            }
            check(GeminiWeb.parse(extracted ?? "", expected: 3) == ["Ela veio ontem.", "Volto às três.", "Olá!"], "espaços de spans animados, parágrafos e br")
            // A conferência do prompt lê pelo MESMO script. Por `innerText`
            // ela devolvia "" num WebView que não está sendo desenhado — sem
            // janela, app em segundo plano — e recusava 162 de 162 lotes.
            let editor = (try? await view.evaluateJavaScript(
                "(\(GeminiWeb.responseTextScript))(document.querySelector('[contenteditable=\"true\"]'))"
            )) as? String ?? ""
            let linhasEditor = editor.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            check(linhasEditor == ["linha um", "linha dois", "Items:"], "lê o editor sem depender de layout")
            // `textContent` inclui <script>/<style>, `innerText` não: sem
            // tirá-los o dump de falha da página saía com JavaScript no lugar
            // do texto que diria o que aconteceu.
            let comScript = (try? await view.evaluateJavaScript(
                "(\(GeminiWeb.responseTextScript))(document.body)"
            )) as? String ?? ""
            check(!comScript.contains("function") && comScript.contains("linha um"),
                  "não traz script nem style para o texto")
            // O editor do site troca aspa reta por curva enquanto se digita:
            // comparar cru recusava todo lote em inglês, que quase sempre tem
            // apóstrofo.
            check(GeminiWeb.semTipografia("39) look at what I\u{2019}ve \u{201C}done\u{201D}\u{2026}")
                  == "39) look at what I've \"done\"...", "tolera a tipografia do editor")
        }
        record("\(failures) falhas")
        exit(failures == 0 ? 0 : 1)
    }
}
