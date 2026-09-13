import AppKit
import Foundation
import OSLog
import WebKit

/// Tradução pelo site do DeepL, sem API e sem chave.
///
/// Por que existe: medido em 12/09/2026 sobre dois vídeos japoneses (66 falas),
/// o DeepL ganha do tradutor do sistema em gênero, nome próprio e registro —
/// ver "DeepL e Google ganham da Apple em japonês" no CLAUDE.md. O que ele
/// custa é a premissa do app: o texto sai da máquina. Por isso é opção, e o
/// padrão continua sendo a Apple.
///
/// **Como o texto entra.** Uma carga de página para o primeiro bloco, e
/// limpar-e-colar para todos os seguintes.
///
/// O campo do site é um `contenteditable` com editor próprio.
/// `execCommand('insertText')` nele não produz uma única requisição — e foi
/// isso que, por um tempo, fez este arquivo recarregar a página a cada bloco.
/// O que o editor aceita é um **evento de cola**: `ClipboardEvent('paste')`
/// com um `DataTransfer`, que é o mesmo caminho de quem aperta ⌘V. Para
/// esvaziar existe o botão do próprio site,
/// `translator-source-clear-button`. Medido em 12/09/2026, dois ciclos
/// seguidos de limpar-colar-ler: 2,2 s e 3,0 s, contagem exata nos dois.
///
/// Por que isso importa mais que os segundos: **recarregar a página a cada
/// bloco é o que parece robô.** O armazenamento é `nonPersistent`, então cada
/// carga chegava sem cookie nenhum, como um visitante novo — e depois de
/// algumas seguidas vinha o desafio da Cloudflare. Colar mantém uma sessão só.
///
/// A primeira carga continua existindo porque é ela que fixa o par de idiomas,
/// pelo formato de link do próprio site, `#<origem>/<destino>/<texto>`. Cada
/// linha do texto vira um `<p>`, e é daí que sai a contagem preservada.
///
/// **O detalhe que custa uma tarde:** trocar só o fragmento não recarrega
/// nada — a página é uma SPA e ignora o fragmento novo. Por isso a carga leva
/// um parâmetro de consulta descartável.
public enum DeepLWeb {

    /// O site gratuito recusa acima de 1500 caracteres por vez. 1400 deixa
    /// margem e foi o tamanho usado na medição que aprovou o motor.
    ///
    /// Fala isolada maior que isto não acontece neste app: o agrupador corta
    /// em 150 caracteres (`SubtitleFileBuilder.maximumCharacters`).
    public static let characterLimit = 1400

    /// Reparte as falas em blocos que cabem no limite, cortando em fim de
    /// linha — cortar no meio de uma fala desalinharia a legenda.
    ///
    /// Devolve índices, não texto: quem chama precisa devolver cada tradução
    /// para a posição de onde a fala saiu.
    public static func chunks(of lines: [String], limit: Int = characterLimit) -> [[Int]] {
        var blocos: [[Int]] = []
        var atual: [Int] = []
        var conta = 0
        for (index, line) in lines.enumerated() {
            let custo = line.count + 1  // +1 pela quebra de linha
            // Fala sozinha maior que o limite vai sozinha assim mesmo: o site
            // trunca, e truncar uma é melhor que desalinhar todas.
            if !atual.isEmpty, conta + custo > limit {
                blocos.append(atual)
                atual = []
                conta = 0
            }
            atual.append(index)
            conta += custo
        }
        if !atual.isEmpty { blocos.append(atual) }
        return blocos
    }

    /// O site às vezes devolve o bloco inteiro num parágrafo só, com as
    /// quebras dentro dele.
    ///
    /// Para o alinhamento da legenda o que vale é a contagem de linhas, então
    /// um parágrafo com as quebras certas é o mesmo que N parágrafos. Só
    /// separa quando a conta fecha exata: partir por chute desalinharia tudo,
    /// que é o defeito que este código inteiro existe para evitar.
    public static func separar(_ destino: [String], esperadas: Int) -> [String] {
        guard destino.count == 1, esperadas > 1 else { return destino }
        let partes = destino[0].components(separatedBy: "\n")
        return partes.count == esperadas ? partes : destino
    }

