import './styles.css';
import { generateCompose, generateRun } from './generator';
import { loadPlatforms, validateVolumePath, validateContainerPath, firstError } from './platforms';
import { highlightYaml, highlightShell } from './highlight';
import { encode as encodeUrl, decode as decodeUrl, type StateOverride } from './urlState';
import { saveState, loadState, clearState } from './persistence';
import {
  BOOLEAN_OPTIONS,
  MAIN_VOLUME_OPTIONS,
  type BooleanConfigKey,
  type MainVolumeConfigKey,
} from './options';
import type { Branch, Config, ExtraVolume, PlatformMap, ValidationIssue } from './types';

const IMAGE = 'ghcr.io/roonlabs/roonserver:latest';

type Tab = 'compose' | 'run';
let currentTab: Tab = 'compose';
let platforms: PlatformMap = {};

// Typed DOM lookup helper — throws clearly if an expected element is missing
// during init, which is simpler to debug than silent null propagation.
function $<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error('Missing element: #' + id);
  return el as T;
}

function currentPlatform(): string {
  return $<HTMLSelectElement>('platform-select').value;
}

// In-memory record of which warning elements currently hold an error-severity
// issue. Keeping this alongside the DOM writes means `hasErrors()` doesn't
// have to query the document — a missed refresh can't silently unblock
// export, and removed extras rows just need their entry dropped explicitly.
const errorSources = new Set<HTMLElement>();

// Applies a validation issue (or clears it) to a warning element, color-coding
// by severity and updating the central error-source set. Renders the symbolic
// prefix (⛔/⚠) as an aria-hidden span so screen readers hear "Error:" /
// "Warning:" rather than "no entry sign" / "warning sign".
function applyValidation(el: HTMLElement, issue: ValidationIssue | null): void {
  if (!issue) {
    el.classList.add('hidden');
    delete el.dataset.severity;
    errorSources.delete(el);
    return;
  }
  const isError = issue.severity === 'error';
  el.textContent = '';
  const symbol = document.createElement('span');
  symbol.setAttribute('aria-hidden', 'true');
  symbol.textContent = (isError ? '⛔' : '⚠') + ' ';
  const srLabel = document.createElement('span');
  srLabel.className = 'sr-only';
  srLabel.textContent = isError ? 'Error: ' : 'Warning: ';
  el.append(symbol, srLabel, document.createTextNode(issue.message));
  el.classList.remove('hidden');
  // Using red-300 (not 400) for error text so it clears 4.5:1 against the
  // dark card backgrounds. Amber-400 already has ample contrast.
  el.classList.toggle('text-red-300', isError);
  el.classList.toggle('text-amber-400', !isError);
  el.dataset.severity = issue.severity;
  if (isError) {
    errorSources.add(el);
  } else {
    errorSources.delete(el);
  }
}

function forgetValidationSource(el: HTMLElement): void {
  errorSources.delete(el);
}

function otherContainerPaths(currentRow: Element): string[] {
  const paths: string[] = [];
  document.querySelectorAll<HTMLElement>('.extra-vol-row').forEach((row) => {
    if (row === currentRow) return;
    const input = row.querySelector<HTMLInputElement>('.extra-vol-container');
    const val = input?.value.trim();
    if (val) paths.push(val);
  });
  return paths;
}

