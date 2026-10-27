"""Validated provider profiles and bounded, auditable single-tool requests."""

import hashlib
import json
import time

from pydantic import SecretStr
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
    if not secret_value(config.meta_api_key).strip() or not config.meta_reasoning_model:
        raise RuntimeError("Configure the inference API key and exact model; no fallback is selected")
    return provider, base, image_limit(config)


def secret_value(value):
    return value.get_secret_value() if isinstance(value, SecretStr) else str(value)


def redacted(value, key):
    """Never persist a credential even if an upstream response happens to echo it."""
    encoded = json.dumps(value, ensure_ascii=False)
    secret = secret_value(key)
    return json.loads(encoded.replace(secret, "[REDACTED]")) if secret else value


class InferenceFailure(RuntimeError):
    def __init__(self, audit):
        super().__init__("Inference request failed; inspect the sanitized provider audit")
        self.audit = audit


def exchange(*, provider, base, key, model, messages, tools, max_tokens, timeout, on_exchange=None, reasoning_effort=None):
    body = {"model": model, "max_tokens": max_tokens, "messages": messages}
    if tools:
        body.update(parallel_tool_calls=False, tool_choice="auto", tools=tools)
    if reasoning_effort:
        body["reasoning_effort"] = reasoning_effort
    encoded = json.dumps(body, sort_keys=True).encode()
    if provider == "baseten" and len(encoded) > BASETEN_MAX_BODY_BYTES:
        raise ValueError("Request exceeds the Baseten media body limit")
    audit = {
        "run_kind": "provider_exchange", "provider": provider, "inference_endpoint": base,
        "model": model, "request_sha256": hashlib.sha256(encoded).hexdigest(),
        "real_network_attempt": True, "simulation": False,
        "open_weight_candidate": "muse-spark-open" in model.lower() or "muse-glimmer" in model.lower(),
        "weights_independently_verified": False,
        "input_image_count": sum(
            item.get("type") == "image_url" for message in messages
            if isinstance(message.get("content"), list) for item in message["content"]
        ),
        "returned_tool_call_ids": [m["tool_call_id"] for m in messages if m.get("role") == "tool"],
    }
    started = time.monotonic()
    try:
        response = httpx.post(
            base + "/chat/completions", headers={"Authorization": "Bearer " + secret_value(key)},
            timeout=timeout, json=body,
        )
        audit.update(http_status=response.status_code, request_id=response.headers.get("x-request-id", "")[:200])
        response.raise_for_status()
        payload = redacted(response.json(), key)
        message = payload["choices"][0]["message"]
        audit.update(
            status="received", response_model=str(payload.get("model", ""))[:200] or None,
            response_id=str(payload.get("id", ""))[:200] or None, usage=payload.get("usage", {}),
            finish_reason=payload["choices"][0].get("finish_reason"), response_message=message,
        )
    except Exception as exc:
        audit.update(status="error", exception_type=type(exc).__name__,
                     duration_ms=round((time.monotonic() - started) * 1000))
        audit = redacted(audit, key)
        if on_exchange:
            on_exchange(audit)
        raise InferenceFailure(audit) from None
    audit["duration_ms"] = round((time.monotonic() - started) * 1000)
    audit = redacted(audit, key)
    if on_exchange:
        on_exchange(audit)
    return message, audit


def function_tool(name, schema, description="Submit one server-validated result."):
    return {"type": "function", "function": {"name": name, "description": description, "parameters": schema}}


def submitted_result(message, tool):
    calls = message.get("tool_calls") or []
    if calls:
        if len(calls) != 1 or calls[0]["function"]["name"] != tool:
            raise ValueError("Unexpected tool or number of calls")
        return calls[0]["function"]["arguments"]
    return message.get("content") or ""


def invoke(*, provider, base, key, model, messages, tool, schema, max_tokens, timeout):
    message, audit = exchange(
        provider=provider, base=base, key=key, model=model, messages=messages,
        tools=[function_tool(tool, schema)], max_tokens=max_tokens, timeout=timeout,
    )
    return submitted_result(message, tool), audit


def invoke_agent(*, provider, base, key, model, messages, tool, schema, max_tokens, timeout,
                 read_tool, handler, on_exchange=None, reasoning_effort="low"):
    """One allowlisted read, one returned result, one final response; no hardware side effects."""
    deadline = time.monotonic() + timeout
    first, first_audit = exchange(
        provider=provider, base=base, key=key, model=model, messages=messages,
        tools=[read_tool], max_tokens=max_tokens, timeout=timeout, on_exchange=on_exchange,
        reasoning_effort=reasoning_effort,
    )
    calls = first.get("tool_calls") or []
    name = read_tool["function"]["name"]
    if len(calls) != 1 or calls[0].get("function", {}).get("name") != name:
        raise ValueError("The provider did not call the authorized observation tool")
    call = calls[0]
    if not isinstance(call.get("id"), str) or not 1 <= len(call["id"]) <= 64:
        raise ValueError("Invalid tool call identifier")
    arguments = json.loads(call["function"]["arguments"])
    if arguments != {}:
        raise ValueError("The observation tool accepts no arguments or session selectors")
    result = redacted(handler(), key)
    execution = {
        "run_kind": "tool_execution", "provider": provider, "model": model, "status": "executed",
        "tool_name": name, "tool_call_id": call["id"], "arguments": arguments, "result": result,
        "result_sha256": hashlib.sha256(json.dumps(result, sort_keys=True).encode()).hexdigest(),
    }
    if on_exchange:
        on_exchange(execution)
    assistant = {"role": "assistant", "content": first.get("content") or "", "tool_calls": calls}
    if first.get("reasoning_content") is not None:
        assistant["reasoning_content"] = first["reasoning_content"]
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Agent inference time budget exhausted")
    final, audit = exchange(
        provider=provider, base=base, key=key, model=model,
        messages=[*messages, assistant, {"role": "tool", "tool_call_id": call["id"],
                                       "content": json.dumps(result, ensure_ascii=False)}],
        tools=[function_tool(tool, schema)], max_tokens=max_tokens, timeout=remaining, on_exchange=on_exchange,
        reasoning_effort=reasoning_effort,
    )
    usage = {name: sum(a.get("usage", {}).get(name, 0) or 0 for a in (first_audit, audit))
             for name in ("prompt_tokens", "completion_tokens", "total_tokens")}
    return submitted_result(final, tool), {
        **audit, "run_kind": "diagnosis", "usage": usage, "exchange_count": 2,
        "exchanges": [first_audit, audit], "tool_executions": [execution],
    }
