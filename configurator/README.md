# RoonServer Docker Configuration Generator

A static web app that generates `docker-compose.yml` and `docker run`
commands for the official RoonServer Docker image. Built with TypeScript
and Vite, deployed to GitHub Pages.

## Development

```sh
npm install
npm run dev          # dev server with hot reload at http://localhost:5173
npm run typecheck    # tsc --noEmit
npm test             # vitest
npm run build        # typecheck + Vite build into dist/
npm run preview      # serve the built dist/ for a final sanity check
```

## Adding a platform

Platforms are declarative JSON under [`public/platforms/`](public/platforms/).
To add one:

1. Create `public/platforms/<id>.json` matching the shape below.
2. Add the `<id>` to the `public/platforms/index.json` manifest in the
   order it should appear in the dropdown.
3. Run `npm test` — the platform-file tests will validate the shape and
   confirm the manifest is in sync.

The manifest's **first visible entry is the default platform**. To change
the default, reorder the manifest.

### Platform JSON shape

```json
{
  "id": "qnap",
  "label": "QNAP",
  "roon": "/share/Container/roon",
  "music": "/share/Music",
  "backup": "/share/Container/roon-backups",
  "prefix": "/share/",
  "hint": "Paths set for QNAP. Container Station stores app data under /share/Container/.",
  "rootPattern": "^/share/",
  "hidden": false
}
```

| Field         | Required | Purpose                                                                    |
|---------------|----------|----------------------------------------------------------------------------|
| `id`          | yes      | Must match the filename (`qnap.json` → `"id": "qnap"`).                    |
| `label`       | yes      | Display text in the dropdown and inline warnings.                          |
| `roon`        | yes      | Default host path for the `/Roon` container mount.                         |
| `music`       | yes      | Default host path for the `/Music` container mount.                        |
| `backup`      | yes      | Default host path for the `/RoonBackups` container mount.                  |
| `prefix`      | yes      | Placeholder text for the "add mount" host input.                           |
| `hint`        | yes      | One-sentence help text shown under the platform dropdown.                  |
| `rootPattern` | no       | Regex string. If present, host paths not matching it show a soft warning. |
| `hidden`      | no       | `true` keeps the platform loaded but omits it from the dropdown.           |

## Tests

- **`src/*.test.ts`** — unit tests for the pure modules (`generator`,
  `platforms`), plus structural checks on every platform JSON file. Uses
  [Vitest](https://vitest.dev/).
- **`e2e/`** — end-to-end tests against the built site, driven by
  [Playwright](https://playwright.dev/). Run with `npm run test:e2e`.

CI runs `typecheck`, `test`, and `test:e2e` before every deploy.

## Architecture

Each source module has one job. Keeping them separate makes the pure
logic unit-testable without a DOM.

| File                   | Responsibility                                                   |
|------------------------|------------------------------------------------------------------|
| `src/types.ts`         | Shared types: `Config`, `Platform`, `ValidationIssue`.           |
| `src/generator.ts`     | Pure functions: `Config` → compose/run output lines.             |
| `src/platforms.ts`     | Platform loader + validation helpers. No DOM.                    |
| `src/highlight.ts`     | DOM-based syntax highlighting for the output editor.             |
| `src/main.ts`          | DOM wiring, event handlers, app init.                            |
| `public/platforms/`    | Platform data files (copied verbatim to the build output).       |

## Deployment

Deployment is automated via [`.github/workflows/pages.yml`](../.github/workflows/pages.yml).
Every push to `main` that touches `configurator/**` triggers a build
and, on success, a Pages deploy. To deploy, the repository's **Settings
→ Pages → Source** must be set to **GitHub Actions**.
