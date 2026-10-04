# Checks that AppImage starts after login, stays hidden when requested, and does not start when autostart is turned off.

import pytest

pytestmark = pytest.mark.packaging("native", "appimage")


@pytest.mark.parametrize("hidden", [False, True], ids=["visible", "hidden"])
def test_autostart_survives_a_new_login(autostart, hidden):
    with autostart.login() as desktop:
        app = desktop.open_app()
        app.enable_autostart(hidden=hidden)
        app.close()

    with autostart.login() as desktop:
        app = desktop.expect_autostart()
        app.expect_hidden(hidden)


def test_disabling_autostart_prevents_login_launch(autostart):
    with autostart.login() as desktop:
        app = desktop.open_app()
        app.enable_autostart()
        app.disable_autostart()
        app.close()

    with autostart.login() as desktop:
        desktop.expect_no_autostart()
