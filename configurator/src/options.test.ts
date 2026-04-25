import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { BOOLEAN_OPTIONS } from './options';

const indexHtml = readFileSync(
  join(dirname(fileURLToPath(import.meta.url)), '..', 'index.html'),
  'utf8',
);

describe('BOOLEAN_OPTIONS', () => {
  it('has at least one entry (guards against accidental empty array)', () => {
    expect(BOOLEAN_OPTIONS.length).toBeGreaterThan(0);
  });

  it.each(BOOLEAN_OPTIONS)(
    'entry %# ($configKey): inputId "$inputId" exists in index.html',
    ({ inputId }) => {
      // Looking for `id="opt-tz"` in the static HTML. Using a regex instead
      // of full HTML parsing because this is a one-assertion file read.
      const found = new RegExp(`id="${inputId}"`).test(indexHtml);
      expect(found, `expected <element id="${inputId}"> in index.html`).toBe(true);
    },
  );

  it('has unique inputIds across all entries', () => {
    const inputIds = BOOLEAN_OPTIONS.map((o) => o.inputId);
    expect(new Set(inputIds).size).toBe(inputIds.length);
  });

  it('has unique urlKeys across all entries', () => {
    const urlKeys = BOOLEAN_OPTIONS.map((o) => o.urlKey);
    expect(new Set(urlKeys).size).toBe(urlKeys.length);
  });

  it('has unique configKeys across all entries', () => {
    const keys = BOOLEAN_OPTIONS.map((o) => o.configKey);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it('does not collide with the reserved "p", "b", "tz", "vr", "vm", "vb", "x" URL keys', () => {
    // These keys are used by platform/branch/tz/volumes/extras in urlState.
    // A new boolean toggle grabbing one would silently clobber that state.
    const reserved = new Set(['p', 'b', 'tz', 'vr', 'vm', 'vb', 'x']);
    for (const o of BOOLEAN_OPTIONS) {
      expect(reserved.has(o.urlKey), `urlKey "${o.urlKey}" collides with a reserved non-boolean key`).toBe(false);
    }
  });
});
