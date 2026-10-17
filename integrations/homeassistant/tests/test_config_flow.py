"""Config flow: manual URL, zeroconf discovery, reauth, reconfigure, options."""

from __future__ import annotations

from ipaddress import ip_address
from urllib.parse import urlsplit

import pytest

from homeassistant.config_entries import SOURCE_USER, SOURCE_ZEROCONF
from homeassistant.const import CONF_TOKEN, CONF_URL
from homeassistant.core import HomeAssistant
from homeassistant.data_entry_flow import FlowResultType
from homeassistant.helpers.service_info.zeroconf import ZeroconfServiceInfo
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.den.const import (
    DOMAIN,
    OPT_EVERYONE_ON_MEMBER_CALENDARS,
    OPT_HIDDEN_LISTS,
    OPT_HIDDEN_MEMBERS,
)

from .fake_hub import GROCERIES, HUB_ID, IVY, LEO, MOM, PACKING, TOKEN, FakeHub


@pytest.fixture
def stream_enabled() -> bool:
    """Flows don't need the event stream."""
    return False


def _discovery(hub_url: str, **properties: str) -> ZeroconfServiceInfo:
    parts = urlsplit(hub_url)
    return ZeroconfServiceInfo(
        ip_address=ip_address(parts.hostname),
        ip_addresses=[ip_address(parts.hostname)],
        hostname="den-hub.local.",
        name="Kitchen hub._den._tcp.local.",
        port=parts.port,
        type="_den._tcp.local.",
        properties={
            "id": HUB_ID,
            "name": "Kitchen hub",
            "version": "0.1.0",
            "api": "1",
            **properties,
        },
    )


async def test_user_flow(hass: HomeAssistant, hub_url: str) -> None:
    """A URL and a token create an entry named after the family, keyed by the hub id."""
    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": SOURCE_USER}
    )
    assert result["type"] is FlowResultType.FORM
    assert result["step_id"] == "user"

    host_port = hub_url.removeprefix("http://")
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {CONF_URL: host_port, CONF_TOKEN: f"  {TOKEN} "}
    )
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert result["title"] == "The Kotvas"
    assert result["data"] == {CONF_URL: hub_url, CONF_TOKEN: TOKEN}
    assert result["result"].unique_id == HUB_ID


@pytest.mark.parametrize(
    ("change", "error"),
    [
        ({"token": "nope"}, "invalid_auth"),
        ({"scopes": ["calendar"]}, "missing_read_scope"),
        ({"ready": False}, "not_ready"),
    ],
)
async def test_user_flow_errors(
    hass: HomeAssistant, hub: FakeHub, hub_url: str, change: dict, error: str
) -> None:
    """Bad tokens, missing scopes and unready hubs are explained, and the form recovers."""
    for key, value in change.items():
        setattr(hub, key, value)
    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": SOURCE_USER}
    )
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {CONF_URL: hub_url, CONF_TOKEN: TOKEN}
    )
    assert result["type"] is FlowResultType.FORM
    assert result["errors"] == {"base": error}

    fresh = FakeHub()
    for key in change:
        setattr(hub, key, getattr(fresh, key))
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {CONF_URL: hub_url, CONF_TOKEN: TOKEN}
    )
    assert result["type"] is FlowResultType.CREATE_ENTRY


async def test_user_flow_unreachable_and_bad_url(
    hass: HomeAssistant, socket_enabled: None
) -> None:
    """Unreachable hubs and non-URLs get their own errors."""
    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": SOURCE_USER}
    )
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {CONF_URL: "http://127.0.0.1:9", CONF_TOKEN: TOKEN}
    )
    assert result["errors"] == {"base": "cannot_connect"}
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {CONF_URL: "ftp://den.local", CONF_TOKEN: TOKEN}
    )
    assert result["errors"] == {CONF_URL: "invalid_url"}


async def test_user_flow_already_configured(hass: HomeAssistant, hub_url: str) -> None:
    """The same hub can't be added twice."""
    MockConfigEntry(
        domain=DOMAIN,
        unique_id=HUB_ID,
        data={CONF_URL: "http://old:47733", CONF_TOKEN: "old"},
    ).add_to_hass(hass)
    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": SOURCE_USER}
    )
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {CONF_URL: hub_url, CONF_TOKEN: TOKEN}
    )
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "already_configured"


