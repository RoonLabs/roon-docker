import { describe, it, expect } from 'vitest';
import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, basename } from 'node:path';
import Ajv from 'ajv/dist/2020';
import {
  validatePrefix,
  validateVolumePath,
  validateContainerPath,
  firstError,
  RESERVED_CONTAINER_PATHS,
} from './platforms';
import type { Platform, PlatformMap } from './types';

const platformsDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'public', 'platforms');

function loadPlatformFile(id: string): Platform {
  const raw = readFileSync(join(platformsDir, id + '.json'), 'utf8');
  return JSON.parse(raw) as Platform;
}

describe('validatePrefix', () => {
  const platforms: PlatformMap = {
    synology: {
      id: 'synology',
      label: 'Synology',
      roon: '/volume1/roon',
      music: '/volume1/music',
      backup: '/volume1/backups',
      prefix: '/volume1/',
      hint: '',
      rootPattern: '^/volume\\d+/',
    },
    custom: {
      id: 'custom',
      label: 'Custom',
      roon: '/x', music: '/y', backup: '/z',
      prefix: '',
      hint: '',
    },
  };

  it('returns null for empty path', () => {
    expect(validatePrefix(platforms, 'synology', '')).toBeNull();
  });

  it('returns null when the path matches the platform root pattern', () => {
    expect(validatePrefix(platforms, 'synology', '/volume1/music')).toBeNull();
    expect(validatePrefix(platforms, 'synology', '/volume2/media')).toBeNull();
  });

  it('returns a warning-severity issue when the path does not match the root pattern', () => {
    const issue = validatePrefix(platforms, 'synology', '/share/music');
    expect(issue?.severity).toBe('warning');
    expect(issue?.message).toContain('Synology');
    expect(issue?.message).toContain('/volume1/');
  });

  it('returns null when the platform has no rootPattern (no validation)', () => {
    expect(validatePrefix(platforms, 'custom', '/anywhere/really')).toBeNull();
  });

  it('returns null for an unknown platform id', () => {
    expect(validatePrefix(platforms, 'not-a-real-platform', '/path')).toBeNull();
  });
});

describe('validateVolumePath', () => {
  const platforms: PlatformMap = {
    qnap: {
      id: 'qnap', label: 'QNAP',
      roon: '/share/Container/roon', music: '/share/Music', backup: '/share/Container/roon-backups',
      prefix: '/share/', hint: '', rootPattern: '^/share/',
    },
    custom: {
      id: 'custom', label: 'Custom',
      roon: '/x', music: '/y', backup: '/z', prefix: '', hint: '',
    },
  };

  it('returns null for empty path', () => {
    expect(validateVolumePath(platforms, 'qnap', '')).toBeNull();
  });

  it('rejects relative paths with error severity', () => {
    // Regression guard: user reported that `share/Music` (no leading /) passed silently.
    const issue = validateVolumePath(platforms, 'qnap', 'share/Music');
    expect(issue?.severity).toBe('error');
    expect(issue?.message).toContain('absolute');
    expect(issue?.message).toContain('named volume');
  });

  it('rejects relative paths even on platforms with no rootPattern', () => {
    const issue = validateVolumePath(platforms, 'custom', 'relative/path');
    expect(issue?.severity).toBe('error');
    expect(issue?.message).toContain('absolute');
  });

  it('accepts absolute paths that match the platform prefix', () => {
    expect(validateVolumePath(platforms, 'qnap', '/share/Music')).toBeNull();
  });

  it('returns a prefix-mismatch warning (not error) for absolute paths on the wrong platform', () => {
    const issue = validateVolumePath(platforms, 'qnap', '/volume1/music');
    expect(issue?.severity).toBe('warning');
    expect(issue?.message).toContain('QNAP');
    expect(issue?.message).toContain('/share/');
  });

  it('accepts any absolute path on a platform without rootPattern', () => {
    expect(validateVolumePath(platforms, 'custom', '/any/absolute/path')).toBeNull();
  });

  it('prefers the absolute-path error over prefix mismatch when both apply', () => {
    const issue = validateVolumePath(platforms, 'qnap', 'volume1/music');
    expect(issue?.severity).toBe('error');
    expect(issue?.message).toContain('absolute');
    expect(issue?.message).not.toContain('QNAP');
  });

  it.each([
    ['newline', '/share/Music\n- /etc/shadow:/evil'],
    ['carriage return', '/share/Music\r'],
    ['tab', '/share/\tMusic'],
    ['null byte', '/share/Music\x00'],
    ['escape char', '/share/\x1bMusic'],
  ])('rejects paths containing a %s as an error', (_, path) => {
    const issue = validateVolumePath(platforms, 'qnap', path);
    expect(issue?.severity).toBe('error');
    expect(issue?.message).toContain('control character');
  });
});

