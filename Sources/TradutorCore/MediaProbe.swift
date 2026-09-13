import Foundation

/// Descobre o container de um arquivo pelos primeiros bytes, sem confiar na
/// extensão.
///
/// Existe por dois motivos. O primeiro é que arquivo sem extensão nenhuma é
/// comum — download interrompido, arquivo renomeado, mídia vinda de outro
/// sistema — e recusá-lo por causa do nome seria recusar por um detalhe que
/// não diz nada sobre o conteúdo.
///
/// O segundo é a mensagem de erro. Quando o formato realmente não é suportado,
/// dizer "não foi possível decodificar" não ajuda ninguém; dizer "isto é um
/// Matroska, e o sistema não lê Matroska" resolve a dúvida na hora.
public enum MediaProbe {

    /// Containers que o AVFoundation abre neste sistema.
    public static let supportedNames = [
        "MP4", "M4V", "M4A", "MOV", "MP3", "WAV", "AIFF", "AAC", "CAF", "FLAC",
    ]

    /// Nome legível do container, ou `nil` quando os bytes não batem com nada
    /// conhecido.
    public static func sniff(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), data.count >= 12 else { return nil }

        let bytes = [UInt8](data)

        func matches(_ signature: [UInt8], at offset: Int) -> Bool {
            guard bytes.count >= offset + signature.count else { return false }
            return Array(bytes[offset..<(offset + signature.count)]) == signature
        }
        func ascii(_ text: String, at offset: Int) -> Bool {
            matches(Array(text.utf8), at: offset)
        }

        // ISO base media: "ftyp" no offset 4, com a marca do perfil logo depois.
        if ascii("ftyp", at: 4) {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            switch brand.prefix(3) {
            case "qt ": return "MOV"
            case "M4A": return "M4A"
            case "M4V": return "M4V"
            default: return "MP4"
            }
        }

        if ascii("RIFF", at: 0) {
            if ascii("WAVE", at: 8) { return "WAV" }
            if ascii("AVI ", at: 8) { return "AVI" }
            return "RIFF"
        }
        if ascii("FORM", at: 0), ascii("AIFF", at: 8) || ascii("AIFC", at: 8) { return "AIFF" }
        if ascii("caff", at: 0) { return "CAF" }
        if ascii("fLaC", at: 0) { return "FLAC" }
        if ascii("OggS", at: 0) { return "Ogg" }
        if ascii("ID3", at: 0) { return "MP3" }
        // EBML: Matroska e WebM compartilham o cabeçalho.
        if matches([0x1A, 0x45, 0xDF, 0xA3], at: 0) {
            let head = Array(bytes.prefix(256))
            return head.containsSubsequence(Array("webm".utf8)) ? "WebM" : "MKV"
        }
        if matches([0x30, 0x26, 0xB2, 0x75], at: 0) { return "ASF/WMV" }
        // MPEG-TS: pacotes de 188 bytes começando em 0x47.
        if bytes[0] == 0x47, bytes.count > 188, bytes[188] == 0x47 { return "MPEG-TS" }
        // Frame sync de MPEG audio sem tag ID3.
        if bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 { return "MP3" }

        return nil
    }

    /// Se o container detectado é um dos que o sistema abre.
    public static func isSupported(_ container: String?) -> Bool {
        guard let container else { return false }
        return supportedNames.contains(container)
    }
}

private extension Array where Element == UInt8 {
    func containsSubsequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        for start in 0...(count - needle.count) where Array(self[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}
