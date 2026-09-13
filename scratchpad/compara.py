#!/usr/bin/env python3
"""Põe traduções lado a lado, uma fala por vez, e confere a contagem.

O arnês do projeto produz arquivos de linhas: `tradutor-verify fonte` extrai
as falas reconhecidas e `tradutor-verify traduzir` devolve a tradução da
Apple. Colar as mesmas falas num site devolve outro arquivo de linhas. Este
script junta todos e mostra fala a fala.

A contagem vem primeiro de propósito: um arquivo com menos linhas que o
original significa que alguém juntou duas falas, e a partir daí toda legenda
recebe o texto da anterior — erro que passa despercebido lendo o texto.

    python3 scratchpad/compara.py falas-ja.txt apple.txt deepl.txt
"""

import sys
from pathlib import Path


def ler(caminho):
    linhas = Path(caminho).read_text().splitlines()
    # `tradutor-verify fonte` e `traduzir` imprimem um cabeçalho na 1ª linha.
    if linhas and (linhas[0].startswith("motor:") or " linhas em " in linhas[0]):
        linhas = linhas[1:]
    return linhas


def main(argumentos):
    if len(argumentos) < 2:
        print(__doc__)
        return 1

    arquivos = [Path(a) for a in argumentos]
    colunas = [ler(a) for a in arquivos]
    esperado = len(colunas[0])

    print(f"{arquivos[0].name}: {esperado} falas (referência)")
    desalinhado = False
    for arquivo, coluna in zip(arquivos[1:], colunas[1:]):
        marca = "ok" if len(coluna) == esperado else "DESALINHADO"
        if len(coluna) != esperado:
            desalinhado = True
        print(f"{arquivo.name}: {len(coluna)} falas  {marca}")
    print()

    if desalinhado:
        print("Contagem diferente: as colunas abaixo saem fora de ordem a partir")
        print("do ponto em que alguém juntou ou partiu uma fala.\n")

    larguras = max(len(a.stem) for a in arquivos)
    for i in range(max(len(c) for c in colunas)):
        print(f"{i + 1:>4}")
        for arquivo, coluna in zip(arquivos, colunas):
            texto = coluna[i] if i < len(coluna) else "—"
            print(f"     {arquivo.stem[:larguras]:<{larguras}}  {texto}")
        print()
    return 1 if desalinhado else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
