"""Den actions: complete_chore, check_step, add_item, adjust_points."""

from __future__ import annotations

import pytest

from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError, ServiceValidationError
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.den.const import DOMAIN

from .fake_hub import GROCERIES, IVY, LEO, FakeHub


@pytest.fixture
def stream_enabled() -> bool:
    """These tests don't need the event stream."""
    return False


async def test_complete_chore(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """Chores resolve by title; the member picks between same-named chores and is who did it."""
    response = await hass.services.async_call(
        DOMAIN,
        "complete_chore",
        {"chore": "make BED", "member": "ivy"},
        blocking=True,
        return_response=True,
    )
    _m, path, _q, body = hub.last("POST", "/api/v1/chores")
    assert path == "/api/v1/chores/C4MAKEBEDIVY7SK7/complete"
    assert body == {"done": True, "date": hub.today.isoformat(), "member": IVY}
    assert response["done"] is True
    assert hass.states.get("sensor.ivy_chores_left_today").state == "0"

    await hass.services.async_call(
        DOMAIN,
        "complete_chore",
        {"chore": "C4MAKEBEDIVY7SK7", "done": False},
        blocking=True,
    )
    assert hub.last("POST", "/api/v1/chores")[3] == {
        "done": False,
        "date": hub.today.isoformat(),
    }
    assert hass.states.get("sensor.ivy_chores_left_today").state == "1"


async def test_complete_chore_errors(
    hass: HomeAssistant, setup_integration: MockConfigEntry
) -> None:
    """Unknown, ambiguous and misnamed inputs explain the choices."""
    with pytest.raises(ServiceValidationError) as info:
        await hass.services.async_call(
            DOMAIN, "complete_chore", {"chore": "Make bed"}, blocking=True
        )
    assert info.value.translation_key == "ambiguous_chore"

    with pytest.raises(ServiceValidationError) as info:
        await hass.services.async_call(
            DOMAIN, "complete_chore", {"chore": "Mow the lawn"}, blocking=True
        )
    assert info.value.translation_key == "unknown_chore"
    assert "Feed the cat" in info.value.translation_placeholders["choices"]

    with pytest.raises(ServiceValidationError) as info:
        await hass.services.async_call(
            DOMAIN,
            "complete_chore",
            {"chore": "Feed the cat", "member": "Zed"},
            blocking=True,
        )
    assert info.value.translation_key == "unknown_member"
    assert info.value.translation_placeholders["choices"] == "Mom, Leo, Ivy"


async def test_check_step(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """Steps resolve by text; checking the last one completes the chore."""
    for step in ("Fill the water bowl", "s2"):
        await hass.services.async_call(
            DOMAIN,
            "check_step",
            {"chore": "Feed the cat", "step": step, "member": "Leo"},
            blocking=True,
        )
    assert (
        hub.last("POST", "/api/v1/chores")[1]
        == "/api/v1/chores/C2FEEDCAT5QK4MXN/steps/s2"
    )
    assert hub.last("POST", "/api/v1/chores")[3]["member"] == LEO
    assert hass.states.get("sensor.leo_chores_left_today").state == "1"

    with pytest.raises(ServiceValidationError) as info:
        await hass.services.async_call(
            DOMAIN,
            "check_step",
            {"chore": "Feed the cat", "step": "Brush"},
            blocking=True,
        )
    assert info.value.translation_key == "unknown_step"


async def test_add_item(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """Lists resolve by title."""
    response = await hass.services.async_call(
        DOMAIN,
        "add_item",
        {"list": "groceries", "text": "Milk", "qty": "1 gal", "store": "Costco"},
        blocking=True,
        return_response=True,
    )
    _m, path, _q, body = hub.last("POST", "/api/v1/lists")
    assert path == f"/api/v1/lists/{GROCERIES}/items"
    assert body == {"text": "Milk", "qty": "1 gal", "store": "Costco"}
    assert response["list_id"] == GROCERIES
    assert response["item_id"].startswith("I9NEW")
    assert hass.states.get("todo.den_groceries").state == "2"

    with pytest.raises(ServiceValidationError) as info:
        await hass.services.async_call(
            DOMAIN, "add_item", {"list": "Hardware", "text": "Nails"}, blocking=True
        )
    assert info.value.translation_placeholders["choices"] == "Groceries, Camping"


async def test_adjust_points(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """Points go to the named member; the sensor follows."""
    response = await hass.services.async_call(
        DOMAIN,
        "adjust_points",
        {"member": "Leo", "delta": 5, "reason": "Helped carry the groceries"},
        blocking=True,
        return_response=True,
    )
    assert hub.last("POST", "/api/v1/points")[3] == {
        "member": LEO,
        "delta": 5,
        "reason": "Helped carry the groceries",
    }
    assert response == {"member_id": LEO, "member": "Leo", "balance": 47}
    assert hass.states.get("sensor.leo_points").state == "47"

    await hass.services.async_call(
        DOMAIN, "adjust_points", {"member": "Leo", "delta": -2}, blocking=True
    )
    assert hub.last("POST", "/api/v1/points")[3]["reason"] == "From Home Assistant"


async def test_missing_scope(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """A token without the scope gets a translated error naming it."""
    hub.scopes = ["read"]
    with pytest.raises(HomeAssistantError) as info:
        await hass.services.async_call(
            DOMAIN, "adjust_points", {"member": "Leo", "delta": 1}, blocking=True
        )
    assert info.value.translation_key == "missing_scope"
    assert info.value.translation_placeholders == {"scope": "points"}


async def test_unknown_entry(
    hass: HomeAssistant, setup_integration: MockConfigEntry
) -> None:
    """Naming an entry that isn't Den's (or isn't loaded) is refused."""
    with pytest.raises(ServiceValidationError) as info:
        await hass.services.async_call(
            DOMAIN,
            "add_item",
            {"list": "Groceries", "text": "x", "config_entry_id": "nope"},
            blocking=True,
        )
    assert info.value.translation_key == "entry_not_loaded"
