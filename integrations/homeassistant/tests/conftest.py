"""Fixtures: a fake Den hub on a local aiohttp server and a config entry pointing at it."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncGenerator, Callable, Generator
from contextlib import nullcontext
from unittest.mock import patch

import pytest
from aiohttp.test_utils import TestServer

from homeassistant.config_entries import ConfigEntryState
from homeassistant.const import CONF_TOKEN, CONF_URL
from homeassistant.core import HomeAssistant
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.den.const import DOMAIN

from .fake_hub import HUB_ID, TOKEN, FakeHub


@pytest.fixture(autouse=True)
def auto_enable_custom_integrations(enable_custom_integrations: None) -> None:
    """Let Home Assistant load custom_components/den."""


@pytest.fixture(autouse=True)
def fast_debounce() -> Generator[None]:
    """Don't wait for the stream debounce."""
    with patch("custom_components.den.coordinator.STREAM_DEBOUNCE_SECONDS", 0.01):
        yield


@pytest.fixture
def hub() -> FakeHub:
    """The fake hub's state."""
    return FakeHub()


@pytest.fixture
async def hub_url(hub: FakeHub, socket_enabled: None) -> AsyncGenerator[str]:
    """Serve the fake hub on 127.0.0.1 and return its base URL."""
    server = TestServer(hub.app(), host="127.0.0.1")
    await server.start_server()
    yield str(server.make_url("")).rstrip("/")
    await hub.drop_streams()
    await server.close()


@pytest.fixture
def stream_enabled() -> bool:
    """Whether setup opens the event stream (override per test module)."""
    return True


@pytest.fixture
def entry_options() -> dict:
    """Options for the config entry."""
    return {}


@pytest.fixture
def config_entry(hub_url: str, entry_options: dict) -> MockConfigEntry:
    """A config entry for the fake hub."""
    return MockConfigEntry(
        domain=DOMAIN,
        title="The Kotvas",
        unique_id=HUB_ID,
        data={CONF_URL: hub_url, CONF_TOKEN: TOKEN},
        options=entry_options,
    )


@pytest.fixture
async def setup_integration(
    hass: HomeAssistant, config_entry: MockConfigEntry, stream_enabled: bool
) -> AsyncGenerator[MockConfigEntry]:
    """Set up Den against the fake hub; unload it afterwards."""
    config_entry.add_to_hass(hass)
    no_stream = patch(
        "custom_components.den.coordinator.DenCoordinator.async_start_stream"
    )
    with nullcontext() if stream_enabled else no_stream:
        assert await hass.config_entries.async_setup(config_entry.entry_id)
        await hass.async_block_till_done()
    yield config_entry
    if config_entry.state is ConfigEntryState.LOADED:
        assert await hass.config_entries.async_unload(config_entry.entry_id)
        await hass.async_block_till_done()


async def until(
    hass: HomeAssistant, predicate: Callable[[], bool], timeout: float = 5.0
) -> None:
    """Wait (in real time, for network round trips) until `predicate()` holds."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while not predicate():
        if loop.time() > deadline:
            raise AssertionError("timed out waiting for a condition")
        await asyncio.sleep(0.02)
        await hass.async_block_till_done()
