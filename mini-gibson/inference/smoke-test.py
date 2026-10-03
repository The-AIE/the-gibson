import json
import os
import urllib.request

host = os.getenv("VLLM_HOST", "127.0.0.1")
port = os.getenv("VLLM_PORT", "8000")
base = f"http://{host}:{port}"

with urllib.request.urlopen(base + "/v1/models", timeout=10) as r:
    models = json.load(r)
assert models.get("data"), "vLLM returned no models"

payload = json.dumps({
    "model": "nemotron-base",
    "messages": [{"role": "user", "content": "Reply with exactly MINI_GIBSON_OK"}],
    "temperature": 0,
    "max_tokens": 32,
}).encode()
req = urllib.request.Request(base + "/v1/chat/completions", data=payload, headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=120) as r:
    result = json.load(r)
text = result["choices"][0]["message"]["content"]
assert "MINI_GIBSON_OK" in text, text
print("PASS vLLM OpenAI-compatible smoke test")
