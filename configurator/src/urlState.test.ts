import { describe, it, expect } from 'vitest';
import { encode, decode } from './urlState';
import type { Config, PlatformMap } from './types';

const platforms: PlatformMap = {
  qnap: {
    id: 'qnap', label: 'QNAP',
    roon: '/share/Container/roon',
    music: '/share/Music',
    backup: '/share/Container/roon-backups',
    prefix: '/share/',
    hint: '',
    rootPattern: '^/share/',
  },
  synology: {
    id: 'synology', label: 'Synology',
    roon: '/volume1/docker/roon',
    music: '/volume1/music',
    backup: '/volume1/roon-backups',
    prefix: '/volume1/',
    hint: '',
    rootPattern: '^/volume\\d+/',
  },
};

function baseConfig(overrides: Partial<Config> = {}): Config {
  return {
    image: 'ghcr.io/roonlabs/roonserver:latest',
    branch: 'production',
    volRoon: '/share/Container/roon',
    volMusic: '/share/Music',
    volBackup: '/share/Container/roon-backups',
    extraVolumes: [],
    tz: true,
    tzValue: 'America/Denver',
    logging: true,
    cifs: false,
    usbAudio: false,
    hdmiAudio: false,
    ...overrides,
  };
}

describe('encode', () => {
  it('emits only the tz value for a fresh QNAP default config', () => {
    // The tz value is user-specific (whatever their browser detected), so
    // we DO encode it. Nothing else should appear. Asserting the exact
    // serialized form prevents a silent regression in keys we forgot to
    // inspect — the original version of this test only checked a subset
    // of keys and missed tz entirely.
    const cfg = baseConfig();
    const params = encode(cfg, 'qnap', platforms, 'qnap');
    expect(params.toString()).toBe('tz=America%2FDenver');
  });

  it('emits only tzOff=1 when tz is disabled and everything else is default', () => {
    // tz=false is the only non-default; the encoder serializes it explicitly
    // (rather than omitting it) so a share link with no tz parameter still
    // means "use the recipient's detected tz" rather than "tz disabled".
    const cfg = baseConfig({ tz: false });
    const params = encode(cfg, 'qnap', platforms, 'qnap');
    expect(params.toString()).toBe('tzOff=1');
  });

  it('emits p when platform differs from the default', () => {
    const cfg = baseConfig({
      volRoon: '/volume1/docker/roon',
      volMusic: '/volume1/music',
      volBackup: '/volume1/roon-backups',
    });
    const params = encode(cfg, 'synology', platforms, 'qnap');
    expect(params.get('p')).toBe('synology');
    // Volume paths now match the Synology defaults, so nothing else needed.
    expect(params.get('vr')).toBeNull();
    expect(params.get('vm')).toBeNull();
  });

  it('emits b=e only for earlyaccess branch', () => {
    expect(encode(baseConfig({ branch: 'production' }), 'qnap', platforms, 'qnap').get('b')).toBeNull();
    expect(encode(baseConfig({ branch: 'earlyaccess' }), 'qnap', platforms, 'qnap').get('b')).toBe('e');
  });

  it('emits tzOff when the timezone toggle is off', () => {
    const params = encode(baseConfig({ tz: false }), 'qnap', platforms, 'qnap');
    expect(params.get('tzOff')).toBe('1');
    // With the toggle off, the tz value is irrelevant and should be omitted.
    expect(params.get('tz')).toBeNull();
  });

  it('emits logOff only when logging is explicitly disabled', () => {
    expect(encode(baseConfig({ logging: true }), 'qnap', platforms, 'qnap').get('logOff')).toBeNull();
    expect(encode(baseConfig({ logging: false }), 'qnap', platforms, 'qnap').get('logOff')).toBe('1');
  });

  it('emits single-char flags for the opt-in toggles', () => {
    const params = encode(
      baseConfig({ cifs: true, usbAudio: true, hdmiAudio: true }),
      'qnap', platforms, 'qnap',
    );
    expect(params.get('c')).toBe('1');
    expect(params.get('u')).toBe('1');
    expect(params.get('h')).toBe('1');
  });

  it('emits vr/vm/vb only when the path diverges from the platform default', () => {
    const params = encode(
      baseConfig({ volMusic: '/share/AllMusic' }),
      'qnap', platforms, 'qnap',
    );
    expect(params.get('vr')).toBeNull();
    expect(params.get('vm')).toBe('/share/AllMusic');
    expect(params.get('vb')).toBeNull();
  });

  it('encodes extras as host:container pairs joined by commas', () => {
    const params = encode(
      baseConfig({
        extraVolumes: [
          { host: '/a', container: '/Music/a' },
          { host: '/b', container: '/Music/b' },
        ],
      }),
      'qnap', platforms, 'qnap',
    );
    expect(params.get('x')).toBe('/a:/Music/a,/b:/Music/b');
  });

  it('skips half-filled extras', () => {
    const params = encode(
      baseConfig({
        extraVolumes: [
          { host: '/a', container: '' },
          { host: '', container: '/b' },
          { host: '/c', container: '/Music/c' },
        ],
      }),
      'qnap', platforms, 'qnap',
    );
    expect(params.get('x')).toBe('/c:/Music/c');
  });
});

