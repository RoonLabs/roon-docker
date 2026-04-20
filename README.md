# RoonServer Docker Image

Official Docker image for [RoonServer](https://roon.app).

```
ghcr.io/roonlabs/roonserver
```

> **Note:** This image is **amd64 (x86_64) only**. ARM-based devices (Raspberry Pi, ARM NAS models like Synology J-series) are not supported.

## Quick Start

Use the **[Docker Setup Guide](https://roonlabs.github.io/roon-docker/)** to generate a `docker run` or `docker compose` command tailored to your system.

On first start, the container downloads and installs RoonServer automatically. Subsequent starts skip the download and launch immediately.

Setting the environment variable `ROON_DOWNLOAD_URL` will allow you to specify a custom RoonServer download URL, which can be useful if you have a local mirror of a RoonServer install tarball. By default, the image uses the official RoonServer download URL from Roon Labs. Example: `-e ROON_DOWNLOAD_URL=https://my-mirror.local/roonserver.tar.gz`.


## Requirements

- **Linux host** (amd64 / x86_64). Common NAS solutions (Unraid, TrueNAS, Synology, QNAP) often fall into this category, but check with your NAS's technical information to confirm.
- **Host networking** (`--net=host`) — required for Roon's multicast device discovery
- **Restart policy** (`--restart unless-stopped`) — ensures the container restarts after unexpected exits

Docker for macOS and Windows will not work.

## Networking

Host networking (`--net=host`) is required. `bridge` networking faces significant limitations for discovery outside the host. No port mapping (`-p`) is needed.

## Timezone

Set the `TZ` environment variable to your [timezone](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones). This ensures correct timestamps in Roon logs, last.fm scrobbles, and backup schedules. For example, `-e TZ=America/New_York` or `-e TZ=Europe/London`. The default is `UTC`.

## Volumes

| Mount | Purpose |
|-------|---------|
| `/Roon` | RoonServer state — database, settings, identity, and application binaries. Must be writable and persistent. |
| `/Music` | Your primary music library — treat this like your user's Music folder on Linux, macOS, or Windows. It's the "default music folder."  Music that Roon imports (e.g. CD rips, downloads) lands here. |
| `/RoonBackups` | Roon backup destination (optional). Configure in Settings > Backups. |

**The `/Roon` volume is critical.** If this volume is not mounted:

- Your Roon data and settings will not persist across container restarts
- Your Roon install must be re-authorized on each start

> **⚠ NAS warning — host paths outside your platform's persistent prefix can silently be tmpfs.** Several NAS OSes run the host root filesystem in RAM and only expose persistent storage under a specific prefix — typically `/share/...` on QNAP, `/volume1/...` on Synology, `/mnt/user/...` on Unraid, `/mnt/<pool>/...` on TrueNAS SCALE. Binding a host path **outside** that prefix (e.g. `/opt/roon` on QNAP) will appear to work: Docker creates the missing directory, the container starts, Roon imports a library — and then a reboot wipes it because the directory only ever lived in RAM. Always mount under your platform's persistent prefix. The [setup generator](https://roonlabs.github.io/roon-docker/) flags paths that don't match the selected platform's prefix.

Mount your **primary** music location directly at `/Music` (e.g. `-v /path/to/music:/Music`). Anything Roon adds to your library from within Roon — CD rips, file imports, downloads — is written here, so this should point at the folder you want to treat as your main library.

If your music is spread across multiple locations on the host, mount each additional location at a named subpath under `/Music`, for example:

```
-v /path/to/primary-music:/Music
-v /mnt/usb1:/Music/usb1
-v /mnt/nas/flac:/Music/nas-flac
```

A few things to know about this layout:

- Each extra mount appears as its own named subfolder inside `/Music`. The mount point (e.g. `usb1`) is created on the primary host folder at container start if it doesn't already exist — that's normally just an empty directory and harmless.
- If the primary folder already contains a real subfolder with the same name as a mount point, the mount will hide it for as long as the container runs. Pick mount names that don't collide with existing folders in your primary library.
- Additional mounts below `/Music` are read/write inside the container just like `/Music` itself. If you want an extra location to be read-only, append `:ro` (e.g. `-v /mnt/archive:/Music/archive:ro`).

To use Roon's database backup feature, mount a volume at `/RoonBackups` and point Roon's backup location to that directory. Example: `-v /mnt/usb1/backups:/RoonBackups` and then enable backups via Settings > Backups in Roon.

## Updating

All RoonServer state and binaries are persisted to the `/Roon` volume. Recreating the container (`docker rm` + `docker run`) does not trigger a re-download if you mount the same folder to the `/Roon` volume.

To update on demand:

```
docker pull ghcr.io/roonlabs/roonserver:latest
docker rm -f roonserver
# re-run your docker run command or: docker compose up -d
```

## Release Branch

RoonServer has two release branches:

| Branch | `ROON_INSTALL_BRANCH` | Community |
|---------|----------------|-----------|
| **Production** | `production` (default) | [Roon](https://community.roonlabs.com/c/roon/8) |
| **Early Access** | `earlyaccess` | [Early Access](https://community.roonlabs.com/c/early-access/120) |

Set the `ROON_INSTALL_BRANCH` environment variable to change the branch. The branch determines which version of RoonServer is downloaded on first start, and Roon's self-updater continues on the same branch automatically.

Warning: Early Access builds may include database changes incompatible with Production, usually noted in the release notes. Please create a fresh backup before switching branches. Be especially careful if switching from Early Access to Production, as the Production branch may not be able to read an Early Access database.

## Troubleshooting

**Container exits immediately** — check `/Roon` is mounted and writable.

**Remotes can't find the server** — verify `--net=host` is set. Bridge networking doesn't support multicast discovery.

**High CPU after first start** — background audio analysis runs after importing a library, it will stop after it's done, and it might take a while if you have a large library.

**First start is slow** — RoonServer is downloaded on first run. Subsequent starts should be quick, if you use the same `/Roon` volume.

**Logs** — `docker logs roonserver` will give you the output of the RoonServer
process on the console. It will not give you RoonServer logs. Those are located on the mounted volume at `/Roon/database/RoonServer/Logs/`.

## License

Copyright Roon Labs LLC. All rights reserved.
