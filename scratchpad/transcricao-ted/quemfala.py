#!/usr/bin/env python3
"""Quem fala nas legendas geradas, contra o gabarito humano.

    quemfala.py <gabarito.txt> <gerado.json>...

`gerado.json` é a saída de `tradutor-verify gerar ... --locutores`.

- acerto: para cada fala do gabarito, o rótulo das legendas que mais cobrem o
  tempo dela; rótulo -> pessoa pelo mapeamento de maioria (a regra do gate
  `gabarito`). Conta só falas de uma pessoa.
- mistura: legendas que cobrem 0,3 s ou mais de duas pessoas diferentes.
- sem rótulo: legendas sem locutor.
"""
import json, re, sys
from collections import Counter, defaultdict

PADRAO = re.compile(r"(\d+)\s+(\d+):(\d+):(\d+),(\d+)\s*-->\s*(\d+):(\d+):(\d+),(\d+)\s+\[([^\]]+)\]")

def segundos(h, m, s, ms):
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000

def gabarito(caminho):
    marcas = []
    for linha in open(caminho, encoding="utf-8"):
        m = PADRAO.search(linha)
        if not m:
            continue
        g = m.groups()
        marcas.append((segundos(*g[1:5]), segundos(*g[5:9]), [q.strip() for q in g[9].split(",")]))
    return marcas

def sobre(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))

def mede(marcas, legendas):
    janela = (min(m[0] for m in marcas) - 1, max(m[1] for m in marcas) + 1)
    legendas = [l for l in legendas if sobre(l["start"], l["end"], *janela) > 0]
    escolha = []
    for a, b, quem in marcas:
        cob = Counter()
        for l in legendas:
            s = sobre(a, b, l["start"], l["end"])
            if s > 0:
                cob[l["speaker"] or "-"] += s
        escolha.append(cob.most_common(1)[0][0] if cob else "-")
    votos = defaultdict(Counter)
    for (a, b, quem), rotulo in zip(marcas, escolha):
        if len(quem) == 1:
            votos[rotulo][quem[0]] += 1
    mapa = {r: c.most_common(1)[0][0] for r, c in votos.items() if r != "-"}
    simples = [(m, r) for m, r in zip(marcas, escolha) if len(m[2]) == 1]
    acertos = sum(1 for (a, b, quem), r in simples if mapa.get(r) == quem[0])
    mistura = 0
    for l in legendas:
        pessoas = Counter()
        for a, b, quem in marcas:
            if len(quem) == 1:
                pessoas[quem[0]] += sobre(a, b, l["start"], l["end"])
        if sum(1 for v in pessoas.values() if v >= 0.3) >= 2:
            mistura += 1
    sem = sum(1 for l in legendas if not l["speaker"])
    vozes = len({l["speaker"] for l in legendas if l["speaker"]})
    return acertos, len(simples), mistura, len(legendas), sem, vozes

if __name__ == "__main__":
    marcas = gabarito(sys.argv[1])
    print(f"gabarito: {len(marcas)} falas, {len({q for m in marcas for q in m[2]})} pessoas")
    for caminho in sys.argv[2:]:
        dados = json.load(open(caminho))
        a, n, mis, tot, sem, vozes = mede(marcas, dados["legendas"])
        nome = caminho.rsplit("/", 1)[-1].removesuffix(".json")
        print(f"  {nome:42s} acerto {a:3d}/{n:<3d} ({100*a/max(n,1):3.0f}%)  "
              f"mistura {mis:3d}/{tot:<3d}  sem rotulo {sem:3d}  vozes {vozes}")
