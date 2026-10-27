"""Validated provider profiles and bounded, auditable single-tool requests."""

import hashlib
import json
from urllib.parse import urlsplit

import httpx

META_URL = "https://api.meta.ai/v1"
BASETEN_URL = "https://inference.baseten.co/v1"
BASETEN_MAX_BODY_BYTES = 100 * 1024 * 1024


def image_limit(config):
    return 8 if (getattr(config, "meta_provider", "meta") == "baseten"
                 or urlsplit(config.meta_api_base_url).hostname == "inference.baseten.co") else 12


def profile(config):
    provider = getattr(config, "meta_provider", "meta")
    base = config.meta_api_base_url.rstrip("/")
    if provider == "baseten" and base == META_URL:
        base = BASETEN_URL
    if urlsplit(base).hostname == "inference.baseten.co":
        provider = "baseten"
    parsed = urlsplit(base)
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Inference endpoints cannot contain credentials, query parameters or fragments")
    local = parsed.hostname in {"localhost", "127.0.0.1", "::1"}
    if not parsed.hostname or (parsed.scheme != "https" and not (local and parsed.scheme == "http")):
        raise ValueError("Inference requires HTTPS outside localhost")
    if provider == "baseten" and base != BASETEN_URL:
        raise ValueError("The Baseten profile requires its official inference endpoint")
    if provider == "meta" and base != META_URL:
        raise ValueError("Use the self_hosted profile for a custom inference endpoint")
    if not config.meta_api_key or not config.meta_reasoning_model:
        raise RuntimeError("Configure the inference API key and exact model; no fallback is selected")
    return provider, base, image_limit(config)


def invoke(*, provider, base, key, model, messages, tool, schema, max_tokens, timeout):
    body = {
        "model": model,
        "max_tokens": max_tokens,
        "messages": messages,
        "parallel_tool_calls": False,
        "tool_choice": "auto",
        "tools": [{"type": "function", "function": {
            "name": tool, "description": "Submit one server-validated result.", "parameters": schema,
        }}],
    }
    encoded_request = json.dumps(body, sort_keys=True).encode()
    if provider == "baseten" and len(encoded_request) > BASETEN_MAX_BODY_BYTES:
        raise ValueError("Request exceeds the Baseten media body limit")
    response = httpx.post(
        base + "/chat/completions", headers={"Authorization": f"Bearer {key}"},
        timeout=timeout, json=body,
    )
    response.raise_for_status()
    payload = response.json()
    message = payload["choices"][0]["message"]
    calls = message.get("tool_calls") or []
    if calls:
        if len(calls) != 1 or calls[0]["function"]["name"] != tool:
            raise ValueError("Unexpected tool or number of calls")
        raw = calls[0]["function"]["arguments"]
    else:
        raw = message.get("content") or ""
    # A reported model is provider evidence, not independent verification of weights.
    audit = {
        "provider": provider, "inference_endpoint": base, "model": model,
        "response_model": str(payload.get("model", ""))[:200] or None,
        "response_id": str(payload.get("id", ""))[:200] or None,
        "request_id": response.headers.get("x-request-id", "")[:200] or None,
        "request_sha256": hashlib.sha256(encoded_request).hexdigest(),
        "usage": payload.get("usage", {}),
        "open_weight_candidate": "muse-spark-open" in model.lower() or "muse-glimmer" in model.lower(),
        "weights_independently_verified": False,
    }
    return raw, audit
