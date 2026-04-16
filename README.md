# RoonServer Docker Image

Official Docker image for [RoonServer](https://roon.app).

```
ghcr.io/roonlabs/roonserver
```

> **Note:** This image is **amd64 (x86_64) only**. ARM-based devices (Raspberry Pi, ARM NAS models like Synology J-series) are not supported.

## Quick Start

Use the **[Docker Setup Guide](https://roonlabs.github.io/roon-docker/)** to generate a `docker run` or `docker compose` command tailored to your system.

On first start, the container downloads and installs RoonServer automatically. Subsequent starts skip the download and launch immediately.

## Requirements

- **Linux host** (amd64 / x86_64) — NAS devices (Synology, QNAP, Unraid, TrueNAS) work well
- **Host networking** (`--net=host`) — required for Roon's multicast device discovery
- **Restart policy** (`--restart unless-stopped`) — ensures the container restarts after unexpected exits

Docker Desktop for macOS and Windows does not support multicast and will not work for production use.

## Networking

Roon requires host networking (`--net=host`) for multicast device discovery. Bridge networking will not work. No port mapping (`-p`) is needed.

## Timezone

Set the `TZ` environment variable to your [timezone](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones). This ensures correct timestamps in Roon logs, last.fm scrobbles, and backup schedules.

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `TZ` | `UTC` | Timezone for logs and schedules |
| `ROON_INSTALL_BRANCH` | `production` | Release channel: `production` or `earlyaccess` |
| `ROON_DOWNLOAD_URL` | *(from Roon servers)* | Override the RoonServer download URL |

## Volumes

| Mount | Purpose |
|-------|---------|
| `/Roon` | RoonServer state — database, settings, identity, and application binaries. Must be writable and persistent. |
| `/RoonBackup` | Roon backup destination (optional). Configure in Settings > Backups. |
| `/music` | Your music library (read-only) |

**The `/Roon` volume is critical.** If this volume is lost:

- Your Roon data and settings are lost unless they can be restored from a Roon backup
- The server will appear as a new machine and must be re-authorized from a Roon remote

We recommend using Roon's built-in backup feature (Settings > Backups) pointed at `/RoonBackup`.

## Updating

When an update is available, RoonServer will download and install it automatically. A restart is required to apply the update, which can be triggered from a Roon remote. The Docker image plays no role in the update process.

All RoonServer state and binaries are persisted to the `/Roon` volume. Recreating the container (`docker rm` + `docker run`) does not trigger a re-download.

## Release Channel

RoonServer has two release channels:

| Channel | `ROON_INSTALL_BRANCH` | Community |
|---------|----------------|-----------|
| **Production** | `production` (default) | [Roon](https://community.roonlabs.com/c/roon/8) |
| **Early Access** | `earlyaccess` | [Early Access](https://community.roonlabs.com/c/early-access/120) |

Set `ROON_INSTALL_BRANCH` to change the channel. The channel determines which version of RoonServer is downloaded on first start, and Roon's self-updater continues on the same channel automatically.

Changing channels on an existing install is safe — the container removes the old binaries and downloads from the new channel. Your data, settings, and identity are preserved.

## Troubleshooting

**Container exits immediately** — check `/Roon` is mounted and writable.

**Remotes can't find the server** — verify `--net=host` is set. Bridge networking doesn't support multicast discovery.

**High CPU after first start** — background audio analysis runs after importing a library. Adjust speed in Settings > Library.

**First start is slow** — RoonServer (~200MB) is downloaded on first run. Subsequent starts are instant.

**Logs** — `docker logs roonserver` or inside the volume at `/Roon/database/RoonServer/Logs/`.

## License

Copyright Roon Labs LLC. All rights reserved.
