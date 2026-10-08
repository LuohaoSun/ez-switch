#!/usr/bin/env python3
"""End-to-end verifier for the EZSwitch token-usage preview.

It exercises the preview router over HTTP against the loopback mock, then (when
a database path is reachable) asserts that the ``usage_records`` rows really
match what the mock returned. Nothing is seeded behind the assertions: the DB is
only ever read. A separate, explicitly requested ``seed-demo-history`` command
exists to paint a labelled synthetic chart, and it is never part of a test run.

Subcommands
-----------

    plan       Port checks + fixture validation + mock conformance self-test.
               No preview app required. This is the command that works today.
    exercise   Send every scenario through the running preview and validate the
               client-facing usage. Starts/stops its own mock unless --no-mock.
    db         Inspect the preview's usage.sqlite and assert recorded attempts.
    full       exercise + db in one run (the canonical end-to-end command).
    seed-demo-history
               OPT-IN ONLY. Insert clearly labelled synthetic rows for previous
               days so the preview chart has data. Never used by the tests.

Examples
--------

    # Works right now, without building the app:
    python3 verify_usage.py plan

    # After the parent starts the preview (port 19007) and the mock (19008):
    python3 verify_usage.py full \
        --config /tmp/ezswitch-usage-preview/config.json \
        --db /tmp/ezswitch-usage-preview/usage.sqlite

    # Only the SQLite side (schema dump + assertions):
    python3 verify_usage.py db --db /tmp/ezswitch-usage-preview/usage.sqlite

Exit code is non-zero if any strict assertion fails.
"""

from __future__ import annotations

import argparse
import http.client
import json
import sqlite3
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))

import mock_server  # noqa: E402  (local sibling module)

DEFAULT_CONFIG = "/tmp/ezswitch-usage-preview/config.json"
DEFAULT_PREVIEW_PORT = 19007
DEFAULT_HOST = "127.0.0.1"

CHAT_MODELS = set(mock_server.CHAT_MODELS)
RESPONSES_MODELS = set(mock_server.RESPONSES_MODELS)
ANTHROPIC_MODELS = set(mock_server.ANTHROPIC_MODELS)
UPSTREAM_PATH = {
    "chat": "/v1/chat/completions",
    "responses": "/v1/responses",
    "messages": "/v1/messages",
}


# ---------------------------------------------------------------------------
# Small reporting helpers
# ---------------------------------------------------------------------------


class Report:
    def __init__(self) -> None:
        self.failures: List[str] = []
        self.warnings: List[str] = []

    def fail(self, message: str) -> None:
        self.failures.append(message)
        print(f"  FAIL  {message}")

    def warn(self, message: str) -> None:
        self.warnings.append(message)
        print(f"  WARN  {message}")

    def ok(self, message: str) -> None:
        print(f"  ok    {message}")


def family_of(model: str) -> str:
    if model in CHAT_MODELS:
        return "chat"
    if model in RESPONSES_MODELS:
        return "responses"
    if model in ANTHROPIC_MODELS:
        return "messages"
    if model == mock_server.FAIL_MODEL:
        return "chat"
    raise KeyError(f"unknown remote model {model!r}")


# ---------------------------------------------------------------------------
# Fixture loading
# ---------------------------------------------------------------------------


def load_active_scenarios(config_path: Path) -> List[Dict[str, Any]]:
    """Active scenarios, enriched with the fixture UUIDs and names.

    The recorder stores ``route_id`` = the fake's UUID and ``route_name`` = the
    fake model id (see UsageStore), so both are carried here for strict checks.
    """
    config = json.loads(config_path.read_text(encoding="utf-8"))
    if "port" not in config or "remotes" not in config or "fakes" not in config:
        raise SystemExit(f"{config_path} does not look like an EZSwitch config")

    remote_by_id = {r["id"]: r for r in config["remotes"]}
    fake_by_route = {f["fakeModelID"]: f for f in config["fakes"]}

    active: List[Dict[str, Any]] = []
    for scenario in mock_server.SCENARIOS:
        fake = fake_by_route.get(scenario["route"])
        if fake is None:
            continue
        remote = remote_by_id.get(fake["remoteID"])
        if remote is None:
            continue
        spec = dict(scenario)
        spec["route_uuid"] = fake["id"]
        spec["expected_model"] = remote["model"]
        spec["expected_provider"] = str(remote["name"]).split(" · ")[0]
        active.append(spec)
    if not active:
        raise SystemExit("no usage-* routes found in the fixture; re-run prepare_fixture.py")
    return active


