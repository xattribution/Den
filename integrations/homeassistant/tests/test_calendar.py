"""Calendars: reading windows, creating, editing and deleting events with recurrence scope."""

from __future__ import annotations

from datetime import date, datetime, timedelta

import pytest

from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError
from homeassistant.util import dt as dt_util
from pytest_homeassistant_custom_component.common import MockConfigEntry
from pytest_homeassistant_custom_component.typing import WebSocketGenerator

from custom_components.den.calendar import edit_scope, event_body, to_calendar_event
from custom_components.den.models import Occurrence

from .fake_hub import IVY, LEO, FakeHub


@pytest.fixture
def stream_enabled() -> bool:
    """These tests don't need the event stream."""
    return False


async def _get_events(hass: HomeAssistant, entity_id: str) -> list[dict]:
    response = await hass.services.async_call(
        "calendar",
        "get_events",
        {"entity_id": entity_id, "duration": {"days": 7}},
        blocking=True,
        return_response=True,
    )
    return response[entity_id]["events"]


async def test_get_events(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """The family calendar has everything; a member's calendar only their events."""
    family = await _get_events(hass, "calendar.den_family")
    assert [e["summary"] for e in family] == [
        "Dentist",
        "Soccer practice",
        "Picture day",
    ]
    picture = family[2]
    assert (
        picture["start"] == (hub.today + timedelta(days=2)).isoformat()
    )  # all-day: dates
    assert picture["end"] == (hub.today + timedelta(days=3)).isoformat()

    leo = await _get_events(hass, "calendar.leo")
    assert [e["summary"] for e in leo] == ["Soccer practice"]
    assert hub.last("GET", "/api/v1/events")[2]["member"] == LEO


@pytest.mark.parametrize("entry_options", [{"everyone_on_member_calendars": True}])
async def test_everyone_events_on_member_calendars(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """With the option on, family-wide events show on each person's calendar too."""
    leo = await _get_events(hass, "calendar.leo")
    assert [e["summary"] for e in leo] == ["Soccer practice", "Picture day"]
    assert hub.last("GET", "/api/v1/events")[2]["include_everyone"] == "true"


async def test_create_event_on_member_calendar(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """An event created on Ivy's calendar is assigned to Ivy."""
    start = dt_util.now().replace(microsecond=0) + timedelta(days=4)
    await hass.services.async_call(
        "calendar",
        "create_event",
        {
            "entity_id": "calendar.ivy",
            "summary": "Piano lesson",
            "description": "Bring the blue book",
            "start_date_time": start,
            "end_date_time": start + timedelta(minutes=45),
        },
        blocking=True,
    )
    _method, _path, _query, body = hub.last("POST", "/api/v1/events")
    assert body["title"] == "Piano lesson"
    assert body["notes"] == "Bring the blue book"
    assert body["assignees"] == [IVY]
    assert body["all_day"] is False
    assert datetime.fromisoformat(body["start"]) == start
    assert body["rrule"] is None
    # The coordinator refetched, so the new event is in its window.
    titles = [o.title for o in setup_integration.runtime_data.data.events]
    assert "Piano lesson" in titles


async def test_create_all_day_family_event(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """All-day events go over as local dates; family events have no assignees."""
    day = date.today() + timedelta(days=5)
    await hass.services.async_call(
        "calendar",
        "create_event",
        {
            "entity_id": "calendar.den_family",
            "summary": "Field trip",
            "start_date": day,
            "end_date": day + timedelta(days=1),
        },
        blocking=True,
    )
    body = hub.last("POST", "/api/v1/events")[3]
    body.pop("notes", None)  # the action passes an empty description
    body.pop("location", None)
    assert body == {
        "title": "Field trip",
        "all_day": True,
        "start": day.isoformat(),
        "end": (day + timedelta(days=1)).isoformat(),
        "rrule": None,
        "assignees": [],
    }


async def test_update_and_delete_with_recurrence(
    hass: HomeAssistant,
    hass_ws_client: WebSocketGenerator,
    hub: FakeHub,
    setup_integration: MockConfigEntry,
) -> None:
    """Recurrence id and range from the calendar UI become Den's scope and occurrence."""
    soccer = next(o for o in hub.events if o["event_id"] == "E2SOCCER7QK4MXN3")
    client = await hass_ws_client(hass)
    start = dt_util.as_local(dt_util.utc_from_timestamp(soccer["start_ms"] / 1000))

    await client.send_json_auto_id(
        {
            "type": "calendar/event/update",
            "entity_id": "calendar.leo",
            "uid": "E2SOCCER7QK4MXN3",
            "recurrence_id": str(soccer["occurrence"]),
            "recurrence_range": "THISANDFUTURE",
            "event": {
                "summary": "Soccer (new field)",
                "dtstart": start.isoformat(),
                "dtend": (start + timedelta(hours=1)).isoformat(),
                "rrule": "FREQ=WEEKLY",
            },
        }
    )
    result = await client.receive_json()
    assert result["success"], result
    _m, path, query, body = hub.last("PATCH")
    assert path == "/api/v1/events/E2SOCCER7QK4MXN3"
    assert query == {"scope": "following", "occurrence": str(soccer["occurrence"])}
    assert body["title"] == "Soccer (new field)"
    assert body["rrule"] == "FREQ=WEEKLY"

    await client.send_json_auto_id(
        {
            "type": "calendar/event/update",
            "entity_id": "calendar.leo",
            "uid": "E2SOCCER7QK4MXN3",
            "recurrence_id": str(soccer["occurrence"]),
            "event": {
                "summary": "Just this once",
                "dtstart": start.isoformat(),
                "dtend": (start + timedelta(hours=2)).isoformat(),
            },
        }
    )
    assert (await client.receive_json())["success"]
    _m, _p, query, body = hub.last("PATCH")
    assert query["scope"] == "one"
    assert "rrule" not in body

    await client.send_json_auto_id(
        {
            "type": "calendar/event/delete",
            "entity_id": "calendar.leo",
            "uid": "E2SOCCER7QK4MXN3",
            "recurrence_id": str(soccer["occurrence"]),
        }
    )
    assert (await client.receive_json())["success"]
    assert hub.last("DELETE")[2] == {
        "scope": "one",
        "occurrence": str(soccer["occurrence"]),
    }

    await client.send_json_auto_id(
        {
            "type": "calendar/event/delete",
            "entity_id": "calendar.ivy",
            "uid": "E3DENTIST4RJ6YP2",
        }
    )
    assert (await client.receive_json())["success"]
    assert hub.last("DELETE")[2] == {"scope": "all"}
    assert all(o["event_id"] != "E3DENTIST4RJ6YP2" for o in hub.events)


async def test_read_only_event(
    hass: HomeAssistant,
    hass_ws_client: WebSocketGenerator,
    setup_integration: MockConfigEntry,
) -> None:
    """Imported events can't be deleted; the error says why."""
    client = await hass_ws_client(hass)
    await client.send_json_auto_id(
        {
            "type": "calendar/event/delete",
            "entity_id": "calendar.den_family",
            "uid": "E4PICTURE2RJ6YP3",
        }
    )
    result = await client.receive_json()
    assert not result["success"]
    assert "subscribed calendar" in result["error"]["message"]


async def test_read_only_token(
    hass: HomeAssistant, hub: FakeHub, config_entry: MockConfigEntry
) -> None:
    """Without the calendar scope, calendars can't be edited."""
    hub.scopes = ["read"]
    config_entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(config_entry.entry_id)
    await hass.async_block_till_done()
    assert hass.states.get("calendar.leo").attributes["supported_features"] == 0
    await hass.config_entries.async_unload(config_entry.entry_id)


def test_mapping_helpers() -> None:
    """Occurrence and event-body mapping in both directions."""
    occ = Occurrence.from_json(
        {
            "event_id": "E1",
            "occurrence": 1792535400000,
            "recurring": True,
            "rrule": "FREQ=FORTNIGHTLY",  # not a frequency Home Assistant accepts
            "title": "Odd",
            "start_ms": 1792535400000,
            "end_ms": 1792539000000,
        }
    )
    event = to_calendar_event(occ, dt_util.get_time_zone("America/Chicago"))
    assert event.uid == "E1"
    assert event.recurrence_id == "1792535400000"
    assert event.rrule is None
    assert event.start.isoformat() == "2026-10-20T17:30:00-05:00"

    assert edit_scope(None, None) == ("all", None)
    assert edit_scope("", None) == ("all", None)
    assert edit_scope("5", "THISANDFUTURE") == ("following", 5)
    assert edit_scope("5", None) == ("one", 5)
    with pytest.raises(HomeAssistantError):
        edit_scope("20261020T173000", None)

    assert event_body(
        {"summary": "x", "dtstart": date(2026, 10, 21), "dtend": date(2026, 10, 22)},
        include_rrule=False,
    ) == {
        "title": "x",
        "all_day": True,
        "start": "2026-10-21",
        "end": "2026-10-22",
    }
