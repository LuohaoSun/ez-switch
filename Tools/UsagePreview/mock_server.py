#!/usr/bin/env python3
"""Deterministic loopback upstream mock for the EZSwitch token-usage preview.

This module is the single source of truth for the preview harness:

* the canned provider/model catalogue and the deterministic token counts,
* the route/scenario table used by ``prepare_fixture.py`` to emit ``config.json``
  and by ``verify_usage.py`` to drive and assert the end-to-end run,
* a local ``ThreadingHTTPServer`` that speaks just enough of the three upstream
  protocols (Chat Completions, Responses, Messages) to exercise the router.

Everything binds to 127.0.0.1 and nothing here ever talks to a real provider or
reads real credentials. API keys in the generated config are literal dummies.

Run standalone:

    python3 mock_server.py --port 19008

Extra endpoints for the harness (not part of the emulated upstream API):

    GET  /__health    -> {"ok": true, ...}
    GET  /__requests  -> every request the mock has seen (path/model/stream)
    POST /__reset     -> forget the request log

No third-party dependencies; Python 3 stdlib only.
"""

from __future__ import annotations

import argparse
import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional, Tuple

HOST = "127.0.0.1"
DEFAULT_PORT = 19008

# Fixed creation timestamp so response bodies are byte-stable between runs.
CREATED = 1_700_000_000

# Per-event delay (seconds) so streaming is observable and cancellable.
STREAM_DELAY = 0.005

PROVIDER_A = "演示供应商 A"
PROVIDER_B = "演示供应商 B"

# ---------------------------------------------------------------------------
# Deterministic upstream payloads
# ---------------------------------------------------------------------------
#
# Keyed by the *remote model id* (what the router rewrites the request to).
# Each entry carries distinct ``nonstream``/``stream`` token counts so a DB row
# can be traced back to exactly one scenario. ``None`` means "omit usage" and is
# what the "usage missing" scenarios rely on.

ChatUsage = Tuple[int, int]  # (prompt_tokens, completion_tokens)

CHAT_MODELS: Dict[str, Dict[str, Optional[ChatUsage]]] = {
    "demo-chat-usage": {"nonstream": (11, 7), "stream": (13, 5)},
    "demo-chat-nousage": {"nonstream": None, "stream": None},
    "demo-resp-convert": {"nonstream": (31, 3), "stream": (37, 2)},
    "demo-resp-convert-nousage": {"nonstream": None, "stream": None},
}

RESPONSES_MODELS: Dict[str, Dict[str, ChatUsage]] = {
    "demo-responses-native": {"nonstream": (17, 9), "stream": (19, 6)},
}

# Anthropic usage also carries optional cache fields for the opt-in cache route.
ANTHROPIC_MODELS: Dict[str, Dict[str, Dict[str, Any]]] = {
    "demo-anthropic": {
        "nonstream": {"input_tokens": 23, "output_tokens": 8},
        "stream": {"input_tokens": 29, "output_tokens": 4},
    },
    # Opt-in (--include-cache). Per docs/token-usage.md the extractor must fold
    # cache read + cache write into total input and keep them as sub-fields.
    "demo-anthropic-cache": {
        "nonstream": {
            "input_tokens": 5,
            "output_tokens": 8,
            "cache_read_input_tokens": 3,
            "cache_creation_input_tokens": 2,
        },
    },
}

# The first fallback candidate always fails with 429 and an explicit usage body,
# so failure-attempt token accounting is observable. The second is healthy.
FAIL_MODEL = "demo-fail-429"
FAIL_USAGE: ChatUsage = (41, 43)
FAIL_STATUS = 429

# Remote catalogue: provider name + which protocol endpoints are enabled.
REMOTE_SPECS: Dict[str, Dict[str, Any]] = {
    "demo-chat-usage": {"provider": PROVIDER_A, "kinds": ["chat"]},
    "demo-chat-nousage": {"provider": PROVIDER_A, "kinds": ["chat"]},
    "demo-responses-native": {"provider": PROVIDER_A, "kinds": ["responses"]},
    FAIL_MODEL: {"provider": PROVIDER_A, "kinds": ["chat"]},
    "demo-anthropic": {"provider": PROVIDER_B, "kinds": ["messages"]},
    "demo-resp-convert": {"provider": PROVIDER_B, "kinds": ["chat"], "transport": "chatCompletions"},
    "demo-resp-convert-nousage": {"provider": PROVIDER_B, "kinds": ["chat"], "transport": "chatCompletions"},
    "demo-anthropic-cache": {"provider": PROVIDER_B, "kinds": ["messages"], "optional": True},
}