function updateExtraVolumeWarning(row: Element): void {
  const hostInput = row.querySelector<HTMLInputElement>('.extra-vol-host');
  const containerInput = row.querySelector<HTMLInputElement>('.extra-vol-container');
  const warning = row.querySelector<HTMLElement>('.extra-vol-warning');
  if (!hostInput || !containerInput || !warning) return;

  const host = hostInput.value.trim();
  const container = containerInput.value.trim();

  // An empty (or half-filled) extras row is always an error — it can't
  // contribute a valid mount and clutters the form otherwise. The user's
  // out is the × button on the row. Flag aria-invalid on the specific
  // input that's the problem.
  if (!host) {
    applyValidation(warning, { severity: 'error', message: 'Host path is required.' });
    hostInput.setAttribute('aria-invalid', 'true');
    containerInput.setAttribute('aria-invalid', 'false');
    return;
  }
  if (!container) {
    applyValidation(warning, { severity: 'error', message: 'Container path is required.' });
    hostInput.setAttribute('aria-invalid', 'false');
    containerInput.setAttribute('aria-invalid', 'true');
    return;
  }

  const hostIssue = validateVolumePath(platforms, currentPlatform(), host);
  const containerIssue = validateContainerPath(container, otherContainerPaths(row));
  applyValidation(warning, firstError(hostIssue, containerIssue));
  hostInput.setAttribute('aria-invalid', String(hostIssue?.severity === 'error'));
  containerInput.setAttribute('aria-invalid', String(containerIssue?.severity === 'error'));
}

function refreshExtraVolumeWarnings(): void {
  document.querySelectorAll('.extra-vol-row').forEach(updateExtraVolumeWarning);
}

function updateMainVolumeWarning(inputId: string): void {
  const input = $<HTMLInputElement>(inputId);
  const warning = $(inputId + '-warning');
  const value = input.value.trim();
  const issue = value
    ? validateVolumePath(platforms, currentPlatform(), value)
    : { severity: 'error' as const, message: 'Path is required.' };
  applyValidation(warning, issue);
  // Keep screen readers informed: aria-invalid announces validity on focus,
  // and adding the warning id to aria-describedby means the SR reads the
  // active error when the user refocuses the field later (the aria-live
  // announcement on first change isn't enough).
  const descId = inputId + '-desc';
  const warningId = inputId + '-warning';
  const hasError = issue?.severity === 'error';
  input.setAttribute('aria-invalid', String(hasError));
  input.setAttribute('aria-describedby', issue ? descId + ' ' + warningId : descId);
}

function refreshMainVolumeWarnings(): void {
  for (const o of MAIN_VOLUME_OPTIONS) updateMainVolumeWarning(o.inputId);
}

function hasVisibleErrors(): boolean {
  return errorSources.size > 0;
}

// Cache the tooltips declared in the HTML so we can restore them verbatim
// when Copy/Download re-enable. Reading from the DOM (instead of hardcoding
// the strings here) keeps index.html the single source of truth. Populated
// lazily on first refreshActions() call, once elBtnCopy/elBtnDownload exist.
const defaultTooltips = new WeakMap<HTMLElement, string>();

function refreshActions(): void {
  const blocked = hasVisibleErrors();
  const reason = blocked ? 'Fix the errors above before copying or downloading.' : null;
  [elBtnCopy, elBtnDownload].forEach((btn) => {
    // Seed the cache on first observation — can't do it at module-load time
    // because the element refs are declared after this function.
    if (!defaultTooltips.has(btn)) {
      defaultTooltips.set(btn, btn.getAttribute('data-tooltip') ?? '');
    }
    btn.disabled = blocked;
    btn.classList.toggle('opacity-40', blocked);
    btn.classList.toggle('cursor-not-allowed', blocked);
    if (reason) {
      btn.setAttribute('data-tooltip', reason);
      btn.setAttribute('aria-disabled', 'true');
    } else {
      btn.setAttribute('data-tooltip', defaultTooltips.get(btn) ?? '');
      btn.removeAttribute('aria-disabled');
    }
  });
}

const elOutput = $('output');
const elBtnCopy = $<HTMLButtonElement>('btn-copy');
const elIconCopy = $('icon-copy');
const elIconCheck = $('icon-check');
const elBtnDownload = $<HTMLButtonElement>('btn-download');
const elBtnShare = $<HTMLButtonElement>('btn-share');
const elIconShare = $('icon-share');
const elIconShareCheck = $('icon-share-check');
const elBtnReset = $<HTMLButtonElement>('btn-reset');
const elIconReset = $('icon-reset');
const elIconResetCheck = $('icon-reset-check');
const elTabCompose = $<HTMLButtonElement>('tab-compose');
const elTabRun = $<HTMLButtonElement>('tab-run');
const elEditorFilename = $('editor-filename');
const elPlatformHint = $('platform-hint');
const elHelpfulNote = $('helpful-note');
const elTzInputWrap = $('tz-input-wrap');
const elCopyStatus = $('copy-status');

