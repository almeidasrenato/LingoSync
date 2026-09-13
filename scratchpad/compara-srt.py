#!/usr/bin/env python3
"""Põe dois arquivos .srt lado a lado, alinhados pelo tempo.

`compara.py` alinha por linha, e serve para arquivos de falas. Dois `.srt`
gerados por tradutores diferentes não têm o mesmo número de legendas — a
quebra de linha depende do tamanho do texto traduzido —, então aqui o
alinhamento é pelo instante em que cada legenda aparece.

    python3 scratchpad/compara-srt.py apple.srt deepl.srt
"""

import re
import sys
from pathlib import Path

TEMPO = re.compile(r"(\d\d):(\d\d):(\d\d),(\d\d\d) --> (\d\d):(\d\d):(\d\d),(\d\d\d)")


def ler(caminho):
    legendas = []
    for bloco in Path(caminho).read_text().split("\n\n"):
        linhas = [l for l in bloco.strip().split("\n") if l.strip()]
        if len(linhas) < 2:
            continue
        i = 0 if "-->" in linhas[0] else 1
        m = TEMPO.search(linhas[i]) if i < len(linhas) else None
        if not m:
            continue
        n = [int(x) for x in m.groups()]
        inicio = n[0] * 3600 + n[1] * 60 + n[2] + n[3] / 1000
        fim = n[4] * 3600 + n[5] * 60 + n[6] + n[7] / 1000
        texto = " ".join(linhas[i + 1:])
        texto = re.sub(r"<[^>]+>", "", texto).strip()
        legendas.append((inicio, fim, texto))
    return legendas


def relogio(s):
    return f"{int(s // 60):02d}:{s % 60:05.2f}"


def main(argumentos):
    if len(argumentos) != 2:
        print(__doc__)
        return 1

    a, b = (Path(x) for x in argumentos)
    esquerda, direita = ler(a), ler(b)
    print(f"{a.name}: {len(esquerda)} legendas")
    print(f"{b.name}: {len(direita)} legendas\n")

    usadas = set()
    for inicio, fim, texto in esquerda:
        meio = (inicio + fim) / 2
        # Casa pelo miolo: a legenda do outro arquivo que cobre este instante,
        # mais as que começam dentro desta janela.
        casadas = [
            (j, d) for j, d in enumerate(direita)
            if (d[0] <= meio <= d[1]) or (inicio <= (d[0] + d[1]) / 2 <= fim)
        ]
        usadas.update(j for j, _ in casadas)
        print(f"{relogio(inicio)}")
        print(f"   A  {texto}")
        if casadas:
            for _, d in casadas:
                print(f"   B  {d[2]}")
        else:
            print("   B  —")
        print()

    sobrando = [d for j, d in enumerate(direita) if j not in usadas]
    if sobrando:
        print(f"sem par do lado A ({len(sobrando)}):")
        for d in sobrando:
            print(f"   {relogio(d[0])}  {d[2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
