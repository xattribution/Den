"""Typed views of the Den hub API's JSON (docs/hub-api.md).

Pure Python with no Home Assistant imports, so the client can be tested on its own. Parsing is
lenient: a missing optional field takes its documented default instead of failing.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import UTC, date, datetime
from typing import Any

type Json = Mapping[str, Any]


def parse_instant(obj: Json, name: str) -> datetime | None:
    """Read an instant written as `<name>` (ISO 8601) and `<name>_ms` (UTC milliseconds)."""
    millis = obj.get(f"{name}_ms")
    if isinstance(millis, int | float) and not isinstance(millis, bool):
        return datetime.fromtimestamp(millis / 1000, UTC)
    text = obj.get(name)
    if isinstance(text, str) and text:
        try:
            parsed = datetime.fromisoformat(text)
        except ValueError:
            return None
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)
    return None


def parse_date(value: Any) -> date | None:
    """Read a local date (`YYYY-MM-DD`)."""
    if isinstance(value, str) and value:
        try:
            return date.fromisoformat(value)
        except ValueError:
            return None
    return None


def _str(obj: Json, key: str, default: str = "") -> str:
    value = obj.get(key)
    return value if isinstance(value, str) else default


def _opt_str(obj: Json, key: str) -> str | None:
    value = obj.get(key)
    return value if isinstance(value, str) else None


def _int(obj: Json, key: str, default: int = 0) -> int:
    value = obj.get(key)
    if isinstance(value, bool) or not isinstance(value, int | float):
        return default
    return int(value)


def _bool(obj: Json, key: str, default: bool = False) -> bool:
    value = obj.get(key)
    return value if isinstance(value, bool) else default


def _strs(obj: Json, key: str) -> tuple[str, ...]:
    value = obj.get(key)
    return (
        tuple(v for v in value if isinstance(v, str)) if isinstance(value, list) else ()
    )


def _ints(obj: Json, key: str) -> tuple[int, ...]:
    value = obj.get(key)
    if not isinstance(value, list):
        return ()
    return tuple(
        int(v) for v in value if isinstance(v, int | float) and not isinstance(v, bool)
    )


def _objs(obj: Json, key: str) -> list[Json]:
    value = obj.get(key)
    return (
        [v for v in value if isinstance(v, Mapping)] if isinstance(value, list) else []
    )


def _obj(obj: Json, key: str) -> Json:
    value = obj.get(key)
    return value if isinstance(value, Mapping) else {}


@dataclass(frozen=True, slots=True)
class Health:
    """`GET /health`."""

    ok: bool
    version: str
    api: int
    device: str | None
    name: str
    ready: bool

    @classmethod
    def from_json(cls, obj: Json) -> Health:
        return cls(
            ok=_bool(obj, "ok"),
            version=_str(obj, "version"),
            api=_int(obj, "api", 1),
            device=_opt_str(obj, "device"),
            name=_str(obj, "name", "Den hub"),
            ready=_bool(obj, "ready", True),
        )


@dataclass(frozen=True, slots=True)
class HubInfo:
    """Which hub answered."""

    device: str
    name: str
    version: str

    @classmethod
    def from_json(cls, obj: Json) -> HubInfo:
        return cls(
            device=_str(obj, "device"),
            name=_str(obj, "name", "Den hub"),
            version=_str(obj, "version"),
        )


@dataclass(frozen=True, slots=True)
class Family:
    """The family's settings that matter to clients."""

    id: str
    name: str
    timezone: str
    week_start: int
    points_enabled: bool

    @classmethod
    def from_json(cls, obj: Json) -> Family:
        return cls(
            id=_str(obj, "id"),
            name=_str(obj, "name", "Den"),
            timezone=_str(obj, "timezone", "UTC"),
            week_start=_int(obj, "week_start"),
            points_enabled=_bool(obj, "points_enabled", True),
        )


@dataclass(frozen=True, slots=True)
class TokenInfo:
    """What the calling token is and may do."""

    label: str
    member: str | None
    scopes: frozenset[str]
    expires: datetime | None

    def has(self, scope: str) -> bool:
        """Whether the token carries a scope (`admin` implies every scope)."""
        return scope in self.scopes or "admin" in self.scopes

    @classmethod
    def from_json(cls, obj: Json) -> TokenInfo:
        return cls(
            label=_str(obj, "label"),
            member=_opt_str(obj, "member"),
            scopes=frozenset(_strs(obj, "scopes")),
            expires=parse_instant(obj, "expires"),
        )


