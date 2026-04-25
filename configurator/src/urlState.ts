import type { Config, ExtraVolume, PlatformMap } from './types';
import { BOOLEAN_OPTIONS, MAIN_VOLUME_OPTIONS } from './options';

// URL-shareable subset of the configurator state. Only fields that deviate
// from defaults are serialized, keeping share URLs short enough to paste
// into Slack/Discord (target: under ~300 chars for a realistic config).
//
// Short keys are a readability trade-off — they're not self-describing, but
// they halve the URL length and this is a one-off format rather than an API.
//
//   p       platform id (default: first visible manifest entry)
//   b       branch; `e` means earlyaccess, omit for production
//   tz      timezone value (IANA string)
//   tzOff   "1" if the timezone toggle is off (default: on)
//   logOff  "1" if the logging toggle is off (default: on)
//   c       "1" if CIFS is on (default: off)
//   u       "1" if USB audio is on (default: off)
//   h       "1" if HDMI audio is on (default: off)
//   vr/vm/vb  custom roon/music/backup host paths (omit if == platform default)
//   x       extras: `host:container,host:container,…`

// Derived from Config so adding a new user-facing field in one place
// automatically widens the override shape. `platform` is URL-only (it's a
// UI concept, not a Config field), so it's the only hand-written key.
// Excluding `image` — it's a constant, never URL-driven.
export type StateOverride = Partial<Omit<Config, 'image'>> & {
  platform?: string;
};

function encodeExtras(extras: readonly ExtraVolume[]): string {
  return extras
    .filter((v) => v.host && v.container)
    .map((v) => v.host + ':' + v.container)
    .join(',');
}

function decodeExtras(encoded: string): ExtraVolume[] {
  return encoded
    .split(',')
    .map((pair) => {
      const idx = pair.indexOf(':');
      if (idx < 0) return null;
      const host = pair.substring(0, idx);
      const container = pair.substring(idx + 1);
      if (!host || !container) return null;
      return { host, container };
    })
    .filter((v): v is ExtraVolume => v !== null);
}

export function encode(
  config: Config,
  platformId: string,
  platforms: PlatformMap,
  defaultPlatformId: string,
): URLSearchParams {
  const params = new URLSearchParams();

  if (platformId !== defaultPlatformId) params.set('p', platformId);
  if (config.branch === 'earlyaccess') params.set('b', 'e');
  // tz value is stored separately; the toggle state goes through the table.
  if (config.tz && config.tzValue) params.set('tz', config.tzValue);

  // Every boolean toggle encodes only its deviation from the default.
  for (const o of BOOLEAN_OPTIONS) {
    if (config[o.configKey] !== o.defaultValue) params.set(o.urlKey, '1');
  }

  const platform = platforms[platformId];
  if (platform) {
    for (const o of MAIN_VOLUME_OPTIONS) {
      if (config[o.configKey] !== platform[o.platformKey]) {
        params.set(o.urlKey, config[o.configKey]);
      }
    }
  }

  if (config.extraVolumes.length) {
    const encoded = encodeExtras(config.extraVolumes);
    if (encoded) params.set('x', encoded);
  }

  return params;
}

export function decode(params: URLSearchParams): StateOverride {
  const state: StateOverride = {};

  const p = params.get('p');
  if (p) state.platform = p;

  if (params.get('b') === 'e') state.branch = 'earlyaccess';

  const tz = params.get('tz');
  if (tz) state.tzValue = tz;

  // A URL key's presence means the toggle is in the non-default state.
  for (const o of BOOLEAN_OPTIONS) {
    if (params.get(o.urlKey) === '1') state[o.configKey] = !o.defaultValue;
  }

  for (const o of MAIN_VOLUME_OPTIONS) {
    const v = params.get(o.urlKey);
    if (v !== null) state[o.configKey] = v;
  }

  const x = params.get('x');
  if (x) state.extraVolumes = decodeExtras(x);

  return state;
}