function getVal(id: string): string {
  return $<HTMLInputElement | HTMLSelectElement>(id).value;
}

function isChecked(id: string): boolean {
  return $<HTMLInputElement>(id).checked;
}

function setVal(id: string, v: string): void {
  $<HTMLInputElement | HTMLSelectElement>(id).value = v;
}

function readConfig(): Config {
  const extras: ExtraVolume[] = [];
  document.querySelectorAll<HTMLElement>('.extra-vol-row').forEach((row) => {
    const hostInput = row.querySelector<HTMLInputElement>('.extra-vol-host');
    const containerInput = row.querySelector<HTMLInputElement>('.extra-vol-container');
    if (!hostInput || !containerInput) return;
    const hostPath = hostInput.value.trim();
    const containerPath = containerInput.value.trim();
    if (hostPath && containerPath) {
      extras.push({ host: hostPath, container: containerPath });
    }
  });

  // Narrow instead of casting: an unexpected option value would silently
  // construct an invalid Config if we just asserted `as Branch`.
  const rawBranch = getVal('branch-select');
  const branch: Branch = rawBranch === 'earlyaccess' ? 'earlyaccess' : 'production';

  // Boolean toggles are collected via the options table so adding a new
  // one doesn't require editing this function.
  const booleanFields = Object.fromEntries(
    BOOLEAN_OPTIONS.map((o) => [o.configKey, isChecked(o.inputId)]),
  ) as Record<BooleanConfigKey, boolean>;

  // Platform-driven user override (e.g. TrueNAS forces UID 568 by default;
  // Roon's image needs root). Conditional spread so the key is absent
  // entirely when the platform doesn't need it — required by
  // exactOptionalPropertyTypes.
  const userOverride = platforms[currentPlatform()]?.userOverride;

  return {
    image: IMAGE,
    branch,
    extraVolumes: extras,
    tzValue: getVal('tz-value'),
    ...booleanFields,
    ...(userOverride ? { user: userOverride } : {}),
    // Main volumes come from the options table. Empty fields surface as
    // validation errors that block export; there's no fallback, so the
    // preview reflects the real state rather than silently substituting
    // a plausible-looking but wrong path.
    ...(Object.fromEntries(
      MAIN_VOLUME_OPTIONS.map((o) => [o.configKey, getVal(o.inputId)]),
    ) as Record<MainVolumeConfigKey, string>),
  };
}

function updateNote(): void {
  elHelpfulNote.textContent = '';
  const code = document.createElement('code');
  code.className = 'text-roon-300 bg-roon-900/30 px-1 py-0.5 rounded font-mono';
  if (currentTab === 'compose') {
    elHelpfulNote.appendChild(document.createTextNode('Uses '));
    code.textContent = 'network_mode: host';
    elHelpfulNote.appendChild(code);
    elHelpfulNote.appendChild(
      document.createTextNode(" for Roon's device discovery (SSDP/mDNS). No port mapping needed."),
    );
  } else {
    elHelpfulNote.appendChild(document.createTextNode('Paste this command into your terminal. Uses '));
    code.textContent = '--network host';
    elHelpfulNote.appendChild(code);
    elHelpfulNote.appendChild(document.createTextNode(" for Roon's device discovery."));
  }
}

// Pure-UI concern: collapse the timezone selector when the toggle is off.
// Lives outside generate() so generate() stays focused on rendering the
// output and syncing the URL — changes to tz-wrap behavior don't touch
// the render pipeline.
function syncTzVisibility(): void {
  const on = isChecked('opt-tz');
  elTzInputWrap.style.maxHeight = on ? '60px' : '0';
  elTzInputWrap.style.opacity = on ? '1' : '0';
}