def totals_from_scenarios(active: Sequence[Dict[str, Any]]) -> Dict[str, int]:
    attempts = known = unknown = failed = 0
    input_sum = output_sum = 0
    for spec in active:
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
        "requests": len(active),
        "attempts": attempts,
        "known_attempts": known,
        "unknown_attempts": unknown,
        "failed_attempts": failed,
        "input_sum": input_sum,
        "output_sum": output_sum,
        "total_sum": input_sum + output_sum,
    }


# ---------------------------------------------------------------------------
# HTTP client
# ---------------------------------------------------------------------------


def request_body(spec: Dict[str, Any]) -> Dict[str, Any]:
    body: Dict[str, Any] = {"model": spec["route"]}
    if spec["stream"]:
        body["stream"] = True
    if spec["inbound"] == "messages":
        body["max_tokens"] = 64
        body["messages"] = [{"role": "user", "content": "hello"}]
    elif spec["inbound"] == "responses":
        body["input"] = "hello"
    else:
        body["messages"] = [{"role": "user", "content": "hello"}]
    return body


def post(host: str, port: int, path: str, payload: Dict[str, Any],
         timeout: float, stream: bool) -> Tuple[http.client.HTTPConnection,
                                                http.client.HTTPResponse]:
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    conn.request(
        "POST", path,
        body=json.dumps(payload).encode("utf-8"),
        headers={
            "content-type": "application/json",
            "accept": "text/event-stream" if stream else "application/json",
        },
    )
    return conn, conn.getresponse()


def read_full(resp: http.client.HTTPResponse) -> bytes:
    chunks: List[bytes] = []
    while True:
        chunk = resp.read(4096)
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


def parse_sse(raw: bytes) -> List[Dict[str, Any]]:
    """Parse ``data:`` payloads out of an SSE byte stream."""
    text = raw.decode("utf-8", "replace")
    events: List[Dict[str, Any]] = []
    for block in text.replace("\r\n", "\n").split("\n\n"):
        data_lines = []
        for line in block.split("\n"):
            if line.startswith("data:"):
                data_lines.append(line[5:].lstrip(" "))
        if not data_lines:
            continue
        payload = "\n".join(data_lines).strip()
        if payload in ("", "[DONE]"):
            continue
        try:
            obj = json.loads(payload)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            events.append(obj)
    return events


