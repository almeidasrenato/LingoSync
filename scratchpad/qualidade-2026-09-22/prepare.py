"""Roteiro pt-BR conhecido; áudio sintético, não substitui gravação real."""
import array, json, random, subprocess, wave
from pathlib import Path

out = Path(__file__).resolve().parent / 'audio'
out.mkdir(exist_ok=True)
lines = [
    ('Luciana', 'Bom dia! A reunião começa às nove horas.', .45),
    ('Rocko (Português (Brasil))', 'Você enviou o relatório?', .15),
    ('Luciana', 'Ainda não. Vou enviar amanhã, depois do almoço.', .5),
    ('Rocko (Português (Brasil))', 'Não são quinze caixas, são cinquenta.', .25),
    ('Luciana', 'Certo.', .12),
    ('Rocko (Português (Brasil))', 'O pagamento foi de cento e vinte e três reais e cinquenta centavos.', .4),
    ('Luciana', 'Por favor, não feche a janela!', .25),
    ('Rocko (Português (Brasil))', 'Entendi. Obrigado por avisar.', .5),
    ('Luciana', 'Se chover amanhã, vamos adiar a viagem para sexta-feira.', .3),
    ('Rocko (Português (Brasil))', 'Combinado. Até logo!', .8),
]
samples, refs = [0] * 8000, []
for i, (voice, text, pause) in enumerate(lines):
    aiff, wav = out / f'utterance-{i}.aiff', out / f'utterance-{i}.wav'
    subprocess.run(['say', '-v', voice, '-r', '165', '-o', str(aiff), text], check=True)
    subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(aiff), str(wav)], check=True)
    with wave.open(str(wav)) as f:
        part = array.array('h'); part.frombytes(f.readframes(f.getnframes()))
    assert len(part) > 1000
    # Remove só o silêncio de arquivo, sem encostar na fala; margem de 80 ms.
    alive = [j for j, x in enumerate(part) if abs(x) > 100]
    part = part[max(0, alive[0]-1280):min(len(part), alive[-1]+1281)]
    start = len(samples)
    samples.extend(part)
    refs.append(dict(text=text, start=start/16000, end=len(samples)/16000, voice=voice))
    samples.extend([0] * int(pause*16000))
    aiff.unlink(); wav.unlink()
for variant in ['pt-clean', 'pt-quiet']:
    data = list(samples)
    if variant == 'pt-quiet':
        for i, r in enumerate(refs):
            if i % 2 == 0:
                for j in range(round(r['start']*16000),round(r['end']*16000)):
                    data[j] = round(data[j] * .0630957344) # -24 dB, só uma voz
    with wave.open(str(out/(variant+'.wav')), 'wb') as f:
        f.setparams((1,2,16000,0,'NONE','not compressed'))
        f.writeframes(array.array('h',data).tobytes())
    (out/(variant+'.truth.json')).write_text(json.dumps(refs,ensure_ascii=False,indent=2))
    print(variant, round(len(data)/16000,2), 'segundos', flush=True)