function generate(): void {
  const cfg = readConfig();

  if (currentTab === 'compose') {
    highlightYaml(generateCompose(cfg), elOutput);
  } else {
    highlightShell(generateRun(cfg), elOutput);
  }

  refreshActions();
  updateUrl(cfg);
}

// Turned on once init finishes applying URL-driven overrides — prevents the
// transient empty state (before overrides are applied) from clearing the URL.
let urlUpdatesEnabled = false;
// The default platform id is the first visible entry in the manifest.
// Populated during init once the manifest has loaded.
let defaultPlatformId = '';

function updateUrl(cfg: Config): void {
  if (!urlUpdatesEnabled || !defaultPlatformId) return;
  const params = encodeUrl(cfg, currentPlatform(), platforms, defaultPlatformId);
  const qs = params.toString();
  const newUrl = qs ? window.location.pathname + '?' + qs : window.location.pathname;
  history.replaceState(null, '', newUrl);
  // Mirror the URL into localStorage so a returning visitor lands back in
  // their last-known state even without the share URL.
  saveState(params);
}

function applyUrlOverride(override: StateOverride): void {
  // Platform already applied before this call (it needs to be set before
  // setPlatform() populates the defaults); everything else goes here.
  if (override.branch === 'earlyaccess') {
    $<HTMLSelectElement>('branch-select').value = 'earlyaccess';
  }
  if (override.tzValue) {
    const tzSelect = $<HTMLSelectElement>('tz-value');
    // Ensure the option exists; otherwise setting .value is a no-op.
    if (!Array.from(tzSelect.options).some((o) => o.value === override.tzValue)) {
      const opt = document.createElement('option');
      opt.value = override.tzValue;
      opt.textContent = override.tzValue + ' (from URL)';
      tzSelect.appendChild(opt);
    }
    tzSelect.value = override.tzValue;
  }

  // Boolean toggles — any key present in the override wins over the default.
  for (const o of BOOLEAN_OPTIONS) {
    const v = override[o.configKey];
    if (v !== undefined) $<HTMLInputElement>(o.inputId).checked = v;
  }

  for (const o of MAIN_VOLUME_OPTIONS) {
    const v = override[o.configKey];
    if (v !== undefined) setVal(o.inputId, v);
  }

  if (override.extraVolumes) {
    for (const v of override.extraVolumes) {
      addExtraVolumeRow({ host: v.host, container: v.container });
    }
  }

  refreshMainVolumeWarnings();
  refreshExtraVolumeWarnings();
}

function getRawText(): string {
  const lines: string[] = [];
  elOutput.querySelectorAll('tr').forEach((row) => {
    const cells = row.querySelectorAll('td');
    const codeCell = cells[1];
    if (codeCell) lines.push(codeCell.textContent ?? '');
  });
  return lines.join('\n');
}

// Set by detectDesktopOS() on pages loaded in macOS/Windows browsers.
// Rendered as a separate paragraph after the platform hint so both
// messages stay visible (and visually distinct) across platform changes.
let desktopHostNote = '';

function setPlatform(platformId: string): void {
  const p = platforms[platformId];
  if (!p) return;
  for (const o of MAIN_VOLUME_OPTIONS) setVal(o.inputId, p[o.platformKey]);

  elPlatformHint.textContent = '';
  const hintLine = document.createElement('p');
  hintLine.textContent = p.hint;
  elPlatformHint.appendChild(hintLine);
  if (desktopHostNote) {
    const noteLine = document.createElement('p');
    noteLine.className = 'text-amber-400';
    noteLine.textContent = desktopHostNote;
    elPlatformHint.appendChild(noteLine);
  }

  refreshMainVolumeWarnings();
  generate();
}

