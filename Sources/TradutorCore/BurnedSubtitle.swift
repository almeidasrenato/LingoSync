import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Lê a legenda que já vem desenhada no vídeo — a "queimada" — com o instante
/// em que ela aparece e o instante em que some.
///
/// Quem descobre que a legenda trocou é o próprio leitor de texto, amostrado a
/// cada `sampleInterval`. A primeira ideia era o contrário — diferença de
/// pixels da faixa em todo quadro, lendo só quando ela assentasse — e foi
/// medida e recusada no vídeo 2 dos exemplos (anime com legenda inglesa): com
/// a legenda parada, o fundo que se mexe atrás dela dá diferença acima de 17,8
/// em 1% dos quadros, e as trocas reais têm mediana 12,1, 10% abaixo de 5,9.
/// A troca é menor que o ruído do fundo; em cena com movimento a faixa nunca
/// assenta e a legenda passaria sem ser lida. Os pixels ficam com o que fazem
/// bem: achar, entre duas amostras, o quadro exato da troca.
///
/// Tudo local: o leitor é o Vision do sistema, sem download e sem rede.
public enum BurnedSubtitle {

    /// O que o cabeçalho da janela diz que produziu a legenda.
    public static let engineName = "Imagem"

    /// De quanto em quanto tempo a faixa é lida.
    ///
    /// Em tempo, não em quadros: o mesmo vídeo a 24 e a 60 quadros por segundo
    /// tem de ser lido do mesmo jeito. Legenda mais curta que isto pode passar
    /// entre duas leituras.
    public static let sampleInterval: TimeInterval = 0.25

    /// Leituras em voo ao mesmo tempo.
    ///
    /// Medido no vídeo 2: 65 ms por leitura uma de cada vez, 26 ms com duas,
    /// 13 ms com quatro — e o mesmo texto nas 386 amostras.
    public static let readsInFlight = 4

    /// A faixa da legenda, em fração da altura, medida do topo.
    ///
    /// Vai até a borda porque no vídeo de 9 minutos a caixa escura da legenda
    /// encosta nela. Com isso a marca d'água do vídeo 2 entra na faixa — e sai
    /// pelo filtro de centro (ver `filter`).
    public static let band: ClosedRange<Double> = 0.76...1.0

    /// A faixa padrão como área: largura inteira, origem em cima à esquerda.
    public static let defaultArea = CGRect(
        x: 0, y: band.lowerBound, width: 1, height: band.upperBound - band.lowerBound)

    /// Recorte mais baixo que isto não tem letra que o Vision leia.
    static let minimumAreaPixels = 16

    // MARK: - Linhas

    /// Uma linha que o leitor achou numa amostra da faixa.
    public struct Line: Sendable, Equatable {
        public var text: String
        /// Normalizada à faixa, com origem no canto de **cima** à esquerda —
        /// o Vision devolve com origem embaixo, e a troca é feita uma vez só,
        /// em `recognize`.
        public var box: CGRect

        public init(text: String, box: CGRect) {
            self.text = text
            self.box = box
        }
    }

    /// O que sobra de uma amostra depois dos filtros.
    public struct Kept: Sendable {
        /// As linhas que ficaram, juntas como uma legenda só.
        public var text: String
        public var lines: [Line]
        /// Alguma linha centralizada foi tirada por estar em outra escrita.
        /// É o que deixa o erro de "nada encontrado" dizer o motivo provável.
        public var otherScript: Bool
    }

    /// Quanto o centro da linha visual pode fugir do meio da faixa.
    ///
    /// Legenda é centralizada: as falas dos dois vídeos medidos ficam entre
    /// 0,48 e 0,51. A marca d'água do vídeo 2 fica em 0,88, e a placa de
    /// cardápio do vídeo de 9 minutos entre 0,27 e 0,30 conforme o
    /// enquadramento — com 0,2 de folga ela passava e virava legenda
    /// (`2小.90 1日 60`). Na mesma altura de uma fala, a placa entra na linha
    /// visual dela; ver `centered`.
    static let centerTolerance = 0.05

    /// Linha mais baixa que isto, diante da mais alta, é furigana.
    ///
    /// Medido no vídeo de 9 minutos: furigana 0,09 contra 0,31 da linha
    /// japonesa; as linhas latinas da mesma legenda ficam entre 0,55 e 0,87
    /// da mais alta delas.
    static let minimumHeightRatio = 0.5

