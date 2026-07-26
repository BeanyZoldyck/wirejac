"""Start Jac's API server with an enforced loopback bind."""

from __future__ import annotations

import sys

from jaclang.scale.jserver.jfast_api import JFastApiServer


_run_server = JFastApiServer.run_server


def _run_server_on_loopback(
    self: JFastApiServer,
    host: str = "127.0.0.1",
    port: int = 8000,
    max_retries: int = 10,
) -> None:
    _run_server(self, host="127.0.0.1", port=port, max_retries=max_retries)


JFastApiServer.run_server = _run_server_on_loopback

from jaclang.cli.cli import start_cli  # noqa: E402


if __name__ == "__main__":
    sys.argv = ["jac", "start", "--no-client", *sys.argv[1:], "main.jac"]
    start_cli()
