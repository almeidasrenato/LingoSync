// Sonda descartável: mediu as hipóteses do PLANO.md da legenda queimada
// (22/09/2026). Não é código do app e não é o desenho a implementar — os
// limiares daqui são os de uma medição rápida. Compilar e usar:
//   swiftc -O -parse-as-library sonda.swift -o /tmp/sonda
//   sonda langs                                   idiomas do Vision (.accurate e .fast)
//   sonda decode <video>                          AVAssetReader: 420v contra 32BGRA
//   sonda scan <video> <lang> <topo> <base> <ocrCada> <saida.tsv> [claro] [escuro]
//                                                 por quadro: diff cru, máscara de traço;
//                                                 OCR (região de interesse) a cada N quadros
//   sonda refine <video> <lang> <topo> <base> <N> OCR a cada N quadros + refino por pixels,
//                                                 contra o oráculo (OCR em todo quadro da troca)
//   EM_VOO=1,2,4 sonda paralelo <video> <lang> <topo> <base> <N> [saida.txt]
//                                                 faixa em cinza (plano Y), leituras em paralelo
//   sonda ocr <video> <lang> <topo> <base> <t1,t2,...>   quadros avulsos, com as caixas
// SEM_CORRECAO=1 desliga usesLanguageCorrection. <topo>/<base>: fração da altura, medida do topo.
import AVFoundation
import CoreVideo
import Foundation
import Vision

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func openReader(_ path: String, format: OSType) async throws -> (AVAssetReader, AVAssetReaderTrackOutput, Float) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let track = try await asset.loadTracks(withMediaType: .video).first!
    let fps = try await track.load(.nominalFrameRate)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: format,
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    reader.startReading()
    return (reader, output, fps)
}

/// Estatística barata da faixa, sobre o plano de luma (420v).
struct BandStats {
    var rawDiff: Double      // média |Y_t - Y_t-1| na faixa, amostrada a cada 2 px
    var cellsOn: Int         // células 8x8 com traço de legenda (claro com contorno escuro)
    var cellXor: Int         // células que mudaram de estado desde o quadro anterior
}

final class BandMeter {
    let hi: Int, lo: Int, radius = 3
    var previousLuma: [UInt8] = []
    var previousCells: [Bool] = []
    init(hi: Int, lo: Int) { self.hi = hi; self.lo = lo }

    func measure(_ pb: CVPixelBuffer, top: Double, bottom: Double) -> BandStats {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let y0 = max(radius, Int(Double(h) * top)), y1 = min(h - radius, Int(Double(h) * bottom))
        let x0 = radius, x1 = w - radius
        let cell = 8
        let cw = (x1 - x0) / cell, ch = (y1 - y0) / cell
        var counts = [Int](repeating: 0, count: cw * ch)
        var luma: [UInt8] = []
        luma.reserveCapacity(((y1 - y0) / 2 + 1) * ((x1 - x0) / 2 + 1))
        var diffSum = 0, n = 0
        let hasPrev = !previousLuma.isEmpty
        var y = y0
        while y < y1 {
            let p = base + y * row
            var x = x0
            while x < x1 {
                let v = Int(p[x])
                if hasPrev { diffSum += abs(v - Int(previousLuma[n])) }
                luma.append(UInt8(v)); n += 1
                if v >= hi {
                    let r = radius
                    if Int(p[x - r]) <= lo || Int(p[x + r]) <= lo
                        || Int(p[x - r * row]) <= lo || Int(p[x + r * row]) <= lo {
                        let cx = (x - x0) / cell, cy = (y - y0) / cell
                        if cx < cw, cy < ch { counts[cy * cw + cx] += 1 }
                    }
                }
                x += 2
            }
            y += 2
        }
        let cells = counts.map { $0 >= 3 }
        var xor = 0
        if previousCells.count == cells.count {
            for i in cells.indices where cells[i] != previousCells[i] { xor += 1 }
        }
        previousLuma = luma
        previousCells = cells
        return BandStats(rawDiff: hasPrev ? Double(diffSum) / Double(n) : 0,
                         cellsOn: cells.lazy.filter { $0 }.count, cellXor: xor)
    }
}