def usage_from_events(kind: str, events: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    """Extract upstream usage the way the recorder should: latest valid value."""
    present = False
    raw: Optional[Dict[str, Any]] = None
    inp: Optional[int] = None
    out: Optional[int] = None
    for obj in events:
        usage = None
        if kind == "responses":
            response = obj.get("response")
            if isinstance(response, dict) and isinstance(response.get("usage"), dict):
                usage = response["usage"]
            elif isinstance(obj.get("usage"), dict):
                usage = obj["usage"]
        elif isinstance(obj.get("usage"), dict):
            usage = obj["usage"]
        else:
            # Anthropic message_start nests usage under message.usage.
            message = obj.get("message")
            if isinstance(message, dict) and isinstance(message.get("usage"), dict):
                usage = message["usage"]
        if not isinstance(usage, dict):
            continue
        present = True
        raw = usage
        for key in ("prompt_tokens", "input_tokens"):
            if usage.get(key) is not None:
                inp = usage[key]
        for key in ("completion_tokens", "output_tokens"):
            if usage.get(key) is not None:
                out = usage[key]
    return {"present": present, "input": inp, "output": out, "raw": raw}


def client_usage(spec: Dict[str, Any], status: int, content_type: str,
                 raw: bytes) -> Dict[str, Any]:
    kind = spec["client_kind"]
    if spec["stream"] or "text/event-stream" in content_type.lower():
        return usage_from_events(kind, parse_sse(raw))
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        return {"present": False, "input": None, "output": None, "raw": None}
    return usage_from_events(kind, [obj] if isinstance(obj, dict) else [])


def check_client_usage(report: Report, spec: Dict[str, Any], status: int,
                       usage: Dict[str, Any]) -> None:
    expected = spec["expect_client"]
    ident = spec["id"]
    if not (200 <= status < 300):
        report.fail(f"{ident}: preview returned HTTP {status}")
        return
    if expected is None:
        if usage["present"] and (usage["input"] or usage["output"]):
            report.fail(f"{ident}: expected unknown usage but got "
                        f"input={usage['input']} output={usage['output']}")
        elif usage["present"]:
            report.ok(f"{ident}: usage reported as zeros ({usage['raw']}); "
                      f"recorder must keep it unknown")
        else:
            report.ok(f"{ident}: usage absent as expected")
        return
    if (usage["input"], usage["output"]) != expected:
        report.fail(f"{ident}: expected client usage {expected} but got "
                    f"({usage['input']}, {usage['output']}) raw={usage['raw']}")
    else:
        report.ok(f"{ident}: client usage {usage['input']}/{usage['output']}")


# ---------------------------------------------------------------------------
# Mock conformance (works without the app)
# ---------------------------------------------------------------------------


def cmd_plan(args: argparse.Namespace) -> int:
    report = Report()
    active = load_active_scenarios(Path(args.config))
    print(f"fixture: {args.config}")
    print(f"routes: {len(active)}")

    print("\nport checks")
    for label, port in (("preview", args.preview_port), ("mock", args.mock_port)):
        if mock_server.port_in_use(DEFAULT_HOST, port):
            report.warn(f"{label} port {port} is already in use (not killed)")
        else:
            report.ok(f"{label} port {port} is free")

    started = None
    if mock_server.port_in_use(DEFAULT_HOST, args.mock_port):
        report.warn("using the already-running mock on the mock port")
    else:
        started, _ = mock_server.start_mock(args.mock_port)
        report.ok(f"mock started on {DEFAULT_HOST}:{args.mock_port}")

    try:
        print("\nmock conformance (direct, no preview)")
        for spec in active:
            _conformance_one(report, spec, args.mock_port)

        print("\nexpected totals for the usage page")
        totals = totals_from_scenarios(active)
        print(f"  requests={totals['requests']} attempts={totals['attempts']} "
              f"known={totals['known_attempts']} unknown={totals['unknown_attempts']} "
              f"failed={totals['failed_attempts']}")
        print(f"  input_sum={totals['input_sum']} output_sum={totals['output_sum']} "
              f"total_sum={totals['total_sum']}")
    finally:
        if started is not None:
            started.shutdown()

    return _finish(report, args)


def _mock_post(model: str, stream: bool, mock_port: int) -> Tuple[int, bytes, str]:
    path = UPSTREAM_PATH[family_of(model)]
    body = {"model": model}
    if stream:
        body["stream"] = True
    conn, resp = post(DEFAULT_HOST, mock_port, path, body, timeout=10.0, stream=stream)
    raw = read_full(resp)
    ctype = resp.getheader("content-type") or ""
    status = resp.status
    conn.close()
    return status, raw, ctype


def _conformance_one(report: Report, spec: Dict[str, Any], mock_port: int) -> None:
    ident = spec["id"]
    model = spec["remote"]
    kind = family_of(model)
    expected = spec["expect_client"]

    if model == mock_server.FAIL_MODEL:
        status, raw, _ = _mock_post(model, False, mock_port)
        if status != mock_server.FAIL_STATUS:
            report.fail(f"{ident}: failure attempt expected {mock_server.FAIL_STATUS}, got {status}")
            return
        obj = json.loads(raw)
        usage = obj.get("usage") or {}
        if (usage.get("prompt_tokens"), usage.get("completion_tokens")) != mock_server.FAIL_USAGE:
            report.fail(f"{ident}: 429 body usage {usage} != {mock_server.FAIL_USAGE}")
        else:
            report.ok(f"{ident}: 429 body carries usage {mock_server.FAIL_USAGE}")
        # Also confirm the healthy fallback target itself.
        status, raw, _ = _mock_post("demo-chat-usage", False, mock_port)
        usage = json.loads(raw).get("usage") or {}
        if (usage.get("prompt_tokens"), usage.get("completion_tokens")) != (11, 7):
            report.fail(f"{ident}: fallback target usage {usage} != (11, 7)")
        else:
            report.ok(f"{ident}: fallback target healthy with usage 11/7")
        return

    status, raw, ctype = _mock_post(model, spec["stream"], mock_port)
    if status != 200:
        report.fail(f"{ident}: mock returned {status}")
        return
    usage = usage_from_events(kind, parse_sse(raw)) if spec["stream"] else \
        usage_from_events(kind, [json.loads(raw)])
    if expected is None:
        if usage["present"] and (usage["input"] or usage["output"]):
            report.fail(f"{ident}: mock emitted unexpected usage {usage['raw']}")
        else:
            report.ok(f"{ident}: mock omits usage (unknown case)")
        return
    if (usage["input"], usage["output"]) != expected:
        report.fail(f"{ident}: mock usage ({usage['input']}, {usage['output']}) != {expected}")
    else:
        report.ok(f"{ident}: mock usage {usage['input']}/{usage['output']}"
                  f"{' (stream)' if spec['stream'] else ''}")
    if spec["stream"]:
        _check_terminator(report, ident, kind, raw)


def _check_terminator(report: Report, ident: str, kind: str, raw: bytes) -> None:
    if kind == "chat" and b"[DONE]" not in raw:
        report.fail(f"{ident}: chat stream missing [DONE] terminator")
    if kind == "responses":
        events = parse_sse(raw)
        if not any(e.get("type") == "response.completed" for e in events):
            report.fail(f"{ident}: responses stream missing response.completed")
    if kind == "messages" and b"message_stop" not in raw:
        report.fail(f"{ident}: messages stream missing message_stop")


# ---------------------------------------------------------------------------
# Exercise through the preview
# ---------------------------------------------------------------------------


def cmd_exercise(args: argparse.Namespace, watermark: Optional[float] = None) -> Dict[str, Any]:
    report = Report()
    active = load_active_scenarios(Path(args.config))
    print(f"preview: http://{DEFAULT_HOST}:{args.preview_port}  routes: {len(active)}")

    started = None
    if args.no_mock:
        report.ok("using external mock (--no-mock)")
    else:
        if mock_server.port_in_use(DEFAULT_HOST, args.mock_port):
            report.warn(f"mock port {args.mock_port} already in use; assuming an external mock")
        else:
            started, _ = mock_server.start_mock(args.mock_port)
            report.ok(f"mock started on {DEFAULT_HOST}:{args.mock_port}")

    try:
        _reset_mock(report, args.mock_port)

        print("\nclient-facing usage through the preview")
        for spec in active:
            _exercise_one(report, spec, args.preview_port, args.timeout)

        print("\nmock upstream hit log")
        _check_mock_log(report, active, args.mock_port)

        if args.cancel_test:
            _cancel_test(report, active, args.preview_port, args.timeout)

        print("\nexpected totals for the usage page")
        totals = totals_from_scenarios(active)
        print(f"  requests={totals['requests']} attempts={totals['attempts']} "
              f"known={totals['known_attempts']} unknown={totals['unknown_attempts']} "
              f"failed={totals['failed_attempts']}")
        print(f"  input_sum={totals['input_sum']} output_sum={totals['output_sum']} "
              f"total_sum={totals['total_sum']}")
    finally:
        if started is not None:
            started.shutdown()

    return {"report": report, "active": active}


def _exercise_one(report: Report, spec: Dict[str, Any], preview_port: int,
                  timeout: float) -> None:
    path = mock_server.INBOUND_PATH[spec["inbound"]]
    try:
        conn, resp = post(DEFAULT_HOST, preview_port, path, request_body(spec),
                          timeout=timeout, stream=spec["stream"])
    except (ConnectionRefusedError, OSError) as error:
        report.fail(f"{spec['id']}: cannot reach preview on {preview_port}: {error}")
        return
    raw = read_full(resp)
    ctype = resp.getheader("content-type") or ""
    status = resp.status
    conn.close()
    usage = client_usage(spec, status, ctype, raw)
    check_client_usage(report, spec, status, usage)


def _reset_mock(report: Report, mock_port: int) -> None:
    try:
        conn, resp = post(DEFAULT_HOST, mock_port, "/__reset", {}, timeout=5.0,
                          stream=False)
        resp.read()
        conn.close()
    except OSError as error:
        report.fail(f"cannot reset mock: {error}")


def _mock_requests(mock_port: int) -> List[Dict[str, Any]]:
    conn = http.client.HTTPConnection(DEFAULT_HOST, mock_port, timeout=5.0)
    conn.request("GET", "/__requests")
    resp = conn.getresponse()
    payload = json.loads(resp.read() or b"{}")
    conn.close()
    return payload.get("requests", [])


def _check_mock_log(report: Report, active: Sequence[Dict[str, Any]],
                    mock_port: int) -> None:
    seen = _mock_requests(mock_port)
    actual = sorted((r.get("path"), r.get("model")) for r in seen)
    expected: List[Tuple[str, str]] = []
    for spec in active:
        models = [spec["remote"], *spec.get("fallback", [])]
        for model in models:
            expected.append((UPSTREAM_PATH[family_of(model)], model))
    expected_sorted = sorted(expected)
    if actual == expected_sorted:
        report.ok(f"mock saw exactly the {len(expected_sorted)} expected upstream calls")
        return
    for item in expected_sorted:
        if item not in actual:
            report.fail(f"mock never received {item[0]} model={item[1]}")
    for item in actual:
        if item not in expected_sorted:
            report.warn(f"mock received an unexpected call {item}")


def _cancel_test(report: Report, active: Sequence[Dict[str, Any]],
                 preview_port: int, timeout: float) -> None:
    print("\nstream cancel (optional)")
    stream_specs = [s for s in active if s["stream"]]
    if not stream_specs:
        report.warn("no stream scenario to cancel")
        return
    spec = stream_specs[0]
    path = mock_server.INBOUND_PATH[spec["inbound"]]
    try:
        conn, resp = post(DEFAULT_HOST, preview_port, path, request_body(spec),
                          timeout=timeout, stream=True)
        # Read a little then abandon the request.
        for _ in range(2):
            if not resp.read(64):
                break
        conn.close()
        report.ok(f"cancelled mid-stream on {spec['id']} (router should stop upstream)")
    except OSError as error:
        report.warn(f"cancel test could not complete: {error}")

    # Preview must still be alive after the cancel.
    try:
        conn = http.client.HTTPConnection(DEFAULT_HOST, preview_port, timeout=5.0)
        conn.request("GET", "/v1/models")
        resp = conn.getresponse()
        resp.read()
        conn.close()
        if resp.status == 200:
            report.ok("preview still healthy after cancel (/v1/models -> 200)")
        else:
            report.fail(f"preview unhealthy after cancel: HTTP {resp.status}")
    except OSError as error:
        report.fail(f"preview unreachable after cancel: {error}")


# ---------------------------------------------------------------------------
# Database assertions
# ---------------------------------------------------------------------------

DB_COLUMNS = [
    "id", "request_id", "ts", "route_id", "route_name", "remote_id", "provider",
    "model", "endpoint", "attempt", "status", "outcome", "duration_ms",
    "input_tokens", "output_tokens", "cached_input_tokens", "cache_write_tokens",
    "reasoning_tokens",
]


def open_db(db_path: Path) -> sqlite3.Connection:
    if not db_path.exists():
        raise SystemExit(
            f"usage database {db_path} does not exist yet.\n"
            f"Start the preview with EZSWITCH_CONFIG pointing at the fixture and run "
            f"`verify_usage.py exercise` first."
        )
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def cmd_db(args: argparse.Namespace, watermark: Optional[float] = None) -> Report:
    report = Report()
    active = load_active_scenarios(Path(args.config))
    db_path = Path(args.db).expanduser()
    total_expected = sum(len(s["expect_attempts"]) for s in active)

    since = watermark if watermark is not None else args.since
    if since is None:
        since = time.time() - args.window
    print(f"database: {db_path}")
    print(f"rows since epoch {since:.3f}")

    deadline = time.time() + args.wait
    conn = open_db(db_path)
    try:
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        report.ok(f"schema user_version={version}")
        if version > 1:
            report.warn("schema is newer than the harness knows; assertions may drift")

        rows = _fetch_rows(conn, since, active)
        while len(rows) < total_expected and time.time() < deadline:
            time.sleep(0.25)
            rows = _fetch_rows(conn, since, active)
        print(f"found {len(rows)} usage-* rows")
        print("\nrecorded attempts")
        _assert_rows(report, active, rows)
        _assert_totals(report, active, rows)
    finally:
        conn.close()
    return report


def _fetch_rows(conn: sqlite3.Connection, since: float,
                active: Sequence[Dict[str, Any]]) -> List[sqlite3.Row]:
    """Fetch this run's rows.

    The recorder writes ``route_id`` = fake UUID and ``route_name`` = fake model
    id, so match on both to stay correct regardless of which one is keyed.
    """
    names = [s["route"] for s in active]
    uuids = [s["route_uuid"] for s in active]
    name_marks = ",".join("?" for _ in names)
    uuid_marks = ",".join("?" for _ in uuids)
    columns = ", ".join(DB_COLUMNS)
    sql = (f"SELECT {columns} FROM usage_records "
           f"WHERE ts >= ? AND (route_name IN ({name_marks}) "
           f"OR upper(route_id) IN ({uuid_marks})) "
           f"ORDER BY ts ASC, attempt ASC")
    params = [since, *names, *[u.upper() for u in uuids]]
    return list(conn.execute(sql, params))


def _match_row(rows: List[sqlite3.Row], used: set, status: Optional[int]) -> Optional[sqlite3.Row]:
    for index, row in enumerate(rows):
        if index in used:
            continue
        if status is None or row["status"] == status:
            used.add(index)
            return row
    return None


def _assert_rows(report: Report, active: Sequence[Dict[str, Any]],
                 rows: List[sqlite3.Row]) -> None:
    uuid_to_route = {s["route_uuid"].upper(): s["route"] for s in active}
    name_to_route = {s["route"]: s["route"] for s in active}
    by_route: Dict[str, List[sqlite3.Row]] = {}
    for row in rows:
        route = uuid_to_route.get(str(row["route_id"]).upper()) or \
            name_to_route.get(row["route_name"])
        if route is None:
            report.warn(f"unexpected row route_id={row['route_id']} "
                        f"route_name={row['route_name']}")
            continue
        by_route.setdefault(route, []).append(row)

    for spec in active:
        ident = spec["id"]
        actual = by_route.get(spec["route"], [])
        if not actual:
            report.fail(f"{ident}: no row recorded for route {spec['route']}")
            continue
        used: set = set()
        for attempt in spec["expect_attempts"]:
            row = _match_row(actual, used, attempt.get("status"))
            if row is None:
                report.fail(f"{ident}: no recorded attempt with status {attempt['status']}")
                continue
            _assert_attempt(report, ident, spec, attempt, row)
        extra = len(actual) - len(used)
        if extra > 0:
            report.warn(f"{ident}: {extra} extra row(s) beyond the expected attempts")


def _assert_attempt(report: Report, ident: str, spec: Dict[str, Any],
                    attempt: Dict[str, Any], row: sqlite3.Row) -> None:
    prefix = f"{ident}[status={attempt.get('status')}]"

    # Metadata that the fixture fixes exactly.
    if str(row["route_id"]).upper() != spec["route_uuid"].upper():
        report.fail(f"{prefix}: route_id {row['route_id']} != fixture UUID "
                    f"{spec['route_uuid']}")
    if row["route_name"] != spec["route"]:
        report.fail(f"{prefix}: route_name {row['route_name']!r} != {spec['route']!r}")
    expected_model = attempt.get("model") or spec["expected_model"]
    if row["model"] != expected_model:
        report.fail(f"{prefix}: model {row['model']!r} != {expected_model!r}")
    if row["provider"] != spec["expected_provider"]:
        report.fail(f"{prefix}: provider {row['provider']!r} != {spec['expected_provider']!r}")
    if row["endpoint"] != spec["inbound"]:
        report.fail(f"{prefix}: endpoint {row['endpoint']!r} != inbound {spec['inbound']!r}")

    if attempt["input"] is None:
        if row["input_tokens"] is not None or row["output_tokens"] is not None:
            report.fail(f"{prefix}: expected unknown usage but recorded "
                        f"input={row['input_tokens']} output={row['output_tokens']} "
                        f"(route {spec['route']})")
            return
        report.ok(f"{prefix}: usage stays unknown as expected")
    else:
        if row["input_tokens"] != attempt["input"] or row["output_tokens"] != attempt["output"]:
            report.fail(f"{prefix}: recorded input/output "
                        f"({row['input_tokens']}, {row['output_tokens']}) != "
                        f"({attempt['input']}, {attempt['output']})")
            return
        report.ok(f"{prefix}: recorded {row['input_tokens']}/{row['output_tokens']}"
                  f" outcome={row['outcome']} model={row['model']}")

    cache = spec.get("expect_cache")
    if cache:
        if row["cached_input_tokens"] != cache["cached"]:
            report.fail(f"{prefix}: cached_input_tokens {row['cached_input_tokens']} "
                        f"!= {cache['cached']}")
        if row["cache_write_tokens"] != cache["cache_write"]:
            report.fail(f"{prefix}: cache_write_tokens {row['cache_write_tokens']} "
                        f"!= {cache['cache_write']}")
        if row["cached_input_tokens"] == cache["cached"] and \
                row["cache_write_tokens"] == cache["cache_write"]:
            report.ok(f"{prefix}: cache sub-fields recorded correctly")
    details = row["cached_input_tokens"], row["cache_write_tokens"], row["reasoning_tokens"]
    if any(d is not None for d in details):
        print(f"        cache/reasoning detail (cached, cache_write, reasoning) = {details}")


def _assert_totals(report: Report, active: Sequence[Dict[str, Any]],
                   rows: List[sqlite3.Row]) -> None:
    expected = totals_from_scenarios(active)
    attempts = len(rows)
    requests = len({row["request_id"] for row in rows})
    known = sum(1 for r in rows
                if r["input_tokens"] is not None and r["output_tokens"] is not None)
    failed = sum(1 for r in rows
                 if r["status"] is None or not (200 <= r["status"] < 300))
    input_sum = sum(r["input_tokens"] or 0 for r in rows)
    output_sum = sum(r["output_tokens"] or 0 for r in rows)
    actual = {
        "requests": requests, "attempts": attempts, "known_attempts": known,
        "unknown_attempts": attempts - known, "failed_attempts": failed,
        "input_sum": input_sum, "output_sum": output_sum,
        "total_sum": input_sum + output_sum,
    }
    print("\nDB totals vs expected")
    for key in ("requests", "attempts", "known_attempts", "unknown_attempts",
                "failed_attempts", "input_sum", "output_sum", "total_sum"):
        mark = "ok  " if actual[key] == expected[key] else "FAIL"
        print(f"  {mark} {key}: db={actual[key]} expected={expected[key]}")
        if actual[key] != expected[key]:
            report.fail(f"total {key}: db={actual[key]} expected={expected[key]}")


# ---------------------------------------------------------------------------
# Optional synthetic history (never part of the tests)
# ---------------------------------------------------------------------------

SEED_SCHEMA = """
CREATE TABLE IF NOT EXISTS usage_records (
    id TEXT PRIMARY KEY NOT NULL,
    request_id TEXT NOT NULL,
    ts REAL NOT NULL,
    route_id TEXT NOT NULL,
    route_name TEXT NOT NULL,
    remote_id TEXT NOT NULL,
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    endpoint TEXT NOT NULL,
    attempt INTEGER NOT NULL,
    status INTEGER,
    outcome TEXT NOT NULL,
    duration_ms INTEGER NOT NULL,
    input_tokens INTEGER,
    output_tokens INTEGER,
    cached_input_tokens INTEGER,
    cache_write_tokens INTEGER,
    reasoning_tokens INTEGER
);
CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_records(ts);
"""


def cmd_seed(args: argparse.Namespace) -> int:
    """Insert labelled synthetic rows for previous days. Opt-in only."""
    db_path = Path(args.db).expanduser()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    try:
        conn.executescript(SEED_SCHEMA)
        if conn.execute("PRAGMA user_version").fetchone()[0] < 1:
            conn.execute("PRAGMA user_version = 1")
        now = time.time()
        inserted = 0
        for day in range(1, args.days + 1):
            # Fixed, obviously synthetic counts per day.
            ts = now - day * 86400
            for n, (route, inp, outp) in enumerate([
                ("demo-history-day-%d-a" % day, 100 * day, 40 * day),
                ("demo-history-day-%d-b" % day, 60 * day, 25 * day),
            ]):
                conn.execute(
                    "INSERT OR REPLACE INTO usage_records "
                    "(id, request_id, ts, route_id, route_name, remote_id, provider, "
                    " model, endpoint, attempt, status, outcome, duration_ms, "
                    " input_tokens, output_tokens, cached_input_tokens, "
                    " cache_write_tokens, reasoning_tokens) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (str(uuid.uuid4()), str(uuid.uuid4()), ts, route,
                     "演示历史（合成） · " + route, "demo-history-remote",
                     "演示历史（合成）", "demo-history", "chat", 0, 200, "success",
                     1, inp, outp, None, None, None),
                )
                inserted += 1
        conn.commit()
    finally:
        conn.close()
    print(f"inserted {inserted} labelled synthetic rows into {db_path}")
    print("These are marked '演示历史（合成）' and must only be used for the preview chart.")
    return 0


