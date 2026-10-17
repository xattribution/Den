"""The API client, SSE parser and stream listener, against the fake hub."""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta

import aiohttp
from aiohttp import web
from aiohttp.test_utils import TestServer
import pytest

from custom_components.den.api import (
    DenAuthError,
    DenClient,
    DenConnectionError,
    DenInvalidInputError,
    DenNotFoundError,
    DenReadOnlyError,
    DenScopeError,
    DenStreamListener,
    error_from_response,
    iter_sse,
    normalize_url,
)
from custom_components.den.models import Occurrence, parse_instant

from .fake_hub import GROCERIES, HUB_ID, LEO, TOKEN, FakeHub


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("den.local", "http://den.local:47733"),
        ("192.168.1.20", "http://192.168.1.20:47733"),
        ("http://192.168.1.20:8080/", "http://192.168.1.20:8080"),
        ("https://den.example.com", "https://den.example.com"),
        ("https://den.example.com/den/", "https://den.example.com/den"),
        ("  http://[fe80::1]:47733 ", "http://[fe80::1]:47733"),
        ("[fe80::1]", "http://[fe80::1]:47733"),
    ],
)
def test_normalize_url(raw: str, expected: str) -> None:
    """Addresses people type become base URLs."""
    assert normalize_url(raw) == expected


@pytest.mark.parametrize("raw", ["", "   ", "ftp://den.local", "http://"])
def test_normalize_url_rejects(raw: str) -> None:
    """Things that aren't http(s) addresses are refused."""
    with pytest.raises(ValueError):
        normalize_url(raw)


def test_error_mapping() -> None:
    """Error bodies map to typed exceptions by code, then by status."""
    err = error_from_response(
        403,
        {
            "error": {
                "code": "insufficient_scope",
                "message": "no",
                "details": {"scope": "lists"},
            }
        },
    )
    assert isinstance(err, DenScopeError)
    assert err.scope == "lists"
    assert err.message == "no"
    assert isinstance(
        error_from_response(409, {"error": {"code": "read_only", "message": "x"}}),
        DenReadOnlyError,
    )
    assert isinstance(error_from_response(401, None), DenAuthError)
    assert isinstance(error_from_response(404, "not json"), DenNotFoundError)


def test_instants_prefer_millis() -> None:
    """`<name>_ms` wins over the ISO string; ISO is the fallback."""
    when = parse_instant(
        {"start": "2026-10-20T17:30:00-05:00", "start_ms": 1792535400000}, "start"
    )
    assert when == datetime(2026, 10, 20, 22, 30, tzinfo=UTC)
    assert parse_instant({"start": "2026-10-20T17:30:00-05:00"}, "start") == when
    assert parse_instant({}, "start") is None


def test_occurrence_defaults() -> None:
    """Minimal occurrences still parse."""
    occ = Occurrence.from_json(
        {
            "event_id": "E1",
            "title": "x",
            "start_ms": 1000,
            "end_ms": 500,
            "assignees": [1, "M1"],
        }
    )
    assert occ.uid == "E1@1000"
    assert occ.end == occ.start  # never before the start
    assert occ.assignees == ("M1",)
    assert not occ.recurring


async def test_client_reads(hub: FakeHub, hub_url: str) -> None:
    """Typed reads of every endpoint the integration uses."""
    async with aiohttp.ClientSession() as session:
        client = DenClient(session, hub_url, TOKEN)
        health = await client.health()
        assert health.device == HUB_ID
        assert health.ready

        directory = await client.members()
        assert directory.family.name == "The Kotvas"
        assert directory.hub.device == HUB_ID
        assert directory.token.has("lists")
        assert not directory.token.has("admin")
        assert [m.name for m in directory.members] == ["Mom", "Leo", "Ivy"]

        now = datetime.now(UTC)
        window = await client.events(now, now + timedelta(days=7), member=LEO)
        assert [o.title for o in window.events] == ["Soccer practice"]
        query = hub.last("GET", "/api/v1/events")[2]
        assert query["start"].isdigit()  # sent as milliseconds
        assert query["member"] == LEO

        chores = await client.chores()
        assert len(chores.chores) == 4
        lists = await client.lists()
        assert lists[0].id == GROCERIES
        assert lists[0].open == 1
        points = await client.points()
        assert points.totals[LEO] == 42


