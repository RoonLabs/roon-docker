import { test, expect, type Page } from '@playwright/test';

// Pulls the generated config as plain text by walking the output table's
// code cells, which is closer to what the Copy button produces than innerText.
async function getOutput(page: Page): Promise<string> {
  return page.evaluate(() => {
    const rows = document.querySelectorAll('#output tr');
    return Array.from(rows)
      .map((r) => (r.querySelectorAll('td')[1]?.textContent ?? ''))
      .join('\n');
  });
}

test.beforeEach(async ({ page }) => {
  await page.goto('/');
  // Platforms load asynchronously — wait for the select to have options.
  await page.waitForFunction(
    () => (document.getElementById('platform-select') as HTMLSelectElement)?.options.length > 0,
  );
});

test.describe('Initial state', () => {
  test('defaults to QNAP and populates its paths', async ({ page }) => {
    await expect(page.locator('#platform-select')).toHaveValue('qnap');
    await expect(page.locator('#vol-roon')).toHaveValue('/share/Container/roon');
    await expect(page.locator('#vol-music')).toHaveValue('/share/Music');
    await expect(page.locator('#vol-backup')).toHaveValue('/share/Container/roon-backups');
  });

  test('platform dropdown lists all visible platforms in expected order', async ({ page }) => {
    const values = await page
      .locator('#platform-select option')
      .evaluateAll((els) => els.map((e) => (e as HTMLOptionElement).value));
    expect(values).toEqual(['qnap', 'synology', 'unraid', 'truenas', 'linux', 'custom']);
  });

  test('Copy and Download are enabled with no input errors', async ({ page }) => {
    await expect(page.locator('#btn-copy')).toBeEnabled();
    await expect(page.locator('#btn-download')).toBeEnabled();
  });
});

test.describe('Platform switching', () => {
  test('switching to Synology swaps all three volume paths', async ({ page }) => {
    await page.locator('#platform-select').selectOption('synology');
    await expect(page.locator('#vol-roon')).toHaveValue('/volume1/docker/roon');
    await expect(page.locator('#vol-music')).toHaveValue('/volume1/music');
    await expect(page.locator('#vol-backup')).toHaveValue('/volume1/roon-backups');
    expect(await getOutput(page)).toContain('- /volume1/music:/Music');
  });
});

test.describe('CIFS toggle', () => {
  test('compose output includes cap_add and both LSM opt-outs in security_opt', async ({ page }) => {
    // The <input> is sr-only (visually hidden) and the styled toggle track
    // is its visible sibling. Click the wrapping <label> the way a real
    // user does — Playwright's .check() on the offscreen input fails its
    // post-click state verification in newer versions.
    await page.locator('label:has(#opt-cifs)').click();
    const out = await getOutput(page);
    expect(out).toContain('cap_add:');
    expect(out).toContain('- SYS_ADMIN');
    expect(out).toContain('- DAC_READ_SEARCH');
    expect(out).toContain('security_opt:');
    expect(out).toContain('- apparmor:unconfined');
    expect(out).toContain('- label:disable');
  });

  test('docker run output uses equals-form LSM flags', async ({ page }) => {
    // The <input> is sr-only (visually hidden) and the styled toggle track
    // is its visible sibling. Click the wrapping <label> the way a real
    // user does — Playwright's .check() on the offscreen input fails its
    // post-click state verification in newer versions.
    await page.locator('label:has(#opt-cifs)').click();
    await page.locator('#tab-run').click();
    const out = await getOutput(page);
    expect(out).toContain('--cap-add SYS_ADMIN');
    expect(out).toContain('--security-opt apparmor=unconfined');
    expect(out).toContain('--security-opt label=disable');
    // Regression guard: run uses `=`, not the compose-style `:`.
    expect(out).not.toContain('--security-opt apparmor:unconfined');
    expect(out).not.toContain('--security-opt label:disable');
  });
});

test.describe('Volume path validation', () => {
  test('relative main volume path disables Copy and Download', async ({ page }) => {
    await page.locator('#vol-music').fill('share/Music');
    const warning = page.locator('#vol-music-warning');
    await expect(warning).toBeVisible();
    await expect(warning).toHaveAttribute('data-severity', 'error');
    await expect(warning).toContainText('absolute');
    await expect(page.locator('#btn-copy')).toBeDisabled();
    await expect(page.locator('#btn-download')).toBeDisabled();
  });

  test('correcting the path re-enables the actions', async ({ page }) => {
    await page.locator('#vol-music').fill('share/Music');
    await expect(page.locator('#btn-copy')).toBeDisabled();
    await page.locator('#vol-music').fill('/share/Music');
    await expect(page.locator('#btn-copy')).toBeEnabled();
    await expect(page.locator('#vol-music-warning')).toBeHidden();
  });

  test('wrong-platform path shows a warning but does not block actions', async ({ page }) => {
    await page.locator('#vol-music').fill('/volume1/music');
    const warning = page.locator('#vol-music-warning');
    await expect(warning).toBeVisible();
    await expect(warning).toHaveAttribute('data-severity', 'warning');
    await expect(warning).toContainText('QNAP');
    await expect(page.locator('#btn-copy')).toBeEnabled();
  });
});

