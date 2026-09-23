"""End-to-end inference tests against the deployed fleet, from the controller.

`make verify` only proves each node can produce one token. These check that the
model gives correct, deterministic answers through the OpenAI-compatible API,
streams, handles concurrent requests at a usable speed, and that every node in
the fleet serves the same model and build.
"""

import json
from concurrent.futures import ThreadPoolExecutor

import requests

# A question a 1B instruct model gets right, with a one-word answer to match on.
QUESTION = "What is the capital of France? Answer with one word."
ANSWER = "paris"
# A prompt with a long enough greedy continuation to expose nondeterminism.
STORY = "Write two sentences about a lighthouse keeper."
# Greedy decoding is only reproducible without prompt-cache reuse: a request that
# starts from a cached KV prefix computes slightly different logits, and near-ties
# then flip. So the reproducibility checks turn the cache off.
REPRODUCIBLE = {"max_tokens": 48, "cache_prompt": False}
# Generation speed floor. The CPU fleet does ~40 tokens/s; anything under this
# means the wrong build or CPU kernels are being used.
MIN_TOKENS_PER_SECOND = 5


def content(response):
    return response["choices"][0]["message"]["content"]


def test_answers_a_factual_question(node):
    response = node.chat(QUESTION, max_tokens=8)
    assert ANSWER in content(response).lower()
    assert response["choices"][0]["finish_reason"] == "stop"


def test_greedy_decoding_is_deterministic(node):
    first = content(node.chat(STORY, **REPRODUCIBLE))
    second = content(node.chat(STORY, **REPRODUCIBLE))
    assert first
    assert first == second


def test_max_tokens_is_honoured(node):
    response = node.chat(STORY, max_tokens=5)
    assert response["choices"][0]["finish_reason"] == "length"
    assert response["usage"]["completion_tokens"] == 5
    assert response["usage"]["prompt_tokens"] > 0


def test_streams_the_same_answer(node):
    body = {
        "messages": [{"role": "user", "content": QUESTION}],
        "temperature": 0,
        "max_tokens": 8,
        "stream": True,
    }
    response = node.post("/v1/chat/completions", body, stream=True)
    assert response.status_code == 200
    events = [
        line.removeprefix(b"data: ").decode()
        for line in response.iter_lines()
        if line.startswith(b"data: ")
    ]
    assert events[-1] == "[DONE]"
    chunks = [json.loads(event) for event in events[:-1]]
    streamed = "".join(chunk["choices"][0]["delta"].get("content") or "" for chunk in chunks)
    assert ANSWER in streamed.lower()
    assert chunks[-1]["choices"][0]["finish_reason"] == "stop"


def test_generates_at_a_usable_speed(node):
    response = node.chat(STORY, max_tokens=32)
    assert response["timings"]["predicted_per_second"] >= MIN_TOKENS_PER_SECOND


def test_tokenizer_round_trips(node):
    text = "The quick brown fox jumps over the lazy dog."
    tokens = node.post("/tokenize", {"content": text}).json()["tokens"]
    assert tokens
    detokenized = node.post("/detokenize", {"tokens": tokens}).json()["content"]
    assert detokenized.strip() == text


def test_serves_concurrent_requests(node):
    # Twice the server's slots, so some requests queue.
    requests_count = 2 * node.get("/props").json()["total_slots"]
    with ThreadPoolExecutor(max_workers=requests_count) as pool:
        answers = list(pool.map(lambda _: content(node.chat(QUESTION, max_tokens=8)), range(requests_count)))
    assert all(ANSWER in answer.lower() for answer in answers), answers


def test_refuses_missing_or_wrong_api_key(node):
    body = {"messages": [{"role": "user", "content": QUESTION}], "max_tokens": 1}
    url = node.base_url + "/v1/chat/completions"
    assert requests.post(url, json=body, timeout=30).status_code == 401
    wrong = {"Authorization": "Bearer not-the-key"}
    assert requests.post(url, json=body, headers=wrong, timeout=30).status_code == 401


def test_fleet_serves_one_model_and_build(fleet):
    props = {
        node.name: (p["model_path"], p["build_info"])
        for node in fleet
        for p in [node.get("/props").json()]
    }
    assert len(set(props.values())) == 1, props


def test_fleet_gives_the_same_answer(fleet):
    # Same weights, build and greedy sampling should give the same tokens on every
    # node, so a load balancer in front of them is invisible to clients.
    answers = {node.name: content(node.chat(STORY, **REPRODUCIBLE)) for node in fleet}
    assert len(set(answers.values())) == 1, answers