@dataclass(frozen=True, slots=True)
class Member:
    """A family member."""

    id: str
    name: str
    role: str
    tier: str | None
    marker: str
    animal: str
    birthday: date | None
    grants: tuple[str, ...]
    order: int

    @classmethod
    def from_json(cls, obj: Json) -> Member:
        return cls(
            id=_str(obj, "id"),
            name=_str(obj, "name"),
            role=_str(obj, "role", "kid"),
            tier=_opt_str(obj, "tier"),
            marker=_str(obj, "marker", "slate"),
            animal=_str(obj, "animal", "cat"),
            birthday=parse_date(obj.get("birthday")),
            grants=_strs(obj, "grants"),
            order=_int(obj, "order"),
        )


@dataclass(frozen=True, slots=True)
class Category:
    """An event category."""

    id: str
    name: str
    icon: str

    @classmethod
    def from_json(cls, obj: Json) -> Category:
        return cls(id=_str(obj, "id"), name=_str(obj, "name"), icon=_str(obj, "icon"))


@dataclass(frozen=True, slots=True)
class Directory:
    """`GET /api/v1/members`: hub, family, token, members and categories."""

    hub: HubInfo
    family: Family
    token: TokenInfo
    members: tuple[Member, ...]
    categories: tuple[Category, ...] = ()

    def member(self, member_id: str | None) -> Member | None:
        """The member with this id."""
        if member_id is None:
            return None
        return next((m for m in self.members if m.id == member_id), None)

    def member_name(self, member_id: str | None) -> str | None:
        """The member's name, or None."""
        member = self.member(member_id)
        return member.name if member else None

    @classmethod
    def from_json(cls, obj: Json) -> Directory:
        return cls(
            hub=HubInfo.from_json(_obj(obj, "hub")),
            family=Family.from_json(_obj(obj, "family")),
            token=TokenInfo.from_json(_obj(obj, "token")),
            members=tuple(
                sorted(
                    (Member.from_json(m) for m in _objs(obj, "members")),
                    key=lambda m: m.order,
                )
            ),
            categories=tuple(Category.from_json(c) for c in _objs(obj, "categories")),
        )


@dataclass(frozen=True, slots=True)
class Occurrence:
    """One occurrence of an event in a window, exceptions applied."""

    uid: str
    event_id: str
    occurrence: int
    recurring: bool
    edited: bool
    title: str
    notes: str
    location: str
    category: str | None
    all_day: bool
    start: datetime
    end: datetime
    start_date: date | None
    end_date: date | None
    tz: str
    rrule: str | None
    assignees: tuple[str, ...]
    reminders: tuple[int, ...]
    read_only: bool
    space: str

    @property
    def for_everyone(self) -> bool:
        """No one in particular is assigned: it's for the whole family."""
        return not self.assignees

    @classmethod
    def from_json(cls, obj: Json) -> Occurrence:
        start = parse_instant(obj, "start") or datetime.fromtimestamp(0, UTC)
        end = parse_instant(obj, "end") or start
        event_id = _str(obj, "event_id") or _str(obj, "id")
        occurrence = _int(obj, "occurrence", int(start.timestamp() * 1000))
        return cls(
            uid=_str(obj, "uid") or f"{event_id}@{occurrence}",
            event_id=event_id,
            occurrence=occurrence,
            recurring=_bool(obj, "recurring", obj.get("rrule") is not None),
            edited=_bool(obj, "edited"),
            title=_str(obj, "title"),
            notes=_str(obj, "notes"),
            location=_str(obj, "location"),
            category=_opt_str(obj, "category"),
            all_day=_bool(obj, "all_day"),
            start=start,
            end=max(end, start),
            start_date=parse_date(obj.get("start_date")),
            end_date=parse_date(obj.get("end_date")),
            tz=_str(obj, "tz", "UTC"),
            rrule=_opt_str(obj, "rrule"),
            assignees=_strs(obj, "assignees"),
            reminders=_ints(obj, "reminders"),
            read_only=_bool(obj, "read_only"),
            space=_str(obj, "space", "f"),
        )


@dataclass(frozen=True, slots=True)
class EventsWindow:
    """`GET /api/v1/events`."""

    start: datetime | None
    end: datetime | None
    events: tuple[Occurrence, ...]
    truncated: bool

    @classmethod
    def from_json(cls, obj: Json) -> EventsWindow:
        return cls(
            start=parse_instant(obj, "start"),
            end=parse_instant(obj, "end"),
            events=tuple(Occurrence.from_json(e) for e in _objs(obj, "events")),
            truncated=_bool(obj, "truncated"),
        )


