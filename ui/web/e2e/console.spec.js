import { test, expect } from '@playwright/test';
import path from 'node:path';

/* Console functionality against the seeded demo org (acme-corp), pre-authed as
 * the owner. Covers the overview, the add → verify → remove domain round-trip,
 * billing, the nav menu → API keys, and the per-domain settings tabs. */

const ORG = 'acme-corp';
const authState = (u) => path.join(process.cwd(), 'e2e', '.auth', `${u}.json`);

test.describe('console', () => {
  test.use({ storageState: authState('demo') });

  test('overview renders the stat strip, domain health, and domain cards', async ({ page }) => {
    await page.goto('/console');
    // Stat strip.
    await expect(page.getByText('Spam blocked')).toBeVisible();
    await expect(page.getByText('AI filtering')).toBeVisible();
    // Domain health.
    await expect(page.getByText('Domain health · receiving mail')).toBeVisible();
    // Domains grid.
    await expect(page.getByRole('heading', { name: 'Your domains' })).toBeVisible();
    await expect(page.getByText('acme.com').first()).toBeVisible();
    await expect(page.getByText('widgets.co').first()).toBeVisible();
  });

  test('add a domain → verify modal (not-live path) → remove it', async ({ page }) => {
    const domain = `e2e-console-${Date.now().toString(36)}${Math.floor(Math.random() * 1e3)}.test`;

    // Add via the onboarding wizard (console currentOrg = demo org).
    await page.goto('/onboarding');
    await page.getByLabel('Your domain').fill(domain);
    await page.getByRole('button', { name: 'Add domain' }).click();
    await expect(page.getByRole('heading', { name: `Verify ${domain}` })).toBeVisible();

    // Reload the console — the new domain shows as a Pending-DNS card. (On step 1
    // the wizard's "Back" returns to step 0, so navigate straight to the console.)
    await page.goto('/console');
    const card = page.locator('article').filter({ hasText: domain });
    await expect(card).toBeVisible();
    await expect(card.getByText('Pending DNS')).toBeVisible();

    // Verify modal — a fake domain won't pass, so the check drops into the
    // auto-re-checking "waiting for DNS to propagate" state.
    await card.getByRole('button', { name: 'Verify' }).click();
    await expect(page.getByRole('heading', { name: `Verify ${domain}` })).toBeVisible();
    await page.getByRole('button', { name: 'Verify now' }).click();
    await expect(page.getByText(/re-checking automatically/i)).toBeVisible();
    await page.getByRole('button', { name: 'Close' }).click();

    // Remove it (restores the org to its seeded two-domain state).
    await card.getByRole('button', { name: `Remove ${domain}` }).click();
    await expect(page.getByRole('heading', { name: `Remove ${domain}?` })).toBeVisible();
    await page.getByRole('button', { name: 'Remove domain' }).click();
    await expect(page.locator('article').filter({ hasText: domain })).toHaveCount(0);
  });

  test('billing section shows the plan cards', async ({ page }) => {
    await page.goto('/console');
    await page.getByRole('link', { name: 'Billing' }).click();
    await expect(page.getByRole('heading', { name: 'Billing & plan' })).toBeVisible();
    // Structural strings (plan names/prices are API-driven).
    await expect(page.getByText('Your current plan')).toBeVisible();
    await expect(page.getByText('/mo').first()).toBeVisible();
  });

  test('nav menu opens the API keys page', async ({ page }) => {
    await page.goto('/console');
    await page.getByRole('button', { name: 'Menu' }).click();
    await expect(page.getByRole('menuitem', { name: 'Change password' })).toBeVisible();
    await expect(page.getByRole('menuitem', { name: 'Log out' })).toBeVisible();
    await page.getByRole('menuitem', { name: 'API keys' }).click();
    await page.waitForURL('**/console/api-keys');
    await expect(page.getByRole('heading', { name: 'API keys' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Create a key' })).toBeVisible();
  });

  test('domain settings tabs (DNS / Team / Advanced) switch', async ({ page }) => {
    await page.goto(`/console/domains/${ORG}`);
    // Default tab is Settings.
    await page.getByRole('button', { name: 'DNS' }).click();
    await expect(page.getByRole('heading', { name: 'DNS records' })).toBeVisible();
    await page.getByRole('button', { name: 'Team' }).click();
    await expect(page.getByRole('row').filter({ hasText: 'Sarah Chen' })).toBeVisible();
    await page.getByRole('button', { name: 'Advanced' }).click();
    await expect(page.getByText('Remove this domain')).toBeVisible();
  });
});
