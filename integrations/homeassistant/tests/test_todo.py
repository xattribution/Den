"""To-do lists: items, descriptions as quantity and store, create, update, delete, move."""

from __future__ import annotations

import pytest

from homeassistant.core import HomeAssistant
from pytest_homeassistant_custom_component.common import MockConfigEntry
from pytest_homeassistant_custom_component.typing import WebSocketGenerator

from custom_components.den.models import Item
from custom_components.den.todo import parse_description, render_description

from .fake_hub import GROCERIES, FakeHub

TODO = "todo.den_groceries"


@pytest.fixture
def stream_enabled() -> bool:
    """These tests don't need the event stream."""
    return False


async def _items(hass: HomeAssistant) -> list[dict]:
    response = await hass.services.async_call(
        "todo", "get_items", {"entity_id": TODO}, blocking=True, return_response=True
    )
    return response[TODO]["items"]


async def test_items(hass: HomeAssistant, setup_integration: MockConfigEntry) -> None:
    """Items in Den's order, open count as state, quantity and store as description."""
    assert hass.states.get(TODO).state == "1"
    items = await _items(hass)
    assert items == [
        {
            "uid": "I2MILK7QK4MXN3TB",
            "summary": "Milk",
            "status": "needs_action",
            "description": "Qty: 2 gal\nStore: Costco",
        },
        {"uid": "I3EGGS5RJ6YP2TQA", "summary": "Eggs", "status": "completed"},
    ]


async def test_add_item(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """Adding with a description sets quantity and store."""
    await hass.services.async_call(
        "todo",
        "add_item",
        {
            "entity_id": TODO,
            "item": "Bread",
            "description": "Qty: 1 loaf\nStore: Bakery",
        },
        blocking=True,
    )
    _m, path, _q, body = hub.last("POST", "/api/v1/lists")
    assert path == f"/api/v1/lists/{GROCERIES}/items"
    assert body == {"text": "Bread", "qty": "1 loaf", "store": "Bakery"}
    assert hass.states.get(TODO).state == "2"


async def test_check_rename_and_describe(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """Completing checks the item; rename and description changes send only what changed."""
    await hass.services.async_call(
        "todo",
        "update_item",
        {"entity_id": TODO, "item": "Milk", "status": "completed"},
        blocking=True,
    )
    assert hub.last("PATCH")[1:] == (
        "/api/v1/items/I2MILK7QK4MXN3TB",
        {},
        {"checked": True},
    )
    assert hass.states.get(TODO).state == "0"

    await hass.services.async_call(
        "todo",
        "update_item",
        {"entity_id": TODO, "item": "Milk", "rename": "Oat milk"},
        blocking=True,
    )
    assert hub.last("PATCH")[3] == {"text": "Oat milk"}

    await hass.services.async_call(
        "todo",
        "update_item",
        {"entity_id": TODO, "item": "Oat milk", "description": "Store: Target"},
        blocking=True,
    )
    assert hub.last("PATCH")[3] == {"qty": None, "store": "Target"}

    await hass.services.async_call(
        "todo",
        "update_item",
        {"entity_id": TODO, "item": "Eggs", "status": "needs_action"},
        blocking=True,
    )
    assert hub.last("PATCH")[1:] == (
        "/api/v1/items/I3EGGS5RJ6YP2TQA",
        {},
        {"checked": False},
    )


async def test_remove_items(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """Removing deletes each item; clearing completed deletes the checked ones."""
    await hass.services.async_call(
        "todo", "remove_item", {"entity_id": TODO, "item": ["Milk"]}, blocking=True
    )
    assert hub.last("DELETE")[1] == "/api/v1/items/I2MILK7QK4MXN3TB"
    await hass.services.async_call(
        "todo", "remove_completed_items", {"entity_id": TODO}, blocking=True
    )
    assert hub.last("DELETE")[1] == "/api/v1/items/I3EGGS5RJ6YP2TQA"
    assert await _items(hass) == []


async def test_move_item(
    hass: HomeAssistant,
    hass_ws_client: WebSocketGenerator,
    hub: FakeHub,
    setup_integration: MockConfigEntry,
) -> None:
    """Moves send both neighbors."""
    client = await hass_ws_client(hass)
    await client.send_json_auto_id(
        {"type": "todo/item/move", "entity_id": TODO, "uid": "I3EGGS5RJ6YP2TQA"}
    )
    assert (await client.receive_json())["success"]
    assert hub.last("PATCH")[3] == {
        "move": {"after": None, "before": "I2MILK7QK4MXN3TB"}
    }
    assert [i["summary"] for i in await _items(hass)] == ["Eggs", "Milk"]

    await client.send_json_auto_id(
        {
            "type": "todo/item/move",
            "entity_id": TODO,
            "uid": "I3EGGS5RJ6YP2TQA",
            "previous_uid": "I2MILK7QK4MXN3TB",
        }
    )
    assert (await client.receive_json())["success"]
    assert hub.last("PATCH")[3] == {
        "move": {"after": "I2MILK7QK4MXN3TB", "before": None}
    }


async def test_read_only_lists(
    hass: HomeAssistant, hub: FakeHub, config_entry: MockConfigEntry
) -> None:
    """Without the lists scope, lists can't be edited."""
    hub.scopes = ["read", "calendar"]
    config_entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(config_entry.entry_id)
    await hass.async_block_till_done()
    assert hass.states.get(TODO).attributes["supported_features"] == 0
    await hass.config_entries.async_unload(config_entry.entry_id)


@pytest.mark.parametrize(
    ("description", "expected"),
    [
        (None, (None, None)),
        ("  ", (None, None)),
        ("Qty: 2 gal\nStore: Costco", ("2 gal", "Costco")),
        ("store: Target", (None, "Target")),
        ("Quantity:3", ("3", None)),
        ("two, the organic ones", ("two, the organic ones", None)),
        ("a\nb", ("a b", None)),
    ],
)
def test_parse_description(description: str | None, expected: tuple) -> None:
    """Descriptions read back as quantity and store."""
    assert parse_description(description) == expected


def test_render_round_trip() -> None:
    """What we render parses back to the same fields."""
    item = Item(
        id="i",
        list="l",
        text="Milk",
        qty="2",
        store="Costco",
        checked=False,
        checked_by=None,
        order="m",
    )
    assert parse_description(render_description(item)) == ("2", "Costco")
