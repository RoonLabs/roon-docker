import type { Config } from './types';

// The generator has two concerns:
//   1. WHAT goes in the container (volumes, env, caps, devices). This is
//      derived from Config and identical for both output formats.
//   2. HOW to format it (compose YAML vs. shell). Each format has its own
//      quoting/escaping rules but the underlying spec is the same.
//
// We split (1) into buildSpec() and (2) into renderCompose()/renderRun(),
// so any change to which mounts/caps/devices apply happens in one place.

type VolumeMount = {
  host: string;
  container: string;
  readOnly?: boolean;
};

type ContainerSpec = {
  image: string;
  containerName: string;
  environment: readonly string[];
  volumes: readonly VolumeMount[];
  capAdd: readonly string[];
  securityOpt: readonly string[];
  devices: readonly string[];
  groupAdd: readonly string[];
  // Object shape (not a string enum) so a second driver can slot in
  // without rippling through the renderers — they already read .driver.
  logging: { driver: string } | null;
  // Optional UID:GID override; null when the image's default USER should
  // apply. null rather than undefined so the renderer's check stays uniform
  // with logging above.
  user: string | null;
};

function buildSpec(cfg: Config): ContainerSpec {
  const env: string[] = [];
  // Always emit the branch — even for production — so the entrypoint's
  // branch-change detection can trigger a downgrade (earlyaccess → production).
  // Without this, an explicit "production" selection still leaves
  // ROON_INSTALL_BRANCH unset in the container, and the entrypoint falls
  // back to "whatever is installed" rather than switching.
  env.push('ROON_INSTALL_BRANCH=' + cfg.branch);
  if (cfg.tz) env.push('TZ=' + cfg.tzValue);

  const volumes: VolumeMount[] = [
    { host: cfg.volRoon, container: '/Roon' },
    { host: cfg.volMusic, container: '/Music' },
    { host: cfg.volBackup, container: '/RoonBackups' },
    ...cfg.extraVolumes.map((v) => ({ host: v.host, container: v.container })),
  ];
  if (cfg.usbAudio) {
    volumes.push({ host: '/run/udev', container: '/run/udev', readOnly: true });
  }

  const capAdd: string[] = [];
  const securityOpt: string[] = [];
  if (cfg.cifs) {
    capAdd.push('SYS_ADMIN', 'DAC_READ_SEARCH');
    // AppArmor and SELinux are mutually exclusive LSMs — only one is
    // active on any given host. Emitting both opt-outs means the output
    // works on Ubuntu/Debian/DSM/QTS (AppArmor) and RHEL/Fedora/Rocky
    // (SELinux) without users having to know which LSM their host runs;
    // Docker silently ignores the inapplicable one.
    securityOpt.push('apparmor:unconfined');
    securityOpt.push('label:disable');
  }

  const devices: string[] = [];
  const groupAdd: string[] = [];
  if (cfg.usbAudio || cfg.hdmiAudio) {
    devices.push('/dev/snd:/dev/snd');
    if (cfg.usbAudio) devices.push('/dev/bus/usb:/dev/bus/usb');
    if (cfg.hdmiAudio) devices.push('/dev/dri:/dev/dri');
    groupAdd.push('audio');
  }

  return {
    image: cfg.image,
    containerName: 'roonserver',
    environment: env,
    volumes,
    capAdd,
    securityOpt,
    devices,
    groupAdd,
    logging: cfg.logging ? { driver: 'local' } : null,
    user: cfg.user ?? null,
  };
}

// --- Path quoting ---
//
// Paths flow unsanitized from user inputs and URL params into the clipboard.
// Without quoting, a crafted path like `/tmp; rm -rf /` would produce a
// `docker run ... -v /tmp; rm -rf /:/Roon` string that a victim could paste
// straight into a terminal. Always-quote when necessary makes injection
// structurally impossible; we err toward unquoted for the common case so
// simple paths stay readable.