    /// Esta leitura pode ser aceita como a tradução **deste** bloco?
    ///
    /// O que ela existe para impedir tem nome e tempo medido: entre o texto
    /// novo entrar no campo de origem e o site limpar o campo de destino
    /// passam-se ~600 ms em que a tradução do bloco **anterior** continua na
    /// tela — completa, estável, diferente da origem e plausível. Uma leitura
    /// nessa janela escreve a legenda do bloco passado no bloco atual, com
    /// timecode válido e arquivo sem erro nenhum.
    ///
    /// Medido no site em 12/09/2026, trocando o idioma de destino:
    ///
    ///     t+0ms     3 parágrafos · volume presente  ← tradução anterior
    ///     t+617ms   1 parágrafo "\n" · volume ausente ← traduzindo
    ///     t+1129ms  3 parágrafos · volume presente  ← tradução nova
    ///
    /// Daí as três condições: o botão de volume do destino de volta (o site
    /// diz que terminou), ter visto o site trabalhando desde que o texto foi
    /// enviado, e — para o caso de a passagem pelo "trabalhando" ser rápida
    /// demais para a leitura pegar — o texto ser diferente do bloco anterior.
    public static func aceitavel(
        destino: [String], falante: Bool, viuTrabalhar: Bool, anterior: [String]?
    ) -> Bool {
        guard falante else { return false }
        if viuTrabalhar { return true }
        guard let anterior else { return true }
        return destino != anterior
    }

    /// Código de idioma do site. Origem e destino diferem: o destino quer a
    /// variante regional, e é dela que sai português brasileiro em vez de
    /// europeu.
    public static func code(for language: Language, target: Bool) -> String? {
        switch language {
        case .portuguese: target ? "pt-BR" : "pt"
        case .english: target ? "en-US" : "en"
        case .chinese: "zh"
        case .spanish, .french, .german, .italian, .dutch, .polish,
             .russian, .ukrainian, .japanese, .korean, .arabic, .turkish:
            language.rawValue
        // Não verificados no site; ficam fora do seletor em vez de sair errado.
        case .hindi, .thai, .vietnamese: nil
        }
    }

    /// Os idiomas do app que o site cobre.
    public static var supportedLanguages: [Language] {
        Language.allCases.filter { code(for: $0, target: false) != nil }
    }

    public static func supports(_ source: Language, _ target: Language) -> Bool {
        code(for: source, target: false) != nil && code(for: target, target: true) != nil
    }

    /// O link que carrega as falas já no campo de origem.
    ///
    /// `nonce` vira parâmetro de consulta por dois motivos: força carga nova
    /// (sem ele a SPA ignora o fragmento) e identifica a página quando a
    /// resposta chega — sem identidade, a leitura pegaria de vez em quando a
    /// tradução do bloco anterior, que ainda está na tela.
    /// Um texto qualquer virando literal de JavaScript.
    ///
    /// Legenda tem aspas, barra invertida e reticências; um escape errado
    /// quebra o script de colagem, e quebrar significa cair calado para a
    /// Apple. `tradutor-verify deepl` cobre os casos.
    public static func jsLiteral(_ text: String) -> String {
        var saida = "\""
        for escalar in text.unicodeScalars {
            switch escalar {
            case "\"": saida += "\\\""
            case "\\": saida += "\\\\"
            case "\n": saida += "\\n"
            case "\r": saida += "\\r"
            case "\u{2028}": saida += "\\u2028"
            case "\u{2029}": saida += "\\u2029"
            default:
                if escalar.value < 0x20 {
                    saida += String(format: "\\u%04x", escalar.value)
                } else {
                    saida.unicodeScalars.append(escalar)
                }
            }
        }
        return saida + "\""
    }

    public static func url(
        for lines: [String], from source: Language, to target: Language, nonce: Int
    ) -> URL? {
        guard let origem = code(for: source, target: false),
              let destino = code(for: target, target: true)
        else { return nil }
        let texto = lines.joined(separator: "\n")
        guard let escapado = texto.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        return URL(string:
            "https://www.deepl.com/pt-BR/translator?bloco=\(nonce)#\(origem)/\(destino)/\(escapado)")
    }
}

// MARK: - O tradutor

public final class DeepLWebTranslator: Translator, @unchecked Sendable {

    public let engineName = "DeepL (site)"

