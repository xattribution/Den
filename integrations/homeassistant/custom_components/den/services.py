"""Den actions: complete chores, check steps, add list items, adjust points."""

from __future__ import annotations

from datetime import date
from typing import Any

import voluptuous as vol

from homeassistant.config_entries import ConfigEntryState
from homeassistant.core import (
    HomeAssistant,
    ServiceCall,
    ServiceResponse,
    SupportsResponse,
)
from homeassistant.exceptions import ServiceValidationError
from homeassistant.helpers import config_validation as cv

from .api import DenError
from .const import (
    ATTR_CONFIG_ENTRY_ID,
    DOMAIN,
    SECTION_CHORES,
    SECTION_LISTS,
    SECTION_POINTS,
)
from .coordinator import DenConfigEntry, DenCoordinator
from .entity import async_den_call, den_error
from .models import ChoreDay, ChoreStep, DenList, Member

SERVICE_COMPLETE_CHORE = "complete_chore"
SERVICE_CHECK_STEP = "check_step"
SERVICE_ADD_ITEM = "add_item"
SERVICE_ADJUST_POINTS = "adjust_points"

ATTR_CHORE = "chore"
ATTR_STEP = "step"
ATTR_DATE = "date"
ATTR_MEMBER = "member"
ATTR_DONE = "done"
ATTR_CHECKED = "checked"
ATTR_LIST = "list"
ATTR_TEXT = "text"
ATTR_QTY = "qty"
ATTR_STORE = "store"
ATTR_DELTA = "delta"
ATTR_REASON = "reason"

DEFAULT_REASON = "From Home Assistant"

_ENTRY = {vol.Optional(ATTR_CONFIG_ENTRY_ID): cv.string}

COMPLETE_CHORE_SCHEMA = vol.Schema(
    {
        **_ENTRY,
        vol.Required(ATTR_CHORE): cv.string,
        vol.Optional(ATTR_DATE): cv.date,
        vol.Optional(ATTR_MEMBER): cv.string,
        vol.Optional(ATTR_DONE, default=True): cv.boolean,
    }
)
CHECK_STEP_SCHEMA = vol.Schema(
    {
        **_ENTRY,
        vol.Required(ATTR_CHORE): cv.string,
        vol.Required(ATTR_STEP): cv.string,
        vol.Optional(ATTR_DATE): cv.date,
        vol.Optional(ATTR_MEMBER): cv.string,
        vol.Optional(ATTR_CHECKED, default=True): cv.boolean,
    }
)
ADD_ITEM_SCHEMA = vol.Schema(
    {
        **_ENTRY,
        vol.Required(ATTR_LIST): cv.string,
        vol.Required(ATTR_TEXT): vol.All(cv.string, vol.Length(min=1, max=200)),
        vol.Optional(ATTR_QTY): vol.All(cv.string, vol.Length(max=40)),
        vol.Optional(ATTR_STORE): vol.All(cv.string, vol.Length(max=60)),
    }
)
ADJUST_POINTS_SCHEMA = vol.Schema(
    {
        **_ENTRY,
        vol.Required(ATTR_MEMBER): cv.string,
        vol.Required(ATTR_DELTA): vol.All(
            vol.Coerce(int), vol.Range(min=-10000, max=10000), vol.NotIn([0])
        ),
        vol.Optional(ATTR_REASON): vol.All(cv.string, vol.Length(min=1, max=200)),
    }
)


def _invalid(key: str, **placeholders: str) -> ServiceValidationError:
    return ServiceValidationError(
        translation_domain=DOMAIN,
        translation_key=key,
        translation_placeholders=placeholders,
    )


def _coordinator(hass: HomeAssistant, call: ServiceCall) -> DenCoordinator:
    """The coordinator the call is for: the named entry, or the only loaded one."""
    if entry_id := call.data.get(ATTR_CONFIG_ENTRY_ID):
        entry: DenConfigEntry | None = hass.config_entries.async_get_entry(entry_id)
        if (
            entry is None
            or entry.domain != DOMAIN
            or entry.state is not ConfigEntryState.LOADED
        ):
            raise _invalid("entry_not_loaded", entry=entry_id)
        return entry.runtime_data
    entries: list[DenConfigEntry] = hass.config_entries.async_loaded_entries(DOMAIN)
    if not entries:
        raise _invalid("no_entries")
    if len(entries) > 1:
        raise _invalid("multiple_entries")
    return entries[0].runtime_data


def _member(coordinator: DenCoordinator, value: str) -> Member:
    """A member by id or (case-insensitive) name."""
    members = coordinator.data.directory.members
    wanted = value.strip().casefold()
    for member in members:
        if member.id == value.strip():
            return member
    for member in members:
        if member.name.casefold() == wanted:
            return member
    raise _invalid(
        "unknown_member",
        member=value,
        choices=", ".join(m.name for m in members) or "-",
    )


def _list(coordinator: DenCoordinator, value: str) -> DenList:
    """A list by id or (case-insensitive) title."""
    lists = coordinator.data.lists
    wanted = value.strip().casefold()
    for den_list in lists:
        if den_list.id == value.strip():
            return den_list
    for den_list in lists:
        if den_list.title.casefold() == wanted:
            return den_list
    raise _invalid(
        "unknown_list", list=value, choices=", ".join(lst.title for lst in lists) or "-"
    )


