export type Branch = 'production' | 'earlyaccess';

export type ExtraVolume = {
  readonly host: string;
  readonly container: string;
};

export type Config = {
  image: string;
  branch: Branch;
  volRoon: string;
  volMusic: string;
  volBackup: string;
  extraVolumes: readonly ExtraVolume[];
  tz: boolean;
  tzValue: string;
  logging: boolean;
  cifs: boolean;
  usbAudio: boolean;
  hdmiAudio: boolean;
  // Optional container UID:GID override. Set by platforms that force a
  // non-root default (e.g. TrueNAS Apps defaults to UID 568). Roon's image
  // needs to run as root; setting "0:0" overrides the platform default.
  // Absent entirely (not undefined) on platforms where the image's default
  // is honored — see exactOptionalPropertyTypes behavior.
  user?: string;
};

export type Platform = {
  id: string;
  label: string;
  roon: string;
  music: string;
  backup: string;
  prefix: string;
  hint: string;
  rootPattern?: string;
  // Keeps the platform loaded (so validation still works if referenced) but
  // omits it from the dropdown. Use for platforms that aren't ready for users.
  hidden?: boolean;
  // Forces the emitted compose/run output to override the container's
  // effective user (e.g. "0:0" for TrueNAS Apps which defaults to UID 568).
  // When absent, the image's default USER directive applies.
  userOverride?: string;
};

export type PlatformMap = Record<string, Platform>;

export type Severity = 'error' | 'warning';

export type ValidationIssue = {
  severity: Severity;
  message: string;
};
