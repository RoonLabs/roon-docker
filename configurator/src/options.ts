import type { Config } from './types';

// Extracts the names of Config fields whose value type is boolean.
// Using this instead of a hand-written union keeps the table in sync with
// the Config type automatically — TypeScript will reject a configKey that
// doesn't correspond to a boolean field.
//
// The `-?` strips the optional modifier from the mapped type so optional
// Config fields (e.g. `user?: string`) don't leak `undefined` into the
// resulting key union.
export type BooleanConfigKey = {
  [K in keyof Config]-?: Config[K] extends boolean ? K : never;
}[keyof Config];

export type BooleanOptionDef = {
  /** Config field this option controls. */
  configKey: BooleanConfigKey;
  /** DOM id of the <input type="checkbox"> in index.html. */
  inputId: string;
  /** Short URL query-string key. */
  urlKey: string;
  /** The default-facing-user value — what the toggle starts at with no URL state. */
  defaultValue: boolean;
};

// Adding a new boolean toggle: add an entry here, add a matching <input
// type="checkbox"> to index.html, and add the field to Config. readConfig,
// applyUrlOverride, encode, decode, and bindEvents pick it up automatically.
//
// For toggles whose default is ON (tz, logging), the URL stores only the
// deviation (e.g. `tzOff=1` when the user turned it off) — keeps share
// URLs short and implies the default without encoding it.
export const BOOLEAN_OPTIONS = [
  { configKey: 'tz',        inputId: 'opt-tz',         urlKey: 'tzOff',  defaultValue: true  },
  { configKey: 'logging',   inputId: 'opt-logging',    urlKey: 'logOff', defaultValue: true  },
  { configKey: 'cifs',      inputId: 'opt-cifs',       urlKey: 'c',      defaultValue: false },
  { configKey: 'usbAudio',  inputId: 'opt-usb-audio',  urlKey: 'u',      defaultValue: false },
  { configKey: 'hdmiAudio', inputId: 'opt-hdmi-audio', urlKey: 'h',      defaultValue: false },
] as const satisfies readonly BooleanOptionDef[];

// Compile-time exhaustiveness guard. Exported so noUnusedLocals doesn't
// flag it; its job is to fail compilation if a boolean is added to Config
// without a corresponding BOOLEAN_OPTIONS entry (or an entry is removed).
// `Exclude` returns `never` when the table covers every boolean key;
// otherwise it returns the missing literal(s), which fail `extends never`.
type _AssertExhaustive<T extends never> = T;
export type _BOOLEAN_OPTIONS_COVERS_ALL_BOOLEANS = _AssertExhaustive<
  Exclude<BooleanConfigKey, (typeof BOOLEAN_OPTIONS)[number]['configKey']>
>;

// --- Main volume options ------------------------------------------------
//
// The three required volume inputs are declared once so encode/decode/
// applyUrlOverride and the warning-refresh loop can iterate instead of
// hand-writing each triplet. `platformKey` is the corresponding field on
// a `Platform` object (the default host path for this volume per
// platform).

export type MainVolumeConfigKey = 'volRoon' | 'volMusic' | 'volBackup';
export type MainVolumePlatformKey = 'roon' | 'music' | 'backup';

export type VolumeOptionDef = {
  configKey: MainVolumeConfigKey;
  inputId: string;
  urlKey: string;
  platformKey: MainVolumePlatformKey;
};

export const MAIN_VOLUME_OPTIONS = [
  { configKey: 'volRoon',   inputId: 'vol-roon',   urlKey: 'vr', platformKey: 'roon' },
  { configKey: 'volMusic',  inputId: 'vol-music',  urlKey: 'vm', platformKey: 'music' },
  { configKey: 'volBackup', inputId: 'vol-backup', urlKey: 'vb', platformKey: 'backup' },
] as const satisfies readonly VolumeOptionDef[];