function setTab(tab: Tab, focusTab = false): void {
  currentTab = tab;
  const isCompose = tab === 'compose';
  // Visuals live in CSS keyed off `aria-selected`; JS only toggles state.
  elTabCompose.setAttribute('aria-selected', String(isCompose));
  elTabRun.setAttribute('aria-selected', String(!isCompose));
  // Roving tabindex: only the active tab receives Tab focus, matching the
  // WAI-ARIA authoring-practices tabs pattern.
  elTabCompose.tabIndex = isCompose ? 0 : -1;
  elTabRun.tabIndex = isCompose ? -1 : 0;
  // Associate the tabpanel with whichever tab is active.
  elOutput.setAttribute('aria-labelledby', isCompose ? 'tab-compose' : 'tab-run');
  elEditorFilename.textContent = isCompose ? 'docker-compose.yml' : 'terminal';
  elBtnDownload.style.display = '';
  if (focusTab) (isCompose ? elTabCompose : elTabRun).focus();
  updateNote();
  generate();
}

// Flashes a button green for ~2 seconds and announces an action via the
// shared copy-status aria-live region. The pattern is identical across
// every toolbar action (Copy, Share, Reset); only the icons and the status
// message differ.
function flashButton(
  button: HTMLButtonElement,
  defaultIcon: HTMLElement,
  checkIcon: HTMLElement,
  statusMessage: string,
): void {
  button.style.borderColor = '#22c55e';
  defaultIcon.classList.add('hidden');
  checkIcon.classList.remove('hidden');
  elCopyStatus.textContent = statusMessage;
  setTimeout(() => {
    button.style.borderColor = '';
    defaultIcon.classList.remove('hidden');
    checkIcon.classList.add('hidden');
    elCopyStatus.textContent = '';
  }, 2000);
}

function copyToClipboard(): void {
  void navigator.clipboard.writeText(getRawText()).then(() => {
    flashButton(elBtnCopy, elIconCopy, elIconCheck, 'Configuration copied to clipboard.');
  });
}

function copyShareLink(): void {
  void navigator.clipboard.writeText(window.location.href).then(() => {
    flashButton(elBtnShare, elIconShare, elIconShareCheck, 'Share link copied to clipboard.');
  });
}

