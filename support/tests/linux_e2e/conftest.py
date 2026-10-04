# Own the real desktop and application lifecycle so scenarios only describe behavior.

from contextlib import ExitStack
from pathlib import Path
import re

import pytest

from runtime import App, Desktop


def pytest_addoption(parser):
    parser.addoption("--bundle", required=True, help="Built Linux release bundle")
    parser.addoption("--packaging", choices=["all", "native", "flatpak"], default="all")
    parser.addoption("--evidence", default="linux-e2e-results", help="Application log directory")


@pytest.fixture
def desktop():
    with Desktop() as session:
        yield session


def pytest_generate_tests(metafunc):
    if "packaging" in metafunc.fixturenames:
        selected = metafunc.config.getoption("--packaging")
        native_autostart = metafunc.definition.get_closest_marker("native_autostart") is not None
        values = (["native"] if native_autostart else ["native", "flatpak"]) if selected == "all" else [selected]
        metafunc.parametrize("packaging", values, indirect=True)


def pytest_configure(config):
    config.addinivalue_line("markers", "native_autostart: checks the native Linux autostart desktop entry")


def pytest_collection_modifyitems(config, items):
    if config.getoption("--packaging") != "flatpak":
        return
    removed = [item for item in items if item.get_closest_marker("native_autostart")]
    if removed:
        config.hook.pytest_deselected(items=removed)
        items[:] = [item for item in items if item not in removed]


@pytest.fixture
def packaging(request):
    return request.param


@pytest.fixture
def launch_app(request, desktop, packaging, tmp_path):
    bundle = Path(request.config.getoption("--bundle")).resolve()
    evidence = Path(request.config.getoption("--evidence")).resolve()
    name = re.sub(r"[^a-zA-Z0-9_.-]", "_", request.node.nodeid)
    with ExitStack() as apps:
        def launch(env=None):
            return apps.enter_context(App.create(bundle, packaging, tmp_path, evidence / f"{name}.app.log", env=env))
        yield launch


@pytest.fixture
def autostart(request, launch_app, tmp_path):
    from autostart import Autostart

    evidence = Path(request.config.getoption("--evidence")).resolve()
    name = re.sub(r"[^a-zA-Z0-9_.-]", "_", request.node.nodeid)
    scenario = Autostart(Path(request.config.getoption("--bundle")).resolve(), tmp_path / "home", evidence / name, launch_app)
    try:
        yield scenario
    finally:
        scenario.snapshot("final")