function needsYamlQuote(s: string): boolean {
  // Quote if the string contains `: ` (colon-space, which YAML treats as a
  // mapping separator), any whitespace (including newlines), any control
  // character, or characters with YAML semantics. Also quote strings that
  // start with characters YAML reserves for flow style or special scalars.
  if (/[\s"#'\\]/.test(s)) return true;
  if (/[\x00-\x1f\x7f]/.test(s)) return true;
  if (s.includes(': ')) return true;
  if (/^[-?!|>*&[{@`%]/.test(s)) return true;
  return false;
}

function yamlQuote(s: string): string {
  // Order matters: escape backslash before quotes. Control characters must
  // be escaped too — a raw \n inside a double-quoted scalar is a literal
  // line break that ends the scalar, letting an attacker-crafted path
  // inject fake entries into the surrounding list. Validation normally
  // rejects these at the input layer; this is defense-in-depth.
  return (
    '"' +
    s
      .replace(/\\/g, '\\\\')
      .replace(/"/g, '\\"')
      .replace(/\n/g, '\\n')
      .replace(/\r/g, '\\r')
      .replace(/\t/g, '\\t')
      .replace(/[\x00-\x1f\x7f]/g, (c) => '\\x' + c.charCodeAt(0).toString(16).padStart(2, '0')) +
    '"'
  );
}

function yamlScalar(s: string): string {
  return needsYamlQuote(s) ? yamlQuote(s) : s;
}

// Conservative allowlist: characters that are unambiguously safe as bare
// shell tokens. Anything outside gets single-quoted.
const SHELL_SAFE = /^[A-Za-z0-9_./:=+@%-]+$/;

function shellToken(s: string): string {
  if (SHELL_SAFE.test(s)) return s;
  // Single-quote and escape embedded single quotes using `'\''` sequence.
  return "'" + s.replace(/'/g, "'\\''") + "'";
}

function volumeString(v: VolumeMount): string {
  const base = v.host + ':' + v.container;
  return v.readOnly ? base + ':ro' : base;
}

// --- Renderers ---

function renderCompose(spec: ContainerSpec): string[] {
  const lines: string[] = [];
  lines.push('services:');
  lines.push('  ' + spec.containerName + ':');
  lines.push('    image: ' + spec.image);
  lines.push('    container_name: ' + spec.containerName);
  // Always quote user to avoid YAML 1.1 sexagesimal interpretation —
  // unquoted "0:0" can be read as a base-60 number by some parsers.
  if (spec.user) lines.push('    user: ' + yamlQuote(spec.user));
  lines.push('    network_mode: host');

  if (spec.environment.length) {
    lines.push('    environment:');
    for (const v of spec.environment) lines.push('      - ' + yamlScalar(v));
  }

  lines.push('    volumes:');
  for (const v of spec.volumes) lines.push('      - ' + yamlScalar(volumeString(v)));

  lines.push('    restart: unless-stopped');

  if (spec.capAdd.length) {
    lines.push('    cap_add:');
    for (const c of spec.capAdd) lines.push('      - ' + yamlScalar(c));
  }
  if (spec.securityOpt.length) {
    lines.push('    security_opt:');
    for (const o of spec.securityOpt) lines.push('      - ' + yamlScalar(o));
  }

  if (spec.devices.length) {
    lines.push('    devices:');
    for (const d of spec.devices) lines.push('      - ' + yamlScalar(d));
    lines.push('    group_add:');
    for (const g of spec.groupAdd) lines.push('      - ' + yamlScalar(g));
  }

  if (spec.logging) {
    lines.push('    logging:');
    lines.push('      driver: ' + spec.logging.driver);
  }

  return lines;
}

function renderRun(spec: ContainerSpec): string[] {
  const parts: string[] = [];
  parts.push('docker run -d');
  parts.push('  --name ' + shellToken(spec.containerName));
  parts.push('  --network host');
  if (spec.user) parts.push('  --user ' + shellToken(spec.user));

  for (const v of spec.environment) parts.push('  -e ' + shellToken(v));
  for (const v of spec.volumes) parts.push('  -v ' + shellToken(volumeString(v)));

  if (spec.logging) parts.push('  --log-driver ' + shellToken(spec.logging.driver));
  parts.push('  --restart unless-stopped');

  for (const c of spec.capAdd) parts.push('  --cap-add ' + shellToken(c));
  // docker run uses `=` between the security-opt key and value; compose uses
  // `:`. The capAdd/securityOpt ordering is identical to compose's.
  for (const o of spec.securityOpt) parts.push('  --security-opt ' + shellToken(o.replace(/:/, '=')));
  for (const d of spec.devices) parts.push('  --device ' + shellToken(d));
  if (spec.groupAdd.length) parts.push('  --group-add ' + shellToken(spec.groupAdd.join(',')));

  parts.push('  ' + shellToken(spec.image));

  // Shell line-continuation: every line except the last gets " \".
  return parts.map((line, i) => (i === parts.length - 1 ? line : line + ' \\'));
}

export function generateCompose(cfg: Config): string[] {
  return renderCompose(buildSpec(cfg));
}

export function generateRun(cfg: Config): string[] {
  return renderRun(buildSpec(cfg));
}