@dataclass(frozen=True, slots=True)
class ChoreStep:
    """One step of a chore on a day."""

    id: str
    text: str
    owner: str | None
    points: int
    checked: bool
    checked_by: str | None

    @classmethod
    def from_json(cls, obj: Json) -> ChoreStep:
        return cls(
            id=_str(obj, "id"),
            text=_str(obj, "text"),
            owner=_opt_str(obj, "owner"),
            points=_int(obj, "points"),
            checked=_bool(obj, "checked"),
            checked_by=_opt_str(obj, "checked_by"),
        )


@dataclass(frozen=True, slots=True)
class ChoreDay:
    """A chore as it stands on one local date."""

    id: str
    completion_id: str
    date: str
    title: str
    notes: str
    icon: str
    owner: str | None
    done: bool
    done_by: str | None
    late: bool
    points: int
    points_available: int
    due: datetime | None
    recurring: bool
    steps: tuple[ChoreStep, ...] = field(default=())

    @classmethod
    def from_json(cls, obj: Json) -> ChoreDay:
        chore_id = _str(obj, "id")
        day = _str(obj, "date")
        return cls(
            id=chore_id,
            completion_id=_str(obj, "completion_id") or f"{chore_id}@{day}",
            date=day,
            title=_str(obj, "title"),
            notes=_str(obj, "notes"),
            icon=_str(obj, "icon", "check"),
            owner=_opt_str(obj, "owner"),
            done=_bool(obj, "done"),
            done_by=_opt_str(obj, "done_by"),
            late=_bool(obj, "late"),
            points=_int(obj, "points"),
            points_available=_int(obj, "points_available", _int(obj, "points")),
            due=parse_instant(obj, "due"),
            recurring=_bool(obj, "recurring"),
            steps=tuple(ChoreStep.from_json(s) for s in _objs(obj, "steps")),
        )


@dataclass(frozen=True, slots=True)
class ChoresDay:
    """`GET /api/v1/chores`."""

    date: str
    chores: tuple[ChoreDay, ...]

    @classmethod
    def from_json(cls, obj: Json) -> ChoresDay:
        return cls(
            date=_str(obj, "date"),
            chores=tuple(ChoreDay.from_json(c) for c in _objs(obj, "chores")),
        )


@dataclass(frozen=True, slots=True)
class Item:
    """An item on a list."""

    id: str
    list: str
    text: str
    qty: str | None
    store: str | None
    checked: bool
    checked_by: str | None
    order: str

    @classmethod
    def from_json(cls, obj: Json) -> Item:
        return cls(
            id=_str(obj, "id"),
            list=_str(obj, "list"),
            text=_str(obj, "text"),
            qty=_opt_str(obj, "qty") or None,
            store=_opt_str(obj, "store") or None,
            checked=_bool(obj, "checked"),
            checked_by=_opt_str(obj, "checked_by"),
            order=_str(obj, "order", "m"),
        )


@dataclass(frozen=True, slots=True)
class DenList:
    """A list with its items in display order."""

    id: str
    title: str
    icon: str
    kind: str
    lifecycle: str
    pinned: bool
    space: str
    items: tuple[Item, ...]

    @property
    def open(self) -> int:
        """Unchecked items."""
        return sum(1 for item in self.items if not item.checked)

    def item(self, item_id: str) -> Item | None:
        """The item with this id."""
        return next((i for i in self.items if i.id == item_id), None)

    @classmethod
    def from_json(cls, obj: Json) -> DenList:
        list_id = _str(obj, "id")
        return cls(
            id=list_id,
            title=_str(obj, "title"),
            icon=_str(obj, "icon", "list"),
            kind=_str(obj, "kind", "checklist"),
            lifecycle=_str(obj, "lifecycle", "running"),
            pinned=_bool(obj, "pinned"),
            space=_str(obj, "space", "f"),
            items=tuple(Item.from_json(i) for i in _objs(obj, "items")),
        )


@dataclass(frozen=True, slots=True)
class Points:
    """`GET /api/v1/points`, the part Home Assistant shows."""

    enabled: bool
    totals: Mapping[str, int]

    @classmethod
    def from_json(cls, obj: Json) -> Points:
        totals = _obj(obj, "totals")
        return cls(
            enabled=_bool(obj, "enabled", True),
            totals={
                k: int(v)
                for k, v in totals.items()
                if isinstance(v, int | float) and not isinstance(v, bool)
            },
        )


@dataclass(frozen=True, slots=True)
class StreamMessage:
    """One server-sent event from `/api/v1/stream`."""

    event: str
    data: Any
    id: str | None = None
