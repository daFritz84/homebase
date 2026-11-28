from __future__ import annotations

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant, ServiceCall
from wiener_netze_smart_meter_api import WNAPIClient

from .const import CONF_API_KEY, CONF_CLIENT_ID, CONF_CLIENT_SECRET, DOMAIN
from .coordinator import WNSmartMeterCoordinator

PLATFORMS = ["sensor"]
SERVICE_IMPORT_ALL_HISTORY = "import_all_history"


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    client = WNAPIClient(
        client_id=entry.data[CONF_CLIENT_ID],
        client_secret=entry.data[CONF_CLIENT_SECRET],
        api_key=entry.data[CONF_API_KEY],
    )
    coordinator = WNSmartMeterCoordinator(hass, entry, client)
    await coordinator.async_config_entry_first_refresh()

    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = coordinator
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    entry.async_on_unload(entry.add_update_listener(_async_update_listener))

    if not hass.services.has_service(DOMAIN, SERVICE_IMPORT_ALL_HISTORY):

        async def _handle_import_all(call: ServiceCall) -> None:
            for coord in hass.data[DOMAIN].values():
                await coord.async_import_full_history()

        hass.services.async_register(
            DOMAIN, SERVICE_IMPORT_ALL_HISTORY, _handle_import_all
        )

    return True


async def _async_update_listener(hass: HomeAssistant, entry: ConfigEntry) -> None:
    await hass.config_entries.async_reload(entry.entry_id)


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    unloaded = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if unloaded:
        hass.data[DOMAIN].pop(entry.entry_id)
        if not hass.data[DOMAIN]:
            hass.services.async_remove(DOMAIN, SERVICE_IMPORT_ALL_HISTORY)
    return unloaded
