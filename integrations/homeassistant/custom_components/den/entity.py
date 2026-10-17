"""Base entity and devices for the Den integration."""

from __future__ import annotations

from collections.abc import Awaitable

from homeassistant.core import HomeAssistant, callback
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers import device_registry as dr, entity_registry as er
from homeassistant.helpers.device_registry import DeviceEntryType, DeviceInfo
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .api import (
    DenAuthError,
    DenError,
    DenPermissionError,
    DenReadOnlyError,
    DenScopeError,
)
from .const import DOMAIN
from .coordinator import DenConfigEntry, DenCoordinator
from .models import Member


def den_error(err: DenError) -> HomeAssistantError:
    """A translated Home Assistant error for a failed Den call."""
    if isinstance(err, DenScopeError):
        return HomeAssistantError(
            translation_domain=DOMAIN,
            translation_key="missing_scope",
            translation_placeholders={"scope": err.scope or "?"},
        )
    if isinstance(err, DenPermissionError):
        return HomeAssistantError(
            translation_domain=DOMAIN,
            translation_key="permission_denied",
            translation_placeholders={"message": err.message},
        )
    if isinstance(err, DenReadOnlyError):
        return HomeAssistantError(
            translation_domain=DOMAIN, translation_key="read_only_event"
        )
    if isinstance(err, DenAuthError):
        return HomeAssistantError(
            translation_domain=DOMAIN, translation_key="invalid_auth"
        )
    return HomeAssistantError(
        translation_domain=DOMAIN,
        translation_key="api_error",
        translation_placeholders={"message": err.message},
    )


def hub_device_info(coordinator: DenCoordinator) -> DeviceInfo:
    """The hub's device; family-wide entities and lists live on it."""
    hub = coordinator.data.directory.hub
    return DeviceInfo(
        identifiers={(DOMAIN, coordinator.hub_id)},
        name="Den",
        manufacturer="Den",
        model="Den hub",
        sw_version=hub.version or None,
        configuration_url=coordinator.client.base_url,
    )


def member_identifier(coordinator: DenCoordinator, member_id: str) -> tuple[str, str]:
    """Device identifier for a family member."""
    return (DOMAIN, f"{coordinator.hub_id}_{member_id}")


def member_device_info(coordinator: DenCoordinator, member: Member) -> DeviceInfo:
    """A service device per family member, so their entities group under their name."""
    return DeviceInfo(
        identifiers={member_identifier(coordinator, member.id)},
        name=member.name,
        manufacturer="Den",
        model=member.role.capitalize(),
        entry_type=DeviceEntryType.SERVICE,
        via_device=(DOMAIN, coordinator.hub_id),
    )


class DenEntity(CoordinatorEntity[DenCoordinator]):
    """An entity backed by the Den coordinator."""

    _attr_has_entity_name = True

    def __init__(self, coordinator: DenCoordinator, key: str) -> None:
        super().__init__(coordinator)
        self._attr_unique_id = f"{coordinator.hub_id}_{key}"

    async def _den_call[T](self, call: Awaitable[T], *refresh: str) -> T:
        """Run a write against the hub, translate failures, then refetch what it touched."""
        return await async_den_call(self.coordinator, call, *refresh)


async def async_den_call[T](
    coordinator: DenCoordinator, call: Awaitable[T], *refresh: str
) -> T:
    """Run a write against the hub, translate failures, then refetch `refresh` sections."""
    try:
        result = await call
    except DenError as err:
        if isinstance(err, DenAuthError):
            coordinator.config_entry.async_start_reauth(coordinator.hass)
        raise den_error(err) from err
    if refresh:
        await coordinator.async_refresh_sections(refresh)
    return result


class DenMemberEntity(DenEntity):
    """An entity about one family member."""

    def __init__(self, coordinator: DenCoordinator, member: Member, key: str) -> None:
        super().__init__(coordinator, f"{member.id}_{key}")
        self.member_id = member.id
        self._attr_device_info = member_device_info(coordinator, member)

    @property
    def available(self) -> bool:
        """Unavailable once the member is gone from Den."""
        return (
            super().available
            and self.coordinator.data.directory.member(self.member_id) is not None
        )


@callback
def async_prune_devices(hass: HomeAssistant, entry: DenConfigEntry) -> None:
    """Drop member devices (and their entities) for members removed or hidden."""
    coordinator = entry.runtime_data
    keep = {member_identifier(coordinator, m.id) for m in coordinator.exposed_members}
    keep.add((DOMAIN, coordinator.hub_id))
    dev_reg = dr.async_get(hass)
    for device in dr.async_entries_for_config_entry(dev_reg, entry.entry_id):
        if not device.identifiers & keep:
            dev_reg.async_update_device(
                device.id, remove_config_entry_id=entry.entry_id
            )


@callback
def async_prune_entities(
    hass: HomeAssistant, entry: DenConfigEntry, domain: str, keep: set[str]
) -> None:
    """Remove this entry's entities of one platform whose unique id isn't in `keep`."""
    ent_reg = er.async_get(hass)
    for entity in er.async_entries_for_config_entry(ent_reg, entry.entry_id):
        if entity.domain == domain and entity.unique_id not in keep:
            ent_reg.async_remove(entity.entity_id)
