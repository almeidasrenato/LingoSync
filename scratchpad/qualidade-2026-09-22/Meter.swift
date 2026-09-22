import AppKit
import AudioCapture
import Foundation
import TradutorCore

@main struct Meter {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            do { try await run(); exit(0) }
            catch { print("FALHA: \(error)"); exit(1) }
        }
        app.run()
    }
    static func save(_ value: Any, _ path: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    static func audio(_ path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    static func rows(_ cues: [Cue]) -> [[String: Any]] {
        cues.map { ["start": $0.start, "end": $0.end, "source": $0.source, "translated": $0.translated] }
    }
    @MainActor static func run() async throws {
        let a = CommandLine.arguments
        let mode = a[1], path = a[2], language = Language(rawValue: a[3])!
        if mode == "confirm" {
            let samples=try audio(path+".prepared.f32")
            let candidate=TimedText(text:"Obrigado por assistir.",start:0,end:Double(samples.count)/16000)
            let result=try await Hallucinations.filter([candidate],samples:samples,language:language)
            try save(["kept":result.map(\.text)],a[4]);return
        }
        if mode == "freeze" {
            let raw = try await SubtitleFileBuilder.extractAudio(from: URL(fileURLWithPath: path), preferring: language, processing: false)
            for (suffix, data) in [("raw", raw), ("prepared", SubtitleFileBuilder.prepareAudio(raw))] {
                try data.withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: a[4]+".\(suffix).f32"))
            }
            let regions = SpeechEnergy.regions(raw, minimumPause: 0.5)
            try save(["duration": Double(raw.count)/16000,
                      "regions": regions.map { ["start":$0.lowerBound,"end":$0.upperBound] }], a[4]+".audio.json")
            return
        }
        if mode == "gemini" || mode == "layout" {
            let data = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:path))) as! [String:Any]
            let draft = (data["draft"] as! [[String:Any]]).enumerated().map { i,r in
                Cue(index:i+1,start:r["start"] as! Double,end:r["end"] as! Double,source:r["source"] as! String)
            }
            if mode == "layout", draft.isEmpty { try save(data,a[4]);return }
            let builder = SubtitleFileBuilder(draft:draft)
            let start=Date()
            let target = mode == "layout" ? language : (language == .portuguese ? .english : .portuguese)
            let cues=try await builder.retranslate(using:mode == "layout" ? .transcriptionOnly : .gemini,from:language,to:target,progress:{_,_,_,_ in })
            var report=data
            report["postprocessSeconds"]=Date().timeIntervalSince(start)
            report["cues"]=rows(cues)
            report["srt"]=SRTWriter.render(cues,charactersPerLine:SubtitleFileBuilder.lineWidth(for:target))
            try save(report,a[4])
            return
        }
        let engine=RecognitionEngine(rawValue:a[4])!
        let samples=try audio(path+".prepared.f32"), raw=try audio(path+".raw.f32")
        let start=Date()
        let transcriber=TranscriberFactory.make(for:language,engine:engine)
        try await transcriber.prepare {_,_ in }
        let loaded=Date()
        if mode == "live" {
            // Replay do VAD por quadros de 20 ms, sem estimar o instante pelo tamanho
            // da chamada de feed (que pode conter várias fronteiras de fechamento).
            var configuration=Segmenter.Configuration()
            if let value=ProcessInfo.processInfo.environment["QUALITY_VAD_FLOOR"].flatMap(Float.init) {
                configuration.absoluteFloor=value
            }
            let segmenter=Segmenter(configuration:configuration)
            var closed:[[String:Any]]=[]
            var consumed=0
            for pos in stride(from:0,to:raw.count,by:Segmenter.frameSize) {
                let end=min(raw.count,pos+Segmenter.frameSize)
                for segment in segmenter.feed(Array(raw[pos..<end])) {
                    let finished = segment.closedBySilence ? end : end-segmenter.inFlight.count
                    let begin = finished-segment.samples.count
                    let t=Date()
                    let text=try await transcriber.transcribe(segment.samples)
                    closed.append(["start":Double(begin)/16000,"end":Double(finished)/16000,"emitted":Double(end)/16000,"text":text,"asrSeconds":Date().timeIntervalSince(t)])
                }
                consumed=end
            }
            if let segment=segmenter.flush() {
                let t=Date(); let text=try await transcriber.transcribe(segment.samples)
                closed.append(["start":Double(consumed-segment.samples.count)/16000,"end":Double(consumed)/16000,"emitted":Double(consumed)/16000,"text":text,"asrSeconds":Date().timeIntervalSince(t)])
            }
            try save(["segments":closed,"engine":transcriber.engineName,"seconds":Date().timeIntervalSince(start)],a[5]);return
        }
        transcriber.pauseBoundaries=SpeechEnergy.pauseBoundaries(samples,minimumPause:SpeechEnergy.subtitlePause)
        let pieces=try await transcriber.transcribeForSubtitles(samples)
        let recognized=Date()
        let builder=SubtitleFileBuilder()
        builder.silences=SpeechEnergy.silences(samples)
        let draft=builder.makeCues(from:pieces,mediaDuration:Double(samples.count)/16000)
        let translated=SubtitleFileBuilder(draft:draft)
        let cues = draft.isEmpty ? [] : try await translated.retranslate(using:.transcriptionOnly,from:language,to:language,progress:{_,_,_,_ in })
        try save(["seconds":Date().timeIntervalSince(start),"loadSeconds":loaded.timeIntervalSince(start),"asrSeconds":recognized.timeIntervalSince(loaded),"engine":transcriber.engineName,
                  "pieces":pieces.map {["start":$0.start,"end":$0.end,"text":$0.text] as [String:Any]},
                  "draft":rows(draft),"cues":rows(cues),"srt":SRTWriter.render(cues,charactersPerLine:SubtitleFileBuilder.lineWidth(for:language))],a[5])
    }
}
