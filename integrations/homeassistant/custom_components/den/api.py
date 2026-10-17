"""Async client for the Den hub's HTTP API and event stream (docs/hub-api.md).

No Home Assistant imports: it takes an aiohttp session and can be used and tested on its own.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Awaitable, Callable, Mapping
from datetime import date, datetime
import json
import logging
import random
from typing import Any
from urllib.parse import urlsplit, urlunsplit

import aiohttp

from .models import (
    ChoresDay,
    DenList,
    Directory,
    EventsWindow,
    Health,
    Points,
    StreamMessage,
)

_LOGGER = logging.getLogger(__name__)

DEFAULT_PORT = 47733
API = "/api/v1"
REQUEST_TIMEOUT = 15
# The hub pings every 20 seconds; this long without a byte means the connection is gone.
STREAM_READ_TIMEOUT = 60

type Body = Mapping[str, Any]
type When = datetime | date | int | str


class DenError(Exception):
    """An error talking to a Den hub."""

    def __init__(
        self,
        message: str,
        *,
        code: str | None = None,
        status: int | None = None,
        details: Mapping[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.status = status
        self.details: Mapping[str, Any] = details or {}


class DenConnectionError(DenError):
    """The hub couldn't be reached or didn't answer in time."""


class DenAuthError(DenError):
    """401: the token is missing, unknown, revoked or expired."""


class DenScopeError(DenError):
    """403 insufficient_scope: the token lacks a scope."""

    @property
    def scope(self) -> str:
        """The scope the endpoint needs."""
        return str(self.details.get("scope", ""))


class DenPermissionError(DenError):
    """403 permission_denied: the token's member may not do this."""


class DenNotFoundError(DenError):
    """404: no such record (or none the token can read)."""


class DenReadOnlyError(DenError):
    """409 read_only: an event imported from a subscribed calendar."""


class DenInvalidInputError(DenError):
    """400 invalid_input."""


class DenNotReadyError(DenError):
    """503 not_ready: the hub isn't in a family yet or is still loading."""


_ERRORS_BY_CODE: dict[str, type[DenError]] = {
    "unauthorized": DenAuthError,
    "insufficient_scope": DenScopeError,
    "permission_denied": DenPermissionError,
    "not_found": DenNotFoundError,
    "read_only": DenReadOnlyError,
    "invalid_input": DenInvalidInputError,
    "not_ready": DenNotReadyError,
}

_ERRORS_BY_STATUS: dict[int, type[DenError]] = {
    400: DenInvalidInputError,
    401: DenAuthError,
    403: DenPermissionError,
    404: DenNotFoundError,
    409: DenReadOnlyError,
    503: DenNotReadyError,
}


def normalize_url(raw: str) -> str:
    """Turn what a person typed into the hub's base URL.

    `den.local` becomes `http://den.local:47733`; a scheme, port or path given is kept, and a
    trailing slash is dropped.
    """
    text = raw.strip()
    if not text:
        raise ValueError("empty URL")
    if "://" not in text:
        text = f"http://{text}"
    parts = urlsplit(text)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ValueError(f"not an http(s) URL: {raw}")
    netloc = parts.netloc
    if parts.port is None:
        host = parts.hostname
        if ":" in host:  # IPv6 literal
            host = f"[{host}]"
        netloc = f"{host}:{DEFAULT_PORT}" if parts.scheme == "http" else host
    return urlunsplit((parts.scheme, netloc, parts.path.rstrip("/"), "", ""))


def format_when(value: When) -> str:
    """Write an instant or local date for a query or body, as the API accepts them."""
    if isinstance(value, datetime):
        if value.tzinfo is None:
            raise ValueError("naive datetime")
        return value.isoformat(timespec="seconds")
    if isinstance(value, date):
        return value.isoformat()
    return str(value)


def to_millis(value: When) -> int | str:
    """An instant as UTC milliseconds; local dates and strings pass through."""
    if isinstance(value, datetime):
        if value.tzinfo is None:
            raise ValueError("naive datetime")
        return int(value.timestamp() * 1000)
    if isinstance(value, date):
        return value.isoformat()
    return value


def _query(params: Mapping[str, Any]) -> dict[str, str]:
    out: dict[str, str] = {}
    for key, value in params.items():
        if value is None:
            continue
        if isinstance(value, bool):
            out[key] = "true" if value else "false"
        elif isinstance(value, datetime | date):
            out[key] = format_when(value)
        else:
            out[key] = str(value)
    return out


