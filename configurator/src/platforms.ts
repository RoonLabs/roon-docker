import type { Platform, PlatformMap, ValidationIssue } from './types';

// Loads platform presets from ./platforms/*.json at runtime.
// The manifest's ordering drives dropdown display order; the first entry
// is treated as the default platform.

export type LoadedPlatforms = {
  platforms: PlatformMap;
  order: readonly string[];
};

// Shape check for platform JSON loaded over the network. Beats a blind `as`
// cast: a malformed platform file fails loudly during init with a message
// pointing at the bad field, instead of producing a half-broken UI.
function isPlatform(v: unknown, id: string): v is Platform {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  const stringKeys: readonly (keyof Platform)[] = ['id', 'label', 'roon', 'music', 'backup', 'prefix', 'hint'];
  for (const k of stringKeys) {
    if (typeof o[k] !== 'string') throw new Error(`platforms/${id}.json: "${k}" must be a string`);
  }
  if (o['id'] !== id) throw new Error(`platforms/${id}.json: "id" must equal "${id}"`);
  if (o['rootPattern'] !== undefined && typeof o['rootPattern'] !== 'string') {
    throw new Error(`platforms/${id}.json: "rootPattern" must be a string if present`);
  }
  if (o['hidden'] !== undefined && typeof o['hidden'] !== 'boolean') {
    throw new Error(`platforms/${id}.json: "hidden" must be a boolean if present`);
  }
  if (o['userOverride'] !== undefined && typeof o['userOverride'] !== 'string') {
    throw new Error(`platforms/${id}.json: "userOverride" must be a string if present`);
  }
  return true;
}

export async function loadPlatforms(): Promise<LoadedPlatforms> {
  const manifestResp = await fetch('./platforms/index.json');
  if (!manifestResp.ok) throw new Error('platforms/index.json: ' + manifestResp.status);
  const manifestRaw: unknown = await manifestResp.json();
  if (!Array.isArray(manifestRaw) || !manifestRaw.every((v) => typeof v === 'string')) {
    throw new Error('platforms/index.json: expected an array of strings');
  }
  const order: readonly string[] = manifestRaw;

  const entries = await Promise.all(
    order.map(async (id): Promise<[string, Platform]> => {
      const r = await fetch('./platforms/' + id + '.json');
      if (!r.ok) throw new Error('platforms/' + id + '.json: ' + r.status);
      const raw: unknown = await r.json();
      if (!isPlatform(raw, id)) throw new Error(`platforms/${id}.json: invalid shape`);
      return [id, raw];
    }),
  );

  return { platforms: Object.fromEntries(entries), order };
}

export function validatePrefix(
  platforms: PlatformMap,
  platformId: string,
  path: string,
): ValidationIssue | null {
  if (!path) return null;
  const p = platforms[platformId];
  if (!p || !p.rootPattern) return null;
  const re = new RegExp(p.rootPattern);
  if (re.test(path)) return null;
  return {
    severity: 'warning',
    message: p.label + ' paths typically start with ' + p.prefix,
  };
}

// Matches ASCII control characters (C0 + DEL). Rejecting these at the
// validation layer keeps newline/tab/NUL-byte injection payloads out of
// the generator entirely — defense-in-depth alongside the output quoting.
const CONTROL_CHARS = /[\x00-\x1f\x7f]/;

// Validates a host-side volume path. Returns the most severe issue found.
// Checked in order:
//   1. Control characters → ERROR. Newlines inside a double-quoted YAML
//      scalar break out of it, so a crafted URL could inject fake volume
//      entries into the clipboard output. Reject at the boundary.
//   2. Relative path → ERROR. Docker creates a named volume that hides the
//      user's files; silent data-loss risk.
//   3. Platform prefix mismatch → WARNING. Docker accepts it; the user may
//      have a non-standard layout.
export function validateVolumePath(
  platforms: PlatformMap,
  platformId: string,
  path: string,
): ValidationIssue | null {
  if (!path) return null;
  if (CONTROL_CHARS.test(path)) {
    return {
      severity: 'error',
      message: 'Path contains a control character (line break, tab, or similar). Remove any invisible characters.',
    };
  }
  if (!path.startsWith('/')) {
    return {
      severity: 'error',
      message:
        'Path must be absolute (start with /). Relative paths become Docker named volumes, which are hidden from the host.',
    };
  }
  return validatePrefix(platforms, platformId, path);
}

// Container paths already bound by the three required volume mounts.
// An extra mount to any of these would shadow a required one.
export const RESERVED_CONTAINER_PATHS = ['/Roon', '/Music', '/RoonBackups'] as const satisfies readonly string[];

function isReservedContainerPath(path: string): boolean {
  return (RESERVED_CONTAINER_PATHS as readonly string[]).includes(path);
}

// Validates a container-side volume path for an extra mount.
// Checked in order:
//   1. Empty → ERROR.
//   2. Not absolute → ERROR.
//   3. Collides with a required mount (/Roon, /Music, /RoonBackups) → ERROR.
//   4. Duplicates another extra's container path → ERROR.
export function validateContainerPath(
  path: string,
  otherContainerPaths: readonly string[] = [],
): ValidationIssue | null {
  if (!path) {
    return { severity: 'error', message: 'Container path is required.' };
  }
  if (CONTROL_CHARS.test(path)) {
    return {
      severity: 'error',
      message: 'Container path contains a control character. Remove any invisible characters.',
    };
  }
  if (!path.startsWith('/')) {
    return {
      severity: 'error',
      message: 'Container path must be absolute (start with /).',
    };
  }
  if (isReservedContainerPath(path)) {
    return {
      severity: 'error',
      message:
        path + ' is already mounted by the required volumes — use a subpath like ' + path + '/extra.',
    };
  }
  if (otherContainerPaths.includes(path)) {
    return {
      severity: 'error',
      message: 'Container path ' + path + ' is mounted more than once. Each mount needs a unique destination.',
    };
  }
  return null;
}

// Picks the most severe issue from a list, preferring errors over warnings.
export function firstError(
  ...issues: (ValidationIssue | null)[]
): ValidationIssue | null {
  for (const i of issues) if (i?.severity === 'error') return i;
  for (const i of issues) if (i) return i;
  return null;
}
