import { describe, it, expect } from 'vitest';
import { generateCompose, generateRun } from './generator';
import type { Config } from './types';

function baseConfig(overrides: Partial<Config> = {}): Config {
  return {
    image: 'ghcr.io/roonlabs/roonserver:latest',
    branch: 'production',
    volRoon: '/host/roon',
    volMusic: '/host/music',
    volBackup: '/host/backups',
    extraVolumes: [],
    tz: false,
    tzValue: 'UTC',
    logging: false,
    cifs: false,
    usbAudio: false,
    hdmiAudio: false,
    ...overrides,
  };
}

describe('generateCompose', () => {
  it('produces a minimal valid compose file with just the required fields', () => {
    const out = generateCompose(baseConfig()).join('\n');
    expect(out).toContain('services:');
    expect(out).toContain('  roonserver:');
    expect(out).toContain('network_mode: host');
    expect(out).toContain('- /host/roon:/Roon');
    expect(out).toContain('- /host/music:/Music');
    expect(out).toContain('- /host/backups:/RoonBackups');
    expect(out).toContain('restart: unless-stopped');
  });

  it('always emits the environment block with ROON_INSTALL_BRANCH', () => {
    // Regression guard: production must be explicit so earlyaccess→production
    // downgrades work. The entrypoint switches branches only when the env var
    // is set AND differs from what's installed. Leaving production implicit
    // strands users on earlyaccess after a "downgrade" attempt.
    const out = generateCompose(baseConfig()).join('\n');
    expect(out).toContain('environment:');
    expect(out).toContain('- ROON_INSTALL_BRANCH=production');
  });

  it('emits TZ when tz is enabled', () => {
    const out = generateCompose(baseConfig({ tz: true, tzValue: 'America/Denver' })).join('\n');
    expect(out).toContain('environment:');
    expect(out).toContain('- TZ=America/Denver');
  });

  it('emits ROON_INSTALL_BRANCH=production explicitly (downgrade from earlyaccess works)', () => {
    // Scenario: user was running earlyaccess, selects production in the
    // generator, redeploys. The entrypoint only switches branches if
    // ROON_INSTALL_BRANCH is SET and differs from the installed VERSION.
    // If production is implicit (omitted), the entrypoint falls back to
    // "keep whatever is installed" and the user stays on earlyaccess.
    const compose = generateCompose(baseConfig({ branch: 'production' })).join('\n');
    const run = generateRun(baseConfig({ branch: 'production' })).join('\n');
    expect(compose).toContain('- ROON_INSTALL_BRANCH=production');
    expect(run).toContain('-e ROON_INSTALL_BRANCH=production');
  });

  it('emits ROON_INSTALL_BRANCH when branch is earlyaccess', () => {
    const out = generateCompose(baseConfig({ branch: 'earlyaccess' })).join('\n');
    expect(out).toContain('- ROON_INSTALL_BRANCH=earlyaccess');
  });

  it('emits both TZ and branch env vars in a single environment block, branch first', () => {
    const out = generateCompose(
      baseConfig({ branch: 'earlyaccess', tz: true, tzValue: 'UTC' }),
    ).join('\n');
    const envIdx = out.indexOf('environment:');
    const branchIdx = out.indexOf('- ROON_INSTALL_BRANCH=earlyaccess');
    const tzIdx = out.indexOf('- TZ=UTC');
    expect(envIdx).toBeGreaterThan(-1);
    expect(branchIdx).toBeGreaterThan(envIdx);
    expect(tzIdx).toBeGreaterThan(branchIdx);
    // Single environment block, not two separate ones.
    expect(out.match(/environment:/g)?.length ?? 0).toBe(1);
  });

  it('appends extra volumes after the required volumes, in order', () => {
    const out = generateCompose(
      baseConfig({
        extraVolumes: [
          { host: '/host/extra1', container: '/Music/a' },
          { host: '/host/extra2', container: '/Music/b' },
        ],
      }),
    );
    // Filter by path-like lines only — both env and volumes share the
    // "      - " prefix, so match the leading slash to isolate volume entries.
    const vols = out.filter((l) => /^ {6}- \//.test(l));
    expect(vols).toEqual([
      '      - /host/roon:/Roon',
      '      - /host/music:/Music',
      '      - /host/backups:/RoonBackups',
      '      - /host/extra1:/Music/a',
      '      - /host/extra2:/Music/b',
    ]);
  });

  it('emits cap_add + security_opt (AppArmor + SELinux) when cifs is enabled', () => {
    // Regression guard: two bugs deep — the option must add both the
    // capabilities AND the LSM opt-outs; LSM and cap checks are
    // independent gatekeepers on the mount syscall. Also emits BOTH
    // AppArmor and SELinux opt-outs since the two LSMs are mutually
    // exclusive and we don't know which one the host runs.
    const out = generateCompose(baseConfig({ cifs: true })).join('\n');
    expect(out).toContain('cap_add:');
    expect(out).toContain('- SYS_ADMIN');
    expect(out).toContain('- DAC_READ_SEARCH');
    expect(out).toContain('security_opt:');
    expect(out).toContain('- apparmor:unconfined');
    expect(out).toContain('- label:disable');
  });

  it('does not emit cap_add or security_opt when cifs is disabled', () => {
    const out = generateCompose(baseConfig({ cifs: false })).join('\n');
    expect(out).not.toContain('cap_add:');
    expect(out).not.toContain('security_opt:');
    expect(out).not.toContain('apparmor:unconfined');
    expect(out).not.toContain('label:disable');
  });

  it('adds /run/udev mount only when usbAudio is enabled', () => {
    const usb = generateCompose(baseConfig({ usbAudio: true })).join('\n');
    expect(usb).toContain('- /run/udev:/run/udev:ro');

    const hdmi = generateCompose(baseConfig({ hdmiAudio: true })).join('\n');
    expect(hdmi).not.toContain('- /run/udev:/run/udev:ro');
  });

  it('adds devices + group_add for USB audio', () => {
    const out = generateCompose(baseConfig({ usbAudio: true })).join('\n');
    expect(out).toContain('devices:');
    expect(out).toContain('- /dev/snd:/dev/snd');
    expect(out).toContain('- /dev/bus/usb:/dev/bus/usb');
    expect(out).toContain('group_add:');
    expect(out).toContain('- audio');
  });

  it('adds /dev/dri for HDMI audio', () => {
    const out = generateCompose(baseConfig({ hdmiAudio: true })).join('\n');
    expect(out).toContain('- /dev/dri:/dev/dri');
  });

  it('merges USB and HDMI audio under a single devices block', () => {
    const out = generateCompose(baseConfig({ usbAudio: true, hdmiAudio: true }));
    const devicesCount = out.filter((l) => l === '    devices:').length;
    expect(devicesCount).toBe(1);
    const joined = out.join('\n');
    expect(joined).toContain('- /dev/bus/usb:/dev/bus/usb');
    expect(joined).toContain('- /dev/dri:/dev/dri');
  });

  it('adds local logging driver when logging is enabled', () => {
    const on = generateCompose(baseConfig({ logging: true })).join('\n');
    expect(on).toContain('logging:');
    expect(on).toContain('driver: local');

    const off = generateCompose(baseConfig({ logging: false })).join('\n');
    expect(off).not.toContain('logging:');
  });

  it('produces stable output for the all-options-on config', () => {
    // Snapshot-style full check so any accidental reordering is caught.
    const out = generateCompose(
      baseConfig({
        branch: 'earlyaccess',
        tz: true,
        tzValue: 'Europe/London',
        logging: true,
        cifs: true,
        usbAudio: true,
        hdmiAudio: true,
        extraVolumes: [{ host: '/x', container: '/y' }],
      }),
    );
    expect(out).toMatchInlineSnapshot(`
      [
        "services:",
        "  roonserver:",
        "    image: ghcr.io/roonlabs/roonserver:latest",
        "    container_name: roonserver",
        "    network_mode: host",
        "    environment:",
        "      - ROON_INSTALL_BRANCH=earlyaccess",
        "      - TZ=Europe/London",
        "    volumes:",
        "      - /host/roon:/Roon",
        "      - /host/music:/Music",
        "      - /host/backups:/RoonBackups",
        "      - /x:/y",
        "      - /run/udev:/run/udev:ro",
        "    restart: unless-stopped",
        "    cap_add:",
        "      - SYS_ADMIN",
        "      - DAC_READ_SEARCH",
        "    security_opt:",
        "      - apparmor:unconfined",
        "      - label:disable",
        "    devices:",
        "      - /dev/snd:/dev/snd",
        "      - /dev/bus/usb:/dev/bus/usb",
        "      - /dev/dri:/dev/dri",
        "    group_add:",
        "      - audio",
        "    logging:",
        "      driver: local",
      ]
    `);
  });
});

describe('generateRun', () => {
  it('produces a minimal docker run command', () => {
    const out = generateRun(baseConfig()).join('\n');
    expect(out).toContain('docker run -d \\');
    expect(out).toContain('--name roonserver \\');
    expect(out).toContain('--network host \\');
    expect(out).toContain('-v /host/roon:/Roon \\');
    expect(out).toContain('-v /host/music:/Music \\');
    expect(out).toContain('-v /host/backups:/RoonBackups \\');
    expect(out).toContain('ghcr.io/roonlabs/roonserver:latest');
  });

  it('last line is the image name, not a backslash-terminated flag', () => {
    const out = generateRun(baseConfig());
    const last = out[out.length - 1];
    expect(last).toBe('  ghcr.io/roonlabs/roonserver:latest');
    expect(last?.endsWith('\\')).toBe(false);
  });

  it('all non-final lines end with " \\" for shell continuation', () => {
    const out = generateRun(baseConfig());
    for (let i = 0; i < out.length - 1; i++) {
      const line = out[i]!;
      expect(line.endsWith(' \\')).toBe(true);
    }
  });

  it('emits --security-opt {apparmor,label}=... (equals form, not colon) when cifs is on', () => {
    // docker run uses `=`, compose uses `:` — easy to get wrong. Both
    // AppArmor and SELinux opt-outs are emitted; one of them will no-op
    // depending on which LSM is active on the host.
    const out = generateRun(baseConfig({ cifs: true })).join('\n');
    expect(out).toContain('--cap-add SYS_ADMIN \\');
    expect(out).toContain('--cap-add DAC_READ_SEARCH \\');
    expect(out).toContain('--security-opt apparmor=unconfined \\');
    expect(out).toContain('--security-opt label=disable \\');
    expect(out).not.toContain('apparmor:unconfined');
    expect(out).not.toContain('label:disable');
  });

  it('emits -e ROON_INSTALL_BRANCH for earlyaccess', () => {
    const out = generateRun(baseConfig({ branch: 'earlyaccess' })).join('\n');
    expect(out).toContain('-e ROON_INSTALL_BRANCH=earlyaccess \\');
  });

  it('emits -e TZ when tz is enabled', () => {
    const out = generateRun(baseConfig({ tz: true, tzValue: 'America/Chicago' })).join('\n');
    expect(out).toContain('-e TZ=America/Chicago \\');
  });

  it('emits --log-driver local when logging is enabled', () => {
    const out = generateRun(baseConfig({ logging: true })).join('\n');
    expect(out).toContain('--log-driver local \\');
  });

  it('preserves extra-volume ordering after required volumes', () => {
    const out = generateRun(
      baseConfig({
        extraVolumes: [{ host: '/extra', container: '/Music/extra' }],
      }),
    );
    const volLines = out.filter((l) => l.includes(' -v '));
    expect(volLines).toEqual([
      '  -v /host/roon:/Roon \\',
      '  -v /host/music:/Music \\',
      '  -v /host/backups:/RoonBackups \\',
      '  -v /extra:/Music/extra \\',
    ]);
  });

  it('passes through --device and --group-add for audio options', () => {
    const usb = generateRun(baseConfig({ usbAudio: true })).join('\n');
    expect(usb).toContain('--device /dev/snd:/dev/snd \\');
    expect(usb).toContain('--device /dev/bus/usb:/dev/bus/usb \\');
    expect(usb).toContain('-v /run/udev:/run/udev:ro \\');
    expect(usb).toContain('--group-add audio \\');

    const hdmi = generateRun(baseConfig({ hdmiAudio: true })).join('\n');
    expect(hdmi).toContain('--device /dev/dri:/dev/dri \\');
    expect(hdmi).not.toContain('--device /dev/bus/usb:/dev/bus/usb');
  });
});

describe('Block ordering invariants', () => {
  // Explicit ordering assertions so a reordering regression gives a
  // clearer failure message than the all-options snapshot diff does.
  it('emits cap_add before security_opt before devices before group_add before logging', () => {
    const out = generateCompose(
      baseConfig({ cifs: true, usbAudio: true, logging: true }),
    ).join('\n');
    const order = ['cap_add:', 'security_opt:', 'devices:', 'group_add:', 'logging:'];
    let lastIdx = -1;
    for (const key of order) {
      const idx = out.indexOf(key);
      expect(idx).toBeGreaterThan(lastIdx);
      lastIdx = idx;
    }
  });

  it('compose emits environment block with ROON_INSTALL_BRANCH when tz is off', () => {
    const out = generateCompose(baseConfig({ branch: 'earlyaccess', tz: false })).join('\n');
    expect(out).toContain('environment:');
    expect(out).toContain('- ROON_INSTALL_BRANCH=earlyaccess');
    expect(out).not.toContain('TZ=');
  });

  it('docker run emits --restart between --log-driver and --cap-add when both apply', () => {
    const out = generateRun(baseConfig({ logging: true, cifs: true }));
    const joined = out.join('\n');
    const logIdx = joined.indexOf('--log-driver');
    const restartIdx = joined.indexOf('--restart');
    const capIdx = joined.indexOf('--cap-add');
    expect(logIdx).toBeGreaterThan(-1);
    expect(restartIdx).toBeGreaterThan(logIdx);
    expect(capIdx).toBeGreaterThan(restartIdx);
  });
});

describe('Platform-driven user override', () => {
  // Context: TrueNAS Apps forces UID 568 on containers by default, but
  // Roon's image needs to run as root. When the TrueNAS platform is
  // selected, the configurator emits `user: "0:0"` so the deployed
  // container actually runs as root. Other platforms don't need this —
  // they respect the image's default USER directive (which is root).
  it('emits `user: "0:0"` in compose between container_name and network_mode', () => {
    const out = generateCompose(baseConfig({ user: '0:0' }));
    const joined = out.join('\n');
    expect(joined).toContain('user: "0:0"');
    const userIdx = out.findIndex((l) => l.includes('user:'));
    const containerNameIdx = out.findIndex((l) => l.includes('container_name:'));
    const networkModeIdx = out.findIndex((l) => l.includes('network_mode:'));
    expect(userIdx).toBeGreaterThan(containerNameIdx);
    expect(userIdx).toBeLessThan(networkModeIdx);
  });

  it('omits user line when config.user is unset', () => {
    const out = generateCompose(baseConfig()).join('\n');
    expect(out).not.toMatch(/^\s*user:/m);
  });

  it('emits --user flag in docker run when user is set', () => {
    const out = generateRun(baseConfig({ user: '0:0' })).join('\n');
    expect(out).toContain('--user 0:0');
  });

  it('omits --user flag in docker run when user is unset', () => {
    const out = generateRun(baseConfig()).join('\n');
    expect(out).not.toContain('--user');
  });

  it('quotes non-numeric user values safely in YAML', () => {
    // Defense in depth — even though platform userOverride is validated to
    // a numeric UID:GID pattern, the generator shouldn't emit raw values.
    const out = generateCompose(baseConfig({ user: 'weird user' })).join('\n');
    expect(out).toContain('"weird user"');
  });
});

describe('Output safety: paths with unusual characters are escaped', () => {
  // These tests are the security net for the clipboard/share-link injection
  // vector: a crafted path must not be able to produce a shell or YAML
  // payload that breaks out of its volume spec.
  it('single-quotes shell arguments containing spaces', () => {
    const out = generateRun(baseConfig({ volMusic: '/mnt/My Music' })).join('\n');
    expect(out).toContain("-v '/mnt/My Music:/Music' \\");
  });

  it('single-quotes shell arguments with shell metacharacters', () => {
    const out = generateRun(baseConfig({ volMusic: '/tmp; rm -rf /' })).join('\n');
    // The metacharacter-carrying path lands inside a single-quoted token
    // and cannot escape it.
    expect(out).toContain("'/tmp; rm -rf /:/Music'");
    expect(out).not.toMatch(/-v \/tmp; rm/);
  });

  it('escapes embedded single quotes using the ' + "'\\''" + ' pattern', () => {
    const out = generateRun(baseConfig({ volMusic: "/mnt/Sam's Music" })).join('\n');
    expect(out).toContain("-v '/mnt/Sam'\\''s Music:/Music' \\");
  });

  it('double-quotes YAML scalars containing spaces', () => {
    const out = generateCompose(baseConfig({ volMusic: '/mnt/My Music' })).join('\n');
    expect(out).toContain('- "/mnt/My Music:/Music"');
  });

  it('escapes YAML special characters in double-quoted scalars', () => {
    const out = generateCompose(baseConfig({ volMusic: '/mnt/"weird"' })).join('\n');
    expect(out).toContain('\\"');
  });

  it('leaves simple paths unquoted in both formats (no whitespace noise)', () => {
    const compose = generateCompose(baseConfig()).join('\n');
    const run = generateRun(baseConfig()).join('\n');
    expect(compose).toContain('- /host/roon:/Roon');
    expect(compose).not.toContain('"/host/roon:/Roon"');
    expect(run).toContain('-v /host/roon:/Roon');
    expect(run).not.toContain("'/host/roon:/Roon'");
  });

  it('escapes newlines in YAML so a crafted path cannot break out of its scalar', () => {
    // Regression guard for the review finding: validation rejects control
    // chars at the input layer, but the generator is called on every
    // keystroke to render the preview. A \n inside a double-quoted YAML
    // scalar is a literal break and would inject a fake volume entry —
    // escape to \\n so every line in the output stays inside its list item.
    const out = generateCompose(baseConfig({ volMusic: '/mnt/music\n- /etc/shadow:/evil' })).join('\n');
    expect(out).toContain('\\n');
    expect(out).not.toMatch(/\n\s*- \/etc\/shadow/);
  });

  it('escapes tabs, carriage returns, and other control chars in YAML', () => {
    const out = generateCompose(baseConfig({ volMusic: '/a\tb\rc\x00d' })).join('\n');
    expect(out).toContain('\\t');
    expect(out).toContain('\\r');
    expect(out).toContain('\\x00');
  });
});
