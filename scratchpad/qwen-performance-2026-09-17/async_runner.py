"""Experimento: agenda um token adiante, sem alterar o cálculo do modelo."""
import importlib

import mlx.core as mx

generation = importlib.import_module('mlx_qwen3_asr.generate')


def generate_async(model, input_ids, audio_features, position_ids, config=None):
    config = config or generation.GenerationConfig()
    if config.temperature != 0 or config.max_new_tokens <= 0:
        return generation.generate_with_info(model, input_ids, audio_features, position_ids, config)

    seq_len = input_ids.shape[1]
    cache = model.create_cache(max_seq_len=int(seq_len + config.max_new_tokens))
    logits = model.prefill(input_ids=input_ids, audio_features=audio_features,
                           position_ids=position_ids, cache=cache)
    token = mx.argmax(logits.reshape(-1)).astype(input_ids.dtype)
    positions = generation._build_decode_positions(
        seq_len=seq_len, max_new_tokens=config.max_new_tokens, dtype=position_ids.dtype)
    mx.async_eval(token)
    generated = []
    for step in range(config.max_new_tokens):
        if step + 1 < config.max_new_tokens:
            logits = model.step(input_ids=token.reshape(1, 1),
                                position_ids=positions[:, :, step:step+1],
                                cache=cache, validate_input_ids=False)
            next_token = mx.argmax(logits.reshape(-1)).astype(input_ids.dtype)
            mx.async_eval(next_token, cache.keys, cache.values)
        current = int(token.item())
        generated.append(current)
        if current in config.eos_token_ids or generation._detect_repetition(generated):
            break
        if step + 1 < config.max_new_tokens:
            token = next_token
    # Uma operação já agendada pode ter ficado além do EOS; descarta sua saída.
    mx.synchronize()
    return generation._finalize_generation_result(generated, config)


if __name__ == '__main__':
    importlib.import_module('mlx_qwen3_asr.transcribe').generate = generate_async
    from mlx_qwen3_asr.cli import main
    main()
