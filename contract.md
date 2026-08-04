# palimpsest — Interface Contract

**This is the source of truth.** Both the NixOS configuration and the container stack are built against it. Neither agent may change a value here; if an agent believes a value is wrong, it stops and tells me.

Everything in this file is something *both* halves need to agree on. Anything only one half cares about does not belong here.

---

## 0. Repositories

Two repos, split by layer rather than by tooling.

| Repo | Checkout | Owns |
|---|---|---|
| `palimpsest-system` | `/opt/palimpsest-system` | NixOS config: boot, drivers, users, filesystems, networking, firewall, the systemd unit that runs the stack |
| `palimpsest-stack` | `/opt/palimpsest-stack` | `compose.yaml`, `.env.example`, application-level configuration |

**The boundary is hard.** A session working in one repo does not edit the other. If the stack needs a firewall port opened or a UID changed, it stops and says so — it does not reach into `palimpsest-system`. This is deliberate: these sessions run with permissions skipped, and a boundary that an agent cannot cross is worth more than the convenience of crossing it.

Named by layer, not technology. If the container runtime changes, `palimpsest-stack` is still the right name.

**Naming convention.** Machines in this household take folkloric, mythic, or literary names, avoiding deities. `palimpsest` — a manuscript scraped clean and written over, the earlier text still faintly legible underneath — names a gaming laptop given a second life. Future machines follow the same scheme, and their repos follow the same `<host>-system` / `<host>-stack` split.

**This contract lives in `palimpsest-system`,** which is authoritative — it implements most of the values. `palimpsest-stack` gets a copy for authoring reference only. **At runtime, the stack reads the live system, never the copy:** `id media`, `getent group render`, `findmnt /data`. Copies drift; the running system cannot. That is what §7 is for.

Each repo carries a `CLAUDE.md` at its root describing that layer's architecture, its contract values, what is deliberate versus incidental, and known-fragile areas — so a future debugging session starts oriented instead of re-deriving it, and knows which values are not its to change.

**Not in git, in either repo:**

- `.env` and any file containing a credential
- `/opt/palimpsest-stack/<appname>/` — per-app runtime state. These directories sit inside the stack checkout but are *not* source: they hold databases, generated API keys, and cross-service tokens. Gitignore them explicitly.
- `hardware-configuration.nix` is generated per-machine; commit it, but note in `NOTES.md` that it is machine-specific and not portable.

Because we use flakes, `palimpsest-system` does **not** need to live at `/etc/nixos`:

```bash
nixos-rebuild switch --flake /opt/palimpsest-system#palimpsest
```

## 1. Identity

| Thing | Value | Set by | Consumed by |
|---|---|---|---|
| Admin user | `frank`, UID 1000 | NixOS | — |
| Service account | `media`, UID **1500** | NixOS | compose `PUID` |
| Service group | `media`, GID **1500** | NixOS | compose `PGID` |
| Render group | `render`, GID **303** (pinned explicitly, not inherited) | NixOS | compose `group_add` |
| Umask | `002` | — | compose `UMASK` |

The admin user takes 1000 because NixOS assigns it to the first normal user. The service account must therefore be elsewhere; 1500 is chosen to be clearly outside the normal-user range.

Containers run as `1500:1500` with supplementary group `303`. Every container in the stack uses the same values — no per-service variation.

## 2. Filesystem

| Path | What | Created by |
|---|---|---|
| `/data` | Single mountpoint. **All media and download paths live under it.** | NixOS `fileSystems` |
| `/data/media/{movies,tv}` | Jellyfin libraries | NixOS tmpfiles |
| `/data/torrents/{movies,tv}` | Torrent download target | NixOS tmpfiles |
| `/data/usenet/{incomplete,complete}` | Usenet download target | NixOS tmpfiles |
| `/data/transcode` | tmpfs, 8 GB | NixOS `fileSystems` |
| `/opt/palimpsest-stack` | Compose file and per-app config subdirectories | NixOS tmpfiles |

All of the above owned `media:media`, mode `0775`.

**`/data` is a single filesystem and must stay that way.** The automation tools hardlink between `/data/torrents` and `/data/media`; a second mountpoint anywhere inside `/data` breaks that silently. The tmpfs at `/data/transcode` is the sole exception and nothing hardlinks into it.

Containers mount `/data` as `/data` — identical path inside and out. No per-service remapping, no `/downloads` or `/movies` aliases.

## 3. Container execution

| Thing | Value |
|---|---|
| Runtime | Docker |
| Compose file | `/opt/palimpsest-stack/compose.yaml` — a **plain file**, not in the Nix store |
| Per-app config | `/opt/palimpsest-stack/<appname>/` bind-mounted to the container's `/config` |
| Boot behavior | systemd unit runs `docker compose up -d`; `down` on stop |
| Unit ordering | `After=docker.service`, `RequiresMountsFor=/data /opt/palimpsest-stack` |
| Unit type | `oneshot` with `RemainAfterExit=yes` |
| Unit restart policy | **None.** Per-container `restart: unless-stopped` handles recovery. |
| Enabled at boot | **No, initially.** Ships disabled; I enable it once the stack works. |

The compose file stays outside the Nix store deliberately: it is the thing that changes most often, and requiring a `nixos-rebuild` per tweak would make the iteration loop miserable. It lives in its own git repo.

## 4. Hardware passthrough

| Thing | Value |
|---|---|
| Transcode device | `/dev/dri` — passed to the Jellyfin container only |
| VAAPI device node | `/dev/dri/renderD128` |
| Driver | Intel iHD (`intel-media-driver`); **not** legacy i965 |
| Transcode temp path | `/data/transcode`, mounted into Jellyfin as `/transcode` |
| NVIDIA | Not installed, not configured. dGPU stays in D3cold. |

## 5. Ports

Jellyfin runs on **host networking** (required for DLNA and client auto-discovery). Everything else publishes to the host.

| Port | Service | Reachable from |
|---|---|---|
| 22 | SSH | LAN + tailscale0 |
| 8096 | Jellyfin | LAN + tailscale0 |
| 5055 | Jellyseerr | tailscale0 only |
| 6767 | Bazarr | tailscale0 only |
| 7878 | Radarr | tailscale0 only |
| 8080 | qBittorrent WebUI | tailscale0 only |
| 8081 | SABnzbd | tailscale0 only |
| 8989 | Sonarr | tailscale0 only |
| 9696 | Prowlarr | tailscale0 only |

Firewall default-deny inbound. LAN means RFC1918 only. Nothing is port-forwarded from the router, ever.

## 6. Secrets

No secret appears in either the Nix config or the compose file. Placeholders only, documented in each half's `NOTES.md`:

- Tailscale auth key — authenticated by hand
- WireGuard/VPN credentials for the download client
- Usenet provider and indexer credentials
- Any API keys the automation tools generate for each other

## 7. Verification

The contract is satisfied when all of these pass on the real machine:

```bash
id media                                    # uid=1500 gid=1500
getent group render                         # gid 303
stat -c '%u %g %a' /data /opt/palimpsest-stack         # 1500 1500 775
findmnt -no SOURCE /data /data/media        # same source
vainfo | grep -c VAProfile                  # non-zero
docker compose -f /opt/palimpsest-stack/compose.yaml config   # parses
touch /data/torrents/x && ln /data/torrents/x /data/media/x && echo HARDLINK OK
```

That last one is the important one. If it fails, the whole automation layer is broken in a way that will not announce itself.
