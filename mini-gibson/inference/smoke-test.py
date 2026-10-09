import json
import os
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _versions_env():
    """KEY=VALUE pairs from env/versions.env, the same file serve-vllm.sh sources,
    so a non-default VLLM_HOST/VLLM_PORT there is honoured here too."""
    values = {}
    try:
        with open(os.path.join(ROOT, "env", "versions.env"), encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


_versions = _versions_env()
host = os.getenv("VLLM_HOST") or _versions.get("VLLM_HOST") or "127.0.0.1"
port = os.getenv("VLLM_PORT") or _versions.get("VLLM_PORT") or "8000"
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
