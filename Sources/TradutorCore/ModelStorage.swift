import Foundation

/// Onde os modelos ficam gravados.
///
/// Os padroes das bibliotecas divergem, e um deles e ruim: o Hugging Face Hub
/// grava em `~/Documents/huggingface`, que na maioria das contas sincroniza com
/// o iCloud — tres gigabytes de pesos subindo para a nuvem sem o usuario pedir.
///
/// Application Support e o lugar certo para dado grande, regeneravel e que nao
/// deve ser sincronizado nem entrar no backup.
public enum ModelStorage {

    public static let root: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tradutor", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // Regeneravel a partir do Hugging Face: nao faz sentido no Time Machine.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = base
        try? mutable.setResourceValues(values)

        return base
    }()

    public static let translation = root.appendingPathComponent("translation", isDirectory: true)
    public static let whisper = root.appendingPathComponent("whisper", isDirectory: true)
    public static let parakeet = root.appendingPathComponent("parakeet", isDirectory: true)
    /// O FluidAudio grava na pasta irmã com o nome do repositório
    /// (`parakeet-0.6b-ja-coreml`), como faz com o v3.

    /// Quanto os modelos ja ocupam. Mostrado nas preferencias, porque tres
    /// gigabytes aparecendo do nada merecem explicacao.
    public static func diskUsageBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                .totalFileAllocatedSize
            total += Int64(size ?? 0)
        }
        return total
    }
}

/// O que o app deixa em disco além dos modelos, e a faxina disso.
///
/// Medido em 11/09/2026, antes desta faxina existir: 3,6 GB em
/// `~/Library/Caches/<bundle>`, quase tudo compilação dos modelos para o
/// Neural Engine feita pelo Core ML — 3,3 GB dela de um modelo que já tinha
/// saído do app —, mais o cache HTTP dos downloads e 88 pastas temporárias
/// esquecidas. Tradução não deixa nada: o framework da Apple não grava cache
/// no espaço do app, e o histórico das legendas vive só na memória.
public enum CacheCleanup {

    /// Mude quando o conjunto de modelos mudar. A compilação para o Neural
    /// Engine é guardada por hash, sem dizer de qual modelo veio; a única
    /// forma segura de soltar a de um modelo que saiu é refazer tudo uma vez.
    /// Custa uma primeira carga mais lenta.
    ///
    /// 1: Whisper turbo + Parakeet v3, depois de sair o large-v3.
    /// 2: + Parakeet japonês, Nemotron 3.5, Cohere. O Cohere rodou primeiro
    ///    na GPU e deixou 9 GB de compilação que o Neural Engine não usa.
    /// 3: sai o Cohere — a compilação dele ocupava 7 GB.
    /// 4: sai o Nemotron 3.5 — media pior que o Whisper e que a Apple.
    /// 5: saem o Parakeet japonês (reconhecia um terço do que os outros
    ///    reconheciam) e o Parakeet Unified EN (mesmo texto do v3, só inglês).
    static let modelSetVersion = 6
    private static let versionKey = "conjuntoDeModelosCompilado"

    /// Chamar ao abrir o app, antes de qualquer download ou carga de modelo.
    public static func run() {
        // Os downloads de modelo passam pelo URLSession padrão, que guarda
        // cópia em Cache.db. Arquivo baixado uma vez para uma pasta própria
        // não tem por que existir de novo em cache HTTP.
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, directory: nil)

        let files = FileManager.default
        if let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let bundle = Bundle.main.bundleIdentifier {
            let own = caches.appendingPathComponent(bundle, isDirectory: true)
            for name in ["fsCachedData", "Cache.db", "Cache.db-shm", "Cache.db-wal"] {
                try? files.removeItem(at: own.appendingPathComponent(name))
            }
            pruneCompiledModels(in: own.appendingPathComponent("com.apple.e5rt.e5bundlecache"))
        }
        removeStaleTemporaries()
    }

    /// O Core ML separa a compilação por versão do sistema. Depois de uma
    /// atualização do macOS a pasta da versão anterior nunca mais é lida.
    static func pruneCompiledModels(in folder: URL) {
        let files = FileManager.default
        let defaults = UserDefaults.standard

        // Sobras de uma faxina interrompida (app encerrado no meio).
        let parent = folder.deletingLastPathComponent()
        for leftover in (try? files.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        where leftover.lastPathComponent.hasPrefix("descartado-") {
            discardInBackground(leftover)
        }

        if defaults.integer(forKey: versionKey) != modelSetVersion {
            // Renomeia na hora e apaga depois. Apagar direto 3 GB leva
            // segundos, e o Core ML que começasse a compilar nesse meio tempo
            // gravaria dentro da pasta sendo apagada — o Whisper recompilava
            // (108 s em vez de 15 s) na abertura seguinte.
            let discarded = parent.appendingPathComponent("descartado-\(UUID().uuidString)")
            if (try? files.moveItem(at: folder, to: discarded)) != nil {
                discardInBackground(discarded)
            }
            defaults.set(modelSetVersion, forKey: versionKey)
            return
        }

        guard let build = osBuild(),
              let entries = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where entry.lastPathComponent != build {
            try? files.removeItem(at: entry)
        }
    }

    /// Apelidos `.mp4` de sessões que terminaram sem passar pela limpeza —
    /// app encerrado com a janela de legendas aberta, por exemplo. Só os
    /// velhos: outra instância pode estar usando um recente.
    static func removeStaleTemporaries() {
        let files = FileManager.default
        let temporary = files.temporaryDirectory
        guard let entries = try? files.contentsOfDirectory(
            at: temporary, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        let limit = Date().addingTimeInterval(-3600)
        for entry in entries where entry.lastPathComponent.hasPrefix("tradutor-") {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < limit { try? files.removeItem(at: entry) }
        }
    }

    private static func discardInBackground(_ url: URL) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func osBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
