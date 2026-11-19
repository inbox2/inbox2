"""Textual app + click entrypoint for the SaaS ops TUI."""

from __future__ import annotations

import contextlib

import click
from textual.app import App
from textual.binding import Binding

from .api import ApiError, SaasApi
from .config import config_path, fingerprint_from_cert, load_config
from .constants import DEFAULT_THEME, MODES
from .modals import SearchPalette
from .screens import DashboardScreen, OrgDetailScreen, UserDetailScreen


class SaasApp(App):
    TITLE = "Inbox2 SaaS"
    SUB_TITLE = "operations"

    CSS = "Screen { background: $background; }"

    BINDINGS = [
        Binding("ctrl+k", "search", "Search"),
        Binding("q", "quit", "Quit"),
        Binding("ctrl+q", "quit", "Quit", show=False),
    ]

    def __init__(self, api: SaasApi, config):
        super().__init__()
        self.api = api
        self.config = config

    def on_mount(self) -> None:
        self.theme = DEFAULT_THEME
        self.push_screen(DashboardScreen())

    async def call(self, coro, ok: str | None = None):
        """Await an api coroutine, surfacing failures as notifications (the
        single error chokepoint, mirroring ui/cli's _rpc)."""
        try:
            result = await coro
            if ok:
                self.notify(ok)
            return result
        except ApiError as e:
            self.notify(str(e), severity="error")
        except Exception as e:  # noqa: BLE001
            self.notify(f"error: {e}", severity="error")
        return None

    def action_search(self) -> None:
        def done(ref):
            if not ref:
                return
            kind, key = ref
            if kind == "org":
                self.push_screen(OrgDetailScreen(key))
            else:
                self.push_screen(UserDetailScreen(key))
        self.push_screen(SearchPalette(self.api), done)


# ── click entrypoint ──────────────────────────────────────────────────────────
@click.group(invoke_without_command=True)
@click.option("--origin", help="API origin, e.g. https://api.inbox2.com")
@click.option("--mode", type=click.Choice(MODES), help="auth transport (mtls|header)")
@click.option("--client-cert", type=click.Path(), help="PEM client cert (mtls / fingerprint source)")
@click.option("--client-key", type=click.Path(), help="PEM client key (if separate)")
@click.option("--ca-bundle", type=click.Path(), help="server CA bundle to verify")
@click.option("--fingerprint", help="cert fingerprint (header mode; overrides cert-derived)")
@click.option("--save", is_flag=True, help="persist these settings to the config file")
@click.pass_context
def main(ctx, origin, mode, client_cert, client_key, ca_bundle, fingerprint, save):
    """Inbox2 SaaS operations TUI. Run with no subcommand to launch the UI."""
    if ctx.invoked_subcommand is not None:
        return

    cfg = load_config(
        origin=origin, mode=mode, client_cert=client_cert,
        client_key=client_key, ca_bundle=ca_bundle, fingerprint=fingerprint,
    )
    if save:
        cfg.save()
        click.echo(f"Saved config to {config_path()}")

    try:
        api = SaasApi(cfg)
    except ApiError as e:
        raise SystemExit(f"config error: {e}")

    app = SaasApp(api, cfg)
    try:
        app.run()
    finally:
        import asyncio
        with contextlib.suppress(Exception):
            asyncio.run(api.aclose())


@main.command()
@click.argument("cert", type=click.Path(exists=True))
def fingerprint(cert):
    """Print the SHA-256 fingerprint of CERT (the AdminCredential value)."""
    click.echo(fingerprint_from_cert(cert))


if __name__ == "__main__":
    main()
