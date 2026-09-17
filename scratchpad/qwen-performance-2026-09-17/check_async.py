"""Verifica limites, EOS e repetição sem carregar pesos de reconhecimento."""
from types import SimpleNamespace
import mlx.core as mx
from async_runner import generate_async, generation


class FakeModel:
    def __init__(self, tokens):
        self.tokens = tokens
        self.steps = 0

    def create_cache(self, max_seq_len):
        return SimpleNamespace(keys=[], values=[])

    def output(self, step):
        token = self.tokens[min(step, len(self.tokens)-1)]
        return mx.where(mx.arange(32) == token, 1.0, -1.0)[None, None, :]

    def prefill(self, **kwargs):
        self.steps = 0
        return self.output(0)

    def step(self, input_ids, position_ids, cache, validate_input_ids):
        assert input_ids.dtype == mx.int32 and input_ids.shape == (1, 1)
        assert int(input_ids.item()) == self.tokens[min(self.steps, len(self.tokens)-1)]
        assert int(position_ids[0, 0, 0].item()) == 2 + self.steps
        self.steps += 1
        return self.output(self.steps)


def check():
    for tokens, limit in [([9], 0), ([9], 1), ([1], 1), ([1, 2, 3, 9], 3),
                          ([1, 2, 9], 8), ([1]*40, 40), ([1, 2]*40, 70)]:
        config = generation.GenerationConfig(max_new_tokens=limit, eos_token_ids=[9])
        baseline, candidate = FakeModel(tokens), FakeModel(tokens)
        inputs = dict(input_ids=mx.array([[0, 1]]), audio_features=mx.zeros((1, 1, 1)),
                      position_ids=mx.array([[[0, 1]]*3]), config=config)
        expected = generation.generate_with_info(model=baseline, **inputs)
        actual = generate_async(model=candidate, **inputs)
        assert actual == expected, (tokens, limit, expected, actual)
        assert candidate.steps <= baseline.steps + 1
    try:
        generate_async(FakeModel([1]), mx.array([[0, 1]]), mx.zeros((1, 1, 1)),
                       mx.array([[[0, 1]]*3]), generation.GenerationConfig(max_new_tokens=-1))
    except ValueError:
        pass
    else:
        raise AssertionError('limite negativo deve ser recusado')
    print('OK: mesmos tokens e motivos de parada; limites, EOS, repetição e posições preservados')


if __name__ == '__main__':
    check()
