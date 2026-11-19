import { test, expect, request } from '@playwright/test';

/* Full onboarding, unauthenticated: sign up a brand-new user → connect the first
 * domain → verify (stubbed, since a fake domain can't pass a real DNS check) →
 * finish. Creates a throwaway org that afterAll deletes via the API. */

const API = process.env.INBOX2_API_ORIGIN || 'http://localhost:4000';

test.describe('onboarding: signup → connect a domain', () => {
  // Fresh, signed-out context — this suite exercises the real signup + wizard.
  test.use({ storageState: { cookies: [], origins: [] } });

  let cleanupToken = null;

  test('signs up, connects a domain, verifies, and reaches the finish step', async ({ page }) => {
    const suffix = `${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`;
    const username = `e2e_${suffix}`;
    const domain = `e2e-${suffix}.test`;

    // --- Signup ---
    await page.goto('/signup');
    await expect(page.getByText('Create your account')).toBeVisible();
    await page.getByLabel('Username').fill(username);
    await page.getByLabel('Billing email').fill(`${username}@external.com`);
    await page.getByLabel('Password').fill('password123');
    await page.getByLabel('Confirm password').fill('password123'); // renders once password is set
    await page.getByRole('button', { name: 'Create account' }).click();

    await page.waitForURL('**/console', { timeout: 45_000 });
    // A brand-new user owns no domains yet.
    await expect(page.getByText('No domains connected yet')).toBeVisible();
    cleanupToken = await page.evaluate(() => localStorage.getItem('inbox2_cloud_auth_token'));

    // --- Connect the first domain (creates the org) ---
    await page.getByRole('button', { name: 'Connect a domain' }).click();
    await page.waitForURL('**/onboarding');
    await expect(page.getByRole('heading', { name: 'Connect your domain' })).toBeVisible();
    await expect(page.getByText('Step 1 of 3')).toBeVisible();

    await page.getByLabel('Your domain').fill(domain);
    await page.getByRole('button', { name: 'Add domain' }).click();

    // --- Step 1: DNS records + verify ---
    await expect(page.getByRole('heading', { name: `Verify ${domain}` })).toBeVisible();
    await expect(page.getByText('MX').first()).toBeVisible(); // a DNS record row
    await expect(page.getByText('Step 2 of 3')).toBeVisible();

    // A fake domain can't pass a real DNS check, so stub the verify call to
    // succeed and drive the flow through to the finish step.
    await page.route('**/dns/verify', (route) => route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ status: 'verified', verified: true, checks: { mx: true, spf: true, dmarc: true, dkim: true } }),
    }));
    await page.getByRole('button', { name: 'Verify now' }).click();

    // --- Step 2: finish ---
    await expect(page.getByRole('heading', { name: /all set/i })).toBeVisible();
    await expect(page.getByText('Step 3 of 3')).toBeVisible();
    await page.getByRole('button', { name: 'Go to inbox' }).click();
  });

  test.afterAll(async () => {
    if (!cleanupToken) return;
    const ctx = await request.newContext({ extraHTTPHeaders: { Authorization: `Bearer ${cleanupToken}` } });
    const acct = await ctx.get(`${API}/api/v1/account`);
    if (acct.ok()) {
      for (const o of (await acct.json()).organizations || []) {
        await ctx.delete(`${API}/api/v1/orgs/${o.id}`);
      }
    }
    await ctx.dispose();
  });
});
