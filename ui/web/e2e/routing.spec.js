import { test, expect } from '@playwright/test';
import path from 'node:path';

/* Routing — the user → org → domain URL scheme (see docs/Routing.md).
 *
 * Seeded org "Acme Corp" (slug `acme-corp`) owns two equal domains: acme.com
 * (default, slug `acme-com`) and widgets.co (slug `widgets-co`). Note the org
 * slug differs from the default domain slug — the case that distinguishes
 * "whole-org MX pool" (org slug) from "one domain" (domain slug).
 *
 * Verifies: each domain is its own addressable workspace, the unified cube maps a
 * domain path back to the org slug, switching domains keeps every tab (the bug
 * that started this), and per-domain settings open + operate on the RIGHT domain —
 * including remove-domain removing only that domain, never the org. */

const ORG = 'acme-corp';
const authState = (u) => path.join(process.cwd(), 'e2e', '.auth', `${u}.json`);

// The top workspace tab strip (scopes tab lookups away from mail-body content
// that may also contain a domain name).
const tab = (page, name) => page.getByTestId('chrome-tabs').getByRole('button', { name });

test.describe('routing — user → org → domain', () => {
  test.use({ storageState: authState('demo') });

  test('console "Open" routes each domain to its own /:domainSlug/mail/inbox', async ({ page }) => {
    await page.goto('/console');
    await page.locator('article').filter({ hasText: 'acme.com' })
      .getByRole('button', { name: 'Open' }).click();
    await page.waitForURL('**/acme-com/mail/inbox');

    await page.goto('/console');
    await page.locator('article').filter({ hasText: 'widgets.co' })
      .getByRole('button', { name: 'Open' }).click();
    await page.waitForURL('**/widgets-co/mail/inbox');
  });

  test('switching domains keeps every tab and gives each its own URL', async ({ page }) => {
    await page.goto('/acme-com/mail/inbox');

    // Both domain tabs render (accessible name is like "inbox2 acme.com").
    const acmeTab = tab(page, 'acme.com');
    const widgetsTab = tab(page, 'widgets.co');
    await expect(acmeTab).toBeVisible();
    await expect(widgetsTab).toBeVisible();

    // Select widgets.co → the URL becomes its own slug AND both tabs remain. The
    // original bug: selecting a domain landed on the unified route, dropping the
    // other tabs / showing only the primary domain.
    await widgetsTab.click();
    await page.waitForURL('**/widgets-co/mail/inbox');
    await expect(acmeTab).toBeVisible();
    await expect(widgetsTab).toBeVisible();
    // (That the pool is genuinely narrowed to the selected domain is covered
    // deterministically by domain-access.spec.js.)
  });

  test('the unified view shows every per-domain tab (not one per-org tab)', async ({ page }) => {
    // Regression: the unified view fed ChromeBar a per-ORG account list, so it
    // collapsed the domain tabs into a single "org" tab. It must show the same
    // per-domain tabs as the single-domain view.
    await page.goto(`/${ORG}/mail`);
    await expect(tab(page, 'acme.com')).toBeVisible();
    await expect(tab(page, 'widgets.co')).toBeVisible();
  });

  test('the unified cube routes a domain path back to the ORG slug', async ({ page }) => {
    await page.goto('/widgets-co/mail/inbox');
    // Cube button's accessible label comes from its tooltip title "Unified Inbox".
    await page.getByRole('button', { name: /Unified Inbox/ }).click();
    // Org-level: /:orgSlug/mail (not /widgets-co/mail) — no domain slug leaks in.
    await page.waitForURL(new RegExp(`/${ORG}/mail(\\?.*)?$`));
  });

  test('each domain card opens ITS OWN per-domain settings', async ({ page }) => {
    // Default domain → org-wide brand (Organization name) is editable here.
    // exact: the card <article role=button> also contains "Manage acme.com".
    await page.goto('/console');
    await page.getByRole('button', { name: 'Manage acme.com', exact: true }).click();
    await page.waitForURL('**/console/domains/acme-com');
    await expect(page.getByRole('heading', { name: 'acme.com', exact: true })).toBeVisible();
    await expect(page.getByText('Default domain')).toBeVisible();
    await expect(page.getByText('Square icon')).toBeVisible();
    await expect(page.getByText('Organization name')).toBeVisible();

    // Non-default domain → per-domain icon, but NO org-wide brand fields.
    await page.goto('/console');
    await page.getByRole('button', { name: 'Manage widgets.co', exact: true }).click();
    await page.waitForURL('**/console/domains/widgets-co');
    await expect(page.getByRole('heading', { name: 'widgets.co', exact: true })).toBeVisible();
    await expect(page.getByText('Square icon')).toBeVisible();
    await expect(page.getByText('Organization name')).toHaveCount(0);
  });

  test('removing a domain from its settings removes ONLY that domain, not the org', async ({ page }) => {
    const name = `e2e-routing-${Date.now().toString(36)}${Math.floor(Math.random() * 1e3)}.test`;
    const slug = name.replace(/\./g, '-');

    // Add a throwaway (pending) domain via the onboarding wizard.
    await page.goto('/onboarding');
    await page.getByLabel('Your domain').fill(name);
    await page.getByRole('button', { name: 'Add domain' }).click();
    await expect(page.getByRole('heading', { name: `Verify ${name}` })).toBeVisible();

    // Open ITS settings by domain slug (fresh load → the session org list now
    // includes it) and remove it via Advanced. Before the fix this called
    // deleteOrg — which would have wiped Acme Corp and every sibling domain.
    await page.goto(`/console/domains/${slug}`);
    await expect(page.getByRole('heading', { name, exact: true })).toBeVisible();
    await page.getByRole('button', { name: 'Advanced' }).click();
    await page.getByRole('button', { name: 'Remove domain' }).click();
    const dialog = page.getByRole('dialog');
    await expect(dialog.getByRole('heading', { name: 'Remove domain?' })).toBeVisible();
    await dialog.getByRole('button', { name: 'Remove domain' }).click();

    // Back on the console: the throwaway is gone, but the org + its two seeded
    // domains survive (this is the whole point — remove-domain ≠ delete-org).
    await page.waitForURL('**/console');
    await expect(page.locator('article').filter({ hasText: name })).toHaveCount(0);
    await expect(page.getByText('acme.com').first()).toBeVisible();
    await expect(page.getByText('widgets.co').first()).toBeVisible();
  });
});