def error_from_response(status: int, body: Any) -> DenError:
    """Build the right DenError from an error response."""
    error = body.get("error") if isinstance(body, Mapping) else None
    if isinstance(error, Mapping):
        code = error.get("code") if isinstance(error.get("code"), str) else None
        message = (
            error.get("message") if isinstance(error.get("message"), str) else None
        )
        details = (
            error.get("details") if isinstance(error.get("details"), Mapping) else None
        )
    else:
        code = message = details = None
    cls = _ERRORS_BY_CODE.get(code or "") or _ERRORS_BY_STATUS.get(status, DenError)
    return cls(
        message or f"Den hub answered HTTP {status}",
        code=code,
        status=status,
        details=details,
    )


async def iter_sse(content: aiohttp.StreamReader) -> AsyncIterator[StreamMessage]:
    """Parse a text/event-stream body into messages.

    Follows the HTML spec's rules: `event`, `data` (joined by newlines), `id` and `retry` fields;
    lines starting with `:` are comments; a blank line dispatches. `retry` is surfaced as a
    message with event `retry` and the delay in milliseconds as data.
    """
    event = ""
    data_lines: list[str] = []
    last_id: str | None = None
    buffer = b""
    while True:
        chunk = await content.readline()
        if not chunk:
            return
        buffer += chunk
        if not buffer.endswith((b"\n", b"\r")):
            continue  # a line longer than the reader's buffer; keep reading
        line = buffer.decode("utf-8", errors="replace").rstrip("\r\n")
        buffer = b""
        if not line:
            if data_lines:
                raw = "\n".join(data_lines)
                try:
                    data: Any = json.loads(raw)
                except ValueError:
                    data = raw
                yield StreamMessage(event=event or "message", data=data, id=last_id)
            event = ""
            data_lines = []
            continue
        if line.startswith(":"):
            continue
        name, _, value = line.partition(":")
        value = value.removeprefix(" ")
        if name == "event":
            event = value
        elif name == "data":
            data_lines.append(value)
        elif name == "id":
            last_id = value or None
        elif name == "retry" and value.isdigit():
            yield StreamMessage(event="retry", data=int(value), id=last_id)


