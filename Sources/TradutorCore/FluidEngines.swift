import Accelerate
import FluidAudio
import Foundation

// O que sobrou dos reconhecedores opcionais do FluidAudio: o agrupamento de
// tokens em trechos e a régua de energia, que o Parakeet v3 e o Whisper usam.
//
// Passaram por aqui e saíram, cada um com a medição no CLAUDE.md: Cohere
// Transcribe (não marcava tempo, 7 GB de cache de compilação), Nemotron 3.5
// (media pior que Whisper e Apple), Parakeet japonês (reconhecia um terço do
// que os outros reconheciam) e Parakeet Unified EN (mesmo texto do v3, só
// inglês, 586 MB).
//
// Todos baixam no primeiro uso para a pasta de modelos do app — nunca para
// o padrão do FluidAudio (`Application Support/FluidAudio`).
//
// O Cohere Transcribe passou por aqui e saiu: não marcava tempo, e a
// compilação dele para o Neural Engine ocupava 7 GB de cache.

// MARK: - Tokens com tempo em trechos

enum TokenPhrases {

    /// Junta tokens marcados em trechos curtos.
    ///
    /// `buildWordTimings` do FluidAudio agrupa pelo marcador de palavra "▁",
    /// que japonês e chinês quase não têm: sairia uma "palavra" do tamanho da
    /// fala inteira. E tokens soltos seriam piores — o agrupador de legendas
    /// junta pedaços com espaço, e "今日は" viraria "今日 は". Mesmo motivo de
    /// `AppleSpeechTranscriber.phrases`.
    static func group(_ timings: [TokenTiming]) -> [TimedText] {
        var pieces: [TimedText] = []
        var text = ""
        var start: Double?
        var end = 0.0

        func close() {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let start, !clean.isEmpty {
                pieces.append(TimedText(text: clean, start: start, end: max(end, start)))
            }
            text = ""
            start = nil
        }

        for timing in timings {
            let raw = timing.token
            guard !raw.isEmpty, raw != "<blank>", raw != "<pad>",
                  !(raw.hasPrefix("<") && raw.hasSuffix(">"))
            else { continue }

            let piece = raw.replacingOccurrences(of: "\u{2581}", with: " ")
            // Só se corta onde começa palavra: em escrita com espaço, no "▁"
            // (ou no espaço, quando o FluidAudio já o trocou); em japonês,
            // chinês e coreano, em qualquer caractere.
            let startsWord = raw.hasPrefix("\u{2581}") || raw.hasPrefix(" ")
                || (raw.unicodeScalars.first.map(isCJK) ?? false)
            // Pontuação entra no texto mas não no tempo. O Parakeet Unified
            // emite o ponto final quando a frase seguinte começa: "on the
            // payments team." terminava aos 5,28 s com a fala acabando aos
            // 3,30 s, e a legenda atravessava a pausa inteira.
            let isPunctuation = piece.trimmingCharacters(in: .whitespaces).allSatisfy(\.isPunctuation)
            if let current = start, startsWord,
               timing.startTime - end > 0.5 || end - current >= 5 {
                close()
            }
            if start == nil, !isPunctuation { start = timing.startTime }
            text += piece
            if !isPunctuation { end = max(end, timing.endTime) }

            if let last = piece.trimmingCharacters(in: .whitespaces).last, ".!?。！？".contains(last) {
                close()
            }
        }
        close()
        return pieces
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xFF00...0xFFEF:
            true
        default:
            false
        }
    }
}

// MARK: - Onde há voz

/// Onde há voz no áudio, pela energia — sem modelo nenhum.
///
/// Serve de régua para os tempos dos reconhecedores: o que eles marcam é
/// quando o modelo decidiu cada token, e isso pode não coincidir com quando a
/// palavra soa.
public enum SpeechEnergy {

    /// Duração de cada quadro analisado.
    public static let frameSeconds = 0.03
    static let frameSamples = 480

