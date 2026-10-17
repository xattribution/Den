"""The Den integration: a family's shared calendar, chores, lists and points from a Den hub."""

from __future__ import annotations

from homeassistant.const import CONF_TOKEN, CONF_URL, Platform
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers import config_validation as cv, device_registry as dr
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.typing import ConfigType

from .api import DenClient
from .const import DOMAIN
from .coordinator import DenConfigEntry, DenCoordinator
from .entity import async_prune_devices, member_identifier
from .services import async_setup_services

PLATFORMS: list[Platform] = [Platform.CALENDAR, Platform.SENSOR, Platform.TODO]

CONFIG_SCHEMA = cv.config_entry_only_config_schema(DOMAIN)


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    """Register Den's actions."""
    async_setup_services(hass)
    return True


async def async_setup_entry(hass: HomeAssistant, entry: DenConfigEntry) -> bool:
    """Connect to a Den hub."""
    client = DenClient(
        async_get_clientsession(hass), entry.data[CONF_URL], entry.data[CONF_TOKEN]
    )
    coordinator = DenCoordinator(hass, entry, client)
    await coordinator.async_config_entry_first_refresh()
    entry.runtime_data = coordinator

    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)

    @callback
    def _prune() -> None:
        if coordinator.last_update_success:
            async_prune_devices(hass, entry)

    _prune()
    entry.async_on_unload(coordinator.async_add_listener(_prune))
    coordinator.async_start_stream()
    return True


async def async_unload_entry(hass: HomeAssistant, entry: DenConfigEntry) -> bool:
    """Disconnect from the hub."""
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)


async def async_remove_config_entry_device(
    hass: HomeAssistant, entry: DenConfigEntry, device: dr.DeviceEntry
) -> bool:
    """Allow removing a member's device once the member is gone or hidden."""
    coordinator: DenCoordinator = entry.runtime_data
    if (DOMAIN, coordinator.hub_id) in device.identifiers:
        return False
    return not any(
        member_identifier(coordinator, m.id) in device.identifiers
        for m in coordinator.exposed_members
    )
