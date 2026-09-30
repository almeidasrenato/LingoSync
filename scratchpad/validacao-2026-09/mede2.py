"""Mede as saídas do item 2 (resultados/item2/gerar/*.json).

- texto japonês: CER pela régua `referencia --srt` (9 min recortado contra a
  legenda da imagem; anime contra o rascunho de máquina) e os termos do anime;
- texto inglês: sem gabarito — WER de cada variante contra a mesma
  combinação sem separação (quanto mudou) e contra o outro motor na mesma
  variante (se Apple e Qwen passam a discordar mais);
- quem fala: `quemfala.py` contra os gabaritos humanos.
"""
import json, re, subprocess, sys
from pathlib import Path

AQUI = Path(__file__).resolve().parent
RAIZ = AQUI.parent.parent
R = AQUI / "resultados/item2"
VERIFY = RAIZ / ".build/release/tradutor-verify"
VE = RAIZ / "Videos Exemplo"
sys.path.insert(0, str(RAIZ / "scratchpad/transcricao-ted"))
sys.path.insert(0, str(AQUI))
import quemfala, entidades

GABARITO = {
    "anime": VE / "video exemplo 2 (Conversa mais complexa).quem-fala.txt",
    "9min": VE / "video exemplo conversa de pessoas.quem-fala-trecho.txt",
    "en2": VE / "video exemplo conversa de pessoas 2 ingles.quem-fala.txt",
}
METODOS = ["original", "htdemucs", "roformer"]


def srt(legs, caminho):
    def tc(s):
        ms = round(s * 1000)
        return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"
    caminho.write_text("\n".join(f"{i}\n{tc(l['start'])} --> {tc(l['end'])}\n{l['source']}\n"
                                 for i, l in enumerate(legs, 1)), encoding="utf8")


def cer(hip, ref):
    out = subprocess.run([str(VERIFY), "referencia", "--srt", str(hip), str(ref)],
                         capture_output=True, text=True).stdout
    m = re.search(r"texto\s+CER ([\d.]+)%", out)
    return float(m[1]) if m else None


def palavras(legs):
    return re.findall(r"[a-z0-9']+", " ".join(l["source"] for l in legs).lower())


def wer(a, b):
    d = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        p, d[0] = d[0], i
        for j, y in enumerate(b, 1):
            p, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, p + (x != y))
    return 100 * d[len(b)] / max(len(a), 1)


def main():
    (R / "srt").mkdir(exist_ok=True)
    dados = {f.stem: json.load(open(f)) for f in sorted((R / "gerar").glob("*.json"))}
    for nome, d in dados.items():
        srt(d["legendas"], R / "srt" / f"{nome}.srt")

    print("== texto (sortformer; o texto quase não depende do modelo de vozes)")
    for v in ["anime", "9min", "en1", "en2"]:
        for e in ["apple", "qwenLarge"]:
            linha = f"{v:5s} {e:9s}"
            for m in METODOS:
                k = f"{v}-{m}-{e}-sortformer"
                if k not in dados:
                    linha += f" | {m}: —"
                    continue
                legs, s = dados[k]["legendas"], dados[k]["segundos"]
                h = R / "srt" / f"{k}.srt"
                if v == "anime":
                    c = cer(h, VE / "video exemplo 2 (Conversa mais complexa).ja.srt")
                    t = sum(entidades.conta(entidades.texto(str(h))).values())
                    linha += f" | {m}: CER* {c:.1f}% termos {t}/17 {len(legs)} leg {s:.0f}s"
                elif v == "9min":
                    rec = R / "srt" / f"{k}-recorte.srt"
                    rec.write_text(subprocess.run(["python3", str(AQUI / "recorta.py"), str(h),
                                                   str(AQUI / "resultados/reguas/9min-ocr.srt")],
                                                  capture_output=True, text=True).stdout)
                    c = cer(rec, AQUI / "resultados/reguas/9min-ocr.srt")
                    linha += f" | {m}: CER {c:.1f}% {len(legs)} leg {s:.0f}s"
                else:
                    w = palavras(legs)
                    base = palavras(dados[f"{v}-original-{e}-sortformer"]["legendas"])
                    outro = "qwenLarge" if e == "apple" else "apple"
                    ko = f"{v}-{m}-{outro}-sortformer"
                    x = f" x{outro[:5]} {wer(palavras(dados[ko]['legendas']), w):.1f}%" if ko in dados else ""
                    linha += f" | {m}: {len(w)} pal, muda {wer(base, w):.1f}%{x} {s:.0f}s"
            print(linha)

    print("\n== quem fala (acerto por fala, mapeamento de maioria)")
    for v, gab in GABARITO.items():
        marcas = quemfala.gabarito(str(gab))
        for e in ["apple", "qwenLarge"]:
            for mod in ["sortformer", "clustering"]:
                linha = f"{v:5s} {e:9s} {mod:10s}"
                for m in METODOS:
                    k = f"{v}-{m}-{e}-{mod}"
                    if k not in dados:
                        linha += f" | {m}: —"
                        continue
                    a, n, mis, tot, sem, vozes = quemfala.mede(marcas, dados[k]["legendas"])
                    linha += f" | {m}: {100 * a / max(n, 1):3.0f}% mist {mis}/{tot} vozes {vozes}"
                print(linha)


if __name__ == "__main__":
    main()