    /// Mesmo lote da Apple, por um motivo diferente: 40 falas de legenda dão
    /// perto de um bloco de 1400 caracteres, ou seja, uma carga de página.
    ///
    /// **Encher mais a carga foi testado e desfeito.** A ideia era boa no
    /// papel — mais texto por ida é mais contexto, que é de onde o DeepL tira
    /// gênero e pronome, e ainda seriam menos idas. Com 120, o primeiro bloco
    /// passou a levar ~100 falas em vez de ~40, e o site **parou de preservar
    /// as linhas**: devolveu tudo num parágrafo só.
    ///
    /// Medido em 12/09/2026, vídeo de 9 minutos, japonês → português:
    ///
    ///     40 por lote:  "devolveu 41 para 40", "19 para 20"  → repartia uma vez
    ///     120 por lote: "devolveu 1 para 103"                → 1 parágrafo
    ///
    /// E um parágrafo só não tem como ser alinhado às legendas: o bloco cai na
    /// repartição binária — 103 → 51 → 25 → 12 → 6 → 3 —, cada nível uma
    /// página, e a geração foi de 23 s para 162 s. Contagem de linhas
    /// preservada vale mais que contexto: é dela que depende a legenda cair no
    /// tempo certo.
    public var preferredBatchSize: Int { 40 }

    private let driver = DeepLDriver()
    private let log = Logger(subsystem: "app.tradutor", category: "DeepL")

    /// Rede de segurança: bloco que o site não entregar cai aqui.
    ///
    /// Deixar a geração inteira morrer porque um bloco deu tempo esgotado
    /// seria pior que uma legenda mista — num vídeo de 18 minutos são dez
    /// minutos de trabalho perdidos. A troca fica no log e no nome do motor.
    private let backup = AppleTranslator()

    /// Quantos blocos precisaram da Apple nesta execução.
    public private(set) var fallbackCount = 0

    public var completionNotice: String? {
        guard fallbackCount > 0 else { return nil }
        return fallbackCount == 1
            ? "1 bloco foi traduzido pela Apple: o DeepL não respondeu."
            : "\(fallbackCount) blocos foram traduzidos pela Apple: o DeepL não respondeu."
    }

    public init() {}

    public func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        progress(0.4, "abrindo o DeepL…")
        await driver.warmUp()
        // Sem carga de aquecimento aqui, e isto foi medido: abrir o site antes
        // do primeiro bloco custava uma página inteira a mais em TODA geração
        // — 11 s no vídeo curto, 25 s no de 9 minutos — para adiantar um
        // desafio anti-robô que aparece de vez em quando. O desafio é
        // esperado onde ele aparece, em `esperar`.
        progress(1.0, "DeepL pronto")
    }

    public func reset() {
        fallbackCount = 0
        let driver = self.driver
        Task { @MainActor in driver.close() }
    }

    public func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        let result = try await translate([text], from: source, to: target)
        return result.first ?? ""
    }

    public func translate(
        _ texts: [String], from source: Language, to target: Language
    ) async throws -> [String] {
        // Par que o site não cobre não é erro: é a Apple fazendo o trabalho,
        // como o menu avisa. Falhar aqui derrubaria a geração inteira por uma
        // escolha de idioma que o usuário já vê anotada na tela.
        guard DeepLWeb.supports(source, target) else {
            return try await backup.translate(texts, from: source, to: target)
        }

        let trimmed = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cheias = trimmed.enumerated().filter { !$0.element.isEmpty }
        guard !cheias.isEmpty else { return Array(repeating: "", count: texts.count) }

        var saida = Array(repeating: "", count: texts.count)
        let blocos = DeepLWeb.chunks(of: cheias.map(\.element))
        for (numero, bloco) in blocos.enumerated() {
            let falas = bloco.map { cheias[$0].element }
            let rotulo = "bloco \(numero + 1) de \(blocos.count)"
            let traduzidas: [String]
            do {
                traduzidas = try await driver.translate(
                    falas, from: source, to: target, label: rotulo
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.error("DeepL falhou em \(rotulo, privacy: .public): \(error.localizedDescription, privacy: .public) — caindo para a Apple")
                fallbackCount += 1
                traduzidas = try await backup.translate(falas, from: source, to: target)
            }
            for (posicao, texto) in zip(bloco, traduzidas) {
                saida[cheias[posicao].offset] = texto
            }
        }
        return saida
    }
}

public enum DeepLWebError: LocalizedError {
    case pairNotSupported(Language, Language)
    case timedOut(String)
    /// O site pediu confirmação de que quem está do outro lado é uma pessoa.
    case challenged

    public var errorDescription: String? {
        switch self {
        case let .pairNotSupported(source, target):
            "O DeepL não cobre \(source.displayName) → \(target.displayName)."
        case let .timedOut(bloco):
            "O DeepL não respondeu a tempo (\(bloco)). Pode ser limite de uso do site."
        case .challenged:
            "O site do DeepL pediu confirmação de que você é humano. "
                + "A tradução continua pela Apple."
        }
    }
}

// MARK: - A janela que mostra o trabalho