test.describe('URL state', () => {
  test('loading with ?c=1 enables the CIFS toggle', async ({ page }) => {
    // E2E value here is that URL state hydrates the DOM checkbox — the
    // compose/run output is covered by unit tests, no need to re-assert.
    await page.goto('/?c=1');
    await page.waitForFunction(
      () => (document.getElementById('platform-select') as HTMLSelectElement)?.options.length > 0,
    );
    await expect(page.locator('#opt-cifs')).toBeChecked();
  });

  test('loading with ?tzOff=1&logOff=1 unchecks the default-on toggles', async ({ page }) => {
    // These are the only "inverted" URL flags (absent = on, present = off),
    // easy to break without E2E coverage.
    await page.goto('/?tzOff=1&logOff=1');
    await page.waitForFunction(
      () => (document.getElementById('platform-select') as HTMLSelectElement)?.options.length > 0,
    );
    await expect(page.locator('#opt-tz')).not.toBeChecked();
    await expect(page.locator('#opt-logging')).not.toBeChecked();
  });

  test('malformed URL params do not crash hydration', async ({ page }) => {
    await page.goto('/?p=notaplatform&b=garbage&x=nocolon&tzOff=maybe');
    await page.waitForFunction(
      () => (document.getElementById('platform-select') as HTMLSelectElement)?.options.length > 0,
    );
    // Unknown platform falls back to the default; invalid branch ignored.
    await expect(page.locator('#platform-select')).toHaveValue('qnap');
    await expect(page.locator('#branch-select')).toHaveValue('production');
    // Malformed extras produced no rows.
    await expect(page.locator('.extra-vol-row')).toHaveCount(0);
  });

  test('loading with ?p=synology&x=... restores the full state', async ({ page }) => {
    await page.goto('/?p=synology&u=1&vm=%2Fvolume1%2Fall&x=%2Fvolume1%2Fm%3A%2FMusic%2Fm');
    await page.waitForFunction(
      () => (document.getElementById('platform-select') as HTMLSelectElement)?.options.length > 0,
    );
    await expect(page.locator('#platform-select')).toHaveValue('synology');
    await expect(page.locator('#opt-usb-audio')).toBeChecked();
    await expect(page.locator('#vol-music')).toHaveValue('/volume1/all');
    const row = page.locator('.extra-vol-row').first();
    await expect(row.locator('.extra-vol-host')).toHaveValue('/volume1/m');
    await expect(row.locator('.extra-vol-container')).toHaveValue('/Music/m');
  });

  test('toggling an option updates the URL without adding history entries', async ({ page }) => {
    await page.goto('/');
    await page.waitForFunction(
      () => (document.getElementById('platform-select') as HTMLSelectElement)?.options.length > 0,
    );
    const initialHistoryLength = await page.evaluate(() => history.length);
    await page.locator('label:has(#opt-cifs)').click();
    await expect(page).toHaveURL(/[?&]c=1(&|$)/);
    // replaceState shouldn't add to history.
    const afterHistoryLength = await page.evaluate(() => history.length);
    expect(afterHistoryLength).toBe(initialHistoryLength);
  });

  test('localStorage hydrates state when URL is empty', async ({ page }) => {
    // First visit: set some non-default state so it gets persisted.
    await page.goto('/');
    await page.waitForFunction(
      () => (document.getElementById('platform-select') as HTMLSelectElement)?.options.length > 0,
    );
    await page.locator('#platform-select').selectOption('synology');
    await page.locator('label:has(#opt-cifs)').click();

    // Return with a clean URL — localStorage should restore Synology + CIFS.
    await page.goto('/');
    await page.waitForFunction(
      () => (document.getElementById('platform-select') as HTMLSelectElement)?.options.length > 0,
    );
    await expect(page.locator('#platform-select')).toHaveValue('synology');
    await expect(page.locator('#opt-cifs')).toBeChecked();
  });

  test('URL parameters override localStorage', async ({ page }) => {
    // Seed localStorage with Synology + CIFS first.
    await page.goto('/');
    await page.waitForFunction(
      () => (document.getElementById('platform-select') as HTMLSelectElement)?.options.length > 0,
    );
    await page.locator('#platform-select').selectOption('synology');
    await page.locator('label:has(#opt-cifs)').click();

    // Now visit with a URL that picks Unraid — share link should win.
    await page.goto('/?p=unraid');
    await page.waitForFunction(
      () => (document.getElementById('platform-select') as HTMLSelectElement)?.options.length > 0,
    );
    await expect(page.locator('#platform-select')).toHaveValue('unraid');
    // CIFS came from persistence and wasn't in the URL; fresh-URL state
    // should mean fresh-URL state — CIFS off.
    await expect(page.locator('#opt-cifs')).not.toBeChecked();
  });

  test('Reset button wipes URL + localStorage and restores defaults', async ({ page }) => {
    await page.goto('/?p=synology&c=1');
    await page.waitForFunction(
      () => (document.getElementById('platform-select') as HTMLSelectElement)?.options.length > 0,
    );

    await page.locator('#btn-reset').click();

    await expect(page.locator('#platform-select')).toHaveValue('qnap');
    await expect(page.locator('#opt-cifs')).not.toBeChecked();

    // URL is clean and localStorage is empty.
    await expect(page).toHaveURL(/^[^?]*$/);
    const stored = await page.evaluate(() => localStorage.getItem('roon-configurator-state'));
    expect(stored).toBeNull();
  });

  test('share button copies the current URL to the clipboard', async ({ page, context }) => {
    await context.grantPermissions(['clipboard-read', 'clipboard-write']);
    await page.goto('/');
    await page.waitForFunction(
      () => (document.getElementById('platform-select') as HTMLSelectElement)?.options.length > 0,
    );
    await page.locator('label:has(#opt-cifs)').click();
    await page.locator('#btn-share').click();
    const clipboard = await page.evaluate(() => navigator.clipboard.readText());
    expect(clipboard).toBe(page.url());
    expect(clipboard).toMatch(/[?&]c=1(&|$)/);
  });
});