class DenClient:
    """Talks to one Den hub with one API token."""

    def __init__(
        self,
        session: aiohttp.ClientSession,
        base_url: str,
        token: str | None = None,
        *,
        request_timeout: float = REQUEST_TIMEOUT,
    ) -> None:
        self._session = session
        self.base_url = base_url.rstrip("/")
        self._token = token
        self._timeout = aiohttp.ClientTimeout(total=request_timeout)

    def _headers(self, *, auth: bool = True) -> dict[str, str]:
        headers = {"Accept": "application/json"}
        if auth and self._token:
            headers["Authorization"] = f"Bearer {self._token}"
        return headers

    async def request(
        self,
        method: str,
        path: str,
        *,
        params: Mapping[str, Any] | None = None,
        body: Body | None = None,
        auth: bool = True,
    ) -> dict[str, Any]:
        """Make one API call and return the decoded JSON object."""
        url = f"{self.base_url}{path}"
        try:
            async with self._session.request(
                method,
                url,
                params=_query(params or {}),
                json=dict(body) if body is not None else None,
                headers=self._headers(auth=auth),
                timeout=self._timeout,
            ) as resp:
                try:
                    payload: Any = await resp.json(content_type=None)
                except ValueError:
                    payload = None
                if resp.status >= 400:
                    raise error_from_response(resp.status, payload)
        except (aiohttp.ClientError, TimeoutError) as err:
            raise DenConnectionError(
                f"Couldn't reach the Den hub at {self.base_url}: {str(err) or type(err).__name__}"
            ) from err
        if payload is None:
            return {}
        if not isinstance(payload, dict):
            raise DenError("The Den hub sent a response that isn't a JSON object")
        return payload

    # ------------------------------------------------------------------ reads

    async def health(self) -> Health:
        """`GET /health` (no token needed)."""
        return Health.from_json(await self.request("GET", "/health", auth=False))

    async def members(self) -> Directory:
        """`GET /api/v1/members`: validates the token and returns family, members, scopes."""
        return Directory.from_json(await self.request("GET", f"{API}/members"))

    async def events(
        self,
        start: When,
        end: When,
        *,
        member: str | None = None,
        include_everyone: bool | None = None,
        limit: int | None = None,
    ) -> EventsWindow:
        """`GET /api/v1/events`: occurrences overlapping [start, end)."""
        params = {
            # Integer milliseconds keep `+` offsets out of the query string.
            "start": to_millis(start),
            "end": to_millis(end),
            "member": member,
            "include_everyone": include_everyone if member else None,
            "limit": limit,
        }
        return EventsWindow.from_json(
            await self.request("GET", f"{API}/events", params=params)
        )

    async def chores(
        self, day: date | str | None = None, *, member: str | None = None
    ) -> ChoresDay:
        """`GET /api/v1/chores`: chores for a local date (default today)."""
        params = {"date": format_when(day) if day else None, "member": member}
        return ChoresDay.from_json(
            await self.request("GET", f"{API}/chores", params=params)
        )

    async def lists(self) -> list[DenList]:
        """`GET /api/v1/lists`: every list with its items."""
        payload = await self.request("GET", f"{API}/lists")
        raw = payload.get("lists")
        return (
            [DenList.from_json(x) for x in raw if isinstance(x, Mapping)]
            if isinstance(raw, list)
            else []
        )

    async def points(self) -> Points:
        """`GET /api/v1/points`."""
        return Points.from_json(
            await self.request("GET", f"{API}/points", params={"recent": 0})
        )

    async def today(self, day: date | str | None = None) -> dict[str, Any]:
        """`GET /api/v1/today` (raw JSON)."""
        params = {"date": format_when(day) if day else None}
        return await self.request("GET", f"{API}/today", params=params)

    async def history(
        self,
        query: str | None = None,
        *,
        member: str | None = None,
        record_type: str | None = None,
        limit: int | None = None,
    ) -> dict[str, Any]:
        """`GET /api/v1/history` (raw JSON)."""
        params = {"q": query, "member": member, "type": record_type, "limit": limit}
        return await self.request("GET", f"{API}/history", params=params)

    async def search(self, query: str, *, limit: int | None = None) -> dict[str, Any]:
        """`GET /api/v1/search` (raw JSON)."""
        return await self.request(
            "GET", f"{API}/search", params={"q": query, "limit": limit}
        )

    # ------------------------------------------------------------------ writes

    async def create_event(self, body: Body) -> dict[str, Any]:
        """`POST /api/v1/events`; returns `{"event": ...}`."""
        return await self.request("POST", f"{API}/events", body=body)

    async def update_event(
        self,
        event_id: str,
        body: Body,
        *,
        scope: str = "all",
        occurrence: int | None = None,
    ) -> dict[str, Any]:
        """`PATCH /api/v1/events/{id}` with `scope` one, following or all."""
        params = {"scope": scope, "occurrence": occurrence}
        return await self.request(
            "PATCH", f"{API}/events/{event_id}", params=params, body=body
        )

    async def delete_event(
        self,
        event_id: str,
        *,
        scope: str = "all",
        occurrence: int | None = None,
    ) -> dict[str, Any]:
        """`DELETE /api/v1/events/{id}`."""
        params = {"scope": scope, "occurrence": occurrence}
        return await self.request("DELETE", f"{API}/events/{event_id}", params=params)

    async def complete_chore(
        self,
        chore_id: str,
        day: date | str | None = None,
        *,
        done: bool = True,
        member: str | None = None,
    ) -> dict[str, Any]:
        """`POST /api/v1/chores/{id}/complete`; returns `{"chore": ChoreDay}`."""
        body: dict[str, Any] = {"done": done}
        if day:
            body["date"] = format_when(day)
        if member:
            body["member"] = member
        return await self.request(
            "POST", f"{API}/chores/{chore_id}/complete", body=body
        )

    async def check_step(
        self,
        chore_id: str,
        step_id: str,
        day: date | str | None = None,
        *,
        checked: bool = True,
        member: str | None = None,
    ) -> dict[str, Any]:
        """`POST /api/v1/chores/{id}/steps/{stepId}`; returns `{"chore": ChoreDay}`."""
        body: dict[str, Any] = {"checked": checked}
        if day:
            body["date"] = format_when(day)
        if member:
            body["member"] = member
        return await self.request(
            "POST", f"{API}/chores/{chore_id}/steps/{step_id}", body=body
        )

    async def add_item(
        self,
        list_id: str,
        text: str,
        *,
        qty: str | None = None,
        store: str | None = None,
    ) -> dict[str, Any]:
        """`POST /api/v1/lists/{id}/items` with one item; returns `{"item": Item}`."""
        body: dict[str, Any] = {"text": text}
        if qty:
            body["qty"] = qty
        if store:
            body["store"] = store
        return await self.request("POST", f"{API}/lists/{list_id}/items", body=body)

    async def update_item(self, item_id: str, body: Body) -> dict[str, Any]:
        """`PATCH /api/v1/items/{id}`; returns `{"item": Item}`."""
        return await self.request("PATCH", f"{API}/items/{item_id}", body=body)

    async def move_item(
        self, item_id: str, *, after: str | None, before: str | None
    ) -> dict[str, Any]:
        """Move an item between two neighbors (None at either end)."""
        return await self.update_item(
            item_id, {"move": {"after": after, "before": before}}
        )

    async def delete_item(self, item_id: str) -> dict[str, Any]:
        """`DELETE /api/v1/items/{id}`."""
        return await self.request("DELETE", f"{API}/items/{item_id}")

    async def adjust_points(
        self, member: str, delta: int, reason: str
    ) -> dict[str, Any]:
        """`POST /api/v1/points/adjust`; returns `{"adjustment": ..., "balance": n}`."""
        body = {"member": member, "delta": delta, "reason": reason}
        return await self.request("POST", f"{API}/points/adjust", body=body)

    # ------------------------------------------------------------------ stream

    async def stream(self) -> AsyncIterator[StreamMessage]:
        """Open `/api/v1/stream` once and yield its messages until it closes."""
        url = f"{self.base_url}{API}/stream"
        headers = self._headers()
        headers["Accept"] = "text/event-stream"
        timeout = aiohttp.ClientTimeout(
            total=None, sock_connect=10, sock_read=STREAM_READ_TIMEOUT
        )
        try:
            async with self._session.get(url, headers=headers, timeout=timeout) as resp:
                if resp.status >= 400:
                    try:
                        payload: Any = await resp.json(content_type=None)
                    except ValueError:
                        payload = None
                    raise error_from_response(resp.status, payload)
                async for message in iter_sse(resp.content):
                    yield message
        except (aiohttp.ClientError, TimeoutError) as err:
            raise DenConnectionError(
                f"Lost the Den event stream: {str(err) or type(err).__name__}"
            ) from err


