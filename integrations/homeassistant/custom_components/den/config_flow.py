"""Config flow for Den: zeroconf discovery or a URL, plus an API token made in the Den app."""

from __future__ import annotations

from collections.abc import Mapping
from ipaddress import IPv6Address, ip_address
import logging
from typing import Any

import voluptuous as vol

from homeassistant.config_entries import (
    ConfigEntryState,
    ConfigFlow,
    ConfigFlowResult,
    OptionsFlowWithReload,
)
from homeassistant.const import CONF_TOKEN, CONF_URL
from homeassistant.core import callback
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.selector import (
    BooleanSelector,
    SelectOptionDict,
    SelectSelector,
    SelectSelectorConfig,
    TextSelector,
    TextSelectorConfig,
    TextSelectorType,
)
from homeassistant.helpers.service_info.zeroconf import ZeroconfServiceInfo

from .api import (
    DenAuthError,
    DenClient,
    DenConnectionError,
    DenError,
    DenNotReadyError,
    DenScopeError,
    normalize_url,
)
from .const import (
    DEFAULT_PORT,
    DOMAIN,
    FIELD_LISTS,
    FIELD_MEMBERS,
    OPT_EVERYONE_ON_MEMBER_CALENDARS,
    OPT_HIDDEN_LISTS,
    OPT_HIDDEN_MEMBERS,
    SCOPE_READ,
)
from .coordinator import DenConfigEntry
from .models import Directory, Health

_LOGGER = logging.getLogger(__name__)

TOKEN_SELECTOR = TextSelector(TextSelectorConfig(type=TextSelectorType.PASSWORD))
URL_SELECTOR = TextSelector(TextSelectorConfig(type=TextSelectorType.URL))


class CannotValidate(Exception):
    """Validation failed; `error` is the strings.json error key."""

    def __init__(self, error: str) -> None:
        super().__init__(error)
        self.error = error


async def _validate(
    flow: ConfigFlow, url: str, token: str
) -> tuple[Health | None, Directory]:
    """Reach the hub and check the token by reading the member list."""
    client = DenClient(async_get_clientsession(flow.hass), url, token)
    try:
        health: Health | None = await client.health()
    except DenConnectionError as err:
        raise CannotValidate("cannot_connect") from err
    except DenError:
        health = None
    if health is not None and not health.ready:
        raise CannotValidate("not_ready")
    try:
        directory = await client.members()
    except DenAuthError as err:
        raise CannotValidate("invalid_auth") from err
    except DenScopeError as err:
        raise CannotValidate("missing_read_scope") from err
    except DenNotReadyError as err:
        raise CannotValidate("not_ready") from err
    except DenConnectionError as err:
        raise CannotValidate("cannot_connect") from err
    except DenError as err:
        _LOGGER.debug("Unexpected answer from the Den hub at %s: %s", url, err)
        raise CannotValidate("unknown") from err
    if not directory.token.has(SCOPE_READ):
        raise CannotValidate("missing_read_scope")
    return health, directory


def _hub_id(health: Health | None, directory: Directory) -> str | None:
    return directory.hub.device or (health.device if health else None)


