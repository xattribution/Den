"""Den sensors: points and chores per member; next event and chores for the family."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

from homeassistant.components.sensor import (
    SensorDeviceClass,
    SensorEntity,
    SensorEntityDescription,
    SensorStateClass,
)
from homeassistant.const import Platform
from homeassistant.core import CALLBACK_TYPE, HomeAssistant, callback
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback
from homeassistant.helpers.event import async_track_point_in_utc_time
from homeassistant.helpers.typing import StateType
from homeassistant.util import dt as dt_util

from .coordinator import DenConfigEntry, DenCoordinator, DenData
from .entity import DenEntity, DenMemberEntity, async_prune_entities, hub_device_info
from .models import Member, Occurrence

PARALLEL_UPDATES = 0


@dataclass(frozen=True, kw_only=True)
class DenMemberSensorDescription(SensorEntityDescription):
    """A sensor about one member."""

    value_fn: Callable[[DenData, str], StateType]
    attrs_fn: Callable[[DenData, str], Mapping[str, Any]] | None = None
    exists_fn: Callable[[DenData], bool] = lambda _data: True


def _chores_left(data: DenData, member_id: str) -> int:
    return sum(1 for c in data.chores_for(member_id) if not c.done)


def _chores_attrs(data: DenData, member_id: str) -> Mapping[str, Any]:
    chores = data.chores_for(member_id)
    return {
        "date": data.chores.date,
        "total": len(chores),
        "done": sum(1 for c in chores if c.done),
        "late": sum(1 for c in chores if c.late and not c.done),
        "remaining": [c.title for c in chores if not c.done],
    }


MEMBER_SENSORS: tuple[DenMemberSensorDescription, ...] = (
    DenMemberSensorDescription(
        key="points",
        translation_key="points",
        native_unit_of_measurement="points",
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=lambda data, member_id: (
            data.points.totals.get(member_id, 0) if data.points else None
        ),
        exists_fn=lambda data: data.directory.family.points_enabled,
    ),
    DenMemberSensorDescription(
        key="chores_left",
        translation_key="chores_left",
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=_chores_left,
        attrs_fn=_chores_attrs,
    ),
)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: DenConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    """Add family sensors and sensors per exposed member."""
    coordinator = entry.runtime_data
    known: set[str] = set()

    @callback
    def _sync() -> None:
        if not coordinator.last_update_success:
            return
        data = coordinator.data
        new: list[SensorEntity] = []
        if "family" not in known:
            known.add("family")
            new += [DenFamilyChoresSensor(coordinator), DenNextEventSensor(coordinator)]
        keep = {f"{coordinator.hub_id}_chores_left", f"{coordinator.hub_id}_next_event"}
        for member in coordinator.exposed_members:
            for description in MEMBER_SENSORS:
                if not description.exists_fn(data):
                    continue
                unique_id = f"{coordinator.hub_id}_{member.id}_{description.key}"
                keep.add(unique_id)
                if unique_id not in known:
                    known.add(unique_id)
                    new.append(DenMemberSensor(coordinator, member, description))
        async_prune_entities(hass, entry, Platform.SENSOR, keep)
        known.intersection_update(keep | {"family"})
        if new:
            async_add_entities(new)

    _sync()
    entry.async_on_unload(coordinator.async_add_listener(_sync))


class DenMemberSensor(DenMemberEntity, SensorEntity):
    """Points or chores left for one member."""

    entity_description: DenMemberSensorDescription

    def __init__(
        self,
        coordinator: DenCoordinator,
        member: Member,
        description: DenMemberSensorDescription,
    ) -> None:
        super().__init__(coordinator, member, description.key)
        self.entity_description = description

    @property
    def native_value(self) -> StateType:
        """The current value."""
        return self.entity_description.value_fn(self.coordinator.data, self.member_id)

    @property
    def extra_state_attributes(self) -> Mapping[str, Any] | None:
        """Details, where the sensor has them."""
        if self.entity_description.attrs_fn is None:
            return None
        return self.entity_description.attrs_fn(self.coordinator.data, self.member_id)


class DenFamilyChoresSensor(DenEntity, SensorEntity):
    """Chores nobody has done yet today, for the whole family."""

    _attr_translation_key = "chores_left"
    _attr_state_class = SensorStateClass.MEASUREMENT

    def __init__(self, coordinator: DenCoordinator) -> None:
        super().__init__(coordinator, "chores_left")
        self._attr_device_info = hub_device_info(coordinator)

    @property
    def native_value(self) -> int:
        """Chores left today."""
        return sum(1 for c in self.coordinator.data.chores.chores if not c.done)

    @property
    def extra_state_attributes(self) -> Mapping[str, Any]:
        """Counts, per member and for "anyone" chores."""
        data = self.coordinator.data
        chores = data.chores.chores
        by_member: dict[str, int] = {}
        for member in data.directory.members:
            owned = data.chores_for(member.id)
            if owned:
                by_member[member.name] = sum(1 for c in owned if not c.done)
        return {
            "date": data.chores.date,
            "total": len(chores),
            "done": sum(1 for c in chores if c.done),
            "anyone_left": sum(1 for c in chores if c.owner is None and not c.done),
            "by_member": by_member,
        }


class DenNextEventSensor(DenEntity, SensorEntity):
    """When the family's next event starts."""

    _attr_translation_key = "next_event"
    _attr_device_class = SensorDeviceClass.TIMESTAMP

    def __init__(self, coordinator: DenCoordinator) -> None:
        super().__init__(coordinator, "next_event")
        self._attr_device_info = hub_device_info(coordinator)
        self._unsub_tick: CALLBACK_TYPE | None = None

    def _next(self) -> Occurrence | None:
        now = dt_util.utcnow()
        upcoming = [o for o in self.coordinator.data.events if o.start > now]
        return min(upcoming, key=lambda o: (o.start, o.title), default=None)

    @property
    def native_value(self) -> datetime | None:
        """Start of the next event."""
        occ = self._next()
        return occ.start if occ else None

    @property
    def extra_state_attributes(self) -> Mapping[str, Any] | None:
        """What the next event is."""
        if (occ := self._next()) is None:
            return None
        directory = self.coordinator.data.directory
        zone = self.coordinator.time_zone
        return {
            "title": occ.title,
            "location": occ.location or None,
            "end": occ.end.astimezone(zone).isoformat(),
            "all_day": occ.all_day,
            "for_everyone": occ.for_everyone,
            "assignees": [
                name
                for a in occ.assignees
                if (name := directory.member_name(a)) is not None
            ],
            "event_id": occ.event_id,
            "uid": occ.uid,
        }

    async def async_added_to_hass(self) -> None:
        """Start following the next event's start."""
        await super().async_added_to_hass()
        self._schedule_tick()

    @callback
    def _handle_coordinator_update(self) -> None:
        super()._handle_coordinator_update()
        self._schedule_tick()

    @callback
    def _schedule_tick(self) -> None:
        """Write state again when the shown event starts, so the sensor moves on."""
        if self._unsub_tick:
            self._unsub_tick()
            self._unsub_tick = None
        if (occ := self._next()) is not None:
            self._unsub_tick = async_track_point_in_utc_time(
                self.hass, self._tick, occ.start + timedelta(seconds=1)
            )

    @callback
    def _tick(self, _now: datetime) -> None:
        self._unsub_tick = None
        self.async_write_ha_state()
        self._schedule_tick()

    async def async_will_remove_from_hass(self) -> None:
        """Stop the timer."""
        if self._unsub_tick:
            self._unsub_tick()
            self._unsub_tick = None
        await super().async_will_remove_from_hass()
