import AVFoundation
import Foundation

/// Converte o mono nativo do tap (48 kHz) para os 16 kHz que os
/// reconhecedores exigem.
///
/// A razao e exatamente 3:1, mas decimar na unha introduz aliasing. O
/// AVAudioConverter ja traz o filtro anti-aliasing, entao nao ha motivo para
/// escrever um.
///
/// Duas armadilhas do AVAudioConverter estao tratadas aqui:
///
/// 1. O bloco de entrada recebe um numero de pacotes pedido e o que passar
///    disso e descartado em silencio. Entregar o buffer inteiro de uma vez faz
///    perder dois tercos do audio sem nenhum erro.
/// 2. Sinalizar `.endOfStream` encerra o conversor de vez. Como aqui ele e
///    reusado a cada bloco do fluxo continuo, a falta de dados e sinalizada
///    com `.noDataNow`, que preserva o estado do filtro entre as chamadas e
///    evita descontinuidade nas emendas.
public final class Resampler {

    public static let targetSampleRate: Double = 16_000

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let outputBuffer: AVAudioPCMBuffer

    /// Capacidade do buffer de saida por volta do laco.
    private static let chunkFrames: AVAudioFrameCount = 4096

    public init(inputSampleRate: Double) throws {
        guard let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: 1,
            interleaved: false
        ), let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: input, to: output),
           let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: Self.chunkFrames)
        else {
            throw CaptureError.unsupportedFormat(
                "nao foi possivel montar conversor de \(inputSampleRate) Hz para 16 kHz"
            )
        }
        self.inputFormat = input
        self.outputFormat = output
        self.converter = converter
        self.outputBuffer = out
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    }

    public func resample(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }

        var position = 0
        var result: [Float] = []
        result.reserveCapacity(
            Int(Double(samples.count) * Self.targetSampleRate / inputFormat.sampleRate) + 64
        )

        while true {
            let positionAtStart = position
            outputBuffer.frameLength = 0
            var conversionError: NSError?

            let status = converter.convert(to: outputBuffer, error: &conversionError) {
                requested, ioStatus in
                let remaining = samples.count - position
                guard remaining > 0 else {
                    // Nao usar .endOfStream: o conversor e reusado no proximo
                    // bloco do fluxo continuo e nao pode ser encerrado aqui.
                    ioStatus.pointee = .noDataNow
                    return nil
                }
                let count = min(Int(requested), remaining)
                // Buffer novo a cada chamada: o conversor pode segurar a
                // referencia depois que o bloco retorna, entao reaproveitar um
                // unico buffer faz ele ler audio ja sobrescrito.
                guard let chunk = AVAudioPCMBuffer(
                    pcmFormat: self.inputFormat,
                    frameCapacity: AVAudioFrameCount(count)
                ) else {
                    ioStatus.pointee = .noDataNow
                    return nil
                }
                chunk.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { source in
                    chunk.floatChannelData![0].update(
                        from: source.baseAddress! + position,
                        count: count
                    )
                }
                position += count
                ioStatus.pointee = .haveData
                return chunk
            }

            if let conversionError {
                throw CaptureError.osStatus(
                    "AVAudioConverter.convert",
                    OSStatus(conversionError.code)
                )
            }

            let produced = Int(outputBuffer.frameLength)
            if produced > 0, let channel = outputBuffer.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: produced))
            }

            if status == .error { break }
            // Sai quando a entrada acabou e o conversor drenou o filtro, ou
            // quando uma volta inteira nao consumiu nem produziu nada — sem
            // essa guarda um comportamento inesperado vira laco infinito.
            if position >= samples.count, produced == 0 { break }
            if position == positionAtStart, produced == 0 { break }
        }

        return result
    }
}