test.describe('Extra volumes', () => {
  test('adding a row appends the mount to the output', async ({ page }) => {
    await page.locator('#btn-add-volume').click();
    const row = page.locator('.extra-vol-row').first();
    await row.locator('.extra-vol-host').fill('/share/Media/extra');
    await row.locator('.extra-vol-container').fill('/Music/extra');
    const out = await getOutput(page);
    expect(out).toContain('- /share/Media/extra:/Music/extra');
  });

  test('a freshly added row immediately flags the missing container path as an error', async ({ page }) => {
    // The row starts with the platform prefix in the host input and an
    // empty container input — that's not a valid mount, so Copy/Download
    // should block until the user either fills the container or removes
    // the row with the × button.
    await page.locator('#btn-add-volume').click();
    const row = page.locator('.extra-vol-row').first();
    const warning = row.locator('.extra-vol-warning');
    await expect(warning).toBeVisible();
    await expect(warning).toHaveAttribute('data-severity', 'error');
    await expect(warning).toContainText('Container path is required');
    await expect(page.locator('#btn-copy')).toBeDisabled();

    // Removing the row clears the error and re-enables Copy.
    await row.locator('button[aria-label="Remove volume mount"]').click();
    await expect(page.locator('#btn-copy')).toBeEnabled();
  });

  test('reserved container path is flagged as an error', async ({ page }) => {
    await page.locator('#btn-add-volume').click();
    const row = page.locator('.extra-vol-row').first();
    await row.locator('.extra-vol-container').fill('/Music');
    const warning = row.locator('.extra-vol-warning');
    await expect(warning).toBeVisible();
    await expect(warning).toHaveAttribute('data-severity', 'error');
    await expect(warning).toContainText('already mounted');
    await expect(page.locator('#btn-copy')).toBeDisabled();
  });

  test('duplicate container paths across rows are flagged on both rows', async ({ page }) => {
    await page.locator('#btn-add-volume').click();
    await page.locator('#btn-add-volume').click();
    const rows = page.locator('.extra-vol-row');
    await rows.nth(0).locator('.extra-vol-container').fill('/Music/extra');
    await rows.nth(1).locator('.extra-vol-container').fill('/Music/extra');
    await expect(rows.nth(0).locator('.extra-vol-warning')).toContainText('more than once');
    await expect(rows.nth(1).locator('.extra-vol-warning')).toContainText('more than once');
    await expect(page.locator('#btn-copy')).toBeDisabled();

    // Fix one of them — both warnings should clear.
    await rows.nth(1).locator('.extra-vol-container').fill('/Music/other');
    await expect(rows.nth(0).locator('.extra-vol-warning')).toBeHidden();
    await expect(rows.nth(1).locator('.extra-vol-warning')).toBeHidden();
    await expect(page.locator('#btn-copy')).toBeEnabled();
  });

  test('removing a row clears any duplicate-errors it caused on siblings', async ({ page }) => {
    await page.locator('#btn-add-volume').click();
    await page.locator('#btn-add-volume').click();
    const rows = page.locator('.extra-vol-row');
    await rows.nth(0).locator('.extra-vol-container').fill('/Music/extra');
    await rows.nth(1).locator('.extra-vol-container').fill('/Music/extra');
    await expect(rows.nth(0).locator('.extra-vol-warning')).toBeVisible();

    // Remove the second row; the first should no longer be duplicate.
    await rows.nth(1).locator('button[aria-label="Remove volume mount"]').click();
    await expect(page.locator('.extra-vol-row .extra-vol-warning').first()).toBeHidden();
    await expect(page.locator('#btn-copy')).toBeEnabled();
  });
});
