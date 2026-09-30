"""Régua do vídeo de anime (97 s): não há legenda japonesa feita por gente.

A legenda inglesa desenhada no vídeo (`*.legenda-na-imagem.txt`) diz quais
nomes e termos são falados e quantas vezes. Conta quantas ocorrências de cada
um a transcrição acerta na grafia canônica da obra. Não é CER: mede nome
próprio e termo, que é onde os motores divergem de verdade neste vídeo.

Uso: python3 entidades.py <legenda.srt>...
"""
import re, sys, unicodedata

# termo canônico: ocorrências esperadas (contadas na legenda inglesa)
TERMOS = {
    "もしもし": 1,        # Hello?!
    "モンキーDルフィ": 1,  # Monkey D. Luffy
    "海賊王": 1,          # King of the Pirates
    "ベガパンク": 1,      # Dr. Vegapunk
    "ヨーク": 1,          # York
    "五老星": 2,          # Five Elders (2x)
    "麦わら": 2,          # Straw Hat (2x)
    "凶悪": 1,            # vicious
    "権力": 1,            # authority
    "エッグヘッド": 1,    # (in there = Egghead)
    "ルフィ": 5,          # Luffy (5x, incluindo Monkey D. Luffy)
}


def texto(srt):
    linhas = [l for l in open(srt, encoding="utf8").read().splitlines()
              if l.strip() and not l.strip().isdigit() and "-->" not in l]
    t = unicodedata.normalize("NFKC", "".join(linhas))
    t = re.sub(r"<[^>]+>", "", t)
    return re.sub(r"[\s・.\-ー]", "", t)


def conta(t):
    return {k: min(t.count(re.sub(r"[ー]", "", k)), n) for k, n in TERMOS.items()}


if __name__ == "__main__":
    total = sum(TERMOS.values())
    for srt in sys.argv[1:]:
        c = conta(texto(srt))
        falta = [f"{k}({TERMOS[k] - v})" for k, v in c.items() if v < TERMOS[k]]
        print(f"{sum(c.values()):2d} de {total}  {srt.split('/')[-1]}  faltam: {' '.join(falta)}")
