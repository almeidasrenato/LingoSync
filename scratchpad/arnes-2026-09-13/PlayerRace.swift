import Foundation
import TradutorCore
@MainActor enum AuditDuration {
 static var call=0
 static func load(_ url:URL) async -> Double {
  call += 1;let request=call
  try? await Task.sleep(for:.milliseconds(request == 1 ? 200 : 10))
  return request == 1 ? 540 : 109
 }
}
@main struct PlayerRace {
 @MainActor static func main() async throws {
  let a=URL(fileURLWithPath:"/tmp/auditoria-tradutor-20260912/ja-longo.mp4");let b=URL(fileURLWithPath:"/tmp/auditoria-tradutor-20260912/en-dialogo.mp4")
  var failures=0
  for same in [false,true] {
   AuditDuration.call=0;let m=SubtitleStudioModel();m.open(a)
   try await Task.sleep(for:.milliseconds(20));m.open(same ? a:b)
   try await Task.sleep(for:.milliseconds(300));let ok=m.duration==109
   print("RACE sameURL=\(same) expected=109 actual=\(m.duration) \(ok ? "PASSOU":"FALHA")")
   if !ok {failures += 1};m.stop()
  }
  AuditDuration.call=0;let m=SubtitleStudioModel();m.open(a)
  try await Task.sleep(for:.milliseconds(20));m.stop()
  try await Task.sleep(for:.milliseconds(300));let ok=m.duration==0
  print("STOP expected=0 actual=\(m.duration) \(ok ? "PASSOU":"FALHA")");if !ok{failures += 1}
  exit(failures==0 ? 0:1)
 }
}
