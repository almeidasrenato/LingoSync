import Foundation

/// A versão publicada no GitHub, para o menu avisar quando há uma mais nova.
///
/// É o único contato com a rede que o app faz sozinho: um GET público, sem
/// conta, sem token e sem mandar nada da máquina. Quem instala continua sendo
/// o usuário — o app é assinado ad-hoc, e um `.app` trocado por ele mesmo
/// perderia a permissão de Gravação de Tela e Áudio (a mesma que cai ao
/// recompilar). O botão baixa o `.dmg` e o abre; arrastar para Aplicativos é
/// com quem usa.
public enum AppUpdate {

    public static let repository = URL(string: "https://github.com/almeidasrenato/LingoSync")!
    static let latestRelease = URL(
        string: "https://api.github.com/repos/almeidasrenato/LingoSync/releases/latest")!

    public struct Release: Sendable, Equatable {
        public let version: String
        public let page: URL
        /// O `.dmg` da release, quando ela tem um.
        public let diskImage: URL?

        public init(version: String, page: URL, diskImage: URL?) {
            self.version = version
            self.page = page
            self.diskImage = diskImage
        }
    }

    /// `1.0` e `1.0.0` são a mesma versão: o app de desenvolvimento declara
    /// `1.0` e a release grava `1.0.0`. O `v` da tag não conta.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// A última release publicada (o GitHub já deixa rascunho e pré-release
    /// de fora deste endereço).
    public static func latest() async throws -> Release {
        var request = URLRequest(url: latestRelease, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> Release {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return Release(
            version: payload.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
            page: payload.html_url,
            diskImage: payload.assets.first { $0.name.hasSuffix(".dmg") }?.browser_download_url)
    }
}
