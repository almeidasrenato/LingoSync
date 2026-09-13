import Foundation
import TradutorCore
@main struct Noise {
 @MainActor static func main() async throws {
  let out=URL(fileURLWithPath:CommandLine.arguments[1]);var seed:UInt64=12345
  let noise:[Float]=(0..<160_000).map{_ in seed=seed &* 6364136223846793005 &+ 1;return (Float(seed>>40)/Float(1<<24)-0.5)*0.0004}
  let cases:[(String,[Float])]=[("silence",[Float](repeating:0,count:160_000)),("noise",noise)]
  var results:[[String:Any]]=[]
  for (engine,language) in [(RecognitionEngine.apple,Language.japanese),(.apple,.english),(.whisper,.japanese),(.whisper,.english),(.parakeet,.english)] {
   let tr=TranscriberFactory.make(for:language,engine:engine);try await tr.prepare{_,_ in}
   for (name,samples) in cases {
    for boost in [false,true] {
     let x=boost ? SubtitleFileBuilder.boostQuietAudio(samples):samples;let text=try await tr.transcribe(x)
     results.append(["engine":engine.rawValue,"language":language.rawValue,"input":name,"boosted":boost,"text":text]);print(engine,language,name,boost,text)
     try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:out)
    }
   }
  }
 }
}
