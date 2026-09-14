import AppKit
import CoreAudio
import Foundation

/// Um aplicativo que o Core Audio conhece como fonte de audio.
///
/// Um "aplicativo" quase nunca e um processo so. O Chrome toca audio em
/// `com.google.Chrome.helper`, nao em `Google Chrome`; navegadores, Electron e
/// qualquer coisa com renderizador separado fazem igual. Escolher o processo
/// principal produz silencio absoluto, sem erro nenhum.
///
/// Por isso a unidade aqui e o aplicativo, e `objectIDs` carrega todos os
/// processos que pertencem a ele. O tap recebe a lista inteira.
public struct AudioProcess: Identifiable, Sendable {

    /// Chave estavel do aplicativo (bundle ID sem o sufixo de helper, ou o
    /// nome do executavel).
    public let id: String
    public let name: String
    /// Todos os processos do aplicativo, para o tap capturar de uma vez.
    public let objectIDs: [AudioObjectID]
    public let pids: [pid_t]
    /// true quando qualquer processo do aplicativo esta emitindo som agora.
    public let isPlaying: Bool

    /// PID principal, para exibicao e para o icone.
    public var pid: pid_t { pids.first ?? 0 }

    public var icon: NSImage? {
        for pid in pids {
            if let icon = NSRunningApplication(processIdentifier: pid)?.icon { return icon }
        }
        return nil
    }

    /// Identificador da opcao "todo o audio do sistema".
    public static let systemWideID = "__sistema__"

    /// Captura tudo que estiver tocando, seja qual for o aplicativo.
    ///
    /// Existe como escolha explicita porque antes isso acontecia por acidente:
    /// sem selecao, o app pegava o primeiro processo com som e o usuario
    /// achava que tinha escolhido outra coisa.
    public static let systemWide = AudioProcess(
        id: systemWideID,
        name: "Todo o áudio do sistema",
        objectIDs: [],
        pids: [],
        isPlaying: true
    )

    public var isSystemWide: Bool { id == Self.systemWideID }

    /// Identificador da opcao "o microfone".
    public static let microphoneID = "__microfone__"

    /// Captura pela entrada, nao pela saida.
    ///
    /// Entra na mesma lista dos aplicativos porque para o usuario a pergunta e
    /// uma so — "de onde vem o audio?" — e um segundo seletor ao lado dela
    /// seria um controle a mais para responder a mesma coisa. Qual microfone,
    /// ai sim, e outra pergunta, e so aparece quando esta e respondida.
    public static let microphone = AudioProcess(
        id: microphoneID,
        name: "Microfone",
        objectIDs: [],
        pids: [],
        isPlaying: false
    )

    public var isMicrophone: Bool { id == Self.microphoneID }

    public init(
        id: String,
        name: String,
        objectIDs: [AudioObjectID],
        pids: [pid_t],
        isPlaying: Bool
    ) {
        self.id = id
        self.name = name
        self.objectIDs = objectIDs
        self.pids = pids
        self.isPlaying = isPlaying
    }
}

