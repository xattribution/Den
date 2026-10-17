"""Setup, unload, entities created, auth failures, sensors and diagnostics."""

from __future__ import annotations

import pytest

from homeassistant.config_entries import SOURCE_REAUTH, ConfigEntryState
from homeassistant.const import CONF_TOKEN, STATE_OFF, STATE_ON
from homeassistant.core import HomeAssistant
from homeassistant.helpers import device_registry as dr, entity_registry as er
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.den.const import DOMAIN, OPT_HIDDEN_LISTS
from custom_components.den.diagnostics import async_get_config_entry_diagnostics

from .fake_hub import HUB_ID, LEO, PACKING, TOKEN, FakeHub


@pytest.fixture
def stream_enabled() -> bool:
    """These tests don't need the event stream."""
    return False


async def test_setup_and_unload(
    hass: HomeAssistant, setup_integration: MockConfigEntry
) -> None:
    """Every entity appears, grouped under the hub and per-member devices."""
    entry = setup_integration
    assert entry.state is ConfigEntryState.LOADED

    for entity_id in (
        "calendar.den_family",
        "calendar.mom",
        "calendar.leo",
        "calendar.ivy",
        "sensor.den_next_event",
        "sensor.den_chores_left_today",
        "sensor.leo_points",
        "sensor.leo_chores_left_today",
        "todo.den_groceries",
        "todo.den_camping",
    ):
        assert hass.states.get(entity_id) is not None, entity_id

    ent_reg = er.async_get(hass)
    assert ent_reg.async_get("sensor.leo_points").unique_id == f"{HUB_ID}_{LEO}_points"
    dev_reg = dr.async_get(hass)
    hub_device = dev_reg.async_get_device(identifiers={(DOMAIN, HUB_ID)})
    assert hub_device.name == "Den"
    leo_device = dev_reg.async_get_device(identifiers={(DOMAIN, f"{HUB_ID}_{LEO}")})
    assert leo_device.name == "Leo"
    assert leo_device.via_device_id == hub_device.id

    assert await hass.config_entries.async_unload(entry.entry_id)
    assert entry.state is ConfigEntryState.NOT_LOADED


async def test_sensors(hass: HomeAssistant, setup_integration: MockConfigEntry) -> None:
    """Points, chores left, and the next event."""
    assert hass.states.get("sensor.leo_points").state == "42"
    assert (
        hass.states.get("sensor.leo_points").attributes["unit_of_measurement"]
        == "points"
    )

    leo = hass.states.get("sensor.leo_chores_left_today")
    assert leo.state == "2"
    assert leo.attributes["remaining"] == ["Feed the cat", "Make bed"]
    assert leo.attributes["total"] == 2

    family = hass.states.get("sensor.den_chores_left_today")
    assert family.state == "4"
    assert family.attributes["anyone_left"] == 1
    assert family.attributes["by_member"] == {"Leo": 2, "Ivy": 1}

    next_event = hass.states.get("sensor.den_next_event")
    assert next_event.attributes["title"] == "Dentist"
    assert next_event.attributes["assignees"] == ["Ivy"]
    assert next_event.attributes["device_class"] == "timestamp"


async def test_calendar_state(
    hass: HomeAssistant, setup_integration: MockConfigEntry
) -> None:
    """Calendars show their next event; member calendars only show that member's."""
    leo = hass.states.get("calendar.leo")
    assert leo.state == STATE_OFF
    assert leo.attributes["message"] == "Soccer practice"
    assert leo.attributes["location"] == "Field 3"
    family = hass.states.get("calendar.den_family")
    assert family.attributes["message"] == "Dentist"
    assert hass.states.get("calendar.mom").attributes.get("message") is None
    assert family.state in (STATE_OFF, STATE_ON)


async def test_points_disabled(
    hass: HomeAssistant, hub: FakeHub, config_entry: MockConfigEntry
) -> None:
    """No points sensors when the family has points turned off."""
    hub.points_enabled = False
    config_entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(config_entry.entry_id)
    await hass.async_block_till_done()
    assert hass.states.get("sensor.leo_points") is None
    assert hass.states.get("sensor.leo_chores_left_today") is not None
    await hass.config_entries.async_unload(config_entry.entry_id)


async def test_bad_token_starts_reauth(
    hass: HomeAssistant, hub: FakeHub, config_entry: MockConfigEntry
) -> None:
    """A rejected token fails setup and asks for a new one."""
    hub.token = "rotated"
    config_entry.add_to_hass(hass)
    assert not await hass.config_entries.async_setup(config_entry.entry_id)
    await hass.async_block_till_done()
    assert config_entry.state is ConfigEntryState.SETUP_ERROR
    flows = hass.config_entries.flow.async_progress()
    assert [f["context"]["source"] for f in flows] == [SOURCE_REAUTH]


async def test_hub_down_retries(hass: HomeAssistant, socket_enabled: None) -> None:
    """An unreachable hub means setup is retried later."""
    entry = MockConfigEntry(
        domain=DOMAIN,
        unique_id=HUB_ID,
        data={"url": "http://127.0.0.1:9", CONF_TOKEN: TOKEN},
    )
    entry.add_to_hass(hass)
    await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    assert entry.state is ConfigEntryState.SETUP_RETRY


async def test_deleted_list_entity_is_removed(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """A list deleted in Den disappears from Home Assistant on the next refresh."""
    coordinator = setup_integration.runtime_data
    hub.lists = [lst for lst in hub.lists if lst["id"] != PACKING]
    await coordinator.async_refresh()
    await hass.async_block_till_done()
    assert hass.states.get("todo.den_camping") is None
    assert er.async_get(hass).async_get("todo.den_camping") is None


@pytest.mark.parametrize("entry_options", [{OPT_HIDDEN_LISTS: [PACKING]}])
async def test_hidden_list(
    hass: HomeAssistant, setup_integration: MockConfigEntry
) -> None:
    """Hidden lists get no entity."""
    assert hass.states.get("todo.den_camping") is None
    assert hass.states.get("todo.den_groceries") is not None


async def test_diagnostics_redact_token(
    hass: HomeAssistant, setup_integration: MockConfigEntry
) -> None:
    """The token never appears in diagnostics, and neither do names."""
    diagnostics = await async_get_config_entry_diagnostics(hass, setup_integration)
    assert diagnostics["entry"]["data"][CONF_TOKEN] == "**REDACTED**"
    assert TOKEN not in repr(diagnostics)
    assert "Leo" not in repr(diagnostics)
    assert diagnostics["hub"]["device"] == HUB_ID
    assert diagnostics["token"]["scopes"] == [
        "calendar",
        "chores",
        "lists",
        "points",
        "read",
    ]
    assert diagnostics["chores"]["total"] == 4