async def _chore(
    coordinator: DenCoordinator, value: str, day: str, member: Member | None
) -> ChoreDay:
    """A chore scheduled on `day`, by id or title; `member` picks between same-named chores."""
    if day == coordinator.data.chores.date:
        chores = coordinator.data.chores.chores
    else:
        try:
            chores = (await coordinator.client.chores(day)).chores
        except DenError as err:
            raise den_error(err) from err
    wanted = value.strip()
    for chore in chores:
        if wanted in (chore.id, chore.completion_id):
            return chore
    matches = [c for c in chores if c.title.casefold() == wanted.casefold()]
    if len(matches) > 1 and member is not None:
        matches = [c for c in matches if c.owner == member.id] or matches
    if len(matches) == 1:
        return matches[0]
    if matches:
        raise _invalid("ambiguous_chore", chore=value, date=day)
    raise _invalid(
        "unknown_chore",
        chore=value,
        date=day,
        choices=", ".join(sorted({c.title for c in chores})) or "-",
    )


def _step(chore: ChoreDay, value: str) -> ChoreStep:
    """A step of a chore by id or text."""
    wanted = value.strip()
    for step in chore.steps:
        if step.id == wanted:
            return step
    for step in chore.steps:
        if step.text.casefold() == wanted.casefold():
            return step
    raise _invalid(
        "unknown_step",
        step=value,
        chore=chore.title,
        choices=", ".join(s.text for s in chore.steps) or "-",
    )


def _day(coordinator: DenCoordinator, value: date | None) -> str:
    return value.isoformat() if value else coordinator.today()


async def _complete_chore(call: ServiceCall) -> ServiceResponse:
    coordinator = _coordinator(call.hass, call)
    member = (
        _member(coordinator, call.data[ATTR_MEMBER])
        if ATTR_MEMBER in call.data
        else None
    )
    day = _day(coordinator, call.data.get(ATTR_DATE))
    chore = await _chore(coordinator, call.data[ATTR_CHORE], day, member)
    result = await async_den_call(
        coordinator,
        coordinator.client.complete_chore(
            chore.id,
            day,
            done=call.data[ATTR_DONE],
            member=member.id if member else None,
        ),
        SECTION_CHORES,
        SECTION_POINTS,
    )
    return _chore_response(result, chore, day)


async def _check_step(call: ServiceCall) -> ServiceResponse:
    coordinator = _coordinator(call.hass, call)
    member = (
        _member(coordinator, call.data[ATTR_MEMBER])
        if ATTR_MEMBER in call.data
        else None
    )
    day = _day(coordinator, call.data.get(ATTR_DATE))
    chore = await _chore(coordinator, call.data[ATTR_CHORE], day, member)
    step = _step(chore, call.data[ATTR_STEP])
    result = await async_den_call(
        coordinator,
        coordinator.client.check_step(
            chore.id,
            step.id,
            day,
            checked=call.data[ATTR_CHECKED],
            member=member.id if member else None,
        ),
        SECTION_CHORES,
        SECTION_POINTS,
    )
    return _chore_response(result, chore, day)


def _chore_response(
    result: dict[str, Any], chore: ChoreDay, day: str
) -> ServiceResponse:
    after = result.get("chore") if isinstance(result.get("chore"), dict) else {}
    return {
        "chore_id": chore.id,
        "title": chore.title,
        "date": day,
        "done": bool(after.get("done", chore.done)),
        "steps_done": after.get("steps_done"),
        "step_count": after.get("step_count", len(chore.steps)),
    }


async def _add_item(call: ServiceCall) -> ServiceResponse:
    coordinator = _coordinator(call.hass, call)
    den_list = _list(coordinator, call.data[ATTR_LIST])
    result = await async_den_call(
        coordinator,
        coordinator.client.add_item(
            den_list.id,
            call.data[ATTR_TEXT],
            qty=call.data.get(ATTR_QTY),
            store=call.data.get(ATTR_STORE),
        ),
        SECTION_LISTS,
    )
    item = result.get("item") if isinstance(result.get("item"), dict) else {}
    return {"item_id": item.get("id"), "list_id": den_list.id, "list": den_list.title}


async def _adjust_points(call: ServiceCall) -> ServiceResponse:
    coordinator = _coordinator(call.hass, call)
    if not coordinator.data.directory.family.points_enabled:
        raise _invalid("points_disabled")
    member = _member(coordinator, call.data[ATTR_MEMBER])
    result = await async_den_call(
        coordinator,
        coordinator.client.adjust_points(
            member.id,
            call.data[ATTR_DELTA],
            call.data.get(ATTR_REASON) or DEFAULT_REASON,
        ),
        SECTION_POINTS,
    )
    balance = result.get("balance")
    return {
        "member_id": member.id,
        "member": member.name,
        "balance": balance if isinstance(balance, int) else None,
    }


def async_setup_services(hass: HomeAssistant) -> None:
    """Register Den's actions (once, for every entry)."""
    for name, handler, schema in (
        (SERVICE_COMPLETE_CHORE, _complete_chore, COMPLETE_CHORE_SCHEMA),
        (SERVICE_CHECK_STEP, _check_step, CHECK_STEP_SCHEMA),
        (SERVICE_ADD_ITEM, _add_item, ADD_ITEM_SCHEMA),
        (SERVICE_ADJUST_POINTS, _adjust_points, ADJUST_POINTS_SCHEMA),
    ):
        hass.services.async_register(
            DOMAIN,
            name,
            handler,
            schema=schema,
            supports_response=SupportsResponse.OPTIONAL,
        )