func makeRequest(lang: String, top: Double, bottom: Double) -> RecognizeTextRequest {
    var r = RecognizeTextRequest()
    r.recognitionLevel = .accurate
    r.recognitionLanguages = [Locale.Language(identifier: lang)]
    r.usesLanguageCorrection = ProcessInfo.processInfo.environment["SEM_CORRECAO"] == nil
    // Vision: origem em baixo à esquerda. A faixa vem medida do topo.
    r.regionOfInterest = NormalizedRect(x: 0, y: 1 - bottom, width: 1, height: bottom - top)
    return r
}

func read(_ obs: [RecognizedTextObservation]) -> String {
    obs.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
        .compactMap { o -> String? in
            guard let t = o.topCandidates(1).first?.string else { return nil }
            let b = o.boundingBox
            return String(format: "%@ {x %.2f w %.2f h %.3f c %.2f}", t, b.origin.x, b.width, b.height, o.confidence)
        }
        .joined(separator: " | ")
}

@main
struct Sonda {
    static func main() async throws {
        let a = CommandLine.arguments
        switch a[1] {
        case "langs":
            var r = RecognizeTextRequest()
            r.recognitionLevel = .accurate
            print("accurate:", r.supportedRecognitionLanguages.map { $0.maximalIdentifier }.joined(separator: " "))
            r.recognitionLevel = .fast
            print("fast:", r.supportedRecognitionLanguages.map { $0.maximalIdentifier }.joined(separator: " "))

        case "decode":
            for (name, fmt) in [("420v", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                ("BGRA", kCVPixelFormatType_32BGRA)] {
                let (reader, output, fps) = try await openReader(a[2], format: fmt)
                let t0 = now(); var frames = 0; var last = 0.0
                while let sb = output.copyNextSampleBuffer() {
                    if CMSampleBufferGetImageBuffer(sb) != nil { frames += 1 }
                    last = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                }
                let dt = now() - t0
                print(String(format: "%@ %d quadros (%.3f fps nominal, até %.1f s) em %.2f s = %.0f q/s, %.1fx tempo real, status %d",
                             name, frames, fps, last, dt, Double(frames) / dt, last / dt, reader.status.rawValue))
            }

        case "scan":
            let (path, lang) = (a[2], a[3])
            let top = Double(a[4])!, bottom = Double(a[5])!, every = Int(a[6])!
            let hi = a.count > 8 ? Int(a[8])! : 180, lo = a.count > 9 ? Int(a[9])! : 90
            let (reader, output, fps) = try await openReader(path, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange); defer { withExtendedLifetime(reader) {} }
            let meter = BandMeter(hi: hi, lo: lo)
            let request = makeRequest(lang: lang, top: top, bottom: bottom)
            var out = "quadro\tpts\trawDiff\tcellsOn\tcellXor\tocrMs\ttexto\n"
            var frame = 0, ocrTotal = 0.0, ocrCount = 0, meterTotal = 0.0
            let t0 = now()
            while let sb = output.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                let m0 = now()
                let s = meter.measure(pb, top: top, bottom: bottom)
                meterTotal += now() - m0
                var ocr = "", ms = ""
                if every > 0, frame % every == 0 {
                    let o0 = now()
                    ocr = read(try await request.perform(on: pb))
                    let d = now() - o0
                    ocrTotal += d; ocrCount += 1
                    ms = String(format: "%.1f", d * 1000)
                }
                out += String(format: "%d\t%.4f\t%.3f\t%d\t%d\t%@\t%@\n", frame, pts, s.rawDiff, s.cellsOn, s.cellXor, ms, ocr)
                frame += 1
            }
            let total = now() - t0
            try out.write(toFile: a[7], atomically: true, encoding: .utf8)
            print(String(format: "%d quadros a %.3f fps; total %.1f s; medidor %.2f ms/quadro; OCR %d x %.1f ms = %.1f s",
                         frame, fps, total, meterTotal / Double(max(frame, 1)) * 1000,
                         ocrCount, ocrTotal / Double(max(ocrCount, 1)) * 1000, ocrTotal))


        case "refine":
            // OCR a cada N quadros acha a troca; os pixels das caixas do OCR
            // escolhem o quadro exato. Oráculo: OCR em todo quadro da janela.
            let (path, lang) = (a[2], a[3])
            let top = Double(a[4])!, bottom = Double(a[5])!, every = Int(a[6])!
            let (reader, output, _) = try await openReader(path, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            defer { withExtendedLifetime(reader) {} }
            let request = makeRequest(lang: lang, top: top, bottom: bottom)
            func key(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)) }
            func same(_ a: String, _ b: String) -> Bool {
                let x = Array(key(a)), y = Array(key(b))
                if x.isEmpty || y.isEmpty { return x.isEmpty && y.isEmpty }
                var d = Array(0...y.count)
                for i in 1...x.count {
                    var prev = d[0]; d[0] = i
                    for j in 1...y.count { let t = d[j]; d[j] = min(d[j] + 1, d[j-1] + 1, prev + (x[i-1] == y[j-1] ? 0 : 1)); prev = t }
                }
                return Double(d[y.count]) / Double(max(x.count, y.count)) <= 0.25
            }
            struct Shot { var pb: CVPixelBuffer; var frame: Int; var text = ""; var boxes: [CGRect] = [] }
            func ocr(_ pb: CVPixelBuffer) async throws -> (String, [CGRect]) {
                let obs = try await request.perform(on: pb)
                let w = Double(CVPixelBufferGetWidth(pb)), h = Double(CVPixelBufferGetHeight(pb))
                let bandTop = top * h, bandH = (bottom - top) * h
                let lines = obs.filter { $0.boundingBox.height < 0.8 }   // "NS" ocupava a faixa inteira
                let text = lines.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
                    .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
                let boxes = lines.map { o -> CGRect in
                    let b = o.boundingBox
                    return CGRect(x: b.origin.x * w - 6, y: bandTop + (1 - b.origin.y - b.height) * bandH - 6,
                                  width: b.width * w + 12, height: b.height * bandH + 12)
                }
                return (text, boxes)
            }
            // Fração dos pixels que diferem entre as duas referências e que, no
            // quadro i, já estão mais perto da referência nova.
            func towardNew(_ i: CVPixelBuffer, _ old: CVPixelBuffer, _ new: CVPixelBuffer, _ boxes: [CGRect]) -> Double {
                for pb in [i, old, new] { CVPixelBufferLockBaseAddress(pb, .readOnly) }
                defer { for pb in [i, old, new] { CVPixelBufferUnlockBaseAddress(pb, .readOnly) } }
                let row = CVPixelBufferGetBytesPerRowOfPlane(i, 0)
                let W = CVPixelBufferGetWidthOfPlane(i, 0), H = CVPixelBufferGetHeightOfPlane(i, 0)
                let pi = CVPixelBufferGetBaseAddressOfPlane(i, 0)!.assumingMemoryBound(to: UInt8.self)
                let po = CVPixelBufferGetBaseAddressOfPlane(old, 0)!.assumingMemoryBound(to: UInt8.self)
                let pn = CVPixelBufferGetBaseAddressOfPlane(new, 0)!.assumingMemoryBound(to: UInt8.self)
                var total = 0, closer = 0
                for r in boxes {
                    for y in max(0, Int(r.minY))..<min(H, Int(r.maxY)) {
                        for x in max(0, Int(r.minX))..<min(W, Int(r.maxX)) {
                            let o = Int(po[y * row + x]), n = Int(pn[y * row + x]), v = Int(pi[y * row + x])
                            guard abs(o - n) > 40 else { continue }
                            total += 1
                            if abs(v - n) < abs(v - o) { closer += 1 }
                        }
                    }
                }
                return total == 0 ? 1 : Double(closer) / Double(total)
            }
            var ring: [Shot] = []
            var last: Shot?
            var frame = 0, results: [(Int, Int, String, String)] = []
            var oracleOCR = 0
            while let sb = output.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                defer { frame += 1 }
                if frame % every != 0 { ring.append(Shot(pb: pb, frame: frame)); continue }
                var shot = Shot(pb: pb, frame: frame)
                (shot.text, shot.boxes) = try await ocr(pb)
                if let prev = last, !same(prev.text, shot.text) {
                    // Refinamento: primeiro quadro que já pende para a amostra nova.
                    let boxes = prev.boxes + shot.boxes
                    var refined = shot.frame
                    for s in ring where towardNew(s.pb, prev.pb, shot.pb, boxes) > 0.5 { refined = s.frame; break }
                    // Oráculo: primeiro quadro a partir do qual o OCR já lê o texto novo.
                    var oracle = shot.frame
                    for s in ring.reversed() {
                        let (t, _) = try await ocr(s.pb); oracleOCR += 1
                        if same(t, shot.text) { oracle = s.frame } else { break }
                    }
                    results.append((oracle, refined, prev.text, shot.text))
                }
                last = shot
                ring.removeAll()
            }
            var hist = [Int: Int]()
            for (o, r, p, n) in results {
                hist[min(3, abs(r - o)), default: 0] += 1
                if abs(r - o) > 1 { print("q\(o) refinado \(r - o): \(p.prefix(30)) -> \(n.prefix(30))") }
            }
            print("trocas \(results.count); erro 0: \(hist[0] ?? 0), 1: \(hist[1] ?? 0), 2: \(hist[2] ?? 0), 3+: \(hist[3] ?? 0); OCR do oráculo \(oracleOCR)")


