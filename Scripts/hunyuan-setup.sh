#!/bin/bash
# Instala o Hunyuan-MT-7B (Tencent), tradutor local que roda fora do processo.
#
# Mesmo desenho do Qwen3-ASR: nao existe port CoreML, o que existe e MLX com
# Python. Entao ele fica num ambiente proprio ao lado dos modelos, e o app so
# oferece esse tradutor quando o ambiente existe. Sem ele, nada muda no app.
#
# Por que ele: o DeepL ganha da Apple em japones, mas manda o texto para fora
# da maquina. Este e o candidato a fazer o mesmo trabalho sem sair daqui —
# pesos abertos, 33 idiomas, especializado em traducao.
#
#   Scripts/hunyuan-setup.sh          instala (≈4,5 GB em 4 bits)
#   Scripts/hunyuan-setup.sh --remove apaga tudo
set -euo pipefail

RAIZ="$HOME/Library/Application Support/Tradutor/hunyuan"
MODELO_MLX="mlx-community/Hunyuan-MT-7B-4bit"
MODELO_ORIGEM="tencent/Hunyuan-MT-7B"

if [ "${1:-}" = "--remove" ]; then
    rm -rf "$RAIZ"
    echo "removido: $RAIZ"
    exit 0
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "precisa do uv para criar o ambiente:  brew install uv"
    exit 1
fi

echo "ambiente em $RAIZ"
mkdir -p "$RAIZ"
uv venv --python 3.12 "$RAIZ/venv"
uv pip install --python "$RAIZ/venv/bin/python" "mlx-lm>=0.21"

export HF_HOME="$RAIZ/hf"

# Primeiro a conversao pronta em 4 bits; se ela nao existir, converte aqui.
# Converter baixa os 15 GB do modelo original, entao a pronta e bem melhor.
echo "baixando $MODELO_MLX"
if "$RAIZ/venv/bin/hf" download "$MODELO_MLX" --local-dir "$RAIZ/modelo" >/dev/null 2>&1; then
    echo "modelo pronto em 4 bits"
else
    echo "conversao pronta indisponivel; convertendo de $MODELO_ORIGEM (baixa ~15 GB)"
    "$RAIZ/venv/bin/python" -m mlx_lm convert \
        --hf-path "$MODELO_ORIGEM" -q --q-bits 4 --mlx-path "$RAIZ/modelo"
fi

# O servidor fica aqui, e nao dentro do .app: quem instala o ambiente instala
# tudo de que ele precisa, e o app nao muda de tamanho por causa disso.
cat > "$RAIZ/servidor.py" <<'PY'
"""Traduz uma fala por linha, mantendo o modelo carregado.

Protocolo, uma linha JSON em cada sentido:

    entra  {"text": "...", "target": "Portuguese",
            "prev_source": "...", "prev_target": "..."}
    sai    {"text": "..."}  ou  {"error": "..."}

A primeira linha da saida e {"ready": true}, depois que o modelo carrega. Uma
fala por requisicao de proposito: pedir varias de uma vez devolve um bloco de
texto, e ai a contagem de linhas deixa de ser garantida — foi exatamente o
problema que apareceu ao usar o site do DeepL.

A fala anterior, quando vem, entra como um **turno de conversa ja respondido**
em vez de texto solto no prompt. Isso resolve duas coisas de uma vez: da
contexto (quem falou o que antes) e mostra ao modelo o formato da resposta
certa — so a traducao, sem comentario. Medido em 12/09/2026, o modelo comentou
a tarefa dentro da legenda duas vezes em 87 ("Parece que houve um erro na
trad...", "Como e que se chama esse personagem? Nao tenho certeza."); e fala
curta e ambigua que o dispara.
"""
import json
import sys
from pathlib import Path

from mlx_lm import generate, load

MODELO = str(Path(__file__).parent / "modelo")


def responde(objeto):
    sys.stdout.write(json.dumps(objeto, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    model, tokenizer = load(MODELO)
    responde({"ready": True})

    for linha in sys.stdin:
        linha = linha.strip()
        if not linha:
            continue
        try:
            pedido = json.loads(linha)
            texto = pedido["text"]
            alvo = pedido.get("target", "Portuguese")

            def instrucao(fala):
                # O formato do cartao do modelo para pares sem chines.
                return (
                    f"Translate the following segment into {alvo}, "
                    f"without additional explanation.\n\n{fala}"
                )

            conversa = []
            anterior, traduzido = pedido.get("prev_source"), pedido.get("prev_target")
            if anterior and traduzido:
                conversa.append({"role": "user", "content": instrucao(anterior)})
                conversa.append({"role": "assistant", "content": traduzido})
            conversa.append({"role": "user", "content": instrucao(texto)})

            prompt = tokenizer.apply_chat_template(
                conversa, add_generation_prompt=True
            )
            saida = generate(
                model, tokenizer, prompt=prompt,
                max_tokens=min(512, 8 + len(texto) * 3), verbose=False,
            )
            responde({"text": saida.strip()})
        except Exception as erro:  # noqa: BLE001 — o app decide o que fazer
            responde({"error": f"{type(erro).__name__}: {erro}"})


if __name__ == "__main__":
    main()
PY

echo "pronto. o app passa a oferecer 'Hunyuan-MT 7B' nos modos de video."
du -sh "$RAIZ"
