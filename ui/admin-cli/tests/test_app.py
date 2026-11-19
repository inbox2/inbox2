import pytest

from inbox2_saas.app import SaasApp
from inbox2_saas.config import Config
from inbox2_saas.screens import (
    DashboardScreen,
    OrgsScreen,
    UsersScreen,
    WaitlistDetailScreen,
    WaitlistScreen,
)


class FakeApi:
    async def dashboard(self):
        return {
            "organizations": {"total": 3, "suspended": 1, "by_status": {"verified": 3}, "new_7d": 1},
            "users": {"total": 9, "new_7d": 2},
            "mailboxes": {"active": 9, "invited": 0, "total": 9},
            "plans": {"free": 2, "paid": 1},
            "mail": {"inbound_7d": 10, "outbound_7d": 4},
            "disk": {"bytes_stored": 5 * 1024 ** 3, "orgs_using": 2, "uploads_7d": 12, "links_created_7d": 3,
                     "imports_7d": {"done": 1, "failed": 1},
                     "previews_7d": [{"mime": "application/pdf", "opens": 40, "failures": 0},
                                     {"mime": "image/heic", "opens": 2, "failures": 3}]},
        }

    async def orgs(self, q="", page=1, per_page=100):
        return {"organizations": [
            {"id": "org_1", "name": "Acme", "domain": "acme.test", "plan": "Paid",
             "mailbox_count": 2, "effective_mailbox_limit": 5, "status": "verified", "suspended": False},
        ], "meta": {"total": 1, "page": 1, "per_page": 100}}

    async def users(self, q="", page=1, per_page=100):
        return {"users": [
            {"id": "usr_1", "username": "alice", "billing_email": "a@x.test", "plan": "Free", "memberships": []},
        ], "meta": {"total": 1, "page": 1, "per_page": 100}}

    async def waitlist(self, q="", page=1, per_page=100):
        return {"waitlist_signups": [
            {"id": "wls_1", "name": "Dana", "email": "dana@x.test", "company": "FBI",
             "industry": "developer", "status": "pending", "created_at": "2026-06-26T00:00:00Z"},
        ], "meta": {"total": 1, "page": 1, "per_page": 100}}

    async def waitlist_entry(self, key):
        return {"id": key, "name": "Dana", "email": "dana@x.test", "company": "FBI",
                "industry": "developer", "status": "pending",
                "email_services": {"gmail_count": 2, "office365_count": 1, "others": ["Fastmail"]},
                "social_accounts": {"whatsapp_count": 1, "meta_count": 0, "messenger_count": 0, "others": []},
                "created_at": "2026-06-26T00:00:00Z"}

    async def invite_waitlist(self, key):
        return {"waitlist_signup": {"id": key, "status": "invited"}}


@pytest.mark.asyncio
async def test_dashboard_boots_and_navigates():
    app = SaasApp(FakeApi(), Config())
    async with app.run_test() as pilot:
        assert isinstance(app.screen, DashboardScreen)
        # metrics rendered
        assert "Organizations" in str(app.screen.query_one("#m-orgs").render())
        disk = str(app.screen.query_one("#m-disk").render())
        assert "uploads 12" in disk and "links 3" in disk and "done=1" in disk
        # only the type whose previews failed is named, as failures out of attempts
        assert "image/heic 3/5" in disk and "application/pdf" not in disk

        await pilot.press("o")
        await pilot.pause()
        assert isinstance(app.screen, OrgsScreen)
        assert app.screen.query_one("#orgs").row_count == 1

        await pilot.press("escape")
        await pilot.pause()
        await pilot.press("u")
        await pilot.pause()
        assert isinstance(app.screen, UsersScreen)
        assert app.screen.query_one("#users").row_count == 1


@pytest.mark.asyncio
async def test_waitlist_navigation_and_detail():
    app = SaasApp(FakeApi(), Config())
    async with app.run_test() as pilot:
        await pilot.press("w")
        await pilot.pause()
        assert isinstance(app.screen, WaitlistScreen)
        assert app.screen.query_one("#waitlist").row_count == 1

        # Drill into the entry detail and confirm the submitted fields render.
        app.push_screen(WaitlistDetailScreen("wls_1"))
        await pilot.pause()
        assert isinstance(app.screen, WaitlistDetailScreen)
        info = str(app.screen.query_one("#info").render())
        assert "Dana" in info
        assert "Gmail" in info
        assert "WhatsApp" in info
