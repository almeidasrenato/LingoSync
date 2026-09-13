import Foundation
import TradutorCore
import AudioCapture

@available(macOS 26.0, *)
@main struct Measure {
 @MainActor static func main() async throws {
  let args=CommandLine.arguments; let mode=args[1]; let url=URL(fileURLWithPath:args[2]); let lang=Language(rawValue:args[3])!;let dest=URL(fileURLWithPath:args[4]); let samples=try await SubtitleFileBuilder.extractAudio(from:url)
  func save(_ value:Any) throws {try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:dest)}
  if mode == "phrases" {
   let tr=MeasuredApple(language:lang);try await tr.prepare{_,_ in};let turns=try await SpeakerDiarizer.turns(in:samples,model:.sortformer)
   var rows:[[String:Any]]=[]
   for rep in 1...2 {
    for diar in [false,true] {
     var result=try await tr.measured(samples,boundaries:diar ? SpeakerDiarizer.boundaries(of:turns) : [])
     result["repeat"]=rep; result["diarize"]=diar;rows.append(result);try save(rows)
    }
   }
  } else if mode == "live" {
   let audio=Array(samples.prefix(75*16000));let tr=TranscriberFactory.make(for:lang,engine:.apple);try await tr.prepare{_,_ in}
   let segmenter=Segmenter();var rows:[[String:Any]]=[]
   for start in stride(from:0,to:audio.count,by:9600) {
    let end=min(start+9600,audio.count)
    for s in segmenter.feed(Array(audio[start..<end])) {
     let text=try await tr.transcribe(s.samples);rows.append(["time":Double(end)/16000,"final":true,"text":text])
    }
    if segmenter.isSpeaking,segmenter.inFlight.count>8000 {
     let text=try await tr.transcribe(segmenter.inFlight);rows.append(["time":Double(end)/16000,"final":false,"text":text])
    }
    try save(rows)
   }
   if let last=segmenter.flush() {let text=try await tr.transcribe(last.samples);rows.append(["time":Double(audio.count)/16000,"final":true,"text":text]);try save(rows)}
  } else if mode == "diargain" {
   let audio=Array(samples.prefix(40*16000));var rows:[[String:Any]]=[]
   for model in [SpeakerDiarizer.Model.sortformer, .clustering] {
    for rep in 1...2 {
     for factor:Float in [1,0.01] {
      for boosted in [false,true] {
       let quiet=audio.map{$0*factor};let rms=sqrt(quiet.reduce(0.0){$0+Double($1*$1)}/Double(quiet.count));let peak=quiet.map{abs($0)}.max() ?? 0
       let gain:Float=boosted && rms>0.00001 && rms<0.003 ? min(20,Float(0.03/rms),0.95/max(peak,0.00001)) : 1
       let turns=try await SpeakerDiarizer.turns(in:quiet.map{$0*gain},model:model)
       rows.append(["model":model.rawValue,"repeat":rep,"factor":factor,"boosted":boosted,"gain":gain,"turns":turns.map{["start":$0.start,"end":$0.end,"speaker":$0.speaker] as [String:Any]}]);try save(rows)
      }
     }
    }
   }
  } else if mode == "gain" || mode == "gain-low" {
   let engine=RecognitionEngine(rawValue:args[5])!;let tr=TranscriberFactory.make(for:lang,engine:engine);try await tr.prepare{_,_ in}
   let audio=Array(samples.prefix(40*16000));var rows:[[String:Any]]=[]
   for rep in 1...2 {
    for factor:Float in (mode == "gain-low" ? [1,0.01] : [1,0.1,0.01]) {
     for boosted in (rep == 1 ? [false,true] : [true,false]) {
      let quiet=audio.map{$0*factor};let rms=sqrt(quiet.reduce(0.0){$0+Double($1*$1)}/Double(quiet.count));let peak=quiet.map{abs($0)}.max() ?? 0
      let gain:Float = boosted && rms>0.00001 && rms<0.03 ? min(20,Float(0.03/rms),0.95/max(peak,0.00001)) : 1
      let x=quiet.map{$0*gain};let start=Date();let timed=try await tr.transcribeTimed(x)
      rows.append(["repeat":rep,"factor":factor,"boosted":boosted,"gain":gain,"rms":rms,"seconds":Date().timeIntervalSince(start),"text":timed.map(\.text).joined(separator:" "),"pieces":timed.map{["text":$0.text,"start":$0.start,"end":$0.end] as [String:Any]}]);try save(rows)
     }
    }
   }
  }
  print("DONE \(mode) \(url.lastPathComponent) \(dest.lastPathComponent)")
 }
}
