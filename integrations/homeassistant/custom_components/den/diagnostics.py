"""Diagnostics for Den: connection state and counts, with the token and family details redacted."""

from __future__ import annotations

from typing import Any

from homeassistant.components.diagnostics import async_redact_data
from homeassistant.const import CONF_TOKEN
from homeassistant.core import HomeAssistant

from .coordinator import DenConfigEntry

TO_REDACT = {CONF_TOKEN}


async def async_get_config_entry_diagnostics(
    hass: HomeAssistant, entry: DenConfigEntry
) -> dict[str, Any]:
    """Return diagnostics for a config entry."""
    coordinator = entry.runtime_data
    listener = coordinator.listener
    data = coordinator.data
    result: dict[str, Any] = {
        "entry": {
            "data": async_redact_data(dict(entry.data), TO_REDACT),
            "options": dict(entry.options),
            "unique_id": entry.unique_id,
        },
        "coordinator": {
            "last_update_success": coordinator.last_update_success,
            "last_exception": repr(coordinator.last_exception)
            if coordinator.last_exception
            else None,
            "update_interval": str(coordinator.update_interval),
        },
        "stream": {
            "connected": listener.connected,
            "connects": listener.connects,
            "last_error": listener.last_error,
            "last_event": coordinator.last_stream_event.isoformat()
            if coordinator.last_stream_event
            else None,
        },
    }
    if data is None:
        return result
    directory = data.directory
    result["hub"] = {"device": directory.hub.device, "version": directory.hub.version}
    result["family"] = {
        "timezone": directory.family.timezone,
        "week_start": directory.family.week_start,
        "points_enabled": directory.family.points_enabled,
    }
    result["token"] = {
        "scopes": sorted(directory.token.scopes),
        "acts_as_member": directory.token.member is not None,
        "expires": directory.token.expires.isoformat()
        if directory.token.expires
        else None,
    }
    # Ids, roles and counts only: no names, titles or item text.
    result["members"] = [
        {"id": m.id, "role": m.role, "tier": m.tier, "grants": list(m.grants)}
        for m in directory.members
    ]
    result["lists"] = [
        {"id": lst.id, "kind": lst.kind, "items": len(lst.items), "open": lst.open}
        for lst in data.lists
    ]
    result["chores"] = {
        "date": data.chores.date,
        "total": len(data.chores.chores),
        "done": sum(1 for c in data.chores.chores if c.done),
    }
    result["events"] = {
        "in_window": len(data.events),
        "recurring": sum(1 for o in data.events if o.recurring),
        "all_day": sum(1 for o in data.events if o.all_day),
    }
    return result
