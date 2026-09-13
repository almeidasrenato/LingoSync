"""Monta um diálogo de duas vozes com fronteiras conhecidas.

Cada fala é gerada separada pelo `say`, e o roteiro diz quem fala e em que
instante — então o teste tem verdade de campo: dá para comparar o que o app
achou contra o que de fato foi dito.
"""
import subprocess, wave, array, json, sys, os

RATE = 16000

def diga(texto, voz, destino):
    aiff = destino + ".aiff"
    subprocess.run(["say", "-v", voz, "-o", aiff, texto], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1",
                    aiff, destino], check=True)
    os.remove(aiff)
    w = wave.open(destino)
    n = w.getnframes()
    a = array.array("h"); a.frombytes(w.readframes(n))
    return list(a)

def monta(roteiro, pasta, saida, pausa=0.35):
    amostras = []
    verdade = []
    for i, (voz, quem, texto) in enumerate(roteiro):
        parte = diga(texto, voz, f"{pasta}/p{i}.wav")
        inicio = len(amostras) / RATE
        amostras += parte
        fim = len(amostras) / RATE
        verdade.append({"quem": quem, "texto": texto, "inicio": round(inicio, 2),
                        "fim": round(fim, 2)})
        amostras += [0] * int(pausa * RATE)
        os.remove(f"{pasta}/p{i}.wav")
    o = wave.open(saida, "wb"); o.setnchannels(1); o.setsampwidth(2); o.setframerate(RATE)
    o.writeframes(array.array("h", amostras).tobytes()); o.close()
    json.dump(verdade, open(saida.replace(".wav", ".json"), "w"), ensure_ascii=False, indent=1)
    print(f"{saida}: {len(amostras)/RATE:.1f}s, {len(verdade)} falas")

# Português: duas pessoas, com gênero marcado nas falas para conferir a tradução.
PT = [
    ("Luciana", "A", "Bom dia. Você é o novo analista?"),
    ("Rocko (Português (Brasil))", "B", "Sou sim. Cheguei hoje, estou muito animado."),
    ("Luciana", "A", "Eu sou a Marina, trabalho aqui há três anos."),
    ("Rocko (Português (Brasil))", "B", "Prazer. Eu estava nervoso, mas agora estou tranquilo."),
    ("Luciana", "A", "Fique calma, quer dizer, fique calmo. O time é ótimo."),
    ("Rocko (Português (Brasil))", "B", "Obrigado. Você foi muito atenciosa comigo."),
    ("Luciana", "A", "Qualquer dúvida, me chame. Estou sempre por aqui."),
    ("Rocko (Português (Brasil))", "B", "Combinado. Vou começar pelo relatório de vendas."),
]
EN = [
    ("Samantha", "A", "Good morning. Are you the new analyst?"),
    ("Fred", "B", "I am. I started today, and I am quite excited."),
    ("Samantha", "A", "I am Marina. I have worked here for three years."),
    ("Fred", "B", "Nice to meet you. I was nervous, but now I am calm."),
    ("Samantha", "A", "Do not worry. The team is great, you will like it."),
    ("Fred", "B", "Thank you. You have been very kind to me."),
    ("Samantha", "A", "Any question, just call me. I am always around."),
    ("Fred", "B", "Will do. I will start with the sales report."),
]
pasta = sys.argv[1]
monta(PT, pasta, f"{pasta}/dialogo-pt.wav")
monta(EN, pasta, f"{pasta}/dialogo-en.wav")