async def test_client_errors(hub: FakeHub, hub_url: str) -> None:
    """HTTP errors become typed exceptions; unreachable hubs are connection errors."""
    async with aiohttp.ClientSession() as session:
        with pytest.raises(DenAuthError):
            await DenClient(session, hub_url, "wrong").members()
        client = DenClient(session, hub_url, TOKEN)
        with pytest.raises(DenNotFoundError):
            await client.delete_item("nope")
        with pytest.raises(DenInvalidInputError):
            await client.adjust_points(LEO, 0, "x")
        with pytest.raises(DenReadOnlyError):
            await client.delete_event("E4PICTURE2RJ6YP3")
        hub.scopes = ["read"]
        with pytest.raises(DenScopeError) as info:
            await client.add_item(GROCERIES, "Milk")
        assert info.value.scope == "lists"
        with pytest.raises(DenConnectionError):
            await DenClient(session, "http://127.0.0.1:9", TOKEN).members()


async def test_sse_parser(socket_enabled: None) -> None:
    """Multi-line data, comments, CRLF, ids, retry and non-JSON data."""
    body = (
        b": comment\r\n"
        b"retry: 2500\r\n\r\n"
        b'event: changed\r\nid: 7\r\ndata: {"types":\r\ndata: ["item"]}\r\n\r\n'
        b"data: plain text\n\n"
        b"event: empty\n\n"
    )

    async def handler(request: web.Request) -> web.Response:
        return web.Response(body=body, content_type="text/event-stream")

    app = web.Application()
    app.router.add_get("/", handler)
    server = TestServer(app, host="127.0.0.1")
    await server.start_server()
    try:
        async with (
            aiohttp.ClientSession() as session,
            session.get(server.make_url("/")) as resp,
        ):
            messages = [m async for m in iter_sse(resp.content)]
    finally:
        await server.close()
    assert [(m.event, m.data, m.id) for m in messages] == [
        ("retry", 2500, None),
        ("changed", {"types": ["item"]}, "7"),
        ("message", "plain text", "7"),
    ]


async def test_stream_listener_reconnects(hub: FakeHub, hub_url: str) -> None:
    """The listener reports hello as a connect, passes events on, and reconnects after a drop."""
    connects: list[int] = []
    drops: list[int] = []
    messages: list[str] = []
    delays: list[float] = []

    async def fast_sleep(delay: float) -> None:
        delays.append(delay)
        await asyncio.sleep(0)

    async with aiohttp.ClientSession() as session:
        listener = DenStreamListener(
            DenClient(session, hub_url, TOKEN),
            on_message=lambda m: messages.append(m.event),
            on_connect=lambda: connects.append(1),
            on_disconnect=lambda: drops.append(1),
            sleep=fast_sleep,
        )
        task = asyncio.create_task(listener.run())

        async def wait(predicate) -> None:
            for _ in range(250):
                if predicate():
                    return
                await asyncio.sleep(0.02)
            raise AssertionError("timed out")

        await wait(lambda: len(connects) == 1)
        assert listener.connected
        await hub.changed("item")
        await wait(lambda: messages == ["changed"])
        await hub.drop_streams()
        await wait(lambda: len(connects) == 2)
        assert drops == [1]
        assert delays and 4.0 <= delays[0] <= 6.0  # honors the hub's retry hint (5 s)
        hub.token = "rotated"
        await hub.drop_streams()
        await asyncio.wait_for(task, 5)  # stops for good on 401
        assert not listener.connected
        assert listener.last_error == "Unknown token."


def test_backoff_grows_and_caps() -> None:
    """Exponential backoff with jitter, capped at the maximum."""
    listener = DenStreamListener(
        None, on_message=lambda m: None, min_backoff=1, max_backoff=60
    )  # type: ignore[arg-type]
    assert 0.8 <= listener.next_delay(0) <= 1.2
    assert 6.4 <= listener.next_delay(3) <= 9.6
    assert 48 <= listener.next_delay(10) <= 72
