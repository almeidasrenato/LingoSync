import Foundation
import TradutorCore
@main struct Replay {
 static func main() throws {
  let out=URL(fileURLWithPath:CommandLine.arguments[1]);let files=try FileManager.default.contentsOfDirectory(at:out,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("live-") && $0.pathExtension=="json"};var summary:[[String:Any]]=[]
  for f in files {
   let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:f)) as! [[String:Any]]
   for mode in ["before","received","final"] {
    var old=OldTracker();var oldP=OldAccumulator();var received=ReceivedTracker();var receivedP=ReceivedAccumulator();var tracker=StablePrefixTracker();var phrases=PhraseAccumulator();var events:[[String:Any]]=[];var confirmed=0;var total=0
    for r in rows {
     let text=r["text"] as! String;let end=r["final"] as! Bool;var closed:[String]=[];var newly:[String]=[]
     if mode == "before" {newly=end ? old.reconcile(text):old.feed(text);closed=oldP.append(newly);if end {if let p=oldP.flush(){closed.append(p)};old.reset()}}
     else if mode == "received" {newly=end ? received.reconcile(text):received.feed(text);closed=receivedP.append(newly);if end {if let p=receivedP.flush(){closed.append(p)};received.reset()}}
     else {newly=end ? tracker.reconcile(text):tracker.feed(text);closed=phrases.append(newly);if end {if let p=phrases.flush(){closed.append(p)};tracker.reset()}}
     let chars=newly.joined().filter{!$0.isWhitespace}.count;total += chars;if !end{confirmed += chars}
     if !closed.isEmpty {events.append(["time":r["time"]!,"final":end,"phrases":closed])}
    }
    summary.append(["file":f.lastPathComponent,"mode":mode,"hypotheses":rows.count,"confirmedBeforeFlush":confirmed,"totalCharacters":total,"earlyPhrases":events.filter{!($0["final"] as! Bool)}.flatMap{$0["phrases"] as! [String]}.count,"events":events])
   }
  }
  try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("prefix-comparison.json"))
  for r in summary {print(r["file"]!,r["mode"]!,r["confirmedBeforeFlush"]!,r["totalCharacters"]!,r["earlyPhrases"]!)}
 }
}