# ---------------------------------------------------------------------------
# Route / scenario table
# ---------------------------------------------------------------------------
#
# ``inbound``   : client-facing endpoint the harness calls on the preview.
# ``client_kind``: which parser to use on the preview's response.
# ``expect_client``: token values the preview must surface to the client
#                    (``None`` = usage must be absent/not-real).
# ``expect_attempts``: one dict per recorded upstream attempt
#                      (``input``/``output`` = None means "must stay unknown").
#
# Scenarios marked ``optional`` only materialise with --include-cache.

SCENARIOS: List[Dict[str, Any]] = [
    {
        "id": "chat-plain",
        "route": "usage-chat-plain",
        "remote": "demo-chat-usage",
        "inbound": "chat",
        "client_kind": "chat",
        "stream": False,
        "expect_client": (11, 7),
        "expect_attempts": [{"status": 200, "input": 11, "output": 7}],
    },
    {
        "id": "chat-stream",
        "route": "usage-chat-stream",
        "remote": "demo-chat-usage",
        "inbound": "chat",
        "client_kind": "chat",
        "stream": True,
        "expect_client": (13, 5),
        "expect_attempts": [{"status": 200, "input": 13, "output": 5}],
    },
    {
        "id": "chat-nousage",
        "route": "usage-chat-nousage",
        "remote": "demo-chat-nousage",
        "inbound": "chat",
        "client_kind": "chat",
        "stream": False,
        "expect_client": None,
        "expect_attempts": [{"status": 200, "input": None, "output": None}],
    },
    {
        "id": "responses-native",
        "route": "usage-responses-native",
        "remote": "demo-responses-native",
        "inbound": "responses",
        "client_kind": "responses",
        "stream": False,
        "expect_client": (17, 9),
        "expect_attempts": [{"status": 200, "input": 17, "output": 9}],
    },
    {
        "id": "responses-native-stream",
        "route": "usage-responses-stream",
        "remote": "demo-responses-native",
        "inbound": "responses",
        "client_kind": "responses",
        "stream": True,
        "expect_client": (19, 6),
        "expect_attempts": [{"status": 200, "input": 19, "output": 6}],
    },
    {
        "id": "anthropic",
        "route": "usage-anthropic",
        "remote": "demo-anthropic",
        "inbound": "messages",
        "client_kind": "anthropic",
        "stream": False,
        "expect_client": (23, 8),
        "expect_attempts": [{"status": 200, "input": 23, "output": 8}],
    },
    {
        "id": "anthropic-stream",
        "route": "usage-anthropic-stream",
        "remote": "demo-anthropic",
        "inbound": "messages",
        "client_kind": "anthropic",
        "stream": True,
        "expect_client": (29, 4),
        "expect_attempts": [{"status": 200, "input": 29, "output": 4}],
    },
    {
        "id": "convert-plain",
        "route": "usage-convert-plain",
        "remote": "demo-resp-convert",
        "inbound": "responses",
        "client_kind": "responses",
        "stream": False,
        "expect_client": (31, 3),
        "expect_attempts": [{"status": 200, "input": 31, "output": 3}],
    },
    {
        "id": "convert-stream",
        "route": "usage-convert-stream",
        "remote": "demo-resp-convert",
        "inbound": "responses",
        "client_kind": "responses",
        "stream": True,
        "expect_client": (37, 2),
        "expect_attempts": [{"status": 200, "input": 37, "output": 2}],
    },
    {
        "id": "convert-nousage",
        "route": "usage-convert-nousage",
        "remote": "demo-resp-convert-nousage",
        "inbound": "responses",
        "client_kind": "responses",
        "stream": False,
        "expect_client": None,
        "expect_attempts": [{"status": 200, "input": None, "output": None}],
    },
    {
        # The bridge may synthesise zero usage when converting a Chat stream
        # that carried none; the recorder must keep the attempt unknown.
        "id": "convert-stream-nousage",
        "route": "usage-convert-stream-nousage",
        "remote": "demo-resp-convert-nousage",
        "inbound": "responses",
        "client_kind": "responses",
        "stream": True,
        "expect_client": None,
        "expect_attempts": [{"status": 200, "input": None, "output": None}],
    },
    {
        "id": "fallback-429",
        "route": "usage-fallback-429",
        "remote": FAIL_MODEL,
        "fallback": ["demo-chat-usage"],
        "inbound": "chat",
        "client_kind": "chat",
        "stream": False,
        "expect_client": (11, 7),
        "expect_attempts": [
            {"status": FAIL_STATUS, "input": FAIL_USAGE[0], "output": FAIL_USAGE[1],
             "model": FAIL_MODEL},
            {"status": 200, "input": 11, "output": 7, "model": "demo-chat-usage"},
        ],
    },
    {
        "id": "anthropic-cache",
        "route": "usage-anthropic-cache",
        "remote": "demo-anthropic-cache",
        "inbound": "messages",
        "client_kind": "anthropic",
        "stream": False,
        "optional": True,
        "expect_client": (10, 8),  # 5 ordinary + 3 cache read + 2 cache write
        "expect_cache": {"cached": 3, "cache_write": 2},
        "expect_attempts": [{"status": 200, "input": 10, "output": 8}],
    },
]

