"""Separa a voz de um vídeo e grava WAV 16 kHz mono (nunca MP3).

    separa.py <video> <metodo> <saida.wav>
    metodo: original   (sem separação: a linha de base, pelo mesmo caminho)
            roformer   (BS-RoFormer, model_bs_roformer_ep_317_sdr_12.9755, via audio-separator)
            htdemucs   (Demucs htdemucs, a faixa de voz)

A separação roda em 44,1 kHz estéreo, que é onde os dois modelos foram
treinados; só a voz separada desce para 16 kHz. Imprime o tempo gasto.
"""
import subprocess, sys, tempfile, time
from pathlib import Path

AQUI = Path(__file__).resolve().parent


def ffmpeg(*a):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *a], check=True)


def main():
    video, metodo, saida = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    t0 = time.time()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        estereo = tmp / "entrada.wav"
        ffmpeg("-i", video, "-vn", "-ac", "2", "-ar", "44100", "-c:a", "pcm_f32le", str(estereo))
        if metodo == "original":
            voz = estereo
        elif metodo == "roformer":
            from audio_separator.separator import Separator
            sep = Separator(output_dir=str(tmp), model_file_dir=str(AQUI / "hf/separacao"),
                            output_format="WAV", output_single_stem="Vocals")
            sep.load_model("model_bs_roformer_ep_317_sdr_12.9755.ckpt")
            voz = tmp / sep.separate(str(estereo))[0]
        elif metodo == "htdemucs":
            import soundfile as sf, torch
            from demucs.pretrained import get_model
            from demucs.apply import apply_model
            modelo = get_model("htdemucs")
            modelo.eval()
            x, sr = sf.read(str(estereo), dtype="float32")
            wav = torch.from_numpy(x.T)
            ref = wav.mean(0)
            wav = (wav - ref.mean()) / ref.std()
            dev = "mps" if torch.backends.mps.is_available() else "cpu"
            with torch.no_grad():
                fontes = apply_model(modelo, wav[None], device=dev, split=True, overlap=0.25)[0]
            fontes = fontes * ref.std() + ref.mean()
            vocal = fontes[modelo.sources.index("vocals")].cpu().numpy().T
            voz = tmp / "voz.wav"
            sf.write(str(voz), vocal, sr, subtype="FLOAT")
        else:
            sys.exit(f"metodo desconhecido: {metodo}")
        saida.parent.mkdir(parents=True, exist_ok=True)
        ffmpeg("-i", str(voz), "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(saida))
    print(f"{metodo} {Path(video).name}: {time.time() - t0:.1f} s")


if __name__ == "__main__":
    main()
