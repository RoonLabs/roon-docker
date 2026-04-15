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
- **Restart policy** (`--restart unless-stopped`) — ensures the container restarts after updates or unexpected exits
- **Init process** (`--init`) — ensures clean signal handling and zombie process reaping
- **Stop timeout** (`--stop-timeout 45`) — gives Roon time to flush its database on shutdown

Docker Desktop for macOS and Windows does not support multicast and will not work for production use.

## Networking

Roon requires host networking (`--net=host`) for multicast device discovery. Bridge networking will not work. No port mapping (`-p`) is needed.

## Timezone

Set the `TZ` environment variable to your [timezone](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones). This ensures correct timestamps in Roon logs, last.fm scrobbles, and backup schedules.

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `TZ` | `UTC` | Timezone for logs and schedules |
| `ROON_CHANNEL` | `production` | Release channel: `production` or `earlyaccess` |
| `ROON_DOWNLOAD_URL` | *(default CDN)* | Override the RoonServer download URL |

## Volumes

All Roon state lives under a single `/Roon` mount:

| Path | Purpose |
|------|---------|
| `/Roon/data` | Database, settings, cache, and identity |
| `/Roon/backup` | Roon backup destination |
| `/Roon/app` | Downloaded RoonServer binaries |
| `/music` | Your music library (mounted read-only) |

```bash
-v /Roon:/Roon \
-v /Music:/music:ro
```

**The `/Roon/data` directory is critical.** If this volume is lost:

- Your Roon data and settings are lost unless they can be restored from a Roon backup
- The server will appear as a new machine and must be re-authorized from a Roon remote

Always back up your `/Roon` volume. We recommend using Roon's built-in backup feature in Settings > Backups, with `/Roon/backup` as the backup destination

## Updating

RoonServer updates itself automatically. When an update is available, the container will download and apply it — no action needed.

Updates persist across `docker stop` / `docker start`. If you recreate the container (`docker rm` + `docker run`), RoonServer will be re-downloaded from the configured release channel on first start.

## Release Channel

RoonServer has two release channels:

| Channel | `ROON_CHANNEL` | Community |
|---------|----------------|-----------|
| **Production** | `production` (default) | [Roon](https://community.roonlabs.com/c/roon/8) |
| **Early Access** | `earlyaccess` | [Early Access](https://community.roonlabs.com/c/early-access/120) |

Set `ROON_CHANNEL` to change the channel. The channel determines which version of RoonServer is downloaded on first start, and Roon's self-updater continues on the same channel automatically.

Changing channels on an existing install is safe — the container removes the old binaries and downloads from the new channel. Your data, settings, and identity are preserved.

## Troubleshooting

**Container exits immediately** — check `/Roon` is mounted and writable.

**Remotes can't find the server** — verify `--net=host` is set. Bridge networking doesn't support multicast discovery.

**High CPU after first start** — background audio analysis runs after importing a library. Adjust speed in Settings > Library.

**First start is slow** — RoonServer (~200MB) is downloaded on first run. Subsequent starts are instant.

**Logs** — `docker logs roonserver` or inside the volume at `/Roon/data/RoonServer/Logs/`.

## License

Copyright Roon Labs LLC. All rights reserved.