async def test_zeroconf_flow(hass: HomeAssistant, hub_url: str) -> None:
    """A discovered hub only needs a token."""
    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": SOURCE_ZEROCONF}, data=_discovery(hub_url)
    )
    assert result["type"] is FlowResultType.FORM
    assert result["step_id"] == "zeroconf_confirm"
    assert result["description_placeholders"] == {"name": "Kitchen hub", "url": hub_url}

    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {CONF_TOKEN: "bad"}
    )
    assert result["errors"] == {"base": "invalid_auth"}
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {CONF_TOKEN: TOKEN}
    )
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert result["data"] == {CONF_URL: hub_url, CONF_TOKEN: TOKEN}
    assert result["result"].unique_id == HUB_ID


async def test_zeroconf_updates_moved_hub(hass: HomeAssistant, hub_url: str) -> None:
    """Rediscovering a configured hub at a new address updates the entry."""
    entry = MockConfigEntry(
        domain=DOMAIN,
        unique_id=HUB_ID,
        data={CONF_URL: "http://10.0.0.9:47733", CONF_TOKEN: TOKEN},
    )
    entry.add_to_hass(hass)
    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": SOURCE_ZEROCONF}, data=_discovery(hub_url)
    )
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "already_configured"
    assert entry.data[CONF_URL] == hub_url


async def test_zeroconf_without_id(hass: HomeAssistant, hub_url: str) -> None:
    """A TXT record without `id` can't be identified."""
    info = _discovery(hub_url)
    info.properties.pop("id")
    result = await hass.config_entries.flow.async_init(
        DOMAIN, context={"source": SOURCE_ZEROCONF}, data=info
    )
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "no_hub_id"


async def test_reauth(
    hass: HomeAssistant, hub: FakeHub, setup_integration: MockConfigEntry
) -> None:
    """A revoked token leads to reauth; a new token is saved."""
    entry = setup_integration
    hub.token = "rotated"
    result = await entry.start_reauth_flow(hass)
    assert result["step_id"] == "reauth_confirm"
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {CONF_TOKEN: "wrong"}
    )
    assert result["errors"] == {"base": "invalid_auth"}
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {CONF_TOKEN: "rotated"}
    )
    await hass.async_block_till_done()
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "reauth_successful"
    assert entry.data[CONF_TOKEN] == "rotated"


async def test_reconfigure(
    hass: HomeAssistant, hub: FakeHub, hub_url: str, setup_integration: MockConfigEntry
) -> None:
    """The address and token can be changed; it must still be the same hub."""
    entry = setup_integration
    result = await entry.start_reconfigure_flow(hass)
    assert result["step_id"] == "reconfigure"

    hub.hub_id = "DOTHERHUB3QK4MXN"
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"], {CONF_URL: hub_url, CONF_TOKEN: TOKEN}
    )
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "wrong_hub"

    hub.hub_id = HUB_ID
    hub.token = "rotated"
    result = await entry.start_reconfigure_flow(hass)
    result = await hass.config_entries.flow.async_configure(
        result["flow_id"],
        {CONF_URL: hub_url.removeprefix("http://") + "/", CONF_TOKEN: "rotated"},
    )
    await hass.async_block_till_done()
    assert result["type"] is FlowResultType.ABORT
    assert result["reason"] == "reconfigure_successful"
    assert entry.data == {CONF_URL: hub_url, CONF_TOKEN: "rotated"}


async def test_options_flow(
    hass: HomeAssistant, setup_integration: MockConfigEntry
) -> None:
    """Unticking a member or list hides it; the stored options name what's hidden."""
    entry = setup_integration
    result = await hass.config_entries.options.async_init(entry.entry_id)
    assert result["type"] is FlowResultType.FORM
    result = await hass.config_entries.options.async_configure(
        result["flow_id"],
        {
            "members": [MOM, LEO],
            "lists": [GROCERIES],
            OPT_EVERYONE_ON_MEMBER_CALENDARS: True,
        },
    )
    await hass.async_block_till_done()
    assert result["type"] is FlowResultType.CREATE_ENTRY
    assert entry.options == {
        OPT_HIDDEN_MEMBERS: [IVY],
        OPT_HIDDEN_LISTS: [PACKING],
        OPT_EVERYONE_ON_MEMBER_CALENDARS: True,
    }
    # The entry reloaded without Ivy's entities and the Camping list.
    assert hass.states.get("calendar.ivy") is None
    assert hass.states.get("sensor.ivy_points") is None
    assert hass.states.get("todo.den_camping") is None
    assert hass.states.get("calendar.leo") is not None
    assert hass.states.get("todo.den_groceries") is not None
