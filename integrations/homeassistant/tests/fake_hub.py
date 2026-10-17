"""An in-memory Den hub speaking docs/hub-api.md, served by aiohttp's test server."""

from __future__ import annotations

import asyncio
from datetime import UTC, date, datetime, timedelta
import itertools
import json
from typing import Any
from zoneinfo import ZoneInfo

from aiohttp import web

TOKEN = "den_test_token"
HUB_ID = "D7HUB2QK4MXN3T5W"
TZ = ZoneInfo("America/Chicago")

MOM = "M3MOMQ7K2XN4B5TA"
LEO = "M5LEOW3H7ZQ2D4VC"
IVY = "M6IVYX4G2AR5E3WD"

GROCERIES = "L2GROCERY5QK4MXN"
PACKING = "L3PACKING6RJ6YP2"


def _instant(name: str, when: datetime | None) -> dict[str, Any]:
    if when is None:
        return {name: None, f"{name}_ms": None}
    return {
        name: when.astimezone(TZ).isoformat(timespec="seconds"),
        f"{name}_ms": int(when.timestamp() * 1000),
    }


def _parse_when(value: str) -> datetime:
    if value.lstrip("-").isdigit():
        return datetime.fromtimestamp(int(value) / 1000, UTC)
    if len(value) == 10:
        return datetime.combine(date.fromisoformat(value), datetime.min.time(), TZ)
    parsed = datetime.fromisoformat(value.replace(" ", "+"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=TZ)


def _error(status: int, code: str, message: str, **details: Any) -> web.Response:
    body: dict[str, Any] = {"error": {"code": code, "message": message}}
    if details:
        body["error"]["details"] = details
    return web.json_response(body, status=status)


class FakeHub:
    """State plus handlers. Tests change the state and push stream events."""

    def __init__(self) -> None:
        self.token = TOKEN
        self.hub_id = HUB_ID
        self.scopes = ["read", "calendar", "chores", "lists", "points"]
        self.ready = True
        self.points_enabled = True
        self.requests: list[tuple[str, str, dict[str, str], Any]] = []
        self.streams: list[asyncio.Queue[str | None]] = []
        self._ids = itertools.count(1)

        now = datetime.now(UTC)
        self.now = now
        self.today = now.astimezone(TZ).date()
        self.members = [
            {
                "id": MOM,
                "name": "Mom",
                "role": "parent",
                "tier": None,
                "marker": "teal",
                "animal": "owl",
                "birthday": None,
                "grants": [],
                "order": 0,
            },
            {
                "id": LEO,
                "name": "Leo",
                "role": "kid",
                "tier": "big",
                "marker": "orange",
                "animal": "fox",
                "birthday": "2017-04-02",
                "grants": ["lists"],
                "order": 1,
            },
            {
                "id": IVY,
                "name": "Ivy",
                "role": "kid",
                "tier": "little",
                "marker": "pink",
                "animal": "rabbit",
                "birthday": None,
                "grants": [],
                "order": 2,
            },
        ]
        soccer_start = (now + timedelta(days=1)).replace(microsecond=0)
        dentist_start = (now + timedelta(hours=3)).replace(second=0, microsecond=0)
        picture_day = self.today + timedelta(days=2)
        picture_start = datetime.combine(picture_day, datetime.min.time(), TZ)
        self.events: list[dict[str, Any]] = [
            self.occurrence(
                "E2SOCCER7QK4MXN3",
                "Soccer practice",
                soccer_start,
                soccer_start + timedelta(hours=1),
                assignees=[LEO],
                rrule="FREQ=WEEKLY",
                reminders=[30],
                location="Field 3",
            ),
            self.occurrence(
                "E3DENTIST4RJ6YP2",
                "Dentist",
                dentist_start,
                dentist_start + timedelta(hours=1),
                assignees=[IVY],
                reminders=[15],
            ),
            self.occurrence(
                "E4PICTURE2RJ6YP3",
                "Picture day",
                picture_start,
                picture_start + timedelta(days=1),
                all_day=True,
                start_date=picture_day.isoformat(),
                end_date=(picture_day + timedelta(days=1)).isoformat(),
                read_only=True,
            ),
        ]
        day = self.today.isoformat()
        self.chores: list[dict[str, Any]] = [
            self.chore(
                "C2FEEDCAT5QK4MXN",
                "Feed the cat",
                LEO,
                points=5,
                steps=[
                    {
                        "id": "s1",
                        "text": "Fill the water bowl",
                        "owner": None,
                        "points": 1,
                        "checked": False,
                        "checked_by": None,
                    },
                    {
                        "id": "s2",
                        "text": "One scoop of food",
                        "owner": None,
                        "points": 1,
                        "checked": False,
                        "checked_by": None,
                    },
                ],
            ),
            self.chore("C3MAKEBEDLEO6RJ6", "Make bed", LEO, points=2),
            self.chore("C4MAKEBEDIVY7SK7", "Make bed", IVY, points=2),
            self.chore("C5DISHES2TL2ZQ3A", "Empty the dishwasher", None, points=3),
        ]
        self.chore_date = day
        self.lists: list[dict[str, Any]] = [
            {
                "id": GROCERIES,
                "title": "Groceries",
                "icon": "cart",
                "kind": "shopping",
                "lifecycle": "running",
                "need_by": None,
                "event": None,
                "pinned": True,
                "order": "m",
                "space": "f",
                "audience": "everyone",
                "items": [
                    {
                        "id": "I2MILK7QK4MXN3TB",
                        "list": GROCERIES,
                        "text": "Milk",
                        "qty": "2 gal",
                        "store": "Costco",
                        "checked": False,
                        "checked_by": None,
                        "order": "m",
                        "to_groceries": False,
                    },
                    {
                        "id": "I3EGGS5RJ6YP2TQA",
                        "list": GROCERIES,
                        "text": "Eggs",
                        "qty": None,
                        "store": None,
                        "checked": True,
                        "checked_by": MOM,
                        "order": "t",
                        "to_groceries": False,
                    },
                ],
            },
            {
                "id": PACKING,
                "title": "Camping",
                "icon": "bag",
                "kind": "packing",
                "lifecycle": "dated",
                "need_by": None,
                "event": None,
                "pinned": False,
                "order": "t",
                "space": "f",
                "audience": "everyone",
                "items": [
                    {
                        "id": "I4SOCKS6SK7ZQ4UB",
                        "list": PACKING,
                        "text": "Socks",
                        "qty": None,
                        "store": None,
                        "checked": False,
                        "checked_by": None,
                        "order": "m",
                        "to_groceries": False,
                    },
                ],
            },
        ]
        self.totals = {MOM: 0, LEO: 42, IVY: 37}

    # ------------------------------------------------------------------ builders

    def occurrence(
        self,
        event_id: str,
        title: str,
        start: datetime,
        end: datetime,
        *,
        assignees: list[str] | None = None,
        rrule: str | None = None,
        reminders: list[int] | None = None,
        all_day: bool = False,
        start_date: str | None = None,
        end_date: str | None = None,
        read_only: bool = False,
        location: str = "",
    ) -> dict[str, Any]:
        """An Occurrence object."""
        occurrence = int(start.timestamp() * 1000)
        return {
            "uid": f"{event_id}@{occurrence}",
            "event_id": event_id,
            "occurrence": occurrence,
            "recurring": rrule is not None,
            "edited": False,
            "title": title,
            "notes": "",
            "location": location,
            "category": None,
            "all_day": all_day,
            **_instant("start", start),
            **_instant("end", end),
            "start_date": start_date,
            "end_date": end_date,
            "tz": "America/Chicago",
            "rrule": rrule,
            "assignees": assignees or [],
            "reminders": reminders or [],
            "rides": [],
            "countdown": False,
            "source": {"kind": "ics" if read_only else "manual", "label": None},
            "read_only": read_only,
            "space": "f",
            "audience": "everyone",
        }

    def chore(
        self,
        chore_id: str,
        title: str,
        owner: str | None,
        *,
        points: int = 0,
        steps: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        """A ChoreDay object for today."""
        day = self.today.isoformat()
        steps = steps or []
        return {
            "id": chore_id,
            "completion_id": f"{chore_id}@{day}",
            "date": day,
            "title": title,
            "notes": "",
            "icon": "check",
            "owner": owner,
            "owner_rule": {"kind": "member", "id": owner}
            if owner
            else {"kind": "anyone"},
            "swapped": False,
            "schedule": {"rrule": "FREQ=DAILY", "start": "2026-01-05"},
            "recurring": True,
            "due_time": None,
            "due": None,
            "due_ms": None,
            "done": False,
            "done_by": None,
            "late": False,
            "points": points,
            "points_available": points + sum(s["points"] for s in steps),
            "steps": steps,
            "steps_done": 0,
            "step_count": len(steps),
            "space": "f",
            "audience": "everyone",
        }

    def find_chore(self, chore_id: str) -> dict[str, Any] | None:
        return next((c for c in self.chores if c["id"] == chore_id), None)

    def find_item(self, item_id: str) -> tuple[dict[str, Any], dict[str, Any]] | None:
        for lst in self.lists:
            for item in lst["items"]:
                if item["id"] == item_id:
                    return lst, item
        return None

    def list_view(self, lst: dict[str, Any]) -> dict[str, Any]:
        open_items = [i for i in lst["items"] if not i["checked"]]
        by_store: dict[str, int] = {}
        for item in open_items:
            by_store[item["store"] or ""] = by_store.get(item["store"] or "", 0) + 1
        return {**lst, "open": len(open_items), "open_by_store": by_store}

    # ------------------------------------------------------------------ stream

    async def push(self, event: str, data: dict[str, Any]) -> None:
        """Send one SSE event to every open stream."""
        frame = f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n"
        for queue in list(self.streams):
            await queue.put(frame)

    async def changed(self, *types: str) -> None:
        """Send a `changed` event."""
        await self.push(
            "changed",
            {
                "types": list(types),
                "records": [],
                "actor": None,
                "via": None,
                **_instant("time", datetime.now(UTC)),
            },
        )

    async def drop_streams(self) -> None:
        """Close every open stream from the hub's side."""
        for queue in list(self.streams):
            await queue.put(None)

    # ------------------------------------------------------------------ app

    def app(self) -> web.Application:
        """The aiohttp application."""
        app = web.Application(middlewares=[self._middleware])
        r = app.router
        r.add_get("/health", self.health)
        r.add_get("/api/v1/members", self.get_members)
        r.add_get("/api/v1/events", self.get_events)
        r.add_post("/api/v1/events", self.post_event)
        r.add_patch("/api/v1/events/{id}", self.patch_event)
        r.add_delete("/api/v1/events/{id}", self.delete_event)
        r.add_get("/api/v1/chores", self.get_chores)
        r.add_post("/api/v1/chores/{id}/complete", self.complete_chore)
        r.add_post("/api/v1/chores/{id}/steps/{step}", self.check_step)
        r.add_get("/api/v1/lists", self.get_lists)
        r.add_post("/api/v1/lists/{id}/items", self.post_item)
        r.add_patch("/api/v1/items/{id}", self.patch_item)
        r.add_delete("/api/v1/items/{id}", self.delete_item)
        r.add_get("/api/v1/points", self.get_points)
        r.add_post("/api/v1/points/adjust", self.adjust_points)
        r.add_get("/api/v1/stream", self.stream)
        return app

    @web.middleware
    async def _middleware(
        self, request: web.Request, handler: Any
    ) -> web.StreamResponse:
        body = None
        if request.can_read_body:
            try:
                body = await request.json()
            except ValueError:
                return _error(400, "invalid_input", "Body isn't JSON.")
        self.requests.append((request.method, request.path, dict(request.query), body))
        request["body"] = body
        if request.path.startswith("/api/v1"):
            if request.headers.get("Authorization") != f"Bearer {self.token}":
                return _error(401, "unauthorized", "Unknown token.")
            if not self.ready:
                return _error(503, "not_ready", "The hub isn't set up yet.")
            needed = self._scope_for(request)
            if needed not in self.scopes and "admin" not in self.scopes:
                return _error(
                    403,
                    "insufficient_scope",
                    f'This token doesn\'t have the "{needed}" scope.',
                    scope=needed,
                )
        return await handler(request)

    @staticmethod
    def _scope_for(request: web.Request) -> str:
        if request.method == "GET":
            return "read"
        path = request.path
        if path.startswith("/api/v1/events"):
            return "calendar"
        if path.startswith("/api/v1/chores"):
            return "chores"
        if path.startswith("/api/v1/points"):
            return "points"
        return "lists"

    def last(
        self, method: str, prefix: str = ""
    ) -> tuple[str, str, dict[str, str], Any]:
        """The latest request with this method (and path prefix)."""
        return next(
            r
            for r in reversed(self.requests)
            if r[0] == method and r[1].startswith(prefix)
        )

    def count(self, method: str, path: str) -> int:
        """How many requests hit exactly this method and path."""
        return sum(1 for r in self.requests if r[0] == method and r[1] == path)

    async def health(self, request: web.Request) -> web.Response:
        return web.json_response(
            {
                "ok": True,
                "version": "0.1.0",
                "api": 1,
                "device": self.hub_id,
                "name": "Kitchen hub",
                "ready": self.ready,
            }
        )

    async def get_members(self, request: web.Request) -> web.Response:
        return web.json_response(
            {
                "hub": {
                    "device": self.hub_id,
                    "name": "Kitchen hub",
                    "version": "0.1.0",
                },
                "family": {
                    "id": "FKQ2M4X7B3N5C6TW",
                    "name": "The Kotvas",
                    "timezone": "America/Chicago",
                    "week_start": 0,
                    "points_enabled": self.points_enabled,
                },
                "token": {
                    "label": "Home Assistant",
                    "member": None,
                    "scopes": self.scopes,
                    "expires": None,
                    "expires_ms": None,
                },
                "members": self.members,
                "categories": [],
            }
        )

    async def get_events(self, request: web.Request) -> web.Response:
        q = request.query
        start = _parse_when(q["start"])
        end = _parse_when(q["end"])
        start_ms, end_ms = int(start.timestamp() * 1000), int(end.timestamp() * 1000)
        member = q.get("member")
        everyone = q.get("include_everyone") == "true"
        out = []
        for occ in sorted(self.events, key=lambda o: o["start_ms"]):
            if not (occ["start_ms"] < end_ms and occ["end_ms"] > start_ms):
                continue
            if (
                member
                and member not in occ["assignees"]
                and not (everyone and not occ["assignees"])
            ):
                continue
            out.append(occ)
        return web.json_response(
            {
                **_instant("start", start),
                **_instant("end", end),
                "timezone": "America/Chicago",
                "truncated": False,
                "events": out,
            }
        )

    async def post_event(self, request: web.Request) -> web.Response:
        body = request["body"]
        event_id = f"E9NEW{next(self._ids):011d}"
        if body.get("all_day"):
            start = _parse_when(body["start"])
            end = _parse_when(body["end"])
            occ = self.occurrence(
                event_id,
                body["title"],
                start,
                end,
                assignees=body.get("assignees"),
                all_day=True,
                start_date=body["start"],
                end_date=body["end"],
            )
        else:
            start = _parse_when(body["start"])
            end = _parse_when(body.get("end") or body["start"])
            occ = self.occurrence(
                event_id,
                body["title"],
                start,
                end,
                assignees=body.get("assignees"),
                rrule=body.get("rrule"),
            )
        self.events.append(occ)
        event = {
            k: v
            for k, v in occ.items()
            if k not in ("uid", "event_id", "occurrence", "recurring", "edited")
        }
        return web.json_response({"event": {"id": event_id, **event}}, status=201)

    async def patch_event(self, request: web.Request) -> web.Response:
        event_id = request.match_info["id"]
        matches = [o for o in self.events if o["event_id"] == event_id]
        if not matches:
            return _error(404, "not_found", "No such event.", type="event", id=event_id)
        if matches[0]["read_only"]:
            return _error(
                409, "read_only", "This event comes from a subscribed calendar."
            )
        body = request["body"]
        for occ in matches:
            if "title" in body:
                occ["title"] = body["title"]
        return web.json_response({"ok": True})

    async def delete_event(self, request: web.Request) -> web.Response:
        event_id = request.match_info["id"]
        matches = [o for o in self.events if o["event_id"] == event_id]
        if not matches:
            return _error(404, "not_found", "No such event.", type="event", id=event_id)
        if matches[0]["read_only"]:
            return _error(
                409, "read_only", "This event comes from a subscribed calendar."
            )
        if request.query.get("scope", "all") == "all":
            self.events = [o for o in self.events if o["event_id"] != event_id]
        return web.json_response({"ok": True})

    async def get_chores(self, request: web.Request) -> web.Response:
        day = request.query.get("date") or self.chore_date
        chores = [c for c in self.chores if c["date"] == day]
        return web.json_response(
            {"date": day, "timezone": "America/Chicago", "chores": chores}
        )

    async def complete_chore(self, request: web.Request) -> web.Response:
        chore = self.find_chore(request.match_info["id"])
        if chore is None:
            return _error(404, "not_found", "No such chore.")
        body = request["body"] or {}
        chore["done"] = body.get("done", True)
        chore["done_by"] = body.get("member") if chore["done"] else None
        for step in chore["steps"]:
            step["checked"] = chore["done"]
        chore["steps_done"] = sum(1 for s in chore["steps"] if s["checked"])
        return web.json_response({"chore": chore})

    async def check_step(self, request: web.Request) -> web.Response:
        chore = self.find_chore(request.match_info["id"])
        step = (
            next(
                (s for s in chore["steps"] if s["id"] == request.match_info["step"]),
                None,
            )
            if chore
            else None
        )
        if chore is None or step is None:
            return _error(404, "not_found", "No such chore or step.")
        body = request["body"] or {}
        step["checked"] = body.get("checked", True)
        step["checked_by"] = body.get("member") if step["checked"] else None
        chore["steps_done"] = sum(1 for s in chore["steps"] if s["checked"])
        chore["done"] = chore["steps_done"] == len(chore["steps"])
        return web.json_response({"chore": chore})

    async def get_lists(self, request: web.Request) -> web.Response:
        return web.json_response(
            {"lists": [self.list_view(lst) for lst in self.lists], "stores": ["Costco"]}
        )

    async def post_item(self, request: web.Request) -> web.Response:
        lst = next((x for x in self.lists if x["id"] == request.match_info["id"]), None)
        if lst is None:
            return _error(404, "not_found", "No such list.")
        body = request["body"]
        if not body.get("text"):
            return _error(400, "invalid_input", "Items need text.", field="text")
        item = {
            "id": f"I9NEW{next(self._ids):011d}",
            "list": lst["id"],
            "text": body["text"],
            "qty": body.get("qty"),
            "store": body.get("store"),
            "checked": False,
            "checked_by": None,
            "order": "z",
            "to_groceries": False,
        }
        lst["items"].append(item)
        return web.json_response({"item": item}, status=201)

    async def patch_item(self, request: web.Request) -> web.Response:
        found = self.find_item(request.match_info["id"])
        if found is None:
            return _error(404, "not_found", "No such item.")
        lst, item = found
        body = request["body"]
        for key in ("text", "qty", "store"):
            if key in body:
                item[key] = body[key]
        if "checked" in body:
            item["checked"] = body["checked"]
            item["checked_by"] = None
        if move := body.get("move"):
            lst["items"].remove(item)
            after = move.get("after")
            index = (
                0
                if after is None
                else next(i for i, x in enumerate(lst["items"]) if x["id"] == after) + 1
            )
            lst["items"].insert(index, item)
        return web.json_response({"item": item})

    async def delete_item(self, request: web.Request) -> web.Response:
        found = self.find_item(request.match_info["id"])
        if found is None:
            return _error(404, "not_found", "No such item.")
        lst, item = found
        lst["items"].remove(item)
        return web.json_response({"ok": True})

    async def get_points(self, request: web.Request) -> web.Response:
        return web.json_response(
            {
                "enabled": self.points_enabled,
                "totals": self.totals,
                "goals": [],
                "recent": [],
                "rewards": [],
                "pending": [],
            }
        )

    async def adjust_points(self, request: web.Request) -> web.Response:
        body = request["body"]
        if not body.get("delta"):
            return _error(400, "invalid_input", "delta can't be zero.", field="delta")
        self.totals[body["member"]] = self.totals.get(body["member"], 0) + body["delta"]
        return web.json_response(
            {
                "adjustment": {
                    "id": "A2ADJUST5QK4MXN3",
                    "member": body["member"],
                    "delta": body["delta"],
                    "reason": body["reason"],
                    "by": None,
                },
                "balance": self.totals[body["member"]],
            },
            status=201,
        )

    async def stream(self, request: web.Request) -> web.StreamResponse:
        response = web.StreamResponse(
            headers={
                "Content-Type": "text/event-stream; charset=utf-8",
                "Cache-Control": "no-cache",
            }
        )
        await response.prepare(request)
        queue: asyncio.Queue[str | None] = asyncio.Queue()
        self.streams.append(queue)
        try:
            await response.write(b"retry: 5000\n\n")
            hello = {
                "hub": HUB_ID,
                "version": "0.1.0",
                **_instant("time", datetime.now(UTC)),
            }
            await response.write(
                f"event: hello\ndata: {json.dumps(hello)}\n\n".encode()
            )
            await response.write(b": ping\n\n")
            while (frame := await queue.get()) is not None:
                await response.write(frame.encode())
        finally:
            self.streams.remove(queue)
        return response