function downloadFile(): void {
  const text = getRawText();
  const blob = new Blob([text], { type: 'text/yaml' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = currentTab === 'compose' ? 'docker-compose.yml' : 'docker-run.sh';
  a.click();
  URL.revokeObjectURL(url);
}

let extraRowCounter = 0;

function addExtraVolumeRow(initial?: { host?: string; container?: string }): void {
  const template = $<HTMLTemplateElement>('extra-vol-template');
  const fragment = template.content.cloneNode(true) as DocumentFragment;
  const row = fragment.querySelector<HTMLElement>('.extra-vol-row')!;
  const removeBtn = row.querySelector<HTMLButtonElement>('[data-action="remove"]')!;
  const hostInput = row.querySelector<HTMLInputElement>('.extra-vol-host')!;
  const containerInput = row.querySelector<HTMLInputElement>('.extra-vol-container')!;
  const warning = row.querySelector<HTMLElement>('.extra-vol-warning')!;

  // Unique warning id so each input can reference its row's warning via
  // aria-describedby — screen readers will re-announce the error when the
  // user refocuses the field, not just at the moment it appears.
  const warningId = 'extra-vol-warning-' + ++extraRowCounter;
  warning.id = warningId;
  hostInput.setAttribute('aria-describedby', warningId);
  containerInput.setAttribute('aria-describedby', warningId);

  hostInput.value = initial?.host ?? platforms[currentPlatform()]?.prefix ?? '';
  containerInput.value = initial?.container ?? '';

  removeBtn.addEventListener('click', () => {
    // Drop the row's warning from the error-source set before the DOM node
    // goes away; otherwise hasVisibleErrors() would count it forever.
    forgetValidationSource(warning);
    // Move focus off the row before removing it, otherwise focus falls
    // back to <body> and a keyboard user loses their place.
    $<HTMLButtonElement>('btn-add-volume').focus();
    row.remove();
    refreshExtraVolumeWarnings();
    generate();
  });
  hostInput.addEventListener('input', () => {
    updateExtraVolumeWarning(row);
    generate();
  });
  // Container changes can flip other rows' duplicate-check results, so
  // refresh every row, not just this one.
  containerInput.addEventListener('input', () => {
    refreshExtraVolumeWarnings();
    generate();
  });

  $('extra-volumes').appendChild(fragment);
  updateExtraVolumeWarning(row);
  // Pushing a new error-severity warning into the set must also refresh the
  // action-button state, otherwise Copy/Download stay enabled until the
  // next keystroke.
  generate();

  // Only autofocus when the user clicked "Add mount" — not when rows are
  // being programmatically added from URL state on page load.
  if (!initial) {
    hostInput.focus();
    hostInput.setSelectionRange(hostInput.value.length, hostInput.value.length);
  }
}

function populateTimezones(): void {
  const tzSelect = $<HTMLSelectElement>('tz-value');
  let detectedTz = '';
  try {
    detectedTz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  } catch {}

  let tzList: string[] = [];
  try {
    tzList = Intl.supportedValuesOf('timeZone');
  } catch {
    tzList = [
      'UTC', 'America/New_York', 'America/Chicago', 'America/Denver', 'America/Los_Angeles',
      'America/Anchorage', 'Pacific/Honolulu', 'America/Toronto', 'America/Vancouver',
      'America/Sao_Paulo', 'America/Mexico_City', 'America/Argentina/Buenos_Aires',
      'Europe/London', 'Europe/Paris', 'Europe/Berlin', 'Europe/Amsterdam', 'Europe/Stockholm',
      'Europe/Zurich', 'Europe/Moscow', 'Europe/Rome', 'Europe/Madrid', 'Europe/Warsaw',
      'Europe/Prague', 'Europe/Vienna', 'Europe/Helsinki', 'Europe/Athens', 'Europe/Istanbul',
      'Europe/Lisbon', 'Europe/Dublin', 'Europe/Oslo', 'Europe/Copenhagen', 'Europe/Brussels',
      'Asia/Tokyo', 'Asia/Shanghai', 'Asia/Hong_Kong', 'Asia/Singapore', 'Asia/Kolkata',
      'Asia/Dubai', 'Asia/Seoul', 'Asia/Taipei', 'Asia/Bangkok', 'Asia/Jakarta',
      'Asia/Karachi', 'Asia/Dhaka', 'Asia/Kuala_Lumpur', 'Asia/Manila', 'Asia/Riyadh',
      'Asia/Tehran', 'Asia/Jerusalem', 'Asia/Novosibirsk', 'Asia/Vladivostok',
      'Australia/Sydney', 'Australia/Melbourne', 'Australia/Perth', 'Australia/Brisbane',
      'Australia/Adelaide', 'Australia/Hobart',
      'Pacific/Auckland', 'Pacific/Fiji', 'Pacific/Guam',
      'Africa/Johannesburg', 'Africa/Cairo', 'Africa/Lagos', 'Africa/Nairobi',
      'Africa/Casablanca',
    ];
  }

  while (tzSelect.firstChild) tzSelect.removeChild(tzSelect.firstChild);

  function getUtcOffset(tz: string): string {
    try {
      const fmt = new Intl.DateTimeFormat('en-US', { timeZone: tz, timeZoneName: 'shortOffset' });
      const parts = fmt.formatToParts(new Date());
      for (const part of parts) {
        if (part.type === 'timeZoneName') return part.value;
      }
    } catch {}
    return '';
  }

  if (detectedTz) {
    const detOpt = document.createElement('option');
    detOpt.value = detectedTz;
    const detOffset = getUtcOffset(detectedTz);
    detOpt.textContent = detectedTz + (detOffset ? ' (' + detOffset + ', detected)' : ' (detected)');
    detOpt.selected = true;
    tzSelect.appendChild(detOpt);
  }

  tzList.forEach((tz) => {
    if (tz === detectedTz) return;
    const opt = document.createElement('option');
    opt.value = tz;
    const offset = getUtcOffset(tz);
    opt.textContent = tz + (offset ? ' (' + offset + ')' : '');
    if (!detectedTz && tz === 'UTC') opt.selected = true;
    tzSelect.appendChild(opt);
  });
}

// Returns every control to its default state and clears all persistence
// (URL + localStorage). Used by the Reset button; also a good place to
// test-drive "what are the defaults?" in a single function.
function resetToDefaults(): void {
  // Reset toggles — the options table already knows each one's default.
  for (const o of BOOLEAN_OPTIONS) {
    $<HTMLInputElement>(o.inputId).checked = o.defaultValue;
  }

  // Reset branch.
  $<HTMLSelectElement>('branch-select').value = 'production';

  // Reset timezone to the browser-detected value if we have it; otherwise
  // UTC, which is always first in the fallback list.
  let detectedTz = '';
  try {
    detectedTz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  } catch {}
  const tzSelect = $<HTMLSelectElement>('tz-value');
  const target = detectedTz && Array.from(tzSelect.options).some((o) => o.value === detectedTz)
    ? detectedTz
    : 'UTC';
  tzSelect.value = target;

  // Remove all extras rows.
  document.querySelectorAll<HTMLElement>('.extra-vol-row').forEach((row) => {
    const w = row.querySelector<HTMLElement>('.extra-vol-warning');
    if (w) forgetValidationSource(w);
    row.remove();
  });

  // Reset platform to default and re-populate volume paths from its preset.
  $<HTMLSelectElement>('platform-select').value = defaultPlatformId;
  setPlatform(defaultPlatformId);

  syncTzVisibility();
  refreshMainVolumeWarnings();

  // Clear persistence AFTER the DOM reset so the setPlatform()/generate()
  // cascade above doesn't save a stale pre-reset state. generate() also
  // re-saves to URL + localStorage; explicitly clear here to get a clean
  // URL bar rather than `?tz=...` carrying the detected value forward.
  clearState();
  history.replaceState(null, '', window.location.pathname);
}

function detectDesktopOS(): void {
  const ua = navigator.userAgent || '';
  const plat = navigator.platform || '';
  const isDesktop = /Mac/i.test(plat) || /Mac/i.test(ua) || /Win/i.test(plat) || /Windows/i.test(ua);
  if (isDesktop) {
    desktopHostNote = 'Roon Server requires a Linux host.';
  }
}

function bindEvents(): void {
  $<HTMLSelectElement>('platform-select').addEventListener('change', function () {
    setPlatform(this.value);
    refreshExtraVolumeWarnings();
    refreshMainVolumeWarnings();
    // Platform change stomps the three volume paths with the new preset.
    // Announce it so a screen reader user isn't surprised when the next
    // field they visit has a different value than they typed.
    const p = platforms[this.value];
    if (p) {
      elCopyStatus.textContent = 'Volume paths set for ' + p.label + '.';
      setTimeout(() => {
        if (elCopyStatus.textContent === 'Volume paths set for ' + p.label + '.') {
          elCopyStatus.textContent = '';
        }
      }, 3000);
    }
  });

  $<HTMLButtonElement>('btn-add-volume').addEventListener('click', () => addExtraVolumeRow());

  elTabCompose.addEventListener('click', () => setTab('compose'));
  elTabRun.addEventListener('click', () => setTab('run'));

  // WAI-ARIA tabs pattern: Left/Right toggle the two tabs; Home/End are
  // aliases for the first/last. Keeps focus + selection in sync.
  const handleTabKeydown = (e: KeyboardEvent): void => {
    if (e.key === 'ArrowLeft' || e.key === 'End') {
      e.preventDefault();
      setTab('compose', /* focusTab */ true);
    } else if (e.key === 'ArrowRight' || e.key === 'Home') {
      e.preventDefault();
      setTab('run', /* focusTab */ true);
    }
  };
  elTabCompose.addEventListener('keydown', handleTabKeydown);
  elTabRun.addEventListener('keydown', handleTabKeydown);
  elBtnCopy.addEventListener('click', copyToClipboard);
  elBtnDownload.addEventListener('click', downloadFile);
  elBtnShare.addEventListener('click', copyShareLink);

  elBtnReset.addEventListener('click', () => {
    resetToDefaults();
    flashButton(elBtnReset, elIconReset, elIconResetCheck, 'Reset to defaults.');
  });

  for (const o of MAIN_VOLUME_OPTIONS) {
    $(o.inputId).addEventListener('input', () => {
      updateMainVolumeWarning(o.inputId);
      generate();
    });
  }

  $<HTMLSelectElement>('tz-value').addEventListener('change', generate);

  $<HTMLSelectElement>('branch-select').addEventListener('change', function () {
    const hint = $('branch-hint');
    hint.textContent = this.value === 'earlyaccess' ? 'Early access to new features and updates.' : '';
    generate();
  });

  for (const o of BOOLEAN_OPTIONS) {
    $<HTMLInputElement>(o.inputId).addEventListener('change', generate);
  }
  // tz-visibility is the one toggle with a UI side-effect beyond re-render,
  // so it gets a dedicated listener rather than threading that concern
  // through generate().
  $<HTMLInputElement>('opt-tz').addEventListener('change', syncTzVisibility);
}

function populatePlatformSelect(order: readonly string[]): void {
  const select = $<HTMLSelectElement>('platform-select');
  const visibleIds: string[] = [];
  for (const id of order) {
    const p = platforms[id];
    if (!p || p.hidden) continue;
    const opt = document.createElement('option');
    opt.value = id;
    opt.textContent = p.label;
    select.appendChild(opt);
    visibleIds.push(id);
  }
  // Convention: first visible entry in the manifest is the default.
  const defaultId = visibleIds[0];
  if (defaultId) select.value = defaultId;
}

// --- Init ---

// Failsafe for the body-opacity loading state in index.html: if init throws
// before reaching the explicit app-ready flip below, the `load` event still
// fires when the document and its resources finish loading, so users won't
// be stuck on a blank page even if loadPlatforms() rejects or a later init
// step crashes. Registered before the first await so it's in place even if
// the very next line fails.
window.addEventListener('load', () => {
  document.body.classList.add('app-ready');
});

const loaded = await loadPlatforms();
platforms = loaded.platforms;
defaultPlatformId = loaded.order.find((id) => !platforms[id]?.hidden) ?? '';
populatePlatformSelect(loaded.order);

// Precedence for restoring state: URL params (shared link) > localStorage
// (returning visitor) > defaults. A share URL always wins so the recipient
// sees exactly what the sender meant; persistence only fills in when there's
// no URL state to honor.
const urlParams = new URLSearchParams(window.location.search);
const effectiveParams = urlParams.toString() ? urlParams : loadState() ?? new URLSearchParams();
const urlOverride = decodeUrl(effectiveParams);
if (urlOverride.platform) {
  const p = platforms[urlOverride.platform];
  if (p && !p.hidden) {
    $<HTMLSelectElement>('platform-select').value = urlOverride.platform;
  }
}

populateTimezones();
detectDesktopOS();
bindEvents();
updateNote();
setPlatform(currentPlatform());

// Overlay any remaining URL-driven fields on top of the platform defaults,
// then enable URL writes and do a final generate() to sync the URL.
applyUrlOverride(urlOverride);
// Reflect the initial tz toggle state (possibly overridden from URL) in the
// selector visibility. generate() no longer does this.
syncTzVisibility();
urlUpdatesEnabled = true;
generate();

// Reveal the body now that the first paint will reflect a fully-initialized
// app (platforms loaded, defaults applied, output rendered). This is the
// happy-path flip; the window 'load' listener at the top of init is the
// failsafe for crash paths.
document.body.classList.add('app-ready');
