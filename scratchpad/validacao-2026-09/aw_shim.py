"""anime-whisper no lugar do CLI do Qwen, para medir pelo caminho do app.

O app chama `qwen/venv/bin/python -c <launcher> --model ... -f json -o <pasta> <fala.wav>`
e lê `<pasta>/fala.json` ({text, segments}). Este script recebe os mesmos
argumentos (o `-c` é tirado pelo wrapper) e grava o mesmo JSON:

- corta o WAV do app em falas com o Silero VAD (o anime-whisper foi treinado
  em falas isoladas de visual novel, não em blocos de 30 s);
- reconhece cada fala com o anime-whisper (transformers, MPS, float16, os
  parâmetros da model card);
- alinha o texto com o MESMO Qwen3-ForcedAligner que o app usa no Qwen, para
  que só o texto do reconhecedor mude entre as duas medições.

Variáveis:
  AW_PONTO=1     põe 。 no fim de cada fala que não termina em pontuação
                 (o modelo omite o ponto final quase sempre)
  AW_LOG=<arq>   grava cada fala crua (texto e tempo) em JSON lines
  AW_CHUNKS=30   em vez do VAD, usa os cortes de 30 s do próprio Qwen
  AW_VAD_LIMIAR  limiar do Silero (padrão 0,5)
  AW_NGRAM=5     no_repeat_ngram_size (a model card: 0, ou 5-10 se houver laço)
"""
import json, os, sys, time
from pathlib import Path

import numpy as np
import soundfile as sf

AQUI = Path(__file__).resolve().parent
SR = 16000


def args():
    a = sys.argv[1:]
    out = a[a.index("-o") + 1]
    lang = a[a.index("--language") + 1] if "--language" in a else "Japanese"
    return Path(a[-1]), Path(out), lang


def segmentos(audio):
    if os.environ.get("AW_CHUNKS"):
        from mlx_qwen3_asr.chunking import split_audio_into_chunks
        return [(int(off * SR), int(off * SR) + len(c)) for c, off in split_audio_into_chunks(audio, sr=SR)]
    import torch
    from silero_vad import load_silero_vad, get_speech_timestamps
    vad = load_silero_vad()
    ts = get_speech_timestamps(torch.from_numpy(audio), vad, sampling_rate=SR,
                               threshold=float(os.environ.get("AW_VAD_LIMIAR", "0.5")),
                               max_speech_duration_s=25, speech_pad_ms=200,
                               min_silence_duration_ms=300)
    return [(t["start"], t["end"]) for t in ts]


def main():
    wav, pasta, lang = args()
    t0 = time.time()
    audio, sr = sf.read(str(wav), dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    assert sr == SR, sr
    trechos = [(a, b) for a, b in segmentos(audio) if b - a >= SR * 0.2]

    import torch
    from transformers import pipeline
    modelo = next((AQUI / "hf/models--litagin--anime-whisper/snapshots").iterdir())
    pipe = pipeline("automatic-speech-recognition", model=str(modelo),
                    device="mps", dtype=torch.float16)
    gen = {"language": "Japanese", "no_repeat_ngram_size": int(os.environ.get("AW_NGRAM", "0")), "repetition_penalty": 1.0}
    entradas = [{"raw": audio[a:b], "sampling_rate": SR} for a, b in trechos]
    textos = [r["text"].strip() for r in pipe(entradas, batch_size=8, generate_kwargs=gen)] if entradas else []
    t1 = time.time()

    from mlx_qwen3_asr.forced_aligner import ForcedAligner
    aligner = ForcedAligner()
    ponto = os.environ.get("AW_PONTO") == "1"
    fim = tuple("。！？!?…」』")
    partes, segs, log = [], [], []
    for (a, b), t in zip(trechos, textos):
        log.append({"start": a / SR, "end": b / SR, "text": t})
        if not t:
            continue
        if ponto and not t.endswith(fim):
            t += "。"
        partes.append(t)
        for w in aligner.align(audio[a:b], t, lang):
            segs.append({"text": w.text, "start": w.start_time + a / SR, "end": w.end_time + a / SR})
    t2 = time.time()

    pasta.mkdir(parents=True, exist_ok=True)
    (pasta / (wav.stem + ".json")).write_text(
        json.dumps({"text": "".join(partes), "language": lang, "segments": segs}, ensure_ascii=False))
    if os.environ.get("AW_LOG"):
        with open(os.environ["AW_LOG"], "a") as f:
            f.write(json.dumps({"audio_s": len(audio) / SR, "trechos": len(trechos),
                                "reconhecer_s": t1 - t0, "alinhar_s": t2 - t1, "falas": log},
                               ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
