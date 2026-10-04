# Exercise Linux autostart through LocalSend Settings and the desktop entry used by login sessions.

import json

import pytest

from autostart import UNSET


pytestmark = pytest.mark.native_autostart


def test_enable_and_disable_autostart_from_settings(autostart):
    autostart.start(xdg_config_home=autostart.home / ".config")
    autostart.enable()
    fields = autostart.entry_fields()
    assert fields["Type"] == "Application"
    assert fields["Exec"] == str(autostart.bundle / "localsend_app")
    autostart.disable()
    assert not autostart.entry.exists()


def test_absolute_xdg_config_home_receives_autostart_entry(autostart, tmp_path):
    custom_config = tmp_path / "custom-config"
    autostart.start(xdg_config_home=custom_config)
    autostart.enable()
    assert autostart.entry == custom_config / "autostart" / f"{autostart.package_name}.desktop"
    assert autostart.entry.is_file(), f"Autostart entry was not written under XDG_CONFIG_HOME: {autostart.entry}"
    home_entry = autostart.home / ".config/autostart" / f"{autostart.package_name}.desktop"
    assert not home_entry.exists(), f"Autostart entry unexpectedly used HOME fallback: {home_entry}"


@pytest.mark.parametrize("xdg_config_home", [UNSET, "", "relative-config"], ids=["unset", "empty", "relative"])
def test_unusable_xdg_config_home_falls_back_to_home(autostart, xdg_config_home):
    autostart.start(xdg_config_home=xdg_config_home)
    autostart.enable()
    assert autostart.entry == autostart.home / ".config/autostart" / f"{autostart.package_name}.desktop"
    assert autostart.entry.is_file(), f"Autostart entry was not written to HOME fallback: {autostart.entry}"


def test_desktop_entry_uses_built_package_name_as_icon(autostart):
    autostart.start(xdg_config_home=autostart.home / ".config")
    autostart.enable()
    fields = autostart.entry_fields()
    assert fields.get("Icon") == autostart.package_name, (
        f"Expected Icon={autostart.package_name!r} from release version.json in {autostart.entry}; "
        f"found {fields.get('Icon')!r}"
    )


def test_disable_succeeds_when_entry_was_removed_outside_app(autostart):
    autostart.start(xdg_config_home=autostart.home / ".config")
    autostart.enable()
    autostart.entry.unlink()
    assert json.loads(autostart.ui("state"))["autostart"] is True, "The Settings switch must still be on after external removal"
    autostart.snapshot("externally-removed")
    autostart.disable()
    assert not autostart.entry.exists()
