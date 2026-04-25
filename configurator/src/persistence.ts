// Small wrapper around localStorage for the configurator's state.
// Stores the same URLSearchParams-serialized form the share URL uses, so
// loading is the exact same code path as loading from a share link.
// Swallows storage errors silently — the app still works without persistence
// (private-browsing, full-disk, corporate lockdown, etc.).

const STORAGE_KEY = 'roon-configurator-state';

export function saveState(params: URLSearchParams): void {
  const serialized = params.toString();
  try {
    if (serialized) {
      window.localStorage.setItem(STORAGE_KEY, serialized);
    } else {
      window.localStorage.removeItem(STORAGE_KEY);
    }
  } catch {
    // Ignore: Safari private mode, quota, corporate policy, etc.
  }
}

export function loadState(): URLSearchParams | null {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    return new URLSearchParams(raw);
  } catch {
    return null;
  }
}

export function clearState(): void {
  try {
    window.localStorage.removeItem(STORAGE_KEY);
  } catch {
    // Same as above — nothing to do if storage is inaccessible.
  }
}