/// Dirige um `WKWebView` numa janela visível.
///
/// A janela não é enfeite: `WKWebView` fora da tela tem temporizador
/// estrangulado pelo sistema, e a página depende de temporizador para disparar
/// a tradução. Mostrar é o que faz funcionar — e de quebra o usuário vê o que
/// está saindo da máquina.
@MainActor
final class DeepLDriver {

    /// Quanto esperar por um bloco antes de desistir dele.
    private static let blockTimeout: TimeInterval = 90
    /// Leituras iguais que bastam quando a contagem de linhas bate.
    private static let stableExact = 2
    /// E quando não bate: mais paciência, contada em **leituras iguais** e não
    /// no relógio. Eram 25 s de espera fixa, com a tradução já pronta na tela.
    private static let stablePartial = 12
    /// Passado isto, requisição em voo deixa de ser motivo para esperar. Há
    /// requisição que não termina nunca (telemetria, conexão longa), e esperar
    /// por ela custava o bloco inteiro parado com a tradução já visível.
    private static let inFlightGrace: TimeInterval = 8
    /// Quanto tempo dar ao desafio anti-robô para passar sozinho.
    ///
    /// O da Cloudflare quase sempre se resolve em poucos segundos, sem clique
    /// nenhum. Desistir no primeiro quadro dele mandava para a Apple um bloco
    /// que ia sair daqui — e o bloco seguinte tentava de novo, do zero.
    private static let challengeGrace: TimeInterval = 25

    private var window: NSWindow?
    private var webView: WKWebView?
    private var nonce = 0
    /// Par de idiomas já carregado na página, ou `nil` se não há página útil.
    ///
    /// Enquanto for o mesmo par, os blocos seguintes entram por limpar-e-colar,
    /// sem recarregar — é o que mantém uma sessão só em vez de parecer um
    /// visitante novo a cada bloco.
    private var loadedPair: (Language, Language)?
    /// A tradução que o bloco anterior deixou na tela.
    ///
    /// É contra ela que se reconhece a leitura atrasada: enquanto o site não
    /// limpa o campo de destino, o que está lá é isto. Ver `DeepLWeb.aceitavel`.
    private var ultimoDestino: [String]?
    private let log = Logger(subsystem: "app.tradutor", category: "DeepL")

    /// Criado fora do main actor — quem chama é um `Translator`, que não é
    /// isolado. Nada aqui toca AppKit antes de `view()`, que é isolado.
    nonisolated init() {}

    /// Instalada antes do código do site rodar.
    ///
    /// Conta requisições em voo: é o "está traduzindo" do site lido por baixo,
    /// e é mais firme que classe de CSS, que muda quando eles quiserem.
    /// Também esconde o aviso de cookies, que cobre o campo — esconder, não
    /// aceitar: o armazenamento é efêmero e nada fica em disco.
    private static let sonda = """
    (function () {
      if (window.__tradutorEmVoo !== undefined) return;
      window.__tradutorEmVoo = 0;
      var f = window.fetch;
      if (f) {
        window.fetch = function () {
          window.__tradutorEmVoo++;
          return f.apply(this, arguments).finally(function () { window.__tradutorEmVoo--; });
        };
      }
      var send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function () {
        window.__tradutorEmVoo++;
        this.addEventListener('loadend', function () { window.__tradutorEmVoo--; });
        return send.apply(this, arguments);
      };
      // O aviso de cookies cobre os dois campos. Duas armadilhas aqui:
      // o <style> pendurado em documentElement some quando o parser monta o
      // <head>, e o testid do aviso muda entre a versão curta e a modal —
      // medido: a modal que aparece sem cookie nenhum não é "dl-cookieBanner".
      // Por isso o seletor é por prefixo e a instalação se repete.
      var CSS = '[data-testid^="dl-cookieBanner"],[data-testid*="cookie-banner"]' +
                '{display:none!important}';
      function limpar() {
        var alvo = document.head || document.documentElement;
        if (!alvo) return;
        if (!document.getElementById('tradutor-sem-banner')) {
          var estilo = document.createElement('style');
          estilo.id = 'tradutor-sem-banner';
          estilo.textContent = CSS;
          alvo.appendChild(estilo);
        }
        // Esconder não é responder. Se houver botão de recusar, ele é clicado:
        // o padrão é sempre a opção que guarda menos.
        var botoes = document.querySelectorAll('button, [role="button"]');
        for (var i = 0; i < botoes.length; i++) {
          var texto = (botoes[i].innerText || '').trim();
          if (/^(rejeitar|recusar|reject|decline)/i.test(texto) ||
              /apenas.*(necess|essenc)/i.test(texto) ||
              /only.*necessary/i.test(texto)) {
            botoes[i].click();
            return;
          }
        }
        // Sem botao de recusar a vista, o aviso e escondido pelo que ele e —
        // uma caixa modal falando de cookie. Aceitar seria responder por quem
        // nao perguntou, e o armazenamento aqui e efemero de qualquer jeito.
        var caixas = document.querySelectorAll('dialog,[role="dialog"],[aria-modal="true"]');
        for (var j = 0; j < caixas.length; j++) {
          if (/cookie/i.test(caixas[j].innerText || '')) {
            caixas[j].style.display = 'none';
          }
        }
      }
      limpar();
      document.addEventListener('DOMContentLoaded', limpar);
      var tentativas = 0;
      var relogio = setInterval(function () {
        limpar();
        if (++tentativas > 50) clearInterval(relogio);
      }, 300);
    })();
    """

