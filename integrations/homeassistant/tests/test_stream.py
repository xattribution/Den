"""The event stream: refetching what changed, bus events, reconnects, den_event_starting."""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta

from freezegun.api import FrozenDateTimeFactory
import pytest

from homeassistant.core import HomeAssistant
from pytest_homeassistant_custom_component.common import (
    MockConfigEntry,
    async_capture_events,
    async_fire_time_changed,
)

from custom_components.den.const import (
    EVENT_CHORE_COMPLETED,
    EVENT_EVENT_STARTING,
    EVENT_ITEM_CHECKED,
    POLL_WHILE_STREAMING,
    POLL_WITHOUT_STREAM,
)

from .conftest import until
from .fake_hub import IVY, LEO, FakeHub


async def _no_wait(_delay: float) -> None:
    await asyncio.sleep(0.01)


async def _connected(hass: HomeAssistant, hub: FakeHub, entry: MockConfigEntry) -> None:
    """Wait for the stream and the refetch that follows its hello."""
    coordinator = entry.runtime_data
    await until(hass, lambda: coordinator.streaming)
    await until(hass, lambda: hub.count("GET", "/api/v1/members") >= 2)
    await hass.async_block_till_done()


async def test_changed_refetches_and_fires_chore_events(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """A `changed` completion refetches chores and points (not lists) and fires den_chore_completed."""
    entry = setup_integration
    await _connected(hass, hub, entry)
    assert entry.runtime_data.update_interval == POLL_WHILE_STREAMING
    events = async_capture_events(hass, EVENT_CHORE_COMPLETED)
    lists_before = hub.count("GET", "/api/v1/lists")
    chores_before = hub.count("GET", "/api/v1/chores")

    bed = hub.find_chore("C3MAKEBEDLEO6RJ6")
    bed["done"], bed["done_by"] = True, LEO
    await hub.changed("completion")
    await until(hass, lambda: len(events) == 1)

    assert hub.count("GET", "/api/v1/chores") == chores_before + 1
    assert hub.count("GET", "/api/v1/lists") == lists_before
    assert events[0].data == {
        "config_entry_id": entry.entry_id,
        "chore_id": "C3MAKEBEDLEO6RJ6",
        "title": "Make bed",
        "date": hub.today.isoformat(),
        "done_by_id": LEO,
        "done_by": "Leo",
        "owner_id": LEO,
        "owner": "Leo",
        "points": 2,
        "owner_chores_left": 1,
        "chores_left": 3,
    }
    assert hass.states.get("sensor.leo_chores_left_today").state == "1"

    cat = hub.find_chore("C2FEEDCAT5QK4MXN")
    cat["done"], cat["done_by"] = True, IVY
    await hub.changed("completion")
    await until(hass, lambda: len(events) == 2)
    assert events[1].data["owner"] == "Leo"
    assert events[1].data["done_by"] == "Ivy"
    assert events[1].data["owner_chores_left"] == 0
    assert hass.states.get("sensor.leo_chores_left_today").state == "0"

    # Nothing newly done: no event.
    await hub.changed("completion")
    await until(hass, lambda: hub.count("GET", "/api/v1/chores") == chores_before + 3)
    assert len(events) == 2


async def test_item_checked_event(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """Checking an item anywhere fires den_item_checked and updates the to-do list."""
    await _connected(hass, hub, setup_integration)
    events = async_capture_events(hass, EVENT_ITEM_CHECKED)
    milk = hub.find_item("I2MILK7QK4MXN3TB")[1]
    milk["checked"], milk["checked_by"] = True, LEO
    await hub.changed("item")
    await until(hass, lambda: len(events) == 1)
    assert events[0].data == {
        "config_entry_id": setup_integration.entry_id,
        "item_id": "I2MILK7QK4MXN3TB",
        "text": "Milk",
        "qty": "2 gal",
        "store": "Costco",
        "list_id": "L2GROCERY5QK4MXN",
        "list": "Groceries",
        "checked_by_id": LEO,
        "checked_by": "Leo",
        "list_open": 0,
    }
    assert hass.states.get("todo.den_groceries").state == "0"


async def test_reconnect_refetches_everything(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """When the stream drops, polling speeds up; on reconnect everything is refetched."""
    coordinator = setup_integration.runtime_data
    await _connected(hass, hub, setup_integration)
    coordinator.listener._sleep = _no_wait  # reconnect at once in the test
    members_before = hub.count("GET", "/api/v1/members")
    hub.find_chore("C5DISHES2TL2ZQ3A")["done"] = True

    await hub.drop_streams()
    await until(hass, lambda: coordinator.listener.connects == 2)
    await until(hass, lambda: hub.count("GET", "/api/v1/members") > members_before)
    await until(
        hass, lambda: hass.states.get("sensor.den_chores_left_today").state == "3"
    )
    assert coordinator.update_interval == POLL_WHILE_STREAMING


async def test_revoked_token_on_stream_starts_reauth(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """A stream that reconnects into a 401 asks for a new token."""
    coordinator = setup_integration.runtime_data
    await _connected(hass, hub, setup_integration)
    coordinator.listener._sleep = _no_wait
    hub.token = "rotated"
    await hub.drop_streams()
    await until(hass, lambda: bool(hass.config_entries.flow.async_progress()))
    assert hass.config_entries.flow.async_progress()[0]["context"]["source"] == "reauth"
    assert coordinator.update_interval == POLL_WITHOUT_STREAM


@pytest.mark.parametrize("stream_enabled", [False])
async def test_event_starting(
    hass: HomeAssistant,
    hub: FakeHub,
    freezer: FrozenDateTimeFactory,
    setup_integration: MockConfigEntry,
) -> None:
    """den_event_starting fires at each reminder and at the start."""
    events = async_capture_events(hass, EVENT_EVENT_STARTING)
    dentist = next(o for o in hub.events if o["event_id"] == "E3DENTIST4RJ6YP2")
    start = datetime.fromtimestamp(dentist["start_ms"] / 1000, UTC)

    freezer.move_to(start - timedelta(minutes=15) + timedelta(seconds=1))
    async_fire_time_changed(hass)
    await hass.async_block_till_done()
    assert [e.data["minutes_before"] for e in events] == [15]
    data = events[0].data
    assert data["title"] == "Dentist"
    assert data["assignees"] == ["Ivy"]
    assert data["assignee_ids"] == [IVY]
    assert data["for_everyone"] is False
    assert data["uid"] == dentist["uid"]
    assert datetime.fromisoformat(data["start"]) == start

    freezer.move_to(start + timedelta(seconds=1))
    async_fire_time_changed(hass)
    await hass.async_block_till_done()
    assert [e.data["minutes_before"] for e in events] == [15, 0]

    # A refresh after firing doesn't fire again.
    await setup_integration.runtime_data.async_refresh()
    await hass.async_block_till_done()
    async_fire_time_changed(hass)
    await hass.async_block_till_done()
    assert [e.data["minutes_before"] for e in events] == [15, 0]
