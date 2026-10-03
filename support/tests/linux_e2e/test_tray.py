# Check real tray icon bytes at startup and after live KDE theme changes, natively and in Flatpak.

import pytest


@pytest.mark.parametrize("theme, color", [("light", "black"), ("dark", "white")])
def test_startup_icon(desktop, launch_app, theme, color):
    desktop.set_theme(theme)
    app = launch_app()
    app.expect_icon(color)


def test_icon_follows_live_theme(desktop, launch_app):
    desktop.set_theme("dark")
    app = launch_app()
    app.expect_icon("white")

    desktop.set_theme("light")
    app.expect_icon("black")
    app.assert_same_instance()

    desktop.set_theme("dark")
    app.expect_icon("white")
    app.assert_same_instance()