describe('decode', () => {
  it('returns an empty override for no params', () => {
    expect(decode(new URLSearchParams(''))).toEqual({});
  });

  it('parses platform', () => {
    expect(decode(new URLSearchParams('p=synology'))).toEqual({ platform: 'synology' });
  });

  it('parses branch=earlyaccess', () => {
    expect(decode(new URLSearchParams('b=e'))).toEqual({ branch: 'earlyaccess' });
  });

  it('parses tzOff and tz value independently', () => {
    expect(decode(new URLSearchParams('tzOff=1'))).toEqual({ tz: false });
    expect(decode(new URLSearchParams('tz=Europe%2FLondon'))).toEqual({ tzValue: 'Europe/London' });
  });

  it('parses the boolean single-char flags', () => {
    expect(decode(new URLSearchParams('c=1&u=1&h=1&logOff=1'))).toEqual({
      cifs: true, usbAudio: true, hdmiAudio: true, logging: false,
    });
  });

  it('parses volume path overrides', () => {
    const state = decode(new URLSearchParams('vr=%2Fa&vm=%2Fb&vb=%2Fc'));
    expect(state).toEqual({ volRoon: '/a', volMusic: '/b', volBackup: '/c' });
  });

  it('parses extras back into structured pairs', () => {
    const state = decode(new URLSearchParams('x=%2Fa%3A%2FMusic%2Fa%2C%2Fb%3A%2FMusic%2Fb'));
    expect(state.extraVolumes).toEqual([
      { host: '/a', container: '/Music/a' },
      { host: '/b', container: '/Music/b' },
    ]);
  });

  it('drops malformed extras (no colon) but keeps valid siblings', () => {
    const encoded = encodeURIComponent('malformed,/a:/Music/a');
    const state = decode(new URLSearchParams('x=' + encoded));
    expect(state.extraVolumes).toEqual([{ host: '/a', container: '/Music/a' }]);
  });
});

describe('encode/decode roundtrip', () => {
  it('preserves a fully customized config', () => {
    const cfg = baseConfig({
      branch: 'earlyaccess',
      tz: true,
      tzValue: 'UTC',
      logging: false,
      cifs: true,
      usbAudio: true,
      hdmiAudio: true,
      volRoon: '/mnt/pool1/roon',
      volMusic: '/mnt/pool1/music',
      volBackup: '/mnt/pool1/backups',
      extraVolumes: [{ host: '/mnt/extra', container: '/Music/extra' }],
    });
    const params = encode(cfg, 'synology', platforms, 'qnap');
    const decoded = decode(params);

    expect(decoded.platform).toBe('synology');
    expect(decoded.branch).toBe('earlyaccess');
    expect(decoded.tzValue).toBe('UTC');
    expect(decoded.logging).toBe(false);
    expect(decoded.cifs).toBe(true);
    expect(decoded.usbAudio).toBe(true);
    expect(decoded.hdmiAudio).toBe(true);
    expect(decoded.volRoon).toBe('/mnt/pool1/roon');
    expect(decoded.volMusic).toBe('/mnt/pool1/music');
    expect(decoded.volBackup).toBe('/mnt/pool1/backups');
    expect(decoded.extraVolumes).toEqual([{ host: '/mnt/extra', container: '/Music/extra' }]);
  });

  it('produces a URL that stays under 200 characters for a realistic config', () => {
    // Target budget is ~300 for Slack/Discord pastability; a realistic
    // config encodes to ~150, so 200 is a tight regression guard.
    const cfg = baseConfig({
      cifs: true,
      extraVolumes: [
        { host: '/share/Media/classical', container: '/Music/classical' },
        { host: '/share/Media/jazz', container: '/Music/jazz' },
      ],
    });
    const qs = encode(cfg, 'qnap', platforms, 'qnap').toString();
    expect(qs.length).toBeLessThan(200);
  });

  it('roundtrips through a real serialized querystring (not the URLSearchParams object)', () => {
    // The other roundtrip test passes the same URLSearchParams to decode;
    // this one serializes to a string and re-parses, which catches any
    // encodeURIComponent mishaps on values with %, &, =, or colons.
    const cfg = baseConfig({
      cifs: true,
      volMusic: '/share/Special & Weird',
      extraVolumes: [{ host: '/share/a=b', container: '/Music/a=b' }],
    });
    const serialized = encode(cfg, 'qnap', platforms, 'qnap').toString();
    const parsed = decode(new URLSearchParams(serialized));
    expect(parsed.cifs).toBe(true);
    expect(parsed.volMusic).toBe('/share/Special & Weird');
    expect(parsed.extraVolumes).toEqual([{ host: '/share/a=b', container: '/Music/a=b' }]);
  });
});

describe('decode defensiveness', () => {
  it('ignores unrecognized branch values', () => {
    expect(decode(new URLSearchParams('b=production')).branch).toBeUndefined();
    expect(decode(new URLSearchParams('b=xyz')).branch).toBeUndefined();
  });

  it('treats tzOff other than "1" as not-set (only "1" disables tz)', () => {
    expect(decode(new URLSearchParams('tzOff=0')).tz).toBeUndefined();
    expect(decode(new URLSearchParams('tzOff=true')).tz).toBeUndefined();
  });

  it('returns an empty array for x with only malformed entries', () => {
    expect(decode(new URLSearchParams('x=nocolon,alsonone')).extraVolumes).toEqual([]);
  });

  it('handles x=""  as no extras rather than a half-filled row', () => {
    expect(decode(new URLSearchParams('x=')).extraVolumes).toBeUndefined();
  });

  it('splits extras on the first colon per pair (first-colon-wins)', () => {
    // Documents the current behavior: if a host path contains a colon,
    // everything after the first colon is treated as the container path.
    // This is a known limitation of the comma/colon format.
    const state = decode(new URLSearchParams('x=%2Fhost%3Atricky%3A%2FMusic'));
    expect(state.extraVolumes).toEqual([{ host: '/host', container: 'tricky:/Music' }]);
  });
});