    /// Um valor por quadro de 30 ms: verdadeiro onde há voz.
    public static func voiced(_ samples: [Float]) -> [Bool] {
        let frames = samples.count / frameSamples
        guard frames > 0 else { return [] }
        var energy = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { buffer in
            for index in 0..<frames {
                vDSP_rmsqv(buffer.baseAddress! + index * frameSamples, 1,
                           &energy[index], vDSP_Length(frameSamples))
            }
        }
        // Limiar relativo ao fundo do próprio arquivo: o quinto mais baixo dos
        // quadros é o ruído, e fala fica bem acima dele.
        let noise = energy.sorted()[frames / 5]
        let threshold = max(0.005, noise * 3)
        return energy.map { $0 > threshold }
    }

    /// Encosta cada trecho na fala de verdade: o começo volta até onde a voz
    /// começou (até 0,6 s) e o fim avança até onde ela acaba (até 2 s), sem
    /// invadir o trecho vizinho.
    ///
    /// Para reconhecedores cujo tempo é o da emissão do token, não o da
    /// palavra. Medido no Parakeet Unified com `tradutor-verify alinhamento`:
    /// as palavras saíam ~0,4 s depois de começarem a soar, e trechos
    /// terminavam até 1,9 s antes de a fala acabar.
    public static func fit(_ pieces: [TimedText], to samples: [Float]) -> [TimedText] {
        let flags = voiced(samples)
        guard !flags.isEmpty else { return pieces }
        let bridge = Int(0.25 / frameSeconds)        // silêncio menor é entre palavras
        let total = Double(flags.count) * frameSeconds
        func frame(_ time: Double) -> Int { min(flags.count - 1, max(0, Int(time / frameSeconds))) }

        var result: [TimedText] = []
        for (index, piece) in pieces.enumerated() {
            let previousEnd = result.last?.end ?? 0
            let nextStart = index + 1 < pieces.count ? pieces[index + 1].start : total

            // Começo: anda para trás enquanto houver voz.
            var onset = frame(piece.start)
            var silence = 0
            var cursor = onset
            let floor = max(frame(previousEnd), frame(piece.start - 0.6))
            while cursor > floor {
                cursor -= 1
                if flags[cursor] { onset = cursor; silence = 0 } else {
                    silence += 1
                    if silence >= bridge { break }
                }
            }

            // Fim: anda para frente enquanto houver voz.
            var offset = frame(piece.end)
            silence = 0
            cursor = offset
            let ceiling = min(frame(nextStart), frame(piece.end + 2))
            while cursor < ceiling {
                cursor += 1
                if flags[cursor] { offset = cursor + 1; silence = 0 } else {
                    silence += 1
                    if silence >= bridge { break }
                }
            }

            let start = max(previousEnd, min(piece.start, Double(onset) * frameSeconds))
            let end = min(nextStart, max(piece.end, Double(offset) * frameSeconds))
            result.append(TimedText(text: piece.text, start: start, end: max(end, start)))
        }
        return result
    }

    /// Trechos contínuos de fala, em segundos. Silêncio mais curto que
    /// `minimumPause` não separa — é o intervalo entre palavras.
    public static func regions(_ samples: [Float], minimumPause: Double = 0.25) -> [ClosedRange<Double>] {
        let flags = voiced(samples)
        let gap = Int(minimumPause / frameSeconds)
        var regions: [ClosedRange<Double>] = []
        var start: Int?
        var last = 0
        for (index, isVoiced) in flags.enumerated() {
            if isVoiced {
                if let current = start, index - last > gap {
                    regions.append(Double(current) * frameSeconds...Double(last + 1) * frameSeconds)
                    start = index
                } else if start == nil {
                    start = index
                }
                last = index
            }
        }
        if let current = start {
            regions.append(Double(current) * frameSeconds...Double(last + 1) * frameSeconds)
        }
        return regions
    }
}

// MARK: - Parakeet Unified EN