describe('validateContainerPath', () => {
  it('returns an error for empty path', () => {
    const issue = validateContainerPath('');
    expect(issue?.severity).toBe('error');
    expect(issue?.message).toContain('required');
  });

  it('returns an error for relative paths', () => {
    const issue = validateContainerPath('Music/extra');
    expect(issue?.severity).toBe('error');
    expect(issue?.message).toContain('absolute');
  });

  it.each([...RESERVED_CONTAINER_PATHS])(
    'flags %s as reserved (collides with a required mount)',
    (reserved) => {
      const issue = validateContainerPath(reserved);
      expect(issue?.severity).toBe('error');
      expect(issue?.message).toContain(reserved);
      expect(issue?.message).toContain('already mounted');
    },
  );

  it('does not flag subpaths of reserved paths', () => {
    expect(validateContainerPath('/Music/extra')).toBeNull();
    expect(validateContainerPath('/Roon/backups')).toBeNull();
  });

  it('flags a container path that duplicates another extra', () => {
    const issue = validateContainerPath('/Music/extra', ['/Music/extra']);
    expect(issue?.severity).toBe('error');
    expect(issue?.message).toContain('mounted more than once');
  });

  it('does not flag a path that appears only once across all rows', () => {
    expect(validateContainerPath('/Music/a', ['/Music/b', '/Music/c'])).toBeNull();
  });

  it('prefers the "reserved" error over the "duplicate" error', () => {
    // If two rows both use /Music, each is reserved — don't also spam about duplicates.
    const issue = validateContainerPath('/Music', ['/Music']);
    expect(issue?.message).toContain('already mounted');
    expect(issue?.message).not.toContain('more than once');
  });
});

describe('firstError', () => {
  const warn = { severity: 'warning' as const, message: 'w' };
  const err = { severity: 'error' as const, message: 'e' };

  it('returns null for all-null input', () => {
    expect(firstError(null, null)).toBeNull();
  });

  it('prefers errors over warnings regardless of order', () => {
    expect(firstError(warn, err)).toBe(err);
    expect(firstError(err, warn)).toBe(err);
  });

  it('returns the first warning if no errors exist', () => {
    const warn2 = { severity: 'warning' as const, message: 'w2' };
    expect(firstError(warn, warn2)).toBe(warn);
  });

  it('returns null if no issues at all', () => {
    expect(firstError(null)).toBeNull();
  });
});

describe('platform JSON files', () => {
  const manifest = JSON.parse(readFileSync(join(platformsDir, 'index.json'), 'utf8')) as string[];

  // Exclude the manifest and schema from the per-platform enumeration —
  // both are meta-files that live alongside the platforms they describe.
  const META_FILES = new Set(['index.json', 'schema.json']);
  const jsonFiles = readdirSync(platformsDir)
    .filter((f) => f.endsWith('.json') && !META_FILES.has(f))
    .map((f) => basename(f, '.json'));

  // Compile the JSON Schema once per test file. Using `allErrors: true` so a
  // malformed contribution surfaces every field problem at once rather than
  // bailing on the first error.
  const schema = JSON.parse(readFileSync(join(platformsDir, 'schema.json'), 'utf8'));
  const ajv = new Ajv({ allErrors: true });
  const validate = ajv.compile(schema);

  it('manifest lists every platform file present on disk', () => {
    expect([...manifest].sort()).toEqual([...jsonFiles].sort());
  });

  it.each<string>(jsonFiles)('%s.json conforms to platform schema', (id: string) => {
    const p = loadPlatformFile(id);
    const ok = validate(p);
    if (!ok) {
      // ajv.errorsText gives "instancePath must have required property 'x'"
      // style messages — good enough to point a contributor at the bad field
      // in their PR's CI output.
      throw new Error(`${id}.json: ${ajv.errorsText(validate.errors)}`);
    }
    // Filename must equal the id — schema can't assert this since it doesn't
    // know the path it was loaded from.
    expect(p.id, `${id}.json: "id" field must equal the filename`).toBe(id);
  });

  it('at least one platform is visible (not hidden)', () => {
    const visible = jsonFiles.filter((id) => !loadPlatformFile(id).hidden);
    expect(visible.length).toBeGreaterThan(0);
  });

  it.each<string>(jsonFiles.filter((id) => loadPlatformFile(id).rootPattern))(
    '%s.json rootPattern compiles as a regex and matches its own paths',
    (id: string) => {
      const p = loadPlatformFile(id);
      // Regex compiles (schema only checks it's a string).
      expect(() => new RegExp(p.rootPattern!)).not.toThrow();
      const re = new RegExp(p.rootPattern!);
      expect(re.test(p.prefix)).toBe(true);
      expect(re.test(p.roon)).toBe(true);
      expect(re.test(p.music)).toBe(true);
      expect(re.test(p.backup)).toBe(true);
    },
  );

  it('truenas.json sets userOverride "0:0"', () => {
    // Regression guard: if this ever disappears, TrueNAS Apps deployments
    // will silently run as UID 568 and fail with `Permission denied` when
    // the entrypoint tries to exec start.sh. See the TrueNAS arc for the
    // full diagnostic story.
    const p = loadPlatformFile('truenas');
    expect(p.userOverride).toBe('0:0');
  });
});