class DenStreamListener:
    """Keeps the event stream open, reconnecting with exponential backoff and jitter.

    Calls `on_connect` when the hub's `hello` arrives (refetch then: there is no replay),
    `on_message` for every other event, and `on_disconnect` whenever a live stream drops.
    Stops for good, after calling `on_auth_error`, when the hub rejects the token.
    """

    def __init__(
        self,
        client: DenClient,
        *,
        on_message: Callable[[StreamMessage], None],
        on_connect: Callable[[], None] | None = None,
        on_disconnect: Callable[[], None] | None = None,
        on_auth_error: Callable[[DenAuthError], None] | None = None,
        min_backoff: float = 1.0,
        max_backoff: float = 60.0,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ) -> None:
        self._client = client
        self._on_message = on_message
        self._on_connect = on_connect
        self._on_disconnect = on_disconnect
        self._on_auth_error = on_auth_error
        self._min = min_backoff
        self._max = max_backoff
        self._sleep = sleep
        self.connected = False
        self.connects = 0
        self.last_error: str | None = None

    def next_delay(self, attempt: int, retry_hint: float | None = None) -> float:
        """Seconds to wait before reconnect attempt number `attempt` (0-based)."""
        base = max(self._min, retry_hint or 0.0)
        delay = min(self._max, base * (2**attempt))
        return delay * random.uniform(0.8, 1.2)  # noqa: S311 - jitter, not crypto

    async def run(self) -> None:
        """Run until cancelled or the token is rejected."""
        attempt = 0
        retry_hint: float | None = None
        while True:
            try:
                async for message in self._client.stream():
                    if message.event == "retry":
                        retry_hint = int(message.data) / 1000
                        continue
                    if message.event == "hello":
                        attempt = 0
                        self.connected = True
                        self.connects += 1
                        self.last_error = None
                        if self._on_connect:
                            self._on_connect()
                        continue
                    try:
                        self._on_message(message)
                    except Exception:
                        _LOGGER.exception(
                            "Error handling Den stream event %s", message.event
                        )
                self.last_error = "stream closed by the hub"
            except DenAuthError as err:
                self.last_error = err.message
                self._dropped()
                if self._on_auth_error:
                    self._on_auth_error(err)
                return
            except DenError as err:
                self.last_error = err.message
                _LOGGER.debug("Den stream error: %s", err.message)
            self._dropped()
            await self._sleep(self.next_delay(attempt, retry_hint))
            attempt += 1

    def _dropped(self) -> None:
        if self.connected:
            self.connected = False
            if self._on_disconnect:
                self._on_disconnect()
