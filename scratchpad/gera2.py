"""Diálogo difícil: pausa curta e interjeição de uma pessoa colada na fala da
outra — é o caso em que o reconhecedor junta as duas num trecho só."""
import subprocess, wave, array, json, os, sys
RATE = 16000

def diga(texto, voz, destino):
    aiff = destino + ".aiff"
    subprocess.run(["say", "-v", voz, "-o", aiff, texto], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1",
                    aiff, destino], check=True)
    os.remove(aiff)
    w = wave.open(destino); a = array.array("h"); a.frombytes(w.readframes(w.getnframes()))
    os.remove(destino)
    return list(a)

def monta(roteiro, pasta, saida):
    amostras, verdade = [], []
    for i, (voz, quem, texto, pausa) in enumerate(roteiro):
        parte = diga(texto, voz, f"{pasta}/t{i}.wav")
        ini = len(amostras) / RATE
        amostras += parte
        verdade.append({"quem": quem, "texto": texto,
                        "inicio": round(ini, 2), "fim": round(len(amostras)/RATE, 2)})
        amostras += [0] * int(pausa * RATE)
    o = wave.open(saida, "wb"); o.setnchannels(1); o.setsampwidth(2); o.setframerate(RATE)
    o.writeframes(array.array("h", amostras).tobytes()); o.close()
    json.dump(verdade, open(saida.replace(".wav", ".json"), "w"), ensure_ascii=False, indent=1)
    print(f"{saida}: {len(amostras)/RATE:.1f}s, {len(verdade)} falas")

A_PT, B_PT = "Luciana", "Rocko (Português (Brasil))"
A_EN, B_EN = "Samantha", "Fred"
# pausa curtíssima depois da fala longa, e a resposta é uma palavra só
PT = [
    (A_PT, "A", "Então o relatório de vendas fecha na sexta", 0.05),
    (B_PT, "B", "Entendi", 0.10),
    (A_PT, "A", "e a apresentação para a diretoria é na segunda", 0.05),
    (B_PT, "B", "Certo", 0.10),
    (A_PT, "A", "Você consegue preparar os números até quinta", 0.05),
    (B_PT, "B", "Consigo sim, sem problema", 0.30),
    (A_PT, "A", "Ótimo, então fechamos assim", 0.05),
    (B_PT, "B", "Combinado", 0.30),
]
EN = [
    (A_EN, "A", "So the sales report closes on Friday", 0.05),
    (B_EN, "B", "Understood", 0.10),
    (A_EN, "A", "and the board presentation is on Monday", 0.05),
    (B_EN, "B", "Right", 0.10),
    (A_EN, "A", "Can you have the numbers ready by Thursday", 0.05),
    (B_EN, "B", "I can, no problem", 0.30),
    (A_EN, "A", "Great, then we are settled", 0.05),
    (B_EN, "B", "Agreed", 0.30),
]
pasta = sys.argv[1]
monta(PT, pasta, f"{pasta}/dificil-pt.wav")
monta(EN, pasta, f"{pasta}/dificil-en.wav")