    /// Esvazia o campo de origem pelo botão do próprio site.
    private static let limpeza = """
    (function () {
      var botao = document.querySelector('[data-testid="translator-source-clear-button"]');
      if (botao) { botao.click(); return "ok"; }
      return "sem-botao";
    })();
    """

    /// Cola o texto como se alguém tivesse apertado ⌘V.
    ///
    /// `execCommand('insertText')` não serve — o editor do site o ignora e
    /// nenhuma tradução é disparada. O evento de cola é o caminho que ele
    /// escuta, e é o mesmo de uma pessoa.
    private static func colagem(_ lines: [String]) -> String {
        """
        (function () {
          var campo = document.querySelector(
            'd-textarea[data-testid="translator-source-input"] [contenteditable]');
          if (!campo) return "sem-campo";
          campo.focus();
          var dados = new DataTransfer();
          dados.setData('text/plain', \(DeepLWeb.jsLiteral(lines.joined(separator: "\n"))));
          campo.dispatchEvent(new ClipboardEvent('paste',
            { clipboardData: dados, bubbles: true, cancelable: true }));
          return "ok";
        })();
        """
    }

    private static let leitura = """
    (function () {
      function linhas(nome) {
        var campo = document.querySelectorAll(
          'd-textarea[data-testid="' + nome + '"] [contenteditable] p');
        return Array.prototype.map.call(campo, function (p) {
          // innerText volta vazio em elemento que o layout ainda nao mediu;
          // textContent nao depende de layout e serve de reserva.
          var t = p.innerText || p.textContent || '';
          return t.replace(/\\u00a0/g, ' ');
        });
      }
      var marca = location.search.match(/bloco=(\\d+)/);
      // O botao de volume do destino some enquanto o site traduz e volta
      // quando o resultado esta pronto. Medido no proprio site em 12/09/2026,
      // trocando o idioma de destino: volume presente com a traducao ANTERIOR
      // na tela, volume ausente com o destino em branco, volume de volta com
      // a traducao nova. E o "estou trabalhando" do site, e e mais firme que
      // qualquer classe de CSS.
      var falante = !!document.querySelector('[data-testid="translator-speaker-target"]');
      // O mesmo, em espera longa: um indicador de carregamento visivel.
      var girando = false;
      var gs = document.querySelectorAll(
        '[data-testid*="loading"],[data-dui-component="LoadingIndicator"],.LoadingIndicator');
      for (var g = 0; g < gs.length; g++) {
        var cg = getComputedStyle(gs[g]);
        if (cg.display !== 'none' && cg.visibility !== 'hidden' && cg.opacity !== '0' &&
            gs[g].getBoundingClientRect().width > 0) { girando = true; break; }
      }
      // Desafio anti-robô: o site para de traduzir e fica esperando um clique
      // que só uma pessoa pode dar. Melhor descobrir agora e cair para a Apple
      // do que esperar o tempo esgotar em cada bloco.
      var desafio = /just a moment|um momento/i.test(document.title || '') ||
        !!document.querySelector(
          '#challenge-form, #cf-challenge-running, iframe[src*="challenges.cloudflare.com"]');
      return JSON.stringify({
        bloco: marca ? marca[1] : "",
        desafio: desafio,
        falante: falante,
        girando: girando,
        origem: linhas('translator-source-input'),
        destino: linhas('translator-target-input'),
        voo: (window.__tradutorEmVoo | 0)
      });
    })();
    """

    func warmUp() {
        _ = view()
    }

    func close() {
        if window != nil { log.notice("janela do DeepL fechada") }
        window?.close()
        window = nil
        webView = nil
        loadedPair = nil
        ultimoDestino = nil
    }

