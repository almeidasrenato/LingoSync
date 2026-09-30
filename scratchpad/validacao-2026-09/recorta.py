"""Fica só com as legendas da hipótese que caem onde a referência tem legenda.

A legenda desenhada no vídeo de 9 min não cobre toda fala (81 legendas contra
~140 do app), e o CER contaria como "a mais" toda fala sem legenda na imagem.
Critério: metade ou mais da duração da legenda dentro de alguma legenda de
referência. Uso: python3 recorta.py <hip.srt> <ref.srt> > recortada.srt
"""
import re, sys

def ler(p):
    blocos = re.split(r"\n\s*\n", open(p, encoding="utf8").read().strip())
    out = []
    for b in blocos:
        l = b.splitlines()
        i = next(k for k, x in enumerate(l) if "-->" in x)
        a, z = [sum(float(v) * m for v, m in zip(t.strip().replace(",", ".").split(":"), (3600, 60, 1))) for t in l[i].split("-->")]
        out.append((a, z, l[i], "\n".join(l[i + 1:])))
    return out

hip, ref = ler(sys.argv[1]), ler(sys.argv[2])
n = 0
for a, z, tc, txt in hip:
    dentro = sum(max(0, min(z, rz) - max(a, ra)) for ra, rz, _, _ in ref)
    if dentro >= 0.5 * (z - a):
        n += 1
        print(f"{n}\n{tc}\n{txt}\n")
