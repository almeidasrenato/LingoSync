import Foundation
import TradutorCore
import WhisperKit
struct Case: Codable {
 var file: String
 var start: Double
 var end: Double
 var suspect: String
 var confirmation: String
 var accepted: Bool
}
@main struct Confirm {
 static func main() async throws {
  let a=Array(CommandLine.arguments.dropFirst()); let folder=URL(fileURLWithPath:a[0])
  var cases: [Case]=[]
  for lang in [Language.japanese,.english] {
   let apple=TranscriberFactory.make(for:lang,engine:.apple); try await apple.prepare { _,_ in }
   let files=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter { $0.pathExtension=="json" && $0.lastPathComponent.hasPrefix(lang==Language.japanese ? "ja-" : "en-") }
   for file in files.sorted(by:{$0.path<$1.path}) {
    let root=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
    let attempts=root["attempts"] as! [[[String:Any]]]
    let basename=file.deletingPathExtension().lastPathComponent.split(separator:"-").dropLast().joined(separator:"-")
    let data=try Data(contentsOf:folder.appendingPathComponent(basename+".f32"))
    let samples=data.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
    for segment in attempts[0] {
     let suspect=WhisperTranscriber.stripSpecialTokens(segment["text"] as! String)
     guard Hallucinations.isIsolatedFiller(suspect), !suspect.isEmpty else { continue }
     let start=segment["start"] as! Double; let end=segment["end"] as! Double
     let begin=max(0,min(samples.count,Int((start-0.5)*16000)))
     let finish=max(begin,min(samples.count,Int((end+0.5)*16000)))
     let answer=finish > begin ? try await apple.transcribe(Array(samples[begin..<finish])) : ""
     func norm(_ s:String)->String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
     let accepted = norm(answer).contains(norm(suspect))
     cases.append(Case(file:file.lastPathComponent,start:start,end:end,suspect:suspect,confirmation:answer,accepted:accepted))
     print("\(file.lastPathComponent) \(String(format:"%.1f",start)): \(suspect) => \(answer), preservar=\(accepted)")
     fflush(stdout)
    }
   }
  }
  let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
  try encoder.encode(cases).write(to:URL(fileURLWithPath:a[1]))
 }
}