# Inbound endpoint -> upstream path appended to the remote's Base URL.
INBOUND_PATH = {
    "chat": "/v1/chat/completions",
    "responses": "/v1/responses",
    "messages": "/v1/messages",
}


def scenarios(include_cache: bool = False) -> List[Dict[str, Any]]:
    """Return the active scenario list (cache scenarios are opt-in)."""
    return [s for s in SCENARIOS if include_cache or not s.get("optional")]


def active_remotes(include_cache: bool = False) -> List[str]:
    """Remote model ids referenced by the active scenarios, in a stable order."""
    order: List[str] = []
    for spec in scenarios(include_cache):
        for model in [spec["remote"], *spec.get("fallback", [])]:
            if model not in order:
                order.append(model)
    return order


# ---------------------------------------------------------------------------
# Expected totals (for the parent's GUI comparison)
# ---------------------------------------------------------------------------


def expected_totals(include_cache: bool = False) -> Dict[str, int]:
    """Sum up what the usage page should show after a full harness run."""
    attempts = known = unknown = failed = 0
    input_sum = output_sum = 0
    for spec in scenarios(include_cache):
        for attempt in spec["expect_attempts"]:
            attempts += 1
            status = attempt.get("status")
            if status is None or not (200 <= status < 300):
                failed += 1
            if attempt["input"] is not None and attempt["output"] is not None:
                known += 1
                input_sum += attempt["input"]
                output_sum += attempt["output"]
            else:
                unknown += 1
    return {
        "requests": len(scenarios(include_cache)),
        "attempts": attempts,
        "known_attempts": known,
        "unknown_attempts": unknown,
        "failed_attempts": failed,
        "input_sum": input_sum,
        "output_sum": output_sum,
        "total_sum": input_sum + output_sum,
    }


# ---------------------------------------------------------------------------
# config.json generation (mirrors Sources/EZSwitch/Config.swift)
# ---------------------------------------------------------------------------


def _endpoint(enabled: bool, base_url: str) -> Dict[str, Any]:
    return {"enabled": enabled, "baseURL": base_url}


def _base_urls(mock_port: int, kinds: List[str]) -> Dict[str, str]:
    root = f"http://{HOST}:{mock_port}"
    return {
        "chat": f"{root}/v1",
        "responses": f"{root}/v1",
        "messages": root,
    }


def build_config(preview_port: int = 19007, mock_port: int = DEFAULT_PORT,
                 include_cache: bool = False) -> Dict[str, Any]:
    """Build an AppConfig dict that decodes with the real Config.swift schema.

    Base URLs are the full prefixes the router appends ``upstreamPath`` to, so
    Chat/Responses use ``.../v1`` and Messages uses ``...`` (its path already
    contains ``/v1``). API keys are literal dummies.
    """
    import uuid

    remotes: List[Dict[str, Any]] = []
    model_to_uuid: Dict[str, str] = {}

    for model in active_remotes(include_cache):
        spec = REMOTE_SPECS[model]
        kinds = spec["kinds"]
        urls = _base_urls(mock_port, kinds)
        transport = spec.get("transport", "native")
        # For the Chat-transport bridge the Responses endpoint is served by the
        # Chat Base URL, so Config.validateEndpoints requires chat enabled only.
        remotes.append({
            "id": str(uuid.uuid4()),
            "name": f"{spec['provider']} · {model}",
            "apiKey": f"demo-key-{model}",
            "model": model,
            "extraHeaders": {},
            "apiEndpoints": {
                "chat": _endpoint("chat" in kinds, urls["chat"]),
                "responses": _endpoint("responses" in kinds, urls["responses"]),
                "messages": _endpoint("messages" in kinds, urls["messages"]),
                "responsesTransport": transport,
            },
        })
        model_to_uuid[model] = remotes[-1]["id"]

    fakes: List[Dict[str, Any]] = []
    for scenario in scenarios(include_cache):
        fallback = scenario.get("fallback", [])
        fakes.append({
            "id": str(uuid.uuid4()),
            "fakeModelID": scenario["route"],
            "displayName": scenario["route"],
            "remoteID": model_to_uuid[scenario["remote"]],
            "fallbackRemoteIDs": [model_to_uuid[m] for m in fallback],
            "autoFallback": True,
        })

    return {"port": preview_port, "remotes": remotes, "fakes": fakes}


