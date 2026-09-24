#!/usr/bin/env python3
"""Tradução antes x depois, sem tradução de referência.

    traducao.py indicadores <gerado.json>...
    traducao.py pares <a.json> <b.json> <saida.md> <chave.json> [--ref legenda.srt] [--n 40]

`indicadores`: o que dá para contar sem saber a tradução certa.
  partido   rascunho que termina sem pontuação e emenda na legenda seguinte
            (a menos de 0,3 s): o tradutor recebe meia oração
  japones   legenda final com kana ou kanji: não traduzida
  hesit.    hesitação que chegou ao português ("Hum", "Uh", "Bem," no começo)

`pares`: trechos de tempo em que as duas versões dizem coisa diferente, em
ordem sorteada e rotulados 1 e 2. A chave de qual é qual vai para outro
arquivo, para o julgamento ser feito às cegas.
"""
import json, random, re, sys

DENSO = re.compile(r"[぀-ヿ㐀-䶿一-鿿]")
FIM = set("。？！、…,.?!;:」』)")
HESIT = re.compile(r"^(hum+|uh+|hã+|ah+|bem|é+)\b[,.…]", re.IGNORECASE)

def carrega(caminho):
    return json.load(open(caminho))

def indicadores(caminho):
    d = carrega(caminho)
    r, l = d["rascunho"], d["legendas"]
    partido = 0
    for a, b in zip(r, r[1:]):
        fim = a["source"].strip()[-1:] if a["source"].strip() else ""
        if fim and fim not in FIM and b["start"] - a["end"] < 0.3:
            partido += 1
    japones = sum(1 for x in l if DENSO.search(x["translated"]))
    hesit = sum(1 for x in l if HESIT.search(x["translated"].strip()))
    return len(r), partido, len(l), japones, hesit, d.get("segundos", 0)

def srt(caminho):
    texto = open(caminho, encoding="utf-8").read().replace("\r", "")
    saida = []
    for bloco in texto.split("\n\n"):
        linhas = [x for x in bloco.split("\n") if x.strip()]
        if len(linhas) >= 3 and "-->" in linhas[1]:
            a, b = linhas[1].split("-->")
            conv = lambda t: sum(float(p) * f for p, f in zip(t.strip().replace(",", ".").split(":"), (3600, 60, 1)))
            saida.append({"start": conv(a), "end": conv(b), "translated": "".join(linhas[2:])})
    return saida

def fronteiras(legendas):
    pontos = set()
    for a, b in zip(legendas, legendas[1:]):
        pontos.add(round((a["end"] + b["start"]) / 2, 2))
    return sorted(pontos)

def pares(pa, pb, saida, chave, ref=None, n=40, semente=7, frase=False):
    A, B = carrega(pa)["legendas"], carrega(pb)["legendas"]
    R = srt(ref) if ref else []
    fa, fb = fronteiras(A), fronteiras(B)
    # Pontos em que as duas versões trocam de legenda quase juntas.
    sinc = [0.0] + [t for t in fa if any(abs(t - u) <= 0.35 for u in fb)] + [1e9]
    def junta(legendas, t0, t1, campo="translated"):
        return " ".join(x[campo].replace("\n", " ") for x in legendas if t0 <= (x["start"] + x["end"]) / 2 < t1).strip()
    if frase:
        # Junta as janelas até a frase fechar (ponto no original) ou haver
        # pausa longa: é a unidade que a tradução por frase manda.
        fechados = [0.0]
        for t0, t1 in zip(sinc, sinc[1:]):
            origem = junta(A, t0, t1, "source")
            proxima = [x["start"] for x in A if x["start"] >= t1]
            ultimo = [x["end"] for x in A if (x["start"] + x["end"]) / 2 < t1]
            pausa = (proxima[0] - ultimo[-1]) if proxima and ultimo else 9
            if (origem and origem.rstrip()[-1:] in "。？！.?!…") or pausa > 1.5 or t1 > 1e8:
                fechados.append(t1)
        sinc = fechados
    trechos = []
    for t0, t1 in zip(sinc, sinc[1:]):
        a, b = junta(A, t0, t1), junta(B, t0, t1)
        norm = lambda s: re.sub(r"\W", "", s.lower())
        if a and b and norm(a) != norm(b):
            trechos.append((t0, t1, a, b, junta(A, t0, t1, "source"), junta(B, t0, t1, "source"),
                            junta(R, t0 - 0.3, t1 + 0.3) if R else ""))
    random.seed(semente)
    escolhidos = sorted(random.sample(trechos, min(n, len(trechos))), key=lambda x: x[0])
    chaves = []
    with open(saida, "w") as f:
        f.write(f"# {len(escolhidos)} de {len(trechos)} trechos diferentes\n\n")
        for i, (t0, t1, a, b, sa, sb, r) in enumerate(escolhidos, 1):
            troca = random.random() < 0.5
            (u, su), (d, sd) = ((b, sb), (a, sa)) if troca else ((a, sa), (b, sb))
            chaves.append("b" if troca else "a")
            fim = "fim" if t1 > 1e8 else f"{t1:.1f}"
            f.write(f"## {i}  ({t0:.1f}–{fim} s)\n")
            if r:
                f.write(f"ref: {r}\n")
            f.write(f"1 [{su}]\n  → {u}\n2 [{sd}]\n  → {d}\n\n")
    json.dump(chaves, open(chave, "w"))
    print(f"{len(trechos)} trechos diferentes, {len(escolhidos)} sorteados -> {saida}")

if __name__ == "__main__":
    if sys.argv[1] == "indicadores":
        print(f"{'arquivo':40s} rascunho partido legendas japones hesit. segundos")
        for c in sys.argv[2:]:
            nr, p, nl, j, h, s = indicadores(c)
            print(f"{c.rsplit('/', 1)[-1].removesuffix('.json'):40s} {nr:8d} {p:7d} {nl:8d} {j:7d} {h:6d} {s:8.0f}")
    else:
        args = sys.argv[2:]
        ref = args[args.index("--ref") + 1] if "--ref" in args else None
        n = int(args[args.index("--n") + 1]) if "--n" in args else 40
        pares(args[0], args[1], args[2], args[3], ref=ref, n=n, frase="--frase" in args)
