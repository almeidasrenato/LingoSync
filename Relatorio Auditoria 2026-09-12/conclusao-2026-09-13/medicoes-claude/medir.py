#!/usr/bin/env python3
"""Roda alinhamento + fonte e resume em números comparáveis."""
import re, subprocess, sys, os, json

RAIZ = "/Users/renatoalmeidasilva/Documentos/Tradutor instantaneo"
VER = os.path.join(RAIZ, ".build/release/tradutor-verify")
TERM = set("。！？.!?…")

CASOS = [
    ("ja-longo",  "Videos Exemplo/video exemplo conversa de pessoas.mp4", "ja"),
    ("ja-musica", "Videos Exemplo/video exemplo 2 (Conversa mais complexa).mp4", "ja"),
    ("en-conversa","Videos Exemplo/video exemplo conversa de pessoas ingles.mp4", "en"),
    ("en-dialogo","Videos Exemplo/video exemplo conversa de pessoas 2 ingles.mp4", "en"),
]

def roda(args):
    r = subprocess.run([VER]+args, cwd=RAIZ, capture_output=True, text=True, timeout=1800)
    return r.stdout + r.stderr

def alinhamento(video, motor, idioma):
    saida = roda(["alinhamento", video, motor, idioma])
    pecas = []
    dentro = False
    for linha in saida.splitlines():
        if linha.startswith("trechos reconhecidos:"):
            dentro = True; continue
        if dentro:
            m = re.match(r"\s*(\d+\.\d+)–\s*(\d+\.\d+)\s\s(.*)$", linha)
            if m: pecas.append((float(m.group(1)), float(m.group(2)), m.group(3)))
            elif linha.strip()=="" and pecas: dentro=False
    med = re.search(r"média reconhecido: início ([+-][\d.]+) s, fim ([+-][\d.]+) s", saida)
    medc = re.search(r"média legenda:\s+início ([+-][\d.]+) s, fim ([+-][\d.]+) s", saida)
    reg = re.search(r"·\s+(\d+) trechos de fala\s+·\s+(\d+) trechos reconhecidos", saida)
    return pecas, med, medc, reg, saida

def metricas(nome, motor, video, idioma):
    pecas, med, medc, reg, bruto = alinhamento(video, motor, idioma)
    if not pecas: return {"caso":nome,"motor":motor,"erro":bruto[-400:]}
    # assinatura do corte por teto: span >= 4.9 s, sem pontuacao no fim,
    # e a peca seguinte comeca colada (sem pausa)
    cortes = 0
    for i,(a,b,t) in enumerate(pecas):
        if b-a < 4.9: continue
        if t and t[-1] in TERM: continue
        if i+1 < len(pecas) and pecas[i+1][0]-b < 0.05: cortes += 1
    texto = "".join(t for _,_,t in pecas)
    fonte = roda(["fonte", video, idioma, motor])
    cues = [l.strip() for l in fonte.splitlines() if l.strip() and not l.startswith("motor:")]
    tot = sum(sum(1 for c in f if c in TERM) for f in cues)
    fim = sum(1 for f in cues if f and f[-1] in TERM)
    return {
        "caso": nome, "motor": motor,
        "pecas": len(pecas), "cortes_teto": cortes,
        "chars": len(texto.replace(" ","")),
        "regioes": int(reg.group(1)) if reg else None,
        "alcancadas": int(reg.group(2)) if reg else None,
        "cues": len(cues), "term_meio": tot-fim, "term_total": tot,
        "ali_ini": float(med.group(1)) if med else None,
        "ali_fim": float(med.group(2)) if med else None,
        "cue_ini": float(medc.group(1)) if medc else None,
        "cue_fim": float(medc.group(2)) if medc else None,
    }

if __name__ == "__main__":
    rotulo = sys.argv[1]
    motores = sys.argv[2].split(",") if len(sys.argv)>2 else ["apple"]
    casos = sys.argv[3].split(",") if len(sys.argv)>3 else [c[0] for c in CASOS]
    out = []
    for nome, video, idioma in CASOS:
        if nome not in casos: continue
        for motor in motores:
            if motor in ("parakeet",) and idioma=="ja": continue
            m = metricas(nome, motor, video, idioma)
            out.append(m)
            print(json.dumps(m, ensure_ascii=False), flush=True)
    destino = os.path.join(os.path.dirname(os.path.abspath(__file__)), f"{rotulo}.json")
    json.dump(out, open(destino,"w"), ensure_ascii=False, indent=1)
    print("gravado em", destino)
