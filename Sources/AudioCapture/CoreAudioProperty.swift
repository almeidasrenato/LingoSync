import CoreAudio
import Foundation

/// Erros da camada de captura, com mensagens que dizem o que fazer.
public enum CaptureError: LocalizedError {
    case osStatus(String, OSStatus)
    case processNotFound(pid_t)
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case let .osStatus(op, status):
            return "\(op) falhou (OSStatus \(status)\(Self.fourCC(status).map { " '\($0)'" } ?? ""))"
        case let .processNotFound(pid):
            return "Nenhum objeto de audio para o processo \(pid). Ele provavelmente nao esta tocando som."
        case let .unsupportedFormat(detail):
            return "Formato de audio inesperado no tap: \(detail)"
        }
    }

    /// OSStatus do Core Audio costuma ser um four-char code legivel.
    private static func fourCC(_ status: OSStatus) -> String? {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
}

func check(_ operation: String, _ status: OSStatus) throws {
    guard status == noErr else { throw CaptureError.osStatus(operation, status) }
}

/// Le uma propriedade de tamanho fixo de um objeto do Core Audio.
func audioProperty<T>(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    as type: T.Type = T.self
) throws -> T {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<T>.size)
    let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { value.deallocate() }
    try check(
        "AudioObjectGetPropertyData(\(selector.fourCC))",
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, value)
    )
    return value.pointee
}

/// Le uma propriedade de tamanho variavel como array.
func audioPropertyArray<T>(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    of type: T.Type = T.self
) throws -> [T] {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try check(
        "AudioObjectGetPropertyDataSize(\(selector.fourCC))",
        AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    )
    let count = Int(size) / MemoryLayout<T>.size
    guard count > 0 else { return [] }
    return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
        try check(
            "AudioObjectGetPropertyData(\(selector.fourCC))",
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer.baseAddress!)
        )
        initialized = count
    }
}

extension AudioObjectPropertySelector {
    var fourCC: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(self)"
    }
}
