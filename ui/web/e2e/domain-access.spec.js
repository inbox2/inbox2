import { test, expect } from '@playwright/test';
import path from 'node:path';

/* Per-domain pool access, driven through the real UI against the seeded demo org
 * (acme-corp): domains acme.com + widgets.co, one shared pool, members scoped —
 * sarah → widgets.co only, alex → acme.com only, owner/admins → all domains.
 *
 * Actors are pre-authenticated in global-setup (token injected via storageState),
 * so specs start already logged in — no flaky UI-login / boot-signout race. */

const ORG = 'acme-corp';
const authState = (user) => path.join(process.cwd(), 'e2e', '.auth', `${user}.json`);

test.describe('per-domain pool access — owner', () => {
  test.use({ storageState: authState('demo') });

  test('sees one card per domain in the console', async ({ page }) => {
    await page.goto('/console');
    await expect(page.getByText('acme.com').first()).toBeVisible();
    await expect(page.getByText('widgets.co').first()).toBeVisible();
  });

  test('Team tab shows each member scoped to their domains', async ({ page }) => {
    await page.goto(`/console/domains/${ORG}?tab=team`);

    const sarah = page.getByRole('row').filter({ hasText: 'Sarah Chen' });
    await expect(sarah).toBeVisible();
    await expect(sarah.getByText('widgets.co')).toBeVisible();

    const alex = page.getByRole('row').filter({ hasText: 'Alex Kim' });
    await expect(alex.getByText('acme.com')).toBeVisible();

    // Owner/admins are unscoped.
    await expect(page.getByText('All domains').first()).toBeVisible();
  });

  test('granting a domain in the Team tab lets it through (round-trip)', async ({ page }) => {
    await page.goto(`/console/domains/${ORG}?tab=team`);
    const sarah = page.getByRole('row').filter({ hasText: 'Sarah Chen' });
    await expect(sarah).toBeVisible();

    // Grant acme.com via the "+ Domain" menu (DropdownMenu items are <button>s
    // portaled to <body>, so target on `page`), confirm the chip appears…
    await sarah.getByRole('button', { name: /domain/i }).click();
    await page.getByRole('button', { name: 'acme.com', exact: true }).click();
    await expect(sarah.getByText('acme.com')).toBeVisible();
    await expect(sarah.getByText('widgets.co')).toBeVisible();

    // …then revoke acme.com again to restore the seeded state.
    await sarah.getByLabel('Revoke acme.com').click();
    await expect(sarah.getByText('acme.com')).toHaveCount(0);
    await expect(sarah.getByText('widgets.co')).toBeVisible();
  });
});

test.describe('per-domain pool access — scoped member', () => {
  test.use({ storageState: authState('sarah') });

  test('sees only their granted domain’s mail', async ({ page }) => {
    await page.goto(`/${ORG}/mail/inbox`);

    // Sarah's granted domain (widgets.co) is visible…
    await expect(page.getByText('widgets.co — order #4821', { exact: false })).toBeVisible();
    // …an acme.com-only thread is NOT (visibility boundary enforced server-side).
    await expect(page.getByText('Q4 Board Presentation', { exact: false })).toHaveCount(0);
  });
});
