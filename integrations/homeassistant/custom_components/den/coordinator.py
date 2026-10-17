"""Coordinator for the Den integration: one hub, one token, live updates from the event stream."""

from __future__ import annotations

import asyncio
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import datetime, time, timedelta, tzinfo
from functools import partial
import logging
from typing import Any

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import CALLBACK_TYPE, HomeAssistant, callback
from homeassistant.exceptions import ConfigEntryAuthFailed
from homeassistant.helpers.event import async_call_later, async_track_point_in_utc_time
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed
from homeassistant.util import dt as dt_util

from .api import DenAuthError, DenClient, DenError, DenStreamListener
from .const import (
    ALL_SECTIONS,
    DOMAIN,
    EVENT_CHORE_COMPLETED,
    EVENT_EVENT_STARTING,
    EVENT_ITEM_CHECKED,
    EVENTS_AHEAD,
    EVENTS_PAST,
    OPT_EVERYONE_ON_MEMBER_CALENDARS,
    OPT_HIDDEN_LISTS,
    OPT_HIDDEN_MEMBERS,
    POLL_WHILE_STREAMING,
    POLL_WITHOUT_STREAM,
    SECTION_CHORES,
    SECTION_EVENTS,
    SECTION_LISTS,
    SECTION_MEMBERS,
    SECTION_POINTS,
    STARTING_HORIZON,
    STREAM_DEBOUNCE_SECONDS,
    TYPE_SECTIONS,
)
from .models import (
    ChoreDay,
    ChoresDay,
    DenList,
    Directory,
    Member,
    Occurrence,
    Points,
    StreamMessage,
)

_LOGGER = logging.getLogger(__name__)

type DenConfigEntry = ConfigEntry[DenCoordinator]


@dataclass(frozen=True, slots=True)
class DenData:
    """Everything the entities show, as last fetched from the hub."""

    directory: Directory
    chores: ChoresDay
    events: tuple[Occurrence, ...]
    lists: tuple[DenList, ...]
    points: Points | None

    def get_list(self, list_id: str) -> DenList | None:
        """The list with this id."""
        return next((lst for lst in self.lists if lst.id == list_id), None)

    def chores_for(self, member_id: str) -> list[ChoreDay]:
        """Today's chores that belong to a member (not "anyone" chores)."""
        return [c for c in self.chores.chores if c.owner == member_id]


def family_zone(directory: Directory) -> tzinfo:
    """The family's time zone (Home Assistant's own if the hub names one we don't know)."""
    return (
        dt_util.get_time_zone(directory.family.timezone)
        or dt_util.get_default_time_zone()
    )