# ---------------------------------------------------------------------------
# Mock HTTP server
# ---------------------------------------------------------------------------


class MockState:
    """Thread-safe request log."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._requests: List[Dict[str, Any]] = []

    def add(self, record: Dict[str, Any]) -> None:
        with self._lock:
            self._requests.append(record)

    def snapshot(self) -> List[Dict[str, Any]]:
        with self._lock:
            return list(self._requests)

    def reset(self) -> None:
        with self._lock:
            self._requests.clear()


def _sse_event(name: Optional[str], payload: Dict[str, Any]) -> bytes:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    prefix = f"event: {name}\n" if name else ""
    return f"{prefix}data: {body}\n\n".encode("utf-8")


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "EZSwitchUsageMock/1.0"

    state: MockState  # injected on the server instance
    on_request = None  # optional callback(record)

    def log_message(self, fmt: str, *args: Any) -> None:  # keep stderr quiet
        return

    # -- plumbing ---------------------------------------------------------

    def _read_json(self) -> Dict[str, Any]:
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            return {}
        return parsed if isinstance(parsed, dict) else {}

    def _send_json(self, status: int, obj: Dict[str, Any]) -> None:
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except BrokenPipeError:
            pass

    def _start_sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

    def _write_sse(self, block: bytes) -> bool:
        """Write one chunked SSE block; False if the client went away."""
        frame = f"{len(block):X}\r\n".encode("ascii") + block + b"\r\n"
        try:
            self.wfile.write(frame)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return False
        time.sleep(STREAM_DELAY)
        return True

    def _end_sse(self) -> None:
        try:
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    # -- harness endpoints ------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        if self.path == "/__health":
            self._send_json(200, {"ok": True, "service": "usage-preview-mock"})
        elif self.path == "/__requests":
            self._send_json(200, {"requests": self.state.snapshot()})
        else:
            self._send_json(404, {"error": {"message": f"no route for {self.path}"}})

    def do_POST(self) -> None:  # noqa: N802 (http.server API)
        if self.path == "/__reset":
            self.state.reset()
            self._send_json(200, {"ok": True})
            return

        body = self._read_json()
        model = body.get("model")
        stream = bool(body.get("stream"))
        record = {
            "time": time.time(),
            "path": self.path,
            "model": model,
            "stream": stream,
        }
        self.state.add(record)
        if self.on_request:
            self.on_request(record)

        try:
            self._dispatch(model, stream)
        except (BrokenPipeError, ConnectionResetError):
            # Client cancelled mid-stream; that is an expected outcome.
            pass

    # -- upstream emulation ----------------------------------------------

    def _dispatch(self, model: Optional[str], stream: bool) -> None:
        if model == FAIL_MODEL:
            self._send_json(FAIL_STATUS, {
                "error": {"message": "demo rate limit (harness)", "type": "rate_limit_error"},
                # Explicit usage on the failure body: the recorder must count it.
                "usage": {
                    "prompt_tokens": FAIL_USAGE[0],
                    "completion_tokens": FAIL_USAGE[1],
                    "total_tokens": FAIL_USAGE[0] + FAIL_USAGE[1],
                },
            })
            return

        if self.path.endswith("/chat/completions"):
            self._chat(model, stream)
        elif self.path.endswith("/responses"):
            self._responses(model, stream)
        elif self.path.endswith("/messages"):
            self._anthropic(model, stream)
        else:
            self._send_json(404, {"error": {"message": f"unsupported path {self.path}"}})

    # -- Chat Completions -------------------------------------------------

    def _chat(self, model: Optional[str], stream: bool) -> None:
        spec = CHAT_MODELS.get(model or "")
        if spec is None:
            self._send_json(404, {"error": {"message": f"unknown chat model {model}"}})
            return
        usage = spec["stream" if stream else "nonstream"]
        response_id = f"chatcmpl-demo-{(model or 'x')}"
        if not stream:
            payload: Dict[str, Any] = {
                "id": response_id,
                "object": "chat.completion",
                "created": CREATED,
                "model": model,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": "demo response"},
                    "finish_reason": "stop",
                }],
            }
            if usage:
                payload["usage"] = {
                    "prompt_tokens": usage[0],
                    "completion_tokens": usage[1],
                    "total_tokens": usage[0] + usage[1],
                }
            self._send_json(200, payload)
            return

        self._start_sse()

        def chunk(delta: Dict[str, Any], finish: Optional[str] = None,
                  usage_obj: Optional[Dict[str, Any]] = None,
                  choices_empty: bool = False) -> Dict[str, Any]:
            obj: Dict[str, Any] = {
                "id": response_id,
                "object": "chat.completion.chunk",
                "created": CREATED,
                "model": model,
                "choices": [] if choices_empty else [
                    {"index": 0, "delta": delta, "finish_reason": finish}
                ],
            }
            if usage_obj:
                obj["usage"] = usage_obj
            return obj

        events = [
            chunk({"role": "assistant", "content": ""}),
            chunk({"content": "demo "}),
            chunk({"content": "stream"}),
            chunk({}, finish="stop"),
        ]
        # Chat streams carry usage only on the final chunk (after the stop one).
        if usage:
            events.append(chunk({}, usage_obj={
                "prompt_tokens": usage[0],
                "completion_tokens": usage[1],
                "total_tokens": usage[0] + usage[1],
            }, choices_empty=True))
        for event in events:
            if not self._write_sse(_sse_event(None, event)):
                return
        self._write_sse(b"data: [DONE]\n\n")
        self._end_sse()

    # -- Responses (native) ----------------------------------------------

    def _responses(self, model: Optional[str], stream: bool) -> None:
        spec = RESPONSES_MODELS.get(model or "")
        if spec is None:
            self._send_json(404, {"error": {"message": f"unknown responses model {model}"}})
            return
        usage = spec["stream" if stream else "nonstream"]
        response_id = f"resp_demo_{(model or 'x')}"
        output = [{
            "id": f"msg_{response_id}",
            "type": "message",
            "role": "assistant",
            "status": "completed",
            "content": [{"type": "output_text", "text": "demo responses", "annotations": []}],
        }]
        usage_obj = {
            "input_tokens": usage[0],
            "output_tokens": usage[1],
            "total_tokens": usage[0] + usage[1],
        }

        if not stream:
            self._send_json(200, {
                "id": response_id,
                "object": "response",
                "created_at": CREATED,
                "status": "completed",
                "model": model,
                "output": output,
                "usage": usage_obj,
            })
            return

        self._start_sse()
        item_id = f"msg_{response_id}"

        def emit(name: str, payload: Dict[str, Any]) -> bool:
            return self._write_sse(_sse_event(name, payload))

        base_response = {"id": response_id, "object": "response", "model": model}
        stream_events: List[Tuple[str, Dict[str, Any]]] = [
            ("response.created", {"type": "response.created",
                                  "response": {**base_response, "status": "in_progress"}}),
            ("response.output_item.added", {
                "type": "response.output_item.added", "output_index": 0,
                "item": {"id": item_id, "type": "message", "role": "assistant",
                         "status": "in_progress", "content": []},
            }),
            ("response.content_part.added", {
                "type": "response.content_part.added", "item_id": item_id,
                "output_index": 0, "content_index": 0,
                "part": {"type": "output_text", "text": "", "annotations": []},
            }),
            ("response.output_text.delta", {
                "type": "response.output_text.delta", "item_id": item_id,
                "output_index": 0, "content_index": 0, "delta": "demo ",
            }),
            ("response.output_text.delta", {
                "type": "response.output_text.delta", "item_id": item_id,
                "output_index": 0, "content_index": 0, "delta": "stream",
            }),
            ("response.output_text.done", {
                "type": "response.output_text.done", "item_id": item_id,
                "output_index": 0, "content_index": 0, "text": "demo stream",
            }),
            ("response.content_part.done", {
                "type": "response.content_part.done", "item_id": item_id,
                "output_index": 0, "content_index": 0,
                "part": {"type": "output_text", "text": "demo stream", "annotations": []},
            }),
            ("response.output_item.done", {
                "type": "response.output_item.done", "output_index": 0, "item": output[0],
            }),
            ("response.completed", {
                "type": "response.completed",
                "response": {**base_response, "status": "completed",
                             "output": output, "usage": usage_obj},
            }),
        ]
        for name, payload in stream_events:
            if not emit(name, payload):
                return
        self._end_sse()

    # -- Anthropic Messages ----------------------------------------------

    def _anthropic(self, model: Optional[str], stream: bool) -> None:
        spec = ANTHROPIC_MODELS.get(model or "")
        if spec is None:
            self._send_json(404, {"error": {"message": f"unknown messages model {model}"}})
            return
        usage = spec["stream" if stream else "nonstream"]
        message_id = f"msg_demo_{(model or 'x')}"

        if not stream:
            self._send_json(200, {
                "id": message_id,
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [{"type": "text", "text": "demo anthropic"}],
                "stop_reason": "end_turn",
                "stop_sequence": None,
                "usage": usage,
            })
            return

        self._start_sse()

        def emit(name: str, payload: Dict[str, Any]) -> bool:
            return self._write_sse(_sse_event(name, payload))

        start_usage = {"input_tokens": usage["input_tokens"], "output_tokens": 1}
        events: List[Tuple[str, Dict[str, Any]]] = [
            ("message_start", {
                "type": "message_start",
                "message": {"id": message_id, "type": "message", "role": "assistant",
                            "model": model, "content": [], "stop_reason": None,
                            "stop_sequence": None, "usage": start_usage},
            }),
            ("content_block_start", {
                "type": "content_block_start", "index": 0,
                "content_block": {"type": "text", "text": ""},
            }),
            ("content_block_delta", {
                "type": "content_block_delta", "index": 0,
                "delta": {"type": "text_delta", "text": "demo "},
            }),
            ("content_block_delta", {
                "type": "content_block_delta", "index": 0,
                "delta": {"type": "text_delta", "text": "stream"},
            }),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            # Cumulative output tokens: the recorder keeps the latest value.
            ("message_delta", {
                "type": "message_delta",
                "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                "usage": {"output_tokens": usage["output_tokens"]},
            }),
            ("message_stop", {"type": "message_stop"}),
        ]
        for name, payload in events:
            if not emit(name, payload):
                return
        self._end_sse()


class MockServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr: Tuple[str, int]) -> None:
        super().__init__(addr, _Handler)
        self.state = MockState()
        _Handler.state = self.state


def port_in_use(host: str, port: int) -> bool:
    """True if something is already listening (connect probe; never kills)."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        return sock.connect_ex((host, port)) == 0


