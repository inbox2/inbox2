import { test, expect } from '@playwright/test';
import path from 'node:path';

/* Team management on the demo org's Team tab, pre-authed as the owner: the invite
 * modal, and a member activate/deactivate round-trip. (Grant/revoke domain access
 * is covered in domain-access.spec.js.) */

const ORG = 'acme-corp';
const authState = (u) => path.join(process.cwd(), 'e2e', '.auth', `${u}.json`);

test.describe('team management', () => {
  test.use({ storageState: authState('demo') });

  test.beforeEach(async ({ page }) => {
    await page.goto(`/console/domains/${ORG}?tab=team`);
    await expect(page.getByRole('row').filter({ hasText: 'Sarah Chen' })).toBeVisible();
  });

  test('the invite modal exposes the invite fields', async ({ page }) => {
    await page.getByRole('button', { name: 'Invite' }).click();
    await expect(page.getByRole('heading', { name: 'Invite a teammate' })).toBeVisible();
    await expect(page.getByPlaceholder('teammate@external.com')).toBeVisible();
    await expect(page.getByPlaceholder('firstname')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Send invite' })).toBeVisible();
    await page.getByRole('button', { name: 'Cancel' }).click();
    await expect(page.getByRole('heading', { name: 'Invite a teammate' })).toHaveCount(0);
  });

  test('deactivating and reactivating a member round-trips', async ({ page }) => {
    const maria = page.getByRole('row').filter({ hasText: 'Maria Lopez' });
    await expect(maria).toBeVisible();
    await expect(maria.getByText('Active')).toBeVisible();

    // Deactivate (RowActionsMenu items are <button>s portaled to <body>).
    await maria.getByRole('button', { name: 'Actions' }).click();
    await page.getByRole('button', { name: 'Deactivate' }).click();
    await expect(maria.getByText('Disabled')).toBeVisible();

    // Reactivate to restore the seeded state.
    await maria.getByRole('button', { name: 'Actions' }).click();
    await page.getByRole('button', { name: 'Reactivate' }).click();
    await expect(maria.getByText('Active')).toBeVisible();
  });
});
