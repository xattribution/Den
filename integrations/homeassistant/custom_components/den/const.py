"""Constants for the Den integration."""

from __future__ import annotations

from datetime import timedelta
from typing import Final

DOMAIN: Final = "den"

DEFAULT_PORT: Final = 47733
ZEROCONF_TYPE: Final = "_den._tcp.local."

# Options. Members and lists are stored as the ones to hide, so anything added in Den later shows
# up in Home Assistant without another trip through the options.
OPT_HIDDEN_MEMBERS: Final = "hidden_members"
OPT_HIDDEN_LISTS: Final = "hidden_lists"
OPT_EVERYONE_ON_MEMBER_CALENDARS: Final = "everyone_on_member_calendars"

# Form fields of the options flow (the inverse of the stored options above).
FIELD_MEMBERS: Final = "members"
FIELD_LISTS: Final = "lists"

# Token scopes (see docs/hub-api.md, "Scopes").
SCOPE_READ: Final = "read"
SCOPE_CALENDAR: Final = "calendar"
SCOPE_CHORES: Final = "chores"
SCOPE_LISTS: Final = "lists"
SCOPE_POINTS: Final = "points"
SCOPE_ADMIN: Final = "admin"

# Events fired on the Home Assistant bus.
EVENT_CHORE_COMPLETED: Final = "den_chore_completed"
EVENT_ITEM_CHECKED: Final = "den_item_checked"
EVENT_EVENT_STARTING: Final = "den_event_starting"

# Parts of the coordinator's data, refreshed separately when the hub says what changed.
SECTION_MEMBERS: Final = "members"
SECTION_EVENTS: Final = "events"
SECTION_CHORES: Final = "chores"
SECTION_LISTS: Final = "lists"
SECTION_POINTS: Final = "points"
ALL_SECTIONS: Final = frozenset(
    {SECTION_MEMBERS, SECTION_EVENTS, SECTION_CHORES, SECTION_LISTS, SECTION_POINTS}
)

# Record types from the hub's `changed` stream events, mapped to what to refetch.
TYPE_SECTIONS: Final[dict[str, frozenset[str]]] = {
    "event": frozenset({SECTION_EVENTS}),
    "eventException": frozenset({SECTION_EVENTS}),
    "category": frozenset({SECTION_EVENTS}),
    "chore": frozenset({SECTION_CHORES, SECTION_POINTS}),
    "completion": frozenset({SECTION_CHORES, SECTION_POINTS}),
    "adjustment": frozenset({SECTION_POINTS}),
    "goal": frozenset({SECTION_POINTS}),
    "reward": frozenset({SECTION_POINTS}),
    "redemption": frozenset({SECTION_POINTS}),
    "list": frozenset({SECTION_LISTS}),
    "item": frozenset({SECTION_LISTS}),
    "member": ALL_SECTIONS,
    "family": ALL_SECTIONS,
}

# How much of the calendar the coordinator keeps for current and next events and for
# `den_event_starting`. Calendar views ask the hub directly for whatever range they show.
EVENTS_PAST: Final = timedelta(days=1)
EVENTS_AHEAD: Final = timedelta(days=30)

# `den_event_starting` timers are only armed this far ahead; refreshes re-arm them.
STARTING_HORIZON: Final = timedelta(hours=36)

# Polling is only a fallback: the event stream drives updates.
POLL_WHILE_STREAMING: Final = timedelta(minutes=30)
POLL_WITHOUT_STREAM: Final = timedelta(minutes=5)

# Coalesce bursts of `changed` events (a sync of many changes) into one refetch.
STREAM_DEBOUNCE_SECONDS: Final = 0.3

ATTR_CONFIG_ENTRY_ID: Final = "config_entry_id"
