# Own the real desktop and application lifecycle so scenarios only describe behavior.

from contextlib import ExitStack
from pathlib import Path
import re

import pytest

from runtime import App, Desktop


def pytest_addoption(parser):
    parser.addoption("--bundle", required=True, help="Built Linux release bundle")
    parser.addoption("--evidence", default="linux-e2e-results", help="Application log directory")


@pytest.fixture
def desktop():
    with Desktop() as session:
        yield session


@pytest.fixture(params=["native", "flatpak"])
def packaging(request):
    return request.param


@pytest.fixture
def launch_app(request, desktop, packaging, tmp_path):
    bundle = Path(request.config.getoption("--bundle")).resolve()
    evidence = Path(request.config.getoption("--evidence")).resolve()
    name = re.sub(r"[^a-zA-Z0-9_.-]", "_", request.node.name)
    with ExitStack() as apps:
        def launch():
            return apps.enter_context(App.create(bundle, packaging, tmp_path, evidence / f"{name}.app.log"))
        yield launch