class DenConfigFlow(ConfigFlow, domain=DOMAIN):
    """Set up a Den hub."""

    VERSION = 1
    MINOR_VERSION = 1

    def __init__(self) -> None:
        """Start a flow."""
        self._url: str | None = None
        self._name: str | None = None

    @staticmethod
    @callback
    def async_get_options_flow(config_entry: DenConfigEntry) -> DenOptionsFlow:
        """Choose which members and lists become entities."""
        return DenOptionsFlow()

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Enter the hub's address and a token."""
        errors: dict[str, str] = {}
        if user_input is not None:
            try:
                url = normalize_url(user_input[CONF_URL])
            except ValueError:
                errors[CONF_URL] = "invalid_url"
            else:
                token = user_input[CONF_TOKEN].strip()
                try:
                    health, directory = await _validate(self, url, token)
                except CannotValidate as err:
                    errors["base"] = err.error
                else:
                    if hub_id := _hub_id(health, directory):
                        await self.async_set_unique_id(hub_id)
                        self._abort_if_unique_id_configured(
                            updates={CONF_URL: url, CONF_TOKEN: token}
                        )
                    return self.async_create_entry(
                        title=directory.family.name,
                        data={CONF_URL: url, CONF_TOKEN: token},
                    )
        return self.async_show_form(
            step_id="user",
            data_schema=self.add_suggested_values_to_schema(
                vol.Schema(
                    {
                        vol.Required(CONF_URL): URL_SELECTOR,
                        vol.Required(CONF_TOKEN): TOKEN_SELECTOR,
                    }
                ),
                user_input or {},
            ),
            errors=errors,
        )

    async def async_step_zeroconf(
        self, discovery_info: ZeroconfServiceInfo
    ) -> ConfigFlowResult:
        """A hub announced itself on the network."""
        properties = discovery_info.properties
        hub_id = properties.get("id")
        if not hub_id:
            return self.async_abort(reason="no_hub_id")
        address = discovery_info.ip_address or ip_address(discovery_info.host)
        host = f"[{address}]" if isinstance(address, IPv6Address) else str(address)
        scheme = "https" if properties.get("tls") == "1" else "http"
        self._url = f"{scheme}://{host}:{discovery_info.port or DEFAULT_PORT}"
        self._name = properties.get("name") or discovery_info.name.split(".", 1)[0]

        await self.async_set_unique_id(hub_id)
        self._abort_if_unique_id_configured(updates={CONF_URL: self._url})
        self.context["title_placeholders"] = {"name": self._name}
        return await self.async_step_zeroconf_confirm()

    async def async_step_zeroconf_confirm(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Paste a token for the discovered hub."""
        assert self._url is not None
        errors: dict[str, str] = {}
        if user_input is not None:
            token = user_input[CONF_TOKEN].strip()
            try:
                _health, directory = await _validate(self, self._url, token)
            except CannotValidate as err:
                errors["base"] = err.error
            else:
                return self.async_create_entry(
                    title=directory.family.name,
                    data={CONF_URL: self._url, CONF_TOKEN: token},
                )
        return self.async_show_form(
            step_id="zeroconf_confirm",
            data_schema=vol.Schema({vol.Required(CONF_TOKEN): TOKEN_SELECTOR}),
            errors=errors,
            description_placeholders={"name": self._name or "Den", "url": self._url},
        )

    async def async_step_reauth(
        self, entry_data: Mapping[str, Any]
    ) -> ConfigFlowResult:
        """The hub stopped accepting the token."""
        return await self.async_step_reauth_confirm()

    async def async_step_reauth_confirm(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Paste a new token."""
        entry = self._get_reauth_entry()
        errors: dict[str, str] = {}
        if user_input is not None:
            token = user_input[CONF_TOKEN].strip()
            try:
                health, directory = await _validate(self, entry.data[CONF_URL], token)
            except CannotValidate as err:
                errors["base"] = err.error
            else:
                if hub_id := _hub_id(health, directory):
                    await self.async_set_unique_id(hub_id)
                    self._abort_if_unique_id_mismatch(reason="wrong_hub")
                return self.async_update_reload_and_abort(
                    entry, data_updates={CONF_TOKEN: token}
                )
        return self.async_show_form(
            step_id="reauth_confirm",
            data_schema=vol.Schema({vol.Required(CONF_TOKEN): TOKEN_SELECTOR}),
            errors=errors,
            description_placeholders={"name": entry.title},
        )

    async def async_step_reconfigure(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Change the hub's address or the token."""
        entry = self._get_reconfigure_entry()
        errors: dict[str, str] = {}
        if user_input is not None:
            try:
                url = normalize_url(user_input[CONF_URL])
            except ValueError:
                errors[CONF_URL] = "invalid_url"
            else:
                token = user_input[CONF_TOKEN].strip()
                try:
                    health, directory = await _validate(self, url, token)
                except CannotValidate as err:
                    errors["base"] = err.error
                else:
                    if hub_id := _hub_id(health, directory):
                        await self.async_set_unique_id(hub_id)
                        self._abort_if_unique_id_mismatch(reason="wrong_hub")
                    return self.async_update_reload_and_abort(
                        entry, data_updates={CONF_URL: url, CONF_TOKEN: token}
                    )
        return self.async_show_form(
            step_id="reconfigure",
            data_schema=self.add_suggested_values_to_schema(
                vol.Schema(
                    {
                        vol.Required(CONF_URL): URL_SELECTOR,
                        vol.Required(CONF_TOKEN): TOKEN_SELECTOR,
                    }
                ),
                user_input or dict(entry.data),
            ),
            errors=errors,
        )


class DenOptionsFlow(OptionsFlowWithReload):
    """Pick which members and lists Home Assistant shows."""

    async def async_step_init(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """The only step."""
        entry: DenConfigEntry = self.config_entry
        if entry.state is not ConfigEntryState.LOADED:
            return self.async_abort(reason="not_loaded")
        data = entry.runtime_data.data
        member_ids = [m.id for m in data.directory.members]
        list_ids = [lst.id for lst in data.lists]

        if user_input is not None:
            shown_members = set(user_input.get(FIELD_MEMBERS, []))
            shown_lists = set(user_input.get(FIELD_LISTS, []))
            return self.async_create_entry(
                data={
                    OPT_HIDDEN_MEMBERS: [
                        m for m in member_ids if m not in shown_members
                    ],
                    OPT_HIDDEN_LISTS: [x for x in list_ids if x not in shown_lists],
                    OPT_EVERYONE_ON_MEMBER_CALENDARS: user_input.get(
                        OPT_EVERYONE_ON_MEMBER_CALENDARS, False
                    ),
                }
            )

        hidden_members = set(entry.options.get(OPT_HIDDEN_MEMBERS, ()))
        hidden_lists = set(entry.options.get(OPT_HIDDEN_LISTS, ()))
        schema = vol.Schema(
            {
                vol.Optional(
                    FIELD_MEMBERS,
                    default=[m for m in member_ids if m not in hidden_members],
                ): SelectSelector(
                    SelectSelectorConfig(
                        options=[
                            SelectOptionDict(value=m.id, label=m.name)
                            for m in data.directory.members
                        ],
                        multiple=True,
                    )
                ),
                vol.Optional(
                    FIELD_LISTS, default=[x for x in list_ids if x not in hidden_lists]
                ): SelectSelector(
                    SelectSelectorConfig(
                        options=[
                            SelectOptionDict(value=lst.id, label=lst.title)
                            for lst in data.lists
                        ],
                        multiple=True,
                    )
                ),
                vol.Optional(
                    OPT_EVERYONE_ON_MEMBER_CALENDARS,
                    default=entry.options.get(OPT_EVERYONE_ON_MEMBER_CALENDARS, False),
                ): BooleanSelector(),
            }
        )
        return self.async_show_form(step_id="init", data_schema=schema)
