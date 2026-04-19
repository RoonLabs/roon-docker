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
| `/Music` | Your music library, think of this like your user's Music folder Linux, macOS, or Windows -- it's the "default music folder" |
| `/RoonBackups` | Roon backup destination (optional). Configure in Settings > Backups. |

**The `/Roon` volume is critical.** If this volume is not mounted:

- Your Roon data and settings will not persist across container restarts
- Your Roon install must be re-authorized on each start

If your music lives in one subdirectory on your host, mount it directly using `-v /path/to/music:/Music`. If your music is spread across multiple locations on your host, mount each location under `/Music`. For example: `-v /mnt/usb1:/Music/first -v /mnt/usb2:/Music/second`.

To use Roon's database backup feature, mount a volume at `/RoonBackups` and point Roon's backup location to that directory. Example: `-v /mnt/usb1/backups:/RoonBackups` and then enable backups via Settings > Backups in Roon.

## Updating

All RoonServer state and binaries are persisted to the `/Roon` volume. Recreating the container (`docker rm` + `docker run`) does not trigger a re-download if you mount in the same folder to the `/Roon` volume.

### Automatic updates via roon-docker-updater

The configuration generator enables **roon-docker-updater** by default — a small sidecar container that detects when a newer RoonServer image is published. Unlike general-purpose auto-updaters such as Watchtower, it does **not** recreate the container on its own schedule; instead it exposes "update available" to Roon, and **Roon decides when to download the image and when to apply the restart**. This means an image update cannot interrupt playback — the sidecar only *detects*; Roon *acts*, at a moment it knows is safe.

The sidecar mounts the Docker socket in order to recreate the container, but it is a purpose-built audited script (~150 lines of bash, no network listeners, no third-party code paths), so the privileged container's attack surface is minimal and reviewable. It is scoped via `WATCH_CONTAINER=roonserver` so only the RoonServer container is managed; other containers on the host are left alone.

The two containers communicate over a named volume `roon-docker-update-state` using four files:

| File | Direction | Meaning |
| --- | --- | --- |
| `update-available` | updater &rarr; Roon | A newer image digest is available at the registry. |
| `ready-to-pull` | Roon &rarr; updater | Roon is OK with downloading the image now. |
| `update-pulled` | updater &rarr; Roon | The new image is locally available. |
| `ready-to-restart` | Roon &rarr; updater | Roon is OK with recreating the container now. |

The updater polls the registry once per hour by default (`POLL_INTERVAL=3600`). Detection uses Docker's `/distribution/<image>/json` endpoint, which queries the registry manifest **without downloading any image layers** — so detection alone cannot cause a later unrelated `docker compose up` on the host to silently install the new version.

If you prefer manual updates, uncheck the updater option in the generator; the generated commands will omit the sidecar entirely. You can then update on demand with:

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