    /// Tira o que não é a legenda e junta o resto, de cima para baixo.
    ///
    /// Cada filtro nasceu de um caso medido nos vídeos de exemplo, e só estes:
    /// fora do centro (marca d'água, placa), escrita que não é a do idioma
    /// escolhido (romaji e inglês junto do japonês) e altura pequena demais
    /// (furigana). As linhas se juntam com `Tokens.join`, como o `SRTParser`
    /// junta as do `.srt` importado: a janela requebra pela largura do idioma.
    ///
    /// `area` é onde a faixa foi recortada no quadro. O centro que vale é o
    /// do **quadro**, não o da área: legenda em cima continua centralizada,
    /// e quem desenha não desenha simétrico. Sem o filtro, uma área desenhada
    /// na faixa de baixo do vídeo 2 deu 63 legendas em vez de 27 — marca
    /// d'água, `Crunchyroll®`, `EI`. Área que nem contém o meio do quadro é
    /// legenda de canto por escolha de quem desenhou: aí o filtro sai.
    public static func filter(_ lines: [Line], for language: Language, area: CGRect = defaultArea) -> Kept {
        let middle = (0.5 - area.minX) / area.width
        let tolerance = centerTolerance / area.width
        let keepsCenter = (0...1).contains(middle)
        let visual = rows(lines).map { keepsCenter ? centered($0, around: middle, tolerance: tolerance) : $0 }.filter { !$0.isEmpty }.map { row in
            (lines: row,
             text: Tokens.join(row.map { $0.text.trimmingCharacters(in: .whitespaces) }),
             height: row.map(\.box.height).max() ?? 0)
        }
        let written = visual.filter { isWritten($0.text, in: language) }
        let tallest = written.map(\.height).max() ?? 0
        let kept = written.filter { $0.height >= tallest * minimumHeightRatio }
        return Kept(
            text: Tokens.join(kept.map(\.text)),
            lines: kept.flatMap(\.lines),
            otherScript: visual.contains { hasLetters($0.text) && !isWritten($0.text, in: language) }
        )
    }

    /// A parte centralizada de uma linha visual: tira a ponta mais longe do
    /// meio até o resto ficar no centro.
    ///
    /// A placa do vídeo de 9 minutos tem letra do tamanho do romaji e, quando
    /// cai na mesma altura, entra na linha visual dele; juntas, as duas ficam
    /// a 0,08 do meio. Tirando a ponta mais afastada, sobra o romaji,
    /// centrado. `え？` e `同じです。` só centram juntas, e ficam juntas.
    static func centered(_ row: [Line], around middle: Double = 0.5,
                         tolerance: Double = centerTolerance) -> [Line] {
        var part = row[...]
        while let first = part.first, let last = part.last {
            let union = part.dropFirst().reduce(first.box) { $0.union($1.box) }
            if abs(union.midX - middle) <= tolerance { return Array(part) }
            if abs(first.box.midX - middle) >= abs(last.box.midX - middle) {
                part = part.dropFirst()
            } else {
                part = part.dropLast()
            }
        }
        return []
    }