# ---------------------------------------------------------------------------
# Subcommand orchestration
# ---------------------------------------------------------------------------


def _finish(report: Report, args: argparse.Namespace) -> int:
    print()
    if report.failures:
        print(f"RESULT: FAIL ({len(report.failures)} failures, "
              f"{len(report.warnings)} warnings)")
        return 1
    print(f"RESULT: PASS ({len(report.warnings)} warnings)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("command", nargs="?", default="full",
                        choices=["plan", "exercise", "db", "full", "seed-demo-history"],
                        help="what to run (default: full)")
    parser.add_argument("--config", default=DEFAULT_CONFIG,
                        help=f"fixture config.json (default {DEFAULT_CONFIG})")
    parser.add_argument("--db", default="/tmp/ezswitch-usage-preview/usage.sqlite",
                        help="usage.sqlite path")
    parser.add_argument("--preview-port", type=int, default=DEFAULT_PREVIEW_PORT,
                        help=f"preview port (default {DEFAULT_PREVIEW_PORT})")
    parser.add_argument("--mock-port", type=int, default=mock_server.DEFAULT_PORT,
                        help=f"mock port (default {mock_server.DEFAULT_PORT})")
    parser.add_argument("--timeout", type=float, default=15.0,
                        help="per-request HTTP timeout seconds (default 15)")
    parser.add_argument("--no-mock", action="store_true",
                        help="do not start a mock; use one already listening")
    parser.add_argument("--cancel-test", action="store_true",
                        help="also abandon a stream mid-flight and check the preview survives")
    parser.add_argument("--wait", type=float, default=10.0,
                        help="seconds to wait for the recorder to flush rows (default 10)")
    parser.add_argument("--since", type=float, default=None,
                        help="epoch seconds lower bound for DB rows (db command)")
    parser.add_argument("--window", type=float, default=600.0,
                        help="db command: look back this many seconds when --since is absent")
    parser.add_argument("--days", type=int, default=7,
                        help="seed-demo-history: how many previous days to fabricate")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    if args.command == "seed-demo-history":
        return cmd_seed(args)
    if args.command == "plan":
        return cmd_plan(args)
    if args.command == "exercise":
        result = cmd_exercise(args)
        return _finish(result["report"], args)
    if args.command == "db":
        return _finish(cmd_db(args), args)

    # full: exercise over HTTP, then assert the recorded rows.
    watermark = time.time()
    result = cmd_exercise(args, watermark=watermark)
    print()
    print("=" * 72)
    db_report = cmd_db(args, watermark=watermark)
    report: Report = result["report"]
    report.failures.extend(db_report.failures)
    report.warnings.extend(db_report.warnings)
    return _finish(report, args)


if __name__ == "__main__":
    raise SystemExit(main())
