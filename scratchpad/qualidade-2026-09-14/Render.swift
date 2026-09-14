import Foundation
import TradutorCore

struct Row: Codable {
 var source: String
 var translated: String
 var start: Double
 var end: Double
}
@main struct Render {
 static func main() async throws {
  let a=Array(CommandLine.arguments.dropFirst())
  let lang=Language(rawValue:a[0])!
  let input=URL(fileURLWithPath:a[1]); let output=URL(fileURLWithPath:a[2])
  let parsed=try SRTParser.parse(contentsOf:input)
  let builder=SubtitleFileBuilder()
  let timed=parsed.map { TimedText(text:$0.translated,start:$0.start,end:$0.end) }
  let cues=builder.makeCues(from:timed)
  let translator=AppleTranslator(); try await translator.prepare { _,_ in }
  let result=await builder.translate(cues,using:translator,from:lang,to:.portuguese)
  guard builder.translationNotice == nil else { fatalError(builder.translationNotice!) }
  let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
  try encoder.encode(result.map { Row(source:$0.source,translated:$0.translated,start:$0.start,end:$0.end) }).write(to:output)
  print("\(input.lastPathComponent): \(cues.count) entradas, \(result.count) legendas")
  translator.reset()
 }
}