    private func view() -> WKWebView {
        if let webView { return webView }

        let config = WKWebViewConfiguration()
        // Nada em disco: sem cookie guardado, sem cache entre execuções. O app
        // já limpa o que o Core ML deixa (ver `CacheCleanup`) e não faz sentido
        // abrir exceção para um site.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(
            WKUserScript(source: Self.sonda, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 620), configuration: config)
        let janela = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        // Sem isto, o usuário fechar a janela no meio da geração derruba o app:
        // o NSWindow criado em código se libera ao fechar por padrão, e a
        // referência daqui viraria lixo.
        janela.isReleasedWhenClosed = false
        janela.title = "DeepL"
        janela.contentView = view
        janela.center()
        // Sem roubar o foco: o app é de barra de menus e o usuário costuma
        // estar assistindo ao vídeo enquanto isto roda.
        janela.orderFrontRegardless()

        webView = view
        window = janela
        return view
    }

    func translate(
        _ lines: [String], from source: Language, to target: Language, label: String
    ) async throws -> [String] {
        try await traduzir(lines, from: source, to: target, label: label, profundidade: 0)
    }

    /// Uma tentativa por bloco; se a contagem não bater, reparte o bloco ao
    /// meio e tenta de novo.
    ///
    /// Repartir em vez de mandar uma a uma porque cada tentativa é uma carga de
    /// página inteira: dividir ao meio custa `log2(n)` níveis, uma a uma custa
    /// `n`. No fundo, com uma fala só, o que voltar é juntado — uma fala não
    /// pode virar duas legendas.
    private func traduzir(
        _ lines: [String], from source: Language, to target: Language,
        label: String, profundidade: Int, recarregou: Bool = false
    ) async throws -> [String] {
        try Task.checkCancellation()

        let view = self.view()
        window?.title = profundidade > 0
            ? "DeepL · \(label) · repartido em \(lines.count)"
            : "DeepL · \(label)"

        // Carga só quando não há página útil: é ela que fixa o par de idiomas.
        // Com a página em pé, o bloco seguinte entra por limpar-e-colar, que é
        // três vezes mais rápido e — o que importa mais — mantém uma sessão só
        // em vez de chegar como visitante novo a cada bloco.
        var marca: Int?
        if loadedPair == nil || loadedPair! != (source, target) {
            nonce += 1
            marca = nonce
            guard let url = DeepLWeb.url(for: lines, from: source, to: target, nonce: nonce) else {
                throw DeepLWebError.pairNotSupported(source, target)
            }
            view.load(URLRequest(url: url))
            loadedPair = (source, target)
        } else {
            let limpou = (try? await view.evaluateJavaScript(Self.limpeza)) as? String
            // O campo não esvazia no mesmo instante do clique; colar antes
            // disso emendaria o bloco novo no anterior. Esperar o campo ficar
            // vazio de verdade é mais rápido e mais seguro que dormir 300 ms
            // no escuro — e quando o botão nem existe, não há o que esperar.
            var vazio = false
            if limpou == "ok" { vazio = try await origem(view, igual: [], prazo: 2) }
            let colou = vazio
                ? (try? await view.evaluateJavaScript(Self.colagem(lines))) as? String
                : nil
            var entrou = false
            if colou == "ok" { entrou = try await origem(view, igual: lines, prazo: 4) }
            if !entrou {
                // A cola não entrou: esperar 90 s por uma tradução que ninguém
                // pediu é o pior dos mundos. Uma carga limpa, uma vez.
                log.notice("colagem nao entrou em \(label, privacy: .public) (limpeza=\(limpou ?? "-", privacy: .public), cola=\(colou ?? "-", privacy: .public)); recarregando")
                loadedPair = nil
                guard !recarregou else { throw DeepLWebError.timedOut(label) }
                return try await traduzir(
                    lines, from: source, to: target, label: label,
                    profundidade: profundidade, recarregou: true
                )
            }
        }

        let relogio = Date()
        let destino: [String]
        do {
            destino = try await esperar(
                view, enviado: lines, marca: marca, esperadas: lines.count, label: label
            )
        } catch DeepLWebError.timedOut where marca == nil && !recarregou {
            // A página colada não respondeu: pode ter perdido a sessão ou saído
            // do ar. Uma carga nova, uma vez — depois disso é a Apple.
            log.notice("DeepL nao respondeu a colagem em \(label, privacy: .public); recarregando")
            loadedPair = nil
            return try await traduzir(
                lines, from: source, to: target, label: label,
                profundidade: profundidade, recarregou: true
            )
        } catch {
            // Desafio anti-robô, ou qualquer outra: a página atual não serve
            // mais, e a próxima tentativa começa carregando.
            loadedPair = nil
            throw error
        }

        log.notice("\(label, privacy: .public): \(lines.count) falas, \(marca == nil ? "cola" : "carga", privacy: .public), \(Int(Date().timeIntervalSince(relogio) * 1000))ms, voltou \(destino.count)")
        if destino.count == lines.count { return destino }

        // Uma fala só: o site partiu a tradução em mais de um parágrafo. Junta.
        if lines.count == 1 {
            log.notice("DeepL devolveu \(destino.count) linhas para uma fala; juntando")
            return [destino.joined(separator: " ").trimmingCharacters(in: .whitespaces)]
        }

        log.notice("DeepL devolveu \(destino.count) para \(lines.count) em \(label, privacy: .public); repartindo")
        let meio = lines.count / 2
        let esquerda = try await traduzir(
            Array(lines[..<meio]), from: source, to: target,
            label: label, profundidade: profundidade + 1)
        let direita = try await traduzir(
            Array(lines[meio...]), from: source, to: target,
            label: label, profundidade: profundidade + 1)
        return esquerda + direita
    }

    /// Espera a página **deste** bloco ficar pronta.
    ///
    /// Cinco condições, e nenhuma basta sozinha:
    ///
    /// - o campo de origem tem o texto deste bloco. É a identidade que vale
    ///   nos dois caminhos: sem ela a leitura pega o bloco anterior, que ainda
    ///   está na tela enquanto a página carrega ou enquanto a cola não chegou
    ///   — e ele tem texto válido, só que errado.
    /// - na carga, `bloco` igual ao nonce dela, por garantia a mais.
    /// - nenhuma requisição em voo (o indicador de "traduzindo" do site).
    /// - o campo de destino não está vazio.
    /// - **o destino é diferente da origem.** Esta custou uma legenda inteira:
    ///   enquanto a tradução não chega, o site mostra o texto de origem do
    ///   lado de destino. Sem requisição em voo e com o texto parado, isso
    ///   passava por "pronto" — e o `.srt` saiu com sete das onze falas em
    ///   japonês, plausível e errado.
    /// - duas leituras seguidas com o mesmo texto: a tradução aparece aos
    ///   poucos, e uma pausa no meio pareceria fim.
    private func esperar(
        _ view: WKWebView, enviado: [String], marca: Int?, esperadas: Int, label: String
    ) async throws -> [String] {
        let inicio = Date()
        let limite = inicio.addingTimeInterval(Self.blockTimeout)
        var anterior: [String] = []
        var iguais = 0
        var desafioDesde: Date?
        // O site já foi visto trabalhando depois deste texto entrar: o botão
        // de volume do destino sumiu, ou o destino ficou em branco, ou havia
        // indicador girando. É o que separa "a resposta é deste bloco" de "a
        // resposta ainda é do bloco anterior".
        var viuTrabalhar = false

        while Date() < limite {
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()

            guard let estado = await ler(view) else { continue }  // página carregando

            // O desafio é do site, e resolver por conta própria não é opção.
            // Mas ele quase sempre passa sozinho em poucos segundos, e
            // desistir no primeiro quadro mandava para a Apple um bloco que ia
            // sair daqui. Esperar é o que uma pessoa faria.
            if estado.desafio {
                let desde = desafioDesde ?? Date()
                desafioDesde = desde
                guard Date().timeIntervalSince(desde) < Self.challengeGrace else {
                    throw DeepLWebError.challenged
                }
                iguais = 0
                continue
            }
            if desafioDesde != nil {
                desafioDesde = nil
                iguais = 0
                log.notice("desafio passou sozinho em \(label, privacy: .public)")
                // Na carga por link o texto volta com a página. Na colagem não
                // volta — quem chamou recarrega.
                if marca == nil { throw DeepLWebError.timedOut(label) }
                continue
            }

            if let marca, estado.bloco != String(marca) {
                iguais = 0
                continue
            }
            guard Self.mesmoTexto(enviado, estado.origem) else {
                iguais = 0
                continue
            }

            // Requisição em voo é o "traduzindo" do site lido por baixo, e é
            // sinal bom — no começo. Há requisição que não termina nunca, e
            // esperar por ela deixava o bloco parado com a tradução na tela.
            // Passados alguns segundos, quem manda é o texto ficar parado.
            let passouDaGraca = Date() > inicio.addingTimeInterval(Self.inFlightGrace)
            // Três formas de ver o site trabalhando, e a primeira é a que o
            // próprio site mostra: o botão de volume do destino sumindo.
            if !estado.falante || estado.girando || estado.voo > 0 {
                viuTrabalhar = true
            }
            if estado.voo > 0, !passouDaGraca {
                iguais = 0
                continue
            }

            let destino = DeepLWeb.separar(estado.destino, esperadas: esperadas)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            iguais = destino == anterior ? iguais + 1 : 0
            anterior = destino

            // Origem e destino iguais é o estado "ainda não traduziu": o site
            // enche o campo de destino com a origem enquanto espera a
            // resposta. Custou uma legenda inteira descobrir isso — o `.srt`
            // saiu com sete das onze falas em japonês, plausível e errado.
            //
            // Só que esse estado é indistinguível do outro, o da tradução que
            // não muda nada (um nome próprio sozinho), e ali a espera nunca
            // terminava: 90 s parados numa fala de uma palavra. Sem requisição
            // em voo e com o texto sem mexer, desistir cedo põe a Apple no
            // lugar em dez segundos em vez de noventa.
            let semTexto = !destino.contains(where: { !$0.isEmpty })
            if semTexto || Self.mesmoTexto(estado.origem, destino) {
                if !semTexto, estado.voo == 0, passouDaGraca, iguais >= Self.stablePartial {
                    log.notice("DeepL devolveu o proprio texto em \(label, privacy: .public); desistindo cedo")
                    throw DeepLWebError.timedOut(label)
                }
                continue
            }

            // A renderização vem depois da resposta: requisição terminada,
            // parágrafos ainda aparecendo — um bloco de 11 falas era lido com
            // 4, e o bloco acabava repartido sem necessidade. Com a contagem
            // certa, duas leituras iguais bastam. Com contagem diferente é
            // preciso mais paciência, e ela agora é contada em leituras iguais
            // (3 s de texto parado) e não em 25 s de relógio — que era o que
            // deixava a tradução pronta esperando na tela.
            let completo = destino.count == esperadas && destino.allSatisfy { !$0.isEmpty }
            guard iguais >= (completo ? Self.stableExact : Self.stablePartial) else { continue }

            // E só então: a resposta é mesmo deste bloco? Passada a graça, a
            // regra afrouxa — um site que mudasse o botão de volume, ou dois
            // blocos com a mesma tradução, não podem travar a geração.
            guard DeepLWeb.aceitavel(
                destino: destino, falante: estado.falante || passouDaGraca,
                viuTrabalhar: viuTrabalhar || passouDaGraca, anterior: ultimoDestino
            ) else {
                log.notice("leitura atrasada em \(label, privacy: .public): o destino ainda e do bloco anterior")
                continue
            }
            ultimoDestino = destino
            return destino
        }
        throw DeepLWebError.timedOut(label)
    }

    /// Espera o campo de origem chegar ao texto esperado — vazio, quando
    /// `esperado` é vazio. Falso se não chegar no prazo.
    ///
    /// É o que separa "a cola entrou" de "a cola não entrou": sem conferir,
    /// os dois casos ficavam iguais daqui de dentro e o segundo custava os
    /// 90 s inteiros de espera por uma tradução que nunca foi pedida.
    private func origem(
        _ view: WKWebView, igual esperado: [String], prazo: TimeInterval
    ) async throws -> Bool {
        let limite = Date().addingTimeInterval(prazo)
        while Date() < limite {
            try Task.checkCancellation()
            if let estado = await ler(view) {
                if estado.desafio { return false }
                if Self.mesmoTexto(esperado, estado.origem) { return true }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Uma leitura da página, ou `nil` enquanto ela não responde.
    private func ler(_ view: WKWebView) async -> Estado? {
        guard let bruto = try? await view.evaluateJavaScript(Self.leitura) as? String,
              let dados = bruto.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(Estado.self, from: dados)
    }

    /// Dois lados do site com o mesmo texto, ignorando espaço.
    ///
    /// Serve para reconhecer o estado "ainda não traduziu": o site enche o
    /// campo de destino com a origem enquanto espera a resposta.
    static func mesmoTexto(_ a: [String], _ b: [String]) -> Bool {
        func achatar(_ linhas: [String]) -> String {
            linhas.joined().filter { !$0.isWhitespace }
        }
        return achatar(a) == achatar(b)
    }

    private struct Estado: Decodable {
        let bloco: String
        let desafio: Bool
        /// O botão de volume do destino existe — o site terminou de traduzir.
        let falante: Bool
        /// Um indicador de carregamento visível na página.
        let girando: Bool
        let origem: [String]
        let destino: [String]
        let voo: Int
    }
}
