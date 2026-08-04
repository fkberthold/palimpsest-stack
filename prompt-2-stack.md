# Prompt 2 — Container stack

Run this **on the target machine**, after NixOS is installed and the contract §7 checks pass. Attach `contract.md`.

Unlike the Nix half, this one is empirical — you'll be starting containers and watching what happens.

---

I am building the container stack for a headless home media server running NixOS. The system layer is already installed and verified.

I have attached `contract.md`. It defines the interface you must build against. **Every value in it is fixed** — UIDs, paths, ports, the render GID. If a value appears wrong, stop and tell me; do not work around it.

Your scope is the compose file and application configuration. You are not touching the NixOS config; if something needs to change there, tell me and I'll handle it in the other session.

## Ground rules

1. **Verify before asserting.** After every meaningful change, check it actually worked — `docker compose ps`, container logs, an HTTP request to the service. Don't tell me something is configured because you wrote it into a file.
2. **Pin image tags.** No `:latest` on anything. State which version you pinned and why.
3. **Run the contract §7 checks first,** before writing anything. If any fail, stop — the system layer is wrong and building on it wastes both our time.
4. **The hardlink check is the important one.** Re-run it after the stack is up, from inside a container, not just from the host. A path mapping that breaks hardlinking looks completely fine until months of imports have silently doubled disk usage.
5. **Ask me** rather than guessing on anything involving my accounts, providers, or preferences.

## Method

Init the `palimpsest-stack` repo at `/opt/palimpsest-stack` per contract §0 before writing anything; commit per working milestone. Note that the per-app config directories live inside this checkout but are runtime state, not source — gitignore them. Bring services up **incrementally**, not all at once — Jellyfin first and confirm it works, then the automation layer, then the download clients. A stack that comes up broken all at once is much harder to diagnose than one service that fails on its own.

## The stack

**Jellyfin.** Host networking (needed for DLNA and client discovery). `/dev/dri` passed through, `group_add` per contract §1. Config and cache under `/opt/palimpsest-stack/jellyfin/`. Transcode temp at `/transcode` per contract §4.

**Automation:** Prowlarr (indexer manager), Sonarr, Radarr, Bazarr (subtitles), Jellyseerr (family-facing request UI). Ports per contract §5.

**Download clients:** both usenet and torrents.
- SABnzbd — direct, no VPN needed; usenet is TLS to a paid provider.
- qBittorrent — routed through gluetun with a killswitch. `network_mode: "service:gluetun"`, WebUI surfaced on gluetun's published port.

Every container gets contract §1's PUID/PGID/UMASK. Every container mounts `/data` as `/data` — identical inside and out, no aliases.

## Configuration after the containers are up

**Setup order matters:** Prowlarr first (add indexers) → Sonarr and Radarr (root folders `/data/media/tv` and `/data/media/movies`, add both download clients, let Prowlarr sync indexers across) → Jellyfin libraries pointing at `/data/media/*` → Jellyseerr last (it connects to all of the above).

**Delay profiles.** In both Sonarr and Radarr: preferred protocol Usenet, usenet delay 0, torrent delay 45 minutes. Usenet gets first crack; torrents cover what usenet's retention missed.

**Jellyfin transcoding.** VAAPI on `/dev/dri/renderD128`. Enable hardware decode for H264, HEVC, VP9, AV1. Enable the Intel low-power H.264/HEVC encoder — meaningfully lower power on Alder Lake. Enable hardware tone mapping. Then **prove it works**: force a transcode and watch `intel_gpu_top` for activity on the Video and VideoEnhance engines. If the CPU cores light up instead, VAAPI fell back to software silently and the setting is lying to you.

## Out of scope

No secrets in any committed file — see contract §6. Use a `.env` file, gitignored, with placeholders, and tell me exactly what to fill in. Do not ask me for credentials in chat; I'll edit the file myself.

Do not modify anything under `/etc/nixos`.

## Deliverables

1. `/opt/palimpsest-stack/compose.yaml`, pinned tags, commented.
2. `.env.example` listing every secret I need to supply, with a note on where each comes from.
3. `.gitignore` covering `.env` and the per-app config directories.
4. `NOTES.md`: what's configured, what I still need to do by hand, the verification commands, and the first things to check for each service when something breaks.
5. Confirmation output from the contract §7 checks and from the hardware-transcode verification — actual command output, not a claim that you ran them.

Start by running the contract §7 checks and telling me the results, before writing anything.
