"""Den lists as Home Assistant to-do lists."""

from __future__ import annotations

import asyncio
import re
from typing import Any

from homeassistant.components.todo import (
    TodoItem,
    TodoItemStatus,
    TodoListEntity,
    TodoListEntityFeature,
)
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant, callback
from homeassistant.exceptions import ServiceValidationError
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from .const import DOMAIN, SCOPE_LISTS, SECTION_LISTS
from .coordinator import DenConfigEntry, DenCoordinator
from .entity import DenEntity, async_prune_entities, hub_device_info
from .models import DenList, Item

PARALLEL_UPDATES = 1

LIST_KINDS = {"shopping", "checklist", "packing", "meal"}

_DESCRIPTION_LINE = re.compile(
    r"^\s*(qty|quantity|store)\s*:\s*(.*?)\s*$", re.IGNORECASE
)


def render_description(item: Item) -> str | None:
    """Show an item's quantity and store as the to-do item's description."""
    lines = []
    if item.qty:
        lines.append(f"Qty: {item.qty}")
    if item.store:
        lines.append(f"Store: {item.store}")
    return "\n".join(lines) or None


def parse_description(description: str | None) -> tuple[str | None, str | None]:
    """Read quantity and store back from a description.

    `Qty: 2 gal` and `Store: Costco` lines set those fields. Free text with neither line becomes
    the quantity, since Den items have no notes and quantity is free text ("2 lbs, organic").
    """
    if not description or not description.strip():
        return None, None
    qty: str | None = None
    store: str | None = None
    matched = False
    for line in description.splitlines():
        if match := _DESCRIPTION_LINE.match(line):
            matched = True
            value = match.group(2) or None
            if match.group(1).lower() == "store":
                store = value
            else:
                qty = value
    if not matched:
        qty = " ".join(description.split())
    return qty, store


def to_todo_item(item: Item) -> TodoItem:
    """Map a Den item to a Home Assistant to-do item."""
    return TodoItem(
        uid=item.id,
        summary=item.text,
        status=TodoItemStatus.COMPLETED
        if item.checked
        else TodoItemStatus.NEEDS_ACTION,
        description=render_description(item),
    )


async def async_setup_entry(
    hass: HomeAssistant,
    entry: DenConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    """Add a to-do list per exposed Den list, following lists as they come and go."""
    coordinator = entry.runtime_data
    known: set[str] = set()

    @callback
    def _sync() -> None:
        if not coordinator.last_update_success:
            return
        lists = coordinator.exposed_lists
        current = {lst.id for lst in lists}
        new = [DenTodoList(coordinator, lst) for lst in lists if lst.id not in known]
        known.intersection_update(current)
        known.update(current)
        async_prune_entities(
            hass,
            entry,
            Platform.TODO,
            {f"{coordinator.hub_id}_list_{list_id}" for list_id in current},
        )
        if new:
            async_add_entities(new)

    _sync()
    entry.async_on_unload(coordinator.async_add_listener(_sync))


class DenTodoList(DenEntity, TodoListEntity):
    """One Den list."""

    def __init__(self, coordinator: DenCoordinator, den_list: DenList) -> None:
        super().__init__(coordinator, f"list_{den_list.id}")
        self.list_id = den_list.id
        self._attr_name = den_list.title
        self._attr_translation_key = (
            den_list.kind if den_list.kind in LIST_KINDS else "checklist"
        )
        self._attr_device_info = hub_device_info(coordinator)

    @property
    def _list(self) -> DenList | None:
        return self.coordinator.data.get_list(self.list_id)

    @property
    def available(self) -> bool:
        """Unavailable once the list is gone from Den."""
        return super().available and self._list is not None

    @callback
    def _handle_coordinator_update(self) -> None:
        if (den_list := self._list) is not None and den_list.title != self._attr_name:
            self._attr_name = den_list.title
        super()._handle_coordinator_update()

    @property
    def supported_features(self) -> TodoListEntityFeature:
        """Editable when the token has the lists scope."""
        if not self.coordinator.can(SCOPE_LISTS):
            return TodoListEntityFeature(0)
        return (
            TodoListEntityFeature.CREATE_TODO_ITEM
            | TodoListEntityFeature.UPDATE_TODO_ITEM
            | TodoListEntityFeature.DELETE_TODO_ITEM
            | TodoListEntityFeature.MOVE_TODO_ITEM
            | TodoListEntityFeature.SET_DESCRIPTION_ON_ITEM
        )

    @property
    def todo_items(self) -> list[TodoItem] | None:
        """The list's items in Den's order."""
        if (den_list := self._list) is None:
            return None
        return [to_todo_item(item) for item in den_list.items]

    def _item(self, uid: str | None) -> Item:
        den_list = self._list
        item = den_list.item(uid) if den_list and uid else None
        if item is None:
            raise ServiceValidationError(
                translation_domain=DOMAIN,
                translation_key="item_not_found",
                translation_placeholders={"item": uid or ""},
            )
        return item

    async def async_create_todo_item(self, item: TodoItem) -> None:
        """Add an item at the end of the list."""
        client = self.coordinator.client
        qty, store = parse_description(item.description)
        result = await self._den_call(
            client.add_item(self.list_id, item.summary or "", qty=qty, store=store)
        )
        created = result.get("item") if isinstance(result, dict) else None
        if (
            item.status == TodoItemStatus.COMPLETED
            and isinstance(created, dict)
            and created.get("id")
        ):
            await self._den_call(client.update_item(created["id"], {"checked": True}))
        await self.coordinator.async_refresh_sections({SECTION_LISTS})

    async def async_update_todo_item(self, item: TodoItem) -> None:
        """Rename, check or uncheck, or change quantity and store."""
        current = self._item(item.uid)
        body: dict[str, Any] = {}
        if item.summary is not None and item.summary != current.text:
            body["text"] = item.summary
        if item.status is not None:
            checked = item.status == TodoItemStatus.COMPLETED
            if checked != current.checked:
                body["checked"] = checked
        if item.description != render_description(current):
            qty, store = parse_description(item.description)
            if qty != current.qty:
                body["qty"] = qty
            if store != current.store:
                body["store"] = store
        if body:
            await self._den_call(
                self.coordinator.client.update_item(current.id, body), SECTION_LISTS
            )

    async def async_delete_todo_items(self, uids: list[str]) -> None:
        """Remove items."""
        client = self.coordinator.client
        await self._den_call(
            asyncio.gather(*(client.delete_item(uid) for uid in uids)), SECTION_LISTS
        )

    async def async_move_todo_item(
        self, uid: str, previous_uid: str | None = None
    ) -> None:
        """Move an item after `previous_uid` (to the top when None)."""
        current = self._item(uid)
        den_list = self._list
        order = [i.id for i in den_list.items if i.id != current.id] if den_list else []
        if previous_uid is None:
            after = None
            before = order[0] if order else None
        else:
            self._item(previous_uid)
            index = order.index(previous_uid)
            after = previous_uid
            before = order[index + 1] if index + 1 < len(order) else None
        await self._den_call(
            self.coordinator.client.move_item(current.id, after=after, before=before),
            SECTION_LISTS,
        )