    /// Agrupa as caixas em linhas visuais, de cima para baixo, cada uma da
    /// esquerda para a direita.
    ///
    /// `え？　同じです。` é uma linha só, com um vão largo, e o Vision a devolve
    /// em duas caixas. Ordenadas só pela altura, a da direita vinha primeiro
    /// sempre que ficava um pixel acima (`・同じです。え？`), e a leitura
    /// alternava entre as duas ordens — legendas falsas de fração de segundo
    /// no vídeo de 9 minutos. E cada metade sozinha fica fora do centro: o
    /// filtro de centro vale para a linha visual inteira.
    ///
    /// Mesma linha é letra do mesmo tamanho na mesma altura. Só sobreposição
    /// não basta: a marca d'água do vídeo 2 encosta na segunda linha da fala,
    /// e juntas elas formariam uma linha fora do centro — a fala sairia com a
    /// marca.
    static func rows(_ lines: [Line]) -> [[Line]] {
        var rows: [[Line]] = []
        for line in lines.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let row = rows.last {
                let height = row.map(\.box.height).max() ?? 0
                let middle = row.map(\.box.midY).reduce(0, +) / Double(row.count)
                let smaller = min(height, line.box.height)
                if smaller >= 0.6 * max(height, line.box.height),
                   abs(line.box.midY - middle) < smaller / 2 {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    enum Script { case latin, cyrillic, arabic, devanagari, thai, hangul, kana, han }

    static func script(of scalar: Unicode.Scalar) -> Script? {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF,
             0xFF21...0xFF3A, 0xFF41...0xFF5A: .latin
        case 0x400...0x52F: .cyrillic
        case 0x600...0x6FF, 0x750...0x77F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: .arabic
        case 0x900...0x97F: .devanagari
        case 0xE00...0xE7F: .thai
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: .hangul
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: .kana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: .han
        default: nil
        }
    }

    static func scripts(for language: Language) -> Set<Script> {
        switch language {
        case .japanese: [.kana, .han]
        case .chinese: [.han]
        case .korean: [.hangul, .han]
        case .russian, .ukrainian: [.cyrillic]
        case .arabic: [.arabic]
        case .hindi: [.devanagari]
        case .thai: [.thai]
        case .portuguese, .english, .spanish, .french, .german, .italian, .dutch,
             .polish, .turkish, .vietnamese: [.latin]
        }
    }

    /// A maioria das letras da linha é da escrita do idioma?
    ///
    /// Maioria, não todas: legenda japonesa com "OK" ou "YouTube" no meio
    /// continua japonesa.
    static func isWritten(_ text: String, in language: Language) -> Bool {
        let accepted = scripts(for: language)
        var inside = 0
        var outside = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            guard let script = script(of: scalar) else { continue }
            if accepted.contains(script) { inside += 1 } else { outside += 1 }
        }
        return inside > outside
    }

    private static func hasLetters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isAlphabetic && script(of: $0) != nil }
    }

    // MARK: - Mesma legenda ou outra

    /// Distância de edição, normalizada, até onde duas leituras são a mesma
    /// legenda.
    static let sameTolerance = 0.25

    /// As duas leituras são da mesma legenda?
    ///
    /// Comparadas sem caixa, sem espaço e sem pontuação: o leitor tremula numa
    /// amostra isolada — `My name iS...` entre `My name is...`, `Everyone..`
    /// entre `Everyone...` — e isso não é troca de legenda. Vazio só é igual a
    /// vazio.
    public static func same(_ a: String, _ b: String) -> Bool {
        let x = key(a)
        let y = key(b)
        if x.isEmpty || y.isEmpty { return x.isEmpty && y.isEmpty }
        return Double(distance(x, y)) / Double(max(x.count, y.count)) <= sameTolerance
    }

    private static func key(_ text: String) -> [Character] {
        Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func distance(_ x: [Character], _ y: [Character]) -> Int {
        var row = Array(0...y.count)
        for i in 1...x.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...y.count {
                let above = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, diagonal + (x[i - 1] == y[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return row[y.count]
    }

    // MARK: - Montagem

    /// Uma amostra já filtrada: o texto que a faixa tinha naquele instante.
    public struct Sample: Sendable, Equatable {
        public var time: TimeInterval
        public var text: String

        public init(time: TimeInterval, text: String) {
            self.time = time
            self.text = text
        }
    }

    /// O instante da troca entre uma amostra e a anterior, achado nos pixels.
    public struct Change: Sendable, Equatable {
        /// Primeiro quadro que já não tem o texto anterior: o `end` dele,
        /// exclusivo, como `SubtitleStudioModel.index(at:)` o lê.
        public var previousEnds: TimeInterval
        /// Primeiro quadro que já tem o texto novo.
        public var nextStarts: TimeInterval

        public init(previousEnds: TimeInterval, nextStarts: TimeInterval) {
            self.previousEnds = previousEnds
            self.nextStarts = nextStarts
        }
    }

    struct Run {
        var first: Int
        var last: Int
    }

    /// Agrupa as amostras em trechos da mesma legenda.
    ///
    /// Amostra isolada e diferente entre duas iguais é tremor do leitor, não
    /// legenda: `A A' A` é um trecho só, mesmo que `A'` passe da tolerância
    /// (`me!` lido `mel` dá 0,33). Vazio no meio não é tremor: o mesmo texto
    /// depois de um buraco é outra legenda — sumiu e voltou. Legenda vista numa
    /// amostra só, entre vazios ou entre legendas diferentes, fica: pode ser
    /// fala curta de verdade.
    static func runs(_ samples: [Sample]) -> [Run] {
        var runs: [Run] = []
        for index in samples.indices {
            if let last = runs.last, same(samples[last.last].text, samples[index].text) {
                runs[runs.count - 1].last = index
                continue
            }
            runs.append(Run(first: index, last: index))
            guard runs.count >= 3 else { continue }
            let before = runs[runs.count - 3]
            let middle = runs[runs.count - 2]
            let after = runs[runs.count - 1]
            if middle.first == middle.last, !samples[middle.first].text.isEmpty,
               !samples[before.last].text.isEmpty,
               same(samples[before.last].text, samples[after.first].text) {
                runs.removeLast(3)
                runs.append(Run(first: before.first, last: after.last))
            }
        }
        return runs
    }

    /// A leitura mais frequente entre as amostras da legenda; no empate, a
    /// mais antiga.
    ///
    /// Uma leitura só, no quadro "estável", pegaria o tremor quando ele cai
    /// nela. As amostras já foram lidas; votar não custa nada.
    static func vote(_ texts: [String]) -> String {
        var counts: [String: Int] = [:]
        for text in texts { counts[text, default: 0] += 1 }
        var best = texts[0]
        for text in texts where counts[text]! > counts[best]! { best = text }
        return best
    }

    /// Monta as legendas a partir das amostras em ordem.
    ///
    /// - Parameters:
    ///   - changes: o instante refinado de cada troca, pelo índice da amostra
    ///     de depois. Sem ele, vale o tempo da amostra.
    ///   - end: o fim do último quadro. Legenda aberta até ali termina ali.
    public static func assemble(_ samples: [Sample], changes: [Int: Change], end: TimeInterval) -> [Cue] {
        var cues: [Cue] = []
        for run in runs(samples) where !samples[run.first].text.isEmpty {
            var start = run.first == 0
                ? samples[0].time
                : changes[run.first]?.nextStarts ?? samples[run.first].time
            let stop = run.last + 1 < samples.count
                ? changes[run.last + 1]?.previousEnds ?? samples[run.last + 1].time
                : end
            if let last = cues.last {
                start = max(start, last.start)
                // Dissolução: a nova ficou legível antes de a velha sumir. Na
                // tela só cabe uma, e a que está chegando é a que se quer ler.
                if start < last.end { cues[cues.count - 1].end = start }
                if cues[cues.count - 1].end <= last.start { cues.removeLast() }
            }
            guard stop > start else { continue }
            cues.append(Cue(
                index: cues.count + 1, start: start, end: stop,
                source: vote(samples[run.first...run.last].map(\.text))
            ))
        }
        for index in cues.indices { cues[index].index = index + 1 }
        return cues
    }

    // MARK: - O quadro exato

    /// A faixa de um quadro, em luma (o plano Y do `420v`), linha a linha.
    public struct Band: Sendable {
        public let width: Int
        public let height: Int
        public var pixels: [UInt8]

        public init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        /// A faixa como imagem cinza, que é o que vai para o Vision.
        ///
        /// Medido no vídeo 2: lendo a faixa recortada em cinza, 27 de 27
        /// legendas saem certas; lendo o quadro colorido com região de
        /// interesse, 26 — "I'm" saía "Im" em 9 de 9 leituras. E o buffer do
        /// decodificador é solto na hora, em vez de esperar a leitura.
        public var image: CGImage? {
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        }
    }

    /// Letra de legenda é núcleo claro com contorno escuro — é assim que ela
    /// se lê sobre qualquer quadro, e é o que a separa do fundo.
    static let glyphBright: UInt8 = 180
    static let glyphDark: UInt8 = 90
    /// Com folga para a compressão e para o começo de um fade.
    static let showsBright: UInt8 = 150
    static let showsDark: UInt8 = 110
    /// Com menos que isto a caixa não tem letra que se possa seguir, e o
    /// instante fica o da amostra.
    static let minimumGlyphPixels = 12

    /// Os pixels de letra de uma legenda, tirados de uma amostra em que ela
    /// está na tela.
    public struct Glyphs: Sendable {
        public let width: Int
        public let height: Int
        public var core: [Int] = []
        public var outline: [Int] = []
    }

    /// Núcleo claro cercado de escuro, e o escuro colado nesse núcleo — o
    /// contorno —, dentro das caixas do leitor.
    ///
    /// Cercado, dos dois lados na horizontal ou na vertical: o traço da letra
    /// tem contorno dos dois lados, e o fundo claro encostado no contorno só
    /// tem de um. Sem essa exigência, céu claro em volta da legenda entrava
    /// como núcleo — mais pixels que a própria letra no teste —, e um corte de
    /// cena atrás de uma legenda parada parecia a legenda sumindo.
    public static func glyphs(of band: Band, in boxes: [CGRect]) -> Glyphs {
        let width = band.width
        let height = band.height
        // O contorno da letra fica um pouco fora da caixa do leitor.
        let margin = max(3, height / 40)
        let pixels = band.pixels
        var area: [(x: Range<Int>, y: Range<Int>)] = []
        for box in boxes {
            let x0 = max(0, Int(box.minX * Double(width)) - margin)
            let x1 = min(width, Int((box.maxX * Double(width)).rounded(.up)) + margin)
            let y0 = max(0, Int(box.minY * Double(height)) - margin)
            let y1 = min(height, Int((box.maxY * Double(height)).rounded(.up)) + margin)
            if x0 < x1, y0 < y1 { area.append((x0..<x1, y0..<y1)) }
        }
        // Até onde procurar o contorno de cada lado: o miolo de um traço
        // grosso fica longe dos dois contornos e sai, o que não faz falta.
        func reaches(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int, _ reach: Int, _ test: (Int) -> Bool) -> Bool {
            for step in 1...reach {
                let nx = x + dx * step
                let ny = y + dy * step
                guard nx >= 0, nx < width, ny >= 0, ny < height else { return false }
                if test(ny * width + nx) { return true }
            }
            return false
        }
        let dark = { (index: Int) in pixels[index] <= glyphDark }
        var isCore = [Bool](repeating: false, count: width * height)
        var found = Glyphs(width: width, height: height)
        for (xs, ys) in area {
            for y in ys {
                for x in xs {
                    let index = y * width + x
                    guard !isCore[index], pixels[index] >= glyphBright else { continue }
                    let across = reaches(x, y, -1, 0, 6, dark) && reaches(x, y, 1, 0, 6, dark)
                    let upright = reaches(x, y, 0, -1, 6, dark) && reaches(x, y, 0, 1, 6, dark)
                    guard across || upright else { continue }
                    isCore[index] = true
                    found.core.append(index)
                }
            }
        }
        var isOutline = [Bool](repeating: false, count: width * height)
        let core = { (index: Int) in isCore[index] }
        for (xs, ys) in area {
            for y in ys {
                for x in xs {
                    let index = y * width + x
                    guard !isOutline[index], pixels[index] <= glyphDark else { continue }
                    guard reaches(x, y, -1, 0, 3, core) || reaches(x, y, 1, 0, 3, core)
                        || reaches(x, y, 0, -1, 3, core) || reaches(x, y, 0, 1, 3, core)
                    else { continue }
                    isOutline[index] = true
                    found.outline.append(index)
                }
            }
        }
        return found
    }

    /// Só os pixels de letra que a outra amostra não repete.
    ///
    /// Duas falas seguidas ocupam o mesmo lugar, e a letra nova cobre parte
    /// da velha: no vídeo de 9 minutos, os traços de `がんばろうね。` cobriam
    /// mais da metade dos de `よかったです。`, a velha "continuava na tela" e o
    /// fim dela saía até 6 quadros atrasado — e o começo da seguinte, pelo
    /// mesmo motivo, até 7 adiantado. Onde as duas amostras mostram o mesmo
    /// pixel, ele não diz qual das duas está na tela.
    public static func distinct(_ glyphs: Glyphs, in reference: Band, against other: Band) -> Glyphs {
        guard other.width == reference.width, other.height == reference.height else { return glyphs }
        func differs(_ index: Int) -> Bool {
            abs(Int(reference.pixels[index]) - Int(other.pixels[index])) > distinctThreshold
        }
        var kept = Glyphs(width: glyphs.width, height: glyphs.height)
        kept.core = glyphs.core.filter(differs)
        kept.outline = glyphs.outline.filter(differs)
        return kept
    }

    /// Diferença de luma a partir da qual um pixel mudou de verdade entre as
    /// duas amostras, e não só pela compressão.
    static let distinctThreshold = 40

    /// As letras continuam na tela neste quadro?
    ///
    /// Os dois lados ao mesmo tempo: fundo claro mantém o núcleo claro depois
    /// que a legenda some, fundo escuro mantém o contorno escuro — e nenhum
    /// fundo imita os dois. O fundo que se mexe ou troca de cena atrás de uma
    /// legenda parada não muda nada aqui, porque a letra está por cima. Num
    /// fade a resposta vira no meio, que é a definição do instante.
    ///
    /// - Returns: `nil` quando sobram pixels de menos para dizer — o instante
    ///   fica o da amostra. Um lado sozinho ainda decide: o outro pode ter
    ///   saído por `distinct`, que é o caso da letra branca sobre céu branco.
    public static func shows(_ frame: Band, _ glyphs: Glyphs) -> Bool? {
        guard frame.width == glyphs.width, frame.height == glyphs.height else { return nil }
        let hasCore = glyphs.core.count >= minimumGlyphPixels
        let hasOutline = glyphs.outline.count >= minimumGlyphPixels
        guard hasCore || hasOutline else { return nil }
        var core = 0
        for index in glyphs.core where frame.pixels[index] >= showsBright { core += 1 }
        var outline = 0
        for index in glyphs.outline where frame.pixels[index] <= showsDark { outline += 1 }
        return (!hasCore || core * 2 > glyphs.core.count)
            && (!hasOutline || outline * 2 > glyphs.outline.count)
    }

    /// Uma amostra lida, com o que o refino precisa dela.
    struct Snapshot {
        var time: TimeInterval
        var band: Band
        var text = ""
        var boxes: [CGRect] = []
    }

    struct Frame {
        var time: TimeInterval
        var band: Band
    }

    /// O instante da troca entre duas amostras seguidas de texto diferente.
    ///
    /// O fim da velha é o primeiro quadro que já não mostra as letras dela; o
    /// começo da nova, o primeiro que já mostra as dela — cada uma com as
    /// próprias caixas, senão legenda → vazio → legenda dentro de um intervalo
    /// dava um instante só para as duas pontas.
    ///
    /// Comparar a caixa inteira entre as duas amostras foi medido e trocado:
    /// quando a cena corta depois de a legenda sumir, o fundo domina a caixa e
    /// o instante caía no corte — 5 das 54 pontas do vídeo 2 saíam 3 quadros
    /// atrasadas (`Hello?!` some no quadro 122, a cena corta no 125). E cada
    /// fala é seguida só pelo que a outra amostra não repete (`distinct`).
    static func change(from previous: Snapshot, to next: Snapshot, over frames: [Frame]) -> Change {
        var ends: Int?
        if !previous.text.isEmpty {
            let letters = distinct(glyphs(of: previous.band, in: previous.boxes),
                                   in: previous.band, against: next.band)
            ends = frames.firstIndex { shows($0.band, letters) == false }
        }
        var starts: Int?
        if !next.text.isEmpty {
            let letters = distinct(glyphs(of: next.band, in: next.boxes),
                                   in: next.band, against: previous.band)
            starts = frames.firstIndex { shows($0.band, letters) == true }
        }
        return Change(
            previousEnds: ends.map { frames[$0].time } ?? next.time,
            nextStarts: starts.map { frames[$0].time } ?? next.time
        )
    }

    // MARK: - Leitura do arquivo

    public enum ReadError: LocalizedError, Equatable {
        case unsupportedLanguage(Language)
        case cannotOpen(String)
        /// A janela aceita áudio também, e áudio não tem legenda para ler.
        case noVideo(String)
        case rotated(String)
        case noText(Language, otherScript: Bool, drawn: Bool = false)
        case areaTooSmall

        public var errorDescription: String? {
            switch self {
            case let .unsupportedLanguage(language):
                "O leitor de texto do macOS não lê \(language.displayName.lowercased())."
            case let .cannotOpen(name):
                "Não consegui ler os quadros de \(name)."
            case let .noVideo(name):
                "\(name) não tem imagem — só áudio. A legenda desenhada precisa de vídeo."
            case let .rotated(name):
                "\(name) foi gravado girado, e a leitura da legenda ainda não trata vídeo girado."
            case let .noText(language, true, drawn):
                "Encontrei texto \(drawn ? "na área escolhida" : "na parte de baixo do vídeo"), mas não em "
                    + "\(language.displayName.lowercased()). Confira o idioma do texto."
            case let .noText(_, false, drawn):
                "Não encontrei legenda \(drawn ? "na área escolhida" : "na parte de baixo do vídeo")."
            case .areaTooSmall:
                "A área escolhida é pequena demais para ler texto. Desenhe um retângulo maior."
            }
        }
    }

    /// Tudo que a leitura achou. A janela usa `cues`; o resto é para o gate
    /// medir o instante contra o oráculo.
    public struct Reading: Sendable {
        public var cues: [Cue]
        public var samples: [Sample]
        public var changes: [Int: Change]
        public var videoEnd: TimeInterval
        public var framesPerSecond: Double
    }

    private static let visionCatalog: [Locale.Language] = RecognizeTextRequest().supportedRecognitionLanguages

    /// Os idiomas do app que o leitor de texto do sistema lê.
    ///
    /// Consultado em tempo de execução: no macOS 27 são os 18, mas o app roda
    /// desde o 15 e a lista lá pode ser menor.
    public static let supportedLanguages: [Language] = Language.allCases.filter {
        !visionLanguages(for: $0).isEmpty
    }

    /// Casados por código de idioma, não por texto: o Vision chama o
    /// vietnamita de `vi-VT` e o chinês vem em duas escritas.
    static func visionLanguages(for language: Language) -> [Locale.Language] {
        let wanted = Locale.Language(identifier: language.rawValue).languageCode
        return visionCatalog.filter { $0.languageCode == wanted }
    }

    /// `.accurate` sempre: o `.fast` só lê seis idiomas latinos, sem japonês.
    public static func recognizer(for language: Language) -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = visionLanguages(for: language)
        return request
    }

    public static func recognize(_ image: CGImage, with request: RecognizeTextRequest) async throws -> [Line] {
        try await request.perform(on: image).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return Line(text: text, box: CGRect(
                x: box.origin.x, y: 1 - box.origin.y - box.height,
                width: box.width, height: box.height
            ))
        }
    }

    /// Copia a área do plano Y, para o buffer do decodificador ser solto.
    public static func copyBand(_ pixels: CVPixelBuffer, area: CGRect) -> Band? {
        guard CVPixelBufferGetPlaneCount(pixels) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let top = max(0, min(height, Int(Double(height) * area.minY)))
        let bottom = max(top, min(height, Int(Double(height) * area.maxY)))
        let left = max(0, min(width, Int(Double(width) * area.minX)))
        let right = max(left, min(width, Int(Double(width) * area.maxX)))
        let columns = right - left
        guard bottom > top, columns > 0 else { return nil }
        var copy = [UInt8](repeating: 0, count: columns * (bottom - top))
        copy.withUnsafeMutableBytes { destination in
            for row in 0..<(bottom - top) {
                memcpy(destination.baseAddress! + row * columns, base + (top + row) * stride + left, columns)
            }
        }
        return Band(width: columns, height: bottom - top, pixels: copy)
    }

    /// Lê a legenda desenhada no vídeo.
    ///
    /// - Parameters:
    ///   - language: o idioma do **texto na tela**, que não é o falado — no
    ///     vídeo 2 a fala é japonesa e a legenda inglesa. Com a dica errada
    ///     (`ja` em texto inglês), 249 de 386 leituras mudam, com erro de
    ///     verdade (`Yes, lam!`).
    ///   - area: onde ler, normalizada ao quadro com origem em cima à
    ///     esquerda. `nil` é a faixa de baixo (`defaultArea`). O filtro de
    ///     centro vale no quadro inteiro; ver `filter`.
    ///   - progress: fração do arquivo, um detalhe legível e se está só
    ///     esperando — a primeira leitura do Vision chegou a levar 24 s, a
    ///     compilar o modelo. Chamado de threads quaisquer.
    /// - Throws: `ReadError`, ou `CancellationError` quando a tarefa é
    ///   cancelada — a leitura olha o cancelamento a cada quadro.
    public static func read(
        from url: URL,
        language: Language,
        area: CGRect? = nil,
        progress: @escaping @Sendable (Double, String, Bool) -> Void = { _, _, _ in }
    ) async throws -> Reading {
        guard !visionLanguages(for: language).isEmpty else {
            throw ReadError.unsupportedLanguage(language)
        }
        let name = url.lastPathComponent
        do {
            return try await scan(url, name: name, language: language, area: area, progress: progress)
        } catch ReadError.cannotOpen {
            // O AVFoundation escolhe o demuxer pela extensão, para o leitor de
            // quadros como para o de áudio: arquivo sem extensão só abre pelo
            // apelido `.mp4`, o mesmo que `extractAudio` usa.
            guard let alias = try? SubtitleFileBuilder.mp4Alias(for: url) else { throw ReadError.cannotOpen(name) }
            defer { try? FileManager.default.removeItem(at: alias.deletingLastPathComponent()) }
            return try await scan(alias, name: name, language: language, area: area, progress: progress)
        }
    }

    private static func scan(
        _ url: URL, name: String, language: Language, area drawn: CGRect?,
        progress: @escaping @Sendable (Double, String, Bool) -> Void
    ) async throws -> Reading {
        let asset = AVURLAsset(url: url)
        // Não abrir é caso para o apelido `.mp4`; abrir sem faixa de vídeo não.
        guard let tracks = try? await asset.loadTracks(withMediaType: .video) else {
            throw ReadError.cannotOpen(name)
        }
        guard let track = tracks.first else {
            let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            throw audio.isEmpty ? ReadError.cannotOpen(name) : ReadError.noVideo(name)
        }
        // Girado, a faixa de baixo do arquivo não é a de baixo da tela.
        let turn = (try? await track.load(.preferredTransform)) ?? .identity
        guard turn.b == 0, turn.c == 0, turn.a > 0, turn.d > 0 else { throw ReadError.rotated(name) }
        let area = drawn ?? defaultArea
        if drawn != nil, let size = try? await track.load(.naturalSize),
           Int(size.height * area.height) < minimumAreaPixels || Int(size.width * area.width) < minimumAreaPixels {
            throw ReadError.areaTooSmall
        }
        let fps = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        let duration = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0

        guard let reader = try? AVAssetReader(asset: asset) else { throw ReadError.cannotOpen(name) }
        // `420v`, não `32BGRA`: medido, 2650 contra 700 quadros por segundo,
        // e o plano Y já é a imagem cinza que o leitor e o refino usam.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ReadError.cannotOpen(name) }
        reader.add(output)
        guard reader.startReading() else { throw ReadError.cannotOpen(name) }
        // O leitor tem de viver o laço inteiro: solto antes, o
        // `copyNextSampleBuffer` derruba o processo. O `defer` o segura e
        // ainda interrompe a decodificação quando a leitura é cancelada.
        defer { reader.cancelReading() }

        let request = recognizer(for: language)
        var samples: [Sample] = []
        var changes: [Int: Change] = [:]
        var otherScript = false
        var previous: Snapshot?
        var waiting: [Int: Snapshot] = [:]
        var intervals: [Int: [Frame]] = [:]
        var ready: [Int: [Line]] = [:]
        var frames: [Frame] = []
        var submitted = 0
        var nextSampleAt = -Double.infinity
        var videoEnd = 0.0
        var reported = -Double.infinity
        let total = duration > 0 ? duration : 1

        // As leituras voltam fora de ordem; o que depende da anterior — a
        // comparação e o refino — anda na ordem das amostras.
        func settle() {
            while let lines = ready.removeValue(forKey: samples.count) {
                let index = samples.count
                guard var snapshot = waiting.removeValue(forKey: index) else { return }
                let kept = filter(lines, for: language, area: area)
                otherScript = otherScript || kept.otherScript
                snapshot.text = kept.text
                snapshot.boxes = kept.lines.map(\.box)
                let between = intervals.removeValue(forKey: index) ?? []
                if let previous, !same(previous.text, snapshot.text) {
                    changes[index] = change(from: previous, to: snapshot, over: between)
                }
                samples.append(Sample(time: snapshot.time, text: snapshot.text))
                previous = snapshot
            }
        }

        progress(0, "carregando o leitor", true)
        try await withThrowingTaskGroup(of: (Int, [Line]).self) { group in
            var inFlight = 0

            func enqueue(_ frame: Frame) {
                let index = submitted
                submitted += 1
                waiting[index] = Snapshot(time: frame.time, band: frame.band)
                intervals[index] = frames
                frames = []
                guard let image = frame.band.image else {
                    ready[index] = []
                    return
                }
                group.addTask { (index, try await recognize(image, with: request)) }
                inFlight += 1
            }

            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
                let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                guard time.isFinite, let band = copyBand(pixels, area: area) else { continue }
                let length = CMSampleBufferGetDuration(buffer).seconds
                videoEnd = max(videoEnd, time + (length.isFinite && length > 0 ? length : (fps > 0 ? 1 / fps : 0)))
                let frame = Frame(time: time, band: band)

                guard time >= nextSampleAt else {
                    frames.append(frame)
                    continue
                }
                nextSampleAt = ((time / sampleInterval + 1e-9).rounded(.down) + 1) * sampleInterval
                enqueue(frame)
                settle()
                // O decodificador espera vaga: sem isso ele corre na frente e
                // os quadros guardados para o refino crescem sem limite.
                if inFlight >= readsInFlight, let (index, lines) = try await group.next() {
                    inFlight -= 1
                    ready[index] = lines
                    settle()
                }
                if !samples.isEmpty, time - reported >= 1 {
                    reported = time
                    progress(min(1, time / total), String(format: "%.0f de %.0f s", time, total), false)
                }
            }
            // O que houver depois da última amostra é lido no último quadro:
            // legenda que muda ali não pode passar sem leitura.
            if let last = frames.popLast() { enqueue(last) }
            while inFlight > 0, let (index, lines) = try await group.next() {
                inFlight -= 1
                ready[index] = lines
                settle()
            }
            settle()
        }
        if reader.status == .failed { throw ReadError.cannotOpen(name) }

        let cues = assemble(samples, changes: changes, end: videoEnd)
        guard !cues.isEmpty else { throw ReadError.noText(language, otherScript: otherScript, drawn: drawn != nil) }
        return Reading(cues: cues, samples: samples, changes: changes,
                       videoEnd: videoEnd, framesPerSecond: fps)
    }
}
