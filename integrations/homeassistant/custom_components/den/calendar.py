"""Den calendars: one for the family and one per member."""

from __future__ import annotations

from collections.abc import Mapping
from datetime import date, datetime, timedelta, tzinfo
from typing import Any

from homeassistant.components.calendar import (
    CalendarEntity,
    CalendarEntityFeature,
    CalendarEvent,
)
from homeassistant.components.calendar.const import (
    EVENT_DESCRIPTION,
    EVENT_END,
    EVENT_LOCATION,
    EVENT_RRULE,
    EVENT_START,
    EVENT_SUMMARY,
)
from homeassistant.core import HomeAssistant, callback
from homeassistant.exceptions import HomeAssistantError, ServiceValidationError
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback
from homeassistant.util import dt as dt_util

from .api import DenError, format_when
from .const import DOMAIN, SCOPE_CALENDAR, SECTION_EVENTS
from .coordinator import DenConfigEntry, DenCoordinator
from .entity import DenEntity, den_error, hub_device_info, member_device_info
from .models import Member, Occurrence

PARALLEL_UPDATES = 1

# The hub answers windows of at most 400 days.
MAX_WINDOW = timedelta(days=400)

RANGE_THIS_AND_FUTURE = "THISANDFUTURE"


async def async_setup_entry(
    hass: HomeAssistant,
    entry: DenConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    """Add the family calendar and a calendar per exposed member."""
    coordinator = entry.runtime_data
    known: set[str] = set()

    @callback
    def _sync() -> None:
        new: list[DenCalendar] = []
        if not known:
            known.add("")
            new.append(DenFamilyCalendar(coordinator))
        for member in coordinator.exposed_members:
            if member.id not in known:
                known.add(member.id)
                new.append(DenMemberCalendar(coordinator, member))
        if new:
            async_add_entities(new)

    _sync()
    entry.async_on_unload(coordinator.async_add_listener(_sync))


def to_calendar_event(occ: Occurrence, zone: tzinfo) -> CalendarEvent:
    """Map a Den occurrence to a Home Assistant calendar event.

    `uid` is the series id and `recurrence_id` the occurrence's original start in UTC ms, so
    edits and deletes from Home Assistant come back addressed the way the hub expects.
    """
    start: date | datetime
    end: date | datetime
    if occ.all_day:
        start = occ.start_date or occ.start.astimezone(zone).date()
        end = occ.end_date or occ.end.astimezone(zone).date()
        if end <= start:
            end = start + timedelta(days=1)
    else:
        start = occ.start.astimezone(zone)
        end = max(occ.end, occ.start).astimezone(zone)
    fields: dict[str, Any] = {
        "start": start,
        "end": end,
        "summary": occ.title,
        "description": occ.notes or None,
        "location": occ.location or None,
        "uid": occ.event_id,
        "recurrence_id": str(occ.occurrence) if occ.recurring else None,
        "rrule": occ.rrule if occ.recurring else None,
    }
    try:
        return CalendarEvent(**fields)
    except HomeAssistantError:
        # A rule Home Assistant's validator doesn't accept (an unusual FREQ): show the
        # occurrence without it rather than failing the whole calendar.
        fields["rrule"] = None
        return CalendarEvent(**fields)


def event_body(event: Mapping[str, Any], *, include_rrule: bool) -> dict[str, Any]:
    """Map Home Assistant's event fields to a Den `POST`/`PATCH /api/v1/events` body."""
    body: dict[str, Any] = {}
    if EVENT_SUMMARY in event:
        body["title"] = event[EVENT_SUMMARY]
    start = event.get(EVENT_START)
    end = event.get(EVENT_END)
    if start is not None:
        body["all_day"] = not isinstance(start, datetime)
        body["start"] = format_when(start)
        if end is not None:
            body["end"] = format_when(end)
    if EVENT_DESCRIPTION in event:
        body["notes"] = event[EVENT_DESCRIPTION] or ""
    if EVENT_LOCATION in event:
        body["location"] = event[EVENT_LOCATION] or ""
    if include_rrule:
        body["rrule"] = event.get(EVENT_RRULE) or None
    return body


def edit_scope(
    recurrence_id: str | None, recurrence_range: str | None
) -> tuple[str, int | None]:
    """Map Home Assistant's recurrence id and range to Den's `scope` and `occurrence`."""
    if not recurrence_id:
        return "all", None
    try:
        occurrence = int(recurrence_id)
    except ValueError as err:
        raise ServiceValidationError(
            translation_domain=DOMAIN,
            translation_key="invalid_recurrence_id",
            translation_placeholders={"recurrence_id": recurrence_id},
        ) from err
    if recurrence_range == RANGE_THIS_AND_FUTURE:
        return "following", occurrence
    return "one", occurrence


class DenCalendar(DenEntity, CalendarEntity):
    """A Den calendar."""

    _member_id: str | None = None

    def _includes(self, occ: Occurrence) -> bool:
        if self._member_id is None or self._member_id in occ.assignees:
            return True
        return occ.for_everyone and self.coordinator.everyone_on_member_calendars

    @property
    def supported_features(self) -> CalendarEntityFeature:
        """Writable when the token has the calendar scope."""
        if self.coordinator.can(SCOPE_CALENDAR):
            return (
                CalendarEntityFeature.CREATE_EVENT
                | CalendarEntityFeature.UPDATE_EVENT
                | CalendarEntityFeature.DELETE_EVENT
            )
        return CalendarEntityFeature(0)

    @property
    def event(self) -> CalendarEvent | None:
        """The event happening now, else the next one."""
        now = dt_util.utcnow()
        candidates = sorted(
            (
                o
                for o in self.coordinator.data.events
                if o.end > now and self._includes(o)
            ),
            key=lambda o: (o.start, o.title),
        )
        if not candidates:
            return None
        return to_calendar_event(candidates[0], self.coordinator.time_zone)

    async def async_get_events(
        self, hass: HomeAssistant, start_date: datetime, end_date: datetime
    ) -> list[CalendarEvent]:
        """Ask the hub for the occurrences in a window."""
        end_date = min(end_date, start_date + MAX_WINDOW)
        coordinator = self.coordinator
        try:
            window = await coordinator.client.events(
                start_date,
                end_date,
                member=self._member_id,
                include_everyone=coordinator.everyone_on_member_calendars,
            )
        except DenError as err:
            raise den_error(err) from err
        zone = coordinator.time_zone
        return [to_calendar_event(o, zone) for o in window.events if self._includes(o)]

    async def async_create_event(self, **kwargs: Any) -> None:
        """Add an event; on a member's calendar it's assigned to them."""
        body = event_body(kwargs, include_rrule=True)
        body["assignees"] = [self._member_id] if self._member_id else []
        await self._den_call(self.coordinator.client.create_event(body), SECTION_EVENTS)

    async def async_update_event(
        self,
        uid: str,
        event: dict[str, Any],
        recurrence_id: str | None = None,
        recurrence_range: str | None = None,
    ) -> None:
        """Change an event, one occurrence, or this and following."""
        scope, occurrence = edit_scope(recurrence_id, recurrence_range)
        body = event_body(event, include_rrule=scope != "one")
        await self._den_call(
            self.coordinator.client.update_event(
                uid, body, scope=scope, occurrence=occurrence
            ),
            SECTION_EVENTS,
        )

    async def async_delete_event(
        self,
        uid: str,
        recurrence_id: str | None = None,
        recurrence_range: str | None = None,
    ) -> None:
        """Delete an event, one occurrence, or this and following."""
        scope, occurrence = edit_scope(recurrence_id, recurrence_range)
        await self._den_call(
            self.coordinator.client.delete_event(
                uid, scope=scope, occurrence=occurrence
            ),
            SECTION_EVENTS,
        )


class DenFamilyCalendar(DenCalendar):
    """Every event the token can read."""

    _attr_translation_key = "family"

    def __init__(self, coordinator: DenCoordinator) -> None:
        super().__init__(coordinator, "calendar")
        self._attr_device_info = hub_device_info(coordinator)


class DenMemberCalendar(DenCalendar):
    """Events assigned to one member (plus family-wide ones, if the options say so)."""

    _attr_translation_key = "member"
    _attr_name = None

    def __init__(self, coordinator: DenCoordinator, member: Member) -> None:
        super().__init__(coordinator, f"{member.id}_calendar")
        self._member_id = member.id
        self._attr_device_info = member_device_info(coordinator, member)

    @property
    def available(self) -> bool:
        """Unavailable once the member is gone from Den."""
        return (
            super().available
            and self.coordinator.data.directory.member(self._member_id) is not None
        )
