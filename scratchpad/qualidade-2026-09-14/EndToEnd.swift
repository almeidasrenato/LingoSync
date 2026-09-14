import Foundation
import TradutorCore
@main struct EndToEnd {
 static func main() async throws {
  let out=URL(fileURLWithPath:"/tmp/tradutor-qualidade-final")
  try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
  var count=0
  for engine in [RecognitionEngine.whisper,.apple,.qwenLarge] {
   for (name,language,target) in [("ja-boa-noite",Language.japanese,"noite"),("en-obrigado",Language.english,"assistir")] {
    let builder=SubtitleFileBuilder(); defer { builder.finish() }
    let cues=try await builder.generate(from:URL(fileURLWithPath:"/tmp/tradutor-qualidade-falas/"+name+".wav"),source:language,target:.portuguese,engine:engine,translation:.apple,progress:{ _,_,_,_ in })
    precondition(!cues.isEmpty && cues.contains { $0.translated.lowercased().contains(target) },"fala real não chegou à tradução")
    precondition(cues.allSatisfy { $0.end > $0.start && $0.end-$0.start <= builder.maximumDuration })
    precondition(cues.allSatisfy { $0.translated.components(separatedBy:"\n").count <= 2 })
    let srt=SRTWriter.render(cues)
    try srt.write(to:out.appendingPathComponent(name+"-"+engine.rawValue+".srt"),atomically:true,encoding:.utf8)
    count += 1; print("PASSOU \(name) \(engine.rawValue): \(cues.map(\.translated).joined(separator:" / "))"); fflush(stdout)
   }
  }
  let builder=SubtitleFileBuilder(); defer { builder.finish() }
  do {
   _ = try await builder.generate(from:URL(fileURLWithPath:"/tmp/tradutor-qualidade-falas/silencio.wav"),source:.english,target:.portuguese,engine:.whisper,translation:.apple,progress:{ _,_,_,_ in })
   fatalError("gerou legenda em silêncio digital")
  } catch SubtitleFileError.noSpeech { print("PASSOU silêncio digital sem legenda inventada") }
  print("\(count) gerações completas + controle de silêncio passaram")
 }
}