def start_mock(port: int = DEFAULT_PORT, host: str = HOST) -> Tuple[MockServer, threading.Thread]:
    """Start the mock on a background thread. Raises OSError if the port is busy."""
    server = MockServer((host, port))
    thread = threading.Thread(target=server.serve_forever, name="usage-mock", daemon=True)
    thread.start()
    return server, thread


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Loopback upstream mock for the EZSwitch usage preview.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Serves /v1/chat/completions, /v1/responses and /v1/messages with "
               "deterministic token counts, plus /__health, /__requests and /__reset.",
    )
    parser.add_argument("--host", default=HOST, help=f"bind address (default {HOST})")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help=f"bind port (default {DEFAULT_PORT})")
    parser.add_argument("--include-cache", action="store_true",
                        help="also expose the optional Anthropic cache-usage model")
    args = parser.parse_args()

    if port_in_use(args.host, args.port):
        print(f"error: {args.host}:{args.port} is already in use (not killing it)", flush=True)
        return 1

    server, _ = start_mock(args.port, args.host)
    totals = expected_totals(args.include_cache)
    print(f"mock listening on http://{args.host}:{args.port}", flush=True)
    print(f"routes: {len(scenarios(args.include_cache))}  "
          f"attempts={totals['attempts']} known={totals['known_attempts']} "
          f"unknown={totals['unknown_attempts']} input={totals['input_sum']} "
          f"output={totals['output_sum']}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nmock stopped", flush=True)
    finally:
        server.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
