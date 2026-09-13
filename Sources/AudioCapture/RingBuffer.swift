import Foundation
import Synchronization

/// Ring buffer de um produtor e um consumidor.
///
/// O lado da escrita roda dentro do IOProc do Core Audio, em contexto de tempo
/// real: nao pode alocar, nao pode travar, nao pode chamar Objective-C. Por
/// isso o armazenamento e pre-alocado e a sincronizacao e so um par de indices
/// atomicos.
public final class RingBuffer: @unchecked Sendable {

    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let overflowCount = Atomic<Int>(0)

    /// - Parameter seconds: quanto audio o buffer segura antes de descartar.
    public init(seconds: Double = 30, sampleRate: Double = 48_000) {
        capacity = Int(seconds * sampleRate)
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Quantas vezes o consumidor ficou para tras e amostras foram perdidas.
    /// Diferente de zero em producao significa que algo esta segurando a fila.
    public var overflows: Int { overflowCount.load(ordering: .relaxed) }

    public var available: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed)
    }

    /// Chamado pelo IOProc. Sem alocacao, sem trava.
    public func write(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)

        if write - read + samples.count > capacity {
            overflowCount.add(1, ordering: .relaxed)
        }

        for offset in 0..<samples.count {
            storage[(write + offset) % capacity] = base[offset]
        }
        writeIndex.store(write + samples.count, ordering: .releasing)
    }

    /// Chamado pelo consumidor. Devolve quantas amostras foram copiadas.
    @discardableResult
    public func read(into destination: inout [Float], maximum: Int) -> Int {
        let write = writeIndex.load(ordering: .acquiring)
        var read = readIndex.load(ordering: .relaxed)

        // Se o produtor deu a volta, pula o que ja foi sobrescrito em vez de
        // entregar audio embaralhado.
        if write - read > capacity {
            read = write - capacity
        }

        let count = min(write - read, maximum)
        guard count > 0 else { return 0 }

        if destination.count < count {
            destination = [Float](repeating: 0, count: count)
        }
        for offset in 0..<count {
            destination[offset] = storage[(read + offset) % capacity]
        }
        readIndex.store(read + count, ordering: .releasing)
        return count
    }
}
