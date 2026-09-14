#!/usr/bin/env python3
"""Áudios com roteiro conhecido; execute fora do sandbox de serviços do macOS."""
import json
import random
import struct
import subprocess
import wave
from pathlib import Path
out = Path("/tmp/tradutor-qualidade-falas")
out.mkdir(exist_ok=True)
examples = [
    ("ja-boa-noite", "Kyoko", "おやすみなさい。"),
    ("en-obrigado", "Samantha", "Thank you for watching."),
    ("ja-contexto", "Kyoko", "明日の会議は午前九時です。資料を忘れないでください。おやすみなさい。"),
    ("en-contexto", "Samantha", "The meeting is at nine tomorrow morning. Do not forget the documents. Thank you for watching."),
]
for name, voice, text in examples:
    aiff = out / (name + ".aiff")
    wav = out / (name + ".wav")
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16", str(aiff), str(wav)], check=True)
    assert wav.stat().st_size > 5000, "O sintetizador retornou arquivo vazio; confira a permissão do serviço de fala."
random.seed(14)
for name, values in [("silencio", [0.0] * 48000), ("ruido", [random.uniform(-.003, .003) for _ in range(48000)])]:
    with wave.open(str(out / (name + ".wav")), "wb") as stream:
        stream.setparams((1, 2, 16000, len(values), "NONE", "not compressed"))
        stream.writeframes(struct.pack("<" + "h" * len(values), *[int(x * 32767) for x in values]))
(out / "referencias.json").write_text(json.dumps(examples, ensure_ascii=False, indent=2))
print(out)