/// Igualdade pela identidade do aplicativo, nunca pelo estado.
///
/// Com a conformidade sintetizada, `isPlaying` entrava na comparacao: assim
/// que o app comecava a tocar, o valor mudava, a `tag` do Picker deixava de
/// casar com a selecao e a escolha do usuario era descartada em silencio.
extension AudioProcess: Hashable {
    public static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public enum AudioProcessList {

    /// Aplicativos que o Core Audio expoe, com quem esta tocando som primeiro.
    public static func all() throws -> [AudioProcess] {
        let objectIDs: [AudioObjectID] = try audioPropertyArray(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList
        )

        struct Raw {
            let objectID: AudioObjectID
            let pid: pid_t
            let bundleID: String?
            let runningName: String?
            let runningBundleID: String?
            let executable: String?
            let isPlaying: Bool
            /// `.regular` tem ícone no Dock, `.accessory` mora na barra de
            /// menus, `.prohibited` não pode nem ser ativado — é agente de
            /// sistema, não aplicativo.
            let policy: NSApplication.ActivationPolicy?
            let bundlePath: String?
        }

        let raws: [Raw] = objectIDs.compactMap { objectID in
            guard let pid: pid_t = try? audioProperty(objectID, kAudioProcessPropertyPID) else {
                return nil
            }
            let running = NSRunningApplication(processIdentifier: pid)
            let playing = (try? audioProperty(objectID, kAudioProcessPropertyIsRunningOutput) as UInt32) ?? 0

            // O Core Audio devolve string VAZIA (nao nil) para processos sem
            // bundle, entao `??` sozinho aceitaria o vazio.
            let raw = (try? audioProperty(objectID, kAudioProcessPropertyBundleID) as CFString?)
                .flatMap { $0 as String? }

            return Raw(
                objectID: objectID,
                pid: pid,
                bundleID: (raw?.isEmpty == true) ? nil : raw,
                runningName: running?.localizedName,
                runningBundleID: running?.bundleIdentifier,
                executable: processName(for: pid),
                isPlaying: playing != 0,
                policy: running?.activationPolicy,
                bundlePath: running?.bundleURL?.path
            )
        }

        // Agrupa helpers com o aplicativo dono.
        var groups: [String: [Raw]] = [:]
        var order: [String] = []
        for raw in raws {
            let key = groupKey(for: raw.runningBundleID ?? raw.bundleID, executable: raw.executable, pid: raw.pid)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(raw)
        }

        let own = Bundle.main.bundleIdentifier
        let processes: [AudioProcess] = order.compactMap { key in
            guard let members = groups[key] else { return nil }

            // O nome tem que ser o do aplicativo, nao o do helper. Quando so
            // o helper esta emitindo audio — que e o caso normal do Chrome —
            // nenhum membro do grupo conhece o nome bom, entao ele e buscado
            // pelo bundle ID do dono.
            let exact = members.first { $0.runningBundleID == key || $0.bundleID == key }
            // Sem `?? key` no fim: a lista so mostra quem tem nome de
            // aplicativo. Os fallbacks antigos enchiam o seletor de
            // `com.apple.WebKit.GPU`, `pid:57939` e `exec:coreaudiod` — linhas
            // que o usuario nao reconhece e nao tem por que escolher. O que
            // sobra desses processos continua alcancavel por "Todo o audio do
            // sistema", que e a escolha honesta para eles.
            guard let name = exact?.runningName
                ?? displayName(forBundleID: key)
                ?? members.compactMap(\.runningName).first
            else { return nil }

            // Capturar a si mesmo nao faz sentido, e o app aparecia na lista
            // por causa do proprio aggregate device do tap.
            guard key != own else { return nil }

            let playing = members.contains(where: \.isPlaying)
            // Agente de sistema fica de fora. Duas peneiras, as duas medidas
            // em 14/09/2026 numa maquina comum, que devolvia nove entradas:
            //
            //   `.prohibited`          universalaccessd, SiriNCService,
            //                          QuickLookUIService — nem ativar da
            //   `/System/Library/`     loginwindow, PowerChime, Central de
            //                          Controle — sao `.accessory`, entao a
            //                          politica sozinha nao os pega
            //
            // Politica sozinha nao bastava e caminho sozinho tambem nao: o
            // Vorssaint e `.accessory` em `/Applications` e tem de ficar.
            // Sobraram tres nomes, todos escolhiveis. O que estiver tocando som
            // AGORA passa de qualquer jeito — se sai audio dali, pode ser o que
            // o usuario quer.
            let visible = members.contains { raw in
                raw.policy != nil && raw.policy != .prohibited
                    && !(raw.bundlePath?.hasPrefix("/System/Library/") ?? true)
            }
            guard playing || visible else { return nil }

            return AudioProcess(
                id: key,
                name: name,
                objectIDs: members.map(\.objectID),
                pids: members.map(\.pid),
                isPlaying: playing
            )
        }

        return processes.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Somente o que esta com audio ativo agora.
    public static func playing() throws -> [AudioProcess] {
        try all().filter(\.isPlaying)
    }

    /// Reduz o bundle ID de um helper ao do aplicativo dono.
    ///
    ///     com.google.Chrome.helper.renderer  ->  com.google.Chrome
    ///     com.microsoft.VSCode.helper        ->  com.microsoft.VSCode
    public static func groupKey(for bundleID: String?, executable: String?, pid: pid_t) -> String {
        guard let bundleID, !bundleID.isEmpty else {
            return executable.map { "exec:\($0)" } ?? "pid:\(pid)"
        }

        var parts = bundleID.split(separator: ".").map(String.init)
        // Corta tudo a partir do primeiro componente que denuncia um helper.
        if let index = parts.firstIndex(where: { component in
            let lower = component.lowercased()
            return lower == "helper" || lower.hasPrefix("helper")
        }) {
            parts = Array(parts.prefix(index))
        }
        let trimmed = parts.joined(separator: ".")
        return trimmed.isEmpty ? bundleID : trimmed
    }

    /// Nome do aplicativo a partir do bundle ID, mesmo que ele nao esteja
    /// entre os processos que emitem audio.
    private static func displayName(forBundleID bundleID: String) -> String? {
        guard bundleID.contains("."),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        let trimmed = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func processName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
