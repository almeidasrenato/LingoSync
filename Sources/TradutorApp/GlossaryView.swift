import SwiftUI
import TradutorCore

/// Editor da lista de termos.
///
/// É a correção mais confiável que existe para o que sobra de errado numa
/// legenda: os erros são substantivos concretos — comida, lugar, moeda — e
/// nenhum modelo acerta todos. Aqui você diz uma vez como quer, e vale para
/// todas as gerações seguintes.
struct GlossaryView: View {

    let source: Language
    let target: Language
    var onClose: () -> Void

    @State private var terms: [Term] = []
    @State private var selection: Set<Term.ID> = []
    @State private var glossary: Glossary?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Termos · \(source.displayName) → \(target.displayName)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Aplicados ao original antes de traduzir")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(terms.filter(\.enabled).count) ativos")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Table($terms, selection: $selection) {
                TableColumn("") { $term in
                    Toggle("", isOn: $term.enabled)
                        .labelsHidden()
                        .controlSize(.mini)
                }
                .width(24)

                TableColumn("No original") { $term in
                    TextField("納豆", text: $term.source)
                        .textFieldStyle(.plain)
                }

                TableColumn("Na tradução") { $term in
                    TextField("natto", text: $term.target)
                        .textFieldStyle(.plain)
                }
            }
            .frame(minHeight: 240)

            HStack(spacing: 8) {
                Button {
                    terms.append(Term(source: "", target: ""))
                } label: {
                    Label("Adicionar", systemImage: "plus")
                }

                Button {
                    terms.removeAll { selection.contains($0.id) }
                    selection.removeAll()
                } label: {
                    Label("Remover", systemImage: "minus")
                }
                .disabled(selection.isEmpty)

                Spacer()

                Button("Fechar") {
                    save()
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }

            Text("""
                 Termos mais longos ganham dos mais curtos: com 山梨 e 山梨県 na \
                 lista, o texto 山梨県 usa o segundo. Termos desligados ficam \
                 guardados mas não são aplicados.
                 """)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 520, height: 400)
        .onAppear(perform: load)
        // Grava a cada mudança: perder a lista por esquecer de salvar seria
        // exatamente o tipo de atrito que faz ninguém usar o recurso.
        .onChange(of: terms) { _, _ in save() }
    }

    private func load() {
        let store = Glossary(source: source, target: target)
        glossary = store
        terms = store.all
    }

    private func save() {
        glossary?.replaceAll(with: terms.filter { !$0.source.isEmpty || !$0.target.isEmpty })
    }
}
