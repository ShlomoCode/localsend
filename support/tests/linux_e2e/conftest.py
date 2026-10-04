# Own the real desktop and application lifecycle so scenarios only describe behavior.

from contextlib import ExitStack
from pathlib import Path
import re

import pytest

from runtime import App, Desktop


def pytest_addoption(parser):
    parser.addoption("--bundle", required=True, help="Built Linux release bundle")
    parser.addoption("--packaging", choices=["all", "native", "flatpak", "appimage"], default="all")
    parser.addoption("--appimage", default="", help="Real AppImage built from the release bundle")
    parser.addoption("--evidence", default="linux-e2e-results", help="Application log directory")


@pytest.fixture
def desktop():
    with Desktop() as session:
        yield session


def pytest_generate_tests(metafunc):
    if "packaging" in metafunc.fixturenames:
        marker = metafunc.definition.get_closest_marker("packaging")
        values = marker.args if marker else ("native", "flatpak")
        metafunc.parametrize("packaging", values, indirect=True)


@pytest.fixture
def packaging(request):
    return request.param


@pytest.fixture
def launch_app(request, desktop, packaging, tmp_path):
    bundle = Path(request.config.getoption("--bundle")).resolve()
    evidence = Path(request.config.getoption("--evidence")).resolve()
    name = re.sub(r"[^a-zA-Z0-9_.-]", "_", request.node.nodeid)
    with ExitStack() as apps:
        def launch():
            return apps.enter_context(App.create(bundle, packaging, tmp_path, evidence / f"{name}.app.log"))
        yield launch


def pytest_configure(config):
    config.addinivalue_line("markers", "packaging(*formats): installation formats supported by a scenario")


def pytest_collection_modifyitems(config, items):
    selected = config.getoption("--packaging")
    if selected == "all":
        return
    kept, removed = [], []
    for item in items:
        packaging = getattr(item, "callspec", None)
        value = packaging.params.get("packaging") if packaging else None
        (kept if value in (None, selected) else removed).append(item)
    config.hook.pytest_deselected(items=removed)
    items[:] = kept


@pytest.fixture
def autostart(request, packaging, tmp_path):
    from autostart import Autostart
    evidence = Path(request.config.getoption("--evidence")).resolve() / re.sub(r"[^a-zA-Z0-9_.-]", "_", request.node.nodeid)
    evidence.mkdir(parents=True, exist_ok=True)
    return Autostart(request.config.getoption("--bundle"), request.config.getoption("--appimage"),
                     packaging, tmp_path / "home", evidence)