        case "paralelo":
            // A faixa vira CGImage cinza (do plano de luma) e o Vision lê com
            // 1, 2 e 4 leituras em voo.
            let (path, lang) = (a[2], a[3])
            let top = Double(a[4])!, bottom = Double(a[5])!, every = Int(a[6])!
            let (reader, output, _) = try await openReader(path, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            defer { withExtendedLifetime(reader) {} }
            var bands: [CGImage] = []
            var frame = 0
            let d0 = now()
            while let sb = output.copyNextSampleBuffer() {
                defer { frame += 1 }
                guard frame % every == 0, let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
                let row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                let y0 = Int(Double(h) * top), y1 = Int(Double(h) * bottom)
                let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
                let data = Data(bytes: base + y0 * row, count: (y1 - y0) * row)
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                let provider = CGDataProvider(data: data as CFData)!
                bands.append(CGImage(width: w, height: y1 - y0, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: row,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!)
            }
            print(String(format: "decodificar e recortar %d faixas: %.1f s", bands.count, now() - d0))
            var r = RecognizeTextRequest()
            r.recognitionLevel = .accurate
            r.recognitionLanguages = [Locale.Language(identifier: lang)]
            r.usesLanguageCorrection = true
            let req = r
            _ = try await req.perform(on: bands[0])   // aquece
            var reference: [String] = []
            for inFlight in (ProcessInfo.processInfo.environment["EM_VOO"] ?? "1,2,4").split(separator: ",").compactMap({ Int($0) }) {
                let t0 = now()
                var texts = [String](repeating: "", count: bands.count)
                try await withThrowingTaskGroup(of: (Int, String).self) { group in
                    var next = 0
                    func add() { let i = next; next += 1
                        group.addTask { (i, read(try await req.perform(on: bands[i])).replacingOccurrences(of: #"\s*\{[^}]*\}"#, with: "", options: .regularExpression)) } }
                    for _ in 0..<min(inFlight, bands.count) { add() }
                    while let (i, t) = try await group.next() { texts[i] = t; if next < bands.count { add() } }
                }
                let dt = now() - t0
                if reference.isEmpty { reference = texts }
                let differ = zip(texts, reference).filter { $0 != $1 }.count
                print(String(format: "%d em voo: %d faixas em %.2f s = %.1f ms/faixa; textos diferentes do sequencial: %d",
                             inFlight, bands.count, dt, dt / Double(bands.count) * 1000, differ))
            }
            print("amostra:", reference.filter { !$0.isEmpty }.prefix(4).joined(separator: " / "))
            if a.count > 7 { try reference.joined(separator: "\n").write(toFile: a[7], atomically: true, encoding: .utf8) }

        case "ocr":
            let (path, lang) = (a[2], a[3])
            let top = Double(a[4])!, bottom = Double(a[5])!
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let gen = AVAssetImageGenerator(asset: asset)
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            let request = makeRequest(lang: lang, top: top, bottom: bottom)
            for t in a[6].split(separator: ",").compactMap({ Double($0) }) {
                let (image, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
                let o0 = now()
                let text = read(try await request.perform(on: image))
                print(String(format: "t=%.1f (%.0f ms): %@", t, (now() - o0) * 1000, text))
            }
        default:
            print("?")
        }
    }
}