class DenCoordinator(DataUpdateCoordinator[DenData]):
    """Fetches from one hub and refetches what changed when the hub's stream says so."""

    config_entry: DenConfigEntry

    def __init__(
        self, hass: HomeAssistant, entry: DenConfigEntry, client: DenClient
    ) -> None:
        super().__init__(
            hass,
            _LOGGER,
            config_entry=entry,
            name=DOMAIN,
            update_interval=POLL_WITHOUT_STREAM,
        )
        self.client = client
        self.listener = DenStreamListener(
            client,
            on_message=self._on_stream_message,
            on_connect=self._on_stream_connect,
            on_disconnect=self._on_stream_disconnect,
            on_auth_error=self._on_stream_auth_error,
        )
        self.last_stream_event: datetime | None = None
        self._lock = asyncio.Lock()
        self._pending: set[str] = set()
        self._unsub_debounce: CALLBACK_TYPE | None = None
        self._unsub_midnight: CALLBACK_TYPE | None = None
        self._starting_timers: dict[tuple[str, int, int], CALLBACK_TYPE] = {}
        self._fired: dict[tuple[str, int, int], datetime] = {}
        self._previous: DenData | None = None

    # ------------------------------------------------------------------ helpers for entities

    @property
    def hub_id(self) -> str:
        """Prefix for unique ids and device identifiers: the hub's device id."""
        return self.config_entry.unique_id or self.config_entry.entry_id

    @property
    def time_zone(self) -> tzinfo:
        """The family's time zone."""
        return family_zone(self.data.directory)

    def today(self) -> str:
        """Today's local date in the family's time zone."""
        return dt_util.now(self.time_zone).date().isoformat()

    def can(self, scope: str) -> bool:
        """Whether the token carries a scope."""
        return self.data is not None and self.data.directory.token.has(scope)

    @property
    def exposed_members(self) -> list[Member]:
        """Members the options say to make entities for."""
        hidden = set(self.config_entry.options.get(OPT_HIDDEN_MEMBERS, ()))
        return [m for m in self.data.directory.members if m.id not in hidden]

    @property
    def exposed_lists(self) -> list[DenList]:
        """Lists the options say to make to-do entities for."""
        hidden = set(self.config_entry.options.get(OPT_HIDDEN_LISTS, ()))
        return [lst for lst in self.data.lists if lst.id not in hidden]

    @property
    def everyone_on_member_calendars(self) -> bool:
        """Whether family-wide events also show on each person's calendar."""
        return bool(
            self.config_entry.options.get(OPT_EVERYONE_ON_MEMBER_CALENDARS, False)
        )

    @property
    def streaming(self) -> bool:
        """Whether the event stream is connected."""
        return self.listener.connected

    # ------------------------------------------------------------------ fetching

    async def _async_update_data(self) -> DenData:
        async with self._lock:
            try:
                return await self._fetch(ALL_SECTIONS, self.data)
            except DenAuthError as err:
                raise ConfigEntryAuthFailed(
                    translation_domain=DOMAIN, translation_key="invalid_auth"
                ) from err
            except DenError as err:
                raise UpdateFailed(
                    translation_domain=DOMAIN,
                    translation_key="update_failed",
                    translation_placeholders={"error": err.message},
                ) from err

    async def _fetch(self, sections: Iterable[str], current: DenData | None) -> DenData:
        wanted = set(sections)
        if current is None or SECTION_MEMBERS in wanted:
            directory = await self.client.members()
            wanted = set(ALL_SECTIONS)
        else:
            directory = current.directory
        now = dt_util.utcnow()
        calls: dict[str, Any] = {}
        if SECTION_CHORES in wanted:
            calls[SECTION_CHORES] = self.client.chores(
                now.astimezone(family_zone(directory)).date()
            )
        if SECTION_EVENTS in wanted:
            calls[SECTION_EVENTS] = self.client.events(
                now - EVENTS_PAST, now + EVENTS_AHEAD
            )
        if SECTION_LISTS in wanted:
            calls[SECTION_LISTS] = self.client.lists()
        if SECTION_POINTS in wanted and directory.family.points_enabled:
            calls[SECTION_POINTS] = self.client.points()
        results = await asyncio.gather(*calls.values(), return_exceptions=True)
        errors = [r for r in results if isinstance(r, BaseException)]
        if errors:
            raise next((e for e in errors if isinstance(e, DenAuthError)), errors[0])
        got = dict(zip(calls, results, strict=True))

        chores = got[SECTION_CHORES] if SECTION_CHORES in got else current.chores  # type: ignore[union-attr]
        events = got[SECTION_EVENTS].events if SECTION_EVENTS in got else current.events  # type: ignore[union-attr]
        lists = tuple(got[SECTION_LISTS]) if SECTION_LISTS in got else current.lists  # type: ignore[union-attr]
        if not directory.family.points_enabled:
            points = None
        elif SECTION_POINTS in got:
            points = got[SECTION_POINTS]
        else:
            points = current.points if current else None
        return DenData(
            directory=directory,
            chores=chores,
            events=events,
            lists=lists,
            points=points,
        )

    async def async_refresh_sections(self, sections: Iterable[str]) -> None:
        """Refetch only some parts (after a write, or when the stream says what changed)."""
        wanted = set(sections)
        if not wanted:
            return
        if self.data is None:
            await self.async_refresh()
            return
        async with self._lock:
            try:
                data = await self._fetch(wanted, self.data)
            except DenAuthError:
                self.config_entry.async_start_reauth(self.hass)
                return
            except DenError as err:
                _LOGGER.debug(
                    "Partial refresh of %s failed: %s", sorted(wanted), err.message
                )
                data = None
        if data is None:
            # Let the regular path record the failure and mark entities unavailable.
            await self.async_refresh()
            return
        self.async_set_updated_data(data)

    # ------------------------------------------------------------------ the event stream

    @callback
    def async_start_stream(self) -> None:
        """Keep the hub's event stream open for as long as the entry is loaded."""
        self.config_entry.async_create_background_task(
            self.hass, self.listener.run(), name=f"{DOMAIN} stream {self.hub_id}"
        )

    @callback
    def _on_stream_connect(self) -> None:
        self.update_interval = POLL_WHILE_STREAMING
        # The hub doesn't replay what happened while we were away: refetch everything.
        self._queue(ALL_SECTIONS)

    @callback
    def _on_stream_disconnect(self) -> None:
        self.update_interval = POLL_WITHOUT_STREAM
        if self._listeners:
            self._schedule_refresh()

    @callback
    def _on_stream_auth_error(self, err: DenAuthError) -> None:
        _LOGGER.debug("Den stream rejected the token: %s", err.message)
        self.config_entry.async_start_reauth(self.hass)

    @callback
    def _on_stream_message(self, message: StreamMessage) -> None:
        self.last_stream_event = dt_util.utcnow()
        if message.event != "changed":
            return
        types = message.data.get("types") if isinstance(message.data, dict) else None
        if not isinstance(types, list):
            self._queue(ALL_SECTIONS)
            return
        sections: set[str] = set()
        for record_type in types:
            sections |= TYPE_SECTIONS.get(record_type, frozenset())
        self._queue(sections)

    @callback
    def _queue(self, sections: Iterable[str]) -> None:
        self._pending |= set(sections)
        if self._pending and self._unsub_debounce is None:
            self._unsub_debounce = async_call_later(
                self.hass, STREAM_DEBOUNCE_SECONDS, self._flush_queue
            )

    @callback
    def _flush_queue(self, _now: datetime) -> None:
        self._unsub_debounce = None
        sections, self._pending = self._pending, set()
        self.config_entry.async_create_task(
            self.hass, self.async_refresh_sections(sections), name=f"{DOMAIN} refresh"
        )

    # ------------------------------------------------------------------ after every update

    @callback
    def async_update_listeners(self) -> None:
        """Update entities, then fire bus events for what changed and re-arm timers."""
        super().async_update_listeners()
        data = self.data
        if data is None:
            return
        previous, self._previous = self._previous, data
        if previous is not None and previous is not data:
            self._fire_change_events(previous, data)
        self._arm_starting_timers(data)
        self._arm_midnight(data)

    def _fire_change_events(self, old: DenData, new: DenData) -> None:
        directory = new.directory
        entry_id = self.config_entry.entry_id
        if old.chores.date == new.chores.date:
            before = {c.completion_id: c for c in old.chores.chores}
            left_total = sum(1 for c in new.chores.chores if not c.done)
            for chore in new.chores.chores:
                prior = before.get(chore.completion_id)
                if prior is None or prior.done or not chore.done:
                    continue
                owner_left = (
                    sum(1 for c in new.chores_for(chore.owner) if not c.done)
                    if chore.owner
                    else None
                )
                self.hass.bus.async_fire(
                    EVENT_CHORE_COMPLETED,
                    {
                        "config_entry_id": entry_id,
                        "chore_id": chore.id,
                        "title": chore.title,
                        "date": chore.date,
                        "done_by_id": chore.done_by,
                        "done_by": directory.member_name(chore.done_by),
                        "owner_id": chore.owner,
                        "owner": directory.member_name(chore.owner),
                        "points": chore.points_available,
                        "owner_chores_left": owner_left,
                        "chores_left": left_total,
                    },
                )
        before_items = {item.id: item for lst in old.lists for item in lst.items}
        for lst in new.lists:
            for item in lst.items:
                prior_item = before_items.get(item.id)
                if prior_item is None or prior_item.checked or not item.checked:
                    continue
                self.hass.bus.async_fire(
                    EVENT_ITEM_CHECKED,
                    {
                        "config_entry_id": entry_id,
                        "item_id": item.id,
                        "text": item.text,
                        "qty": item.qty,
                        "store": item.store,
                        "list_id": lst.id,
                        "list": lst.title,
                        "checked_by_id": item.checked_by,
                        "checked_by": directory.member_name(item.checked_by),
                        "list_open": lst.open,
                    },
                )

    def _arm_starting_timers(self, data: DenData) -> None:
        """Arm `den_event_starting` at each event's start and at each of its reminders.

        All-day events fire only for their reminders, not at midnight.
        """
        for unsub in self._starting_timers.values():
            unsub()
        self._starting_timers.clear()
        now = dt_util.utcnow()
        self._fired = {
            k: t for k, t in self._fired.items() if t > now - timedelta(days=1)
        }
        horizon = now + STARTING_HORIZON
        for occ in data.events:
            leads = {lead for lead in occ.reminders if lead > 0}
            if not occ.all_day:
                leads.add(0)
            start_ms = int(occ.start.timestamp() * 1000)
            for lead in leads:
                at = occ.start - timedelta(minutes=lead)
                key = (occ.uid, start_ms, lead)
                if key in self._fired or not now < at <= horizon:
                    continue
                self._starting_timers[key] = async_track_point_in_utc_time(
                    self.hass, partial(self._fire_starting, key, occ, lead), at
                )

    @callback
    def _fire_starting(
        self, key: tuple[str, int, int], occ: Occurrence, lead: int, now: datetime
    ) -> None:
        self._starting_timers.pop(key, None)
        if key in self._fired:
            return
        self._fired[key] = now
        directory = self.data.directory
        zone = self.time_zone
        self.hass.bus.async_fire(
            EVENT_EVENT_STARTING,
            {
                "config_entry_id": self.config_entry.entry_id,
                "uid": occ.uid,
                "event_id": occ.event_id,
                "occurrence": occ.occurrence,
                "title": occ.title,
                "location": occ.location,
                "notes": occ.notes,
                "start": occ.start.astimezone(zone).isoformat(),
                "end": occ.end.astimezone(zone).isoformat(),
                "all_day": occ.all_day,
                "minutes_before": lead,
                "for_everyone": occ.for_everyone,
                "assignee_ids": list(occ.assignees),
                "assignees": [
                    name
                    for a in occ.assignees
                    if (name := directory.member_name(a)) is not None
                ],
            },
        )

    def _arm_midnight(self, data: DenData) -> None:
        """Refetch just after the family's midnight, when "today" moves on."""
        if self._unsub_midnight:
            self._unsub_midnight()
        zone = family_zone(data.directory)
        tomorrow = dt_util.now(zone).date() + timedelta(days=1)
        at = datetime.combine(tomorrow, time(0, 0, 5), zone)
        self._unsub_midnight = async_track_point_in_utc_time(
            self.hass, self._midnight, dt_util.as_utc(at)
        )

    @callback
    def _midnight(self, _now: datetime) -> None:
        self._unsub_midnight = None
        self.config_entry.async_create_task(
            self.hass,
            self.async_refresh_sections({SECTION_CHORES, SECTION_EVENTS}),
            name=f"{DOMAIN} midnight refresh",
        )

    async def async_shutdown(self) -> None:
        """Cancel timers along with the coordinator's own."""
        await super().async_shutdown()
        if self._unsub_debounce:
            self._unsub_debounce()
            self._unsub_debounce = None
        if self._unsub_midnight:
            self._unsub_midnight()
            self._unsub_midnight = None
        for unsub in self._starting_timers.values():
            unsub()
        self._starting_timers.clear()
