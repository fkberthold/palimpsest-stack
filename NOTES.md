# palimpsest-stack — operator notes

Built against `contract.md`. This file covers what is configured, what you have
to do by hand, how to verify it, and where to look first when a service breaks.

**Status: authored, not yet deployed.** Everything below was written and
syntax-verified on a workstation. Nothing in it has been run against palimpsest
itself. The commands in "Verification" are the ones that turn this from a claim
into a fact — run them on the target before trusting any of it.

---

## What's in the stack

| Service | Image | Pinned | Port (contract §5) |
|---|---|---|---|
| Jellyfin | `jellyfin/jellyfin` | `10.11.11` | 8096, host networking |
| Prowlarr | `lscr.io/linuxserver/prowlarr` | `2.5.2` | 9696 |
| Sonarr | `lscr.io/linuxserver/sonarr` | `4.0.19` | 8989 |
| Radarr | `lscr.io/linuxserver/radarr` | `6.3.0` | 7878 |
| Bazarr | `lscr.io/linuxserver/bazarr` | `1.6.0` | 6767 |
| Jellyseerr | `ghcr.io/fallenbagel/jellyseerr` | `2.7.3` | 5055 |
| SABnzbd | `lscr.io/linuxserver/sabnzbd` | `5.0.4` | 8081 → 8080 in-container |
| qBittorrent | `lscr.io/linuxserver/qbittorrent` | `5.2.3` | via gluetun |
| gluetun | `qmcgaw/gluetun` | `v3.41.3` | publishes 8080 for qBittorrent |

### Why these tags

Each is the current **stable** release of its project as of 2026-08-03, resolved
by asking each registry what `latest` actually pointed at rather than by reading
the tag list — several of these projects push nightly/develop/unstable tags that
sort to the top of a "most recently updated" listing and are not what you want:

- **Jellyfin `10.11.11`**, not `12.0-rc4`. There is a v12 release candidate out;
  it is a release candidate. `latest` = `10.11.11`.
- **Prowlarr `2.5.2`**, not `2.6.2` — 2.6.2 is the nightly branch.
- **Sonarr `4.0.19`** — the same version number also appears as
  `4.0.19-develop` with a different build; the bare tag is the stable one.
- **Bazarr `1.6.0`**, not `1.6.1` — 1.6.1 is `-beta`.
- **SABnzbd `5.0.4`**, not `5.1.0` — 5.1.0 is `RC2`.
- **Radarr `6.3.0`**, **qBittorrent `5.2.3`**, **gluetun `v3.41.3`**,
  **Jellyseerr `2.7.3`** are each straightforwardly current stable.

Update deliberately — bump a tag, `docker compose up -d <service>`, watch it.
Never all nine at once.

### Identity, and the two exceptions

Contract §1 puts every container at `1500:1500` with supplementary group `303`.
Three different mechanisms deliver that, because three different image families
are involved:

- **LinuxServer.io images** (Prowlarr, Sonarr, Radarr, Bazarr, SABnzbd,
  qBittorrent) read `PUID`/`PGID`/`UMASK` and drop privileges in their own s6
  init. Do **not** add `user:` to these — it breaks that init.
- **Jellyfin** ignores PUID/PGID entirely. Identity comes from `user:` plus
  `group_add: ["303"]`, which is also what gives it `/dev/dri`.
- **Jellyseerr** runs as `node:node` in its own Dockerfile and has no PUID/PGID
  support, so it also uses `user:`.

`UMASK: 002` only exists on the LinuxServer images. Jellyfin and Jellyseerr do
not honour it; neither writes into shared media paths, so it does not matter.

---

## Things you must do by hand

### 1. Pre-create the per-app config directories — do this FIRST

Docker will happily create a missing bind-mount source, and it creates it
**owned by root**. Every one of these containers then fails to write its
database, in a way whose logs point at the application rather than at ownership.
Create them before the first `up`:

```bash
sudo install -d -o media -g media -m 0775 \
  /opt/palimpsest-stack/{prowlarr,sonarr,radarr,bazarr,jellyseerr,sabnzbd,qbittorrent} \
  /opt/palimpsest-stack/jellyfin/{config,cache}
```

(Contract §2 has NixOS tmpfiles create `/opt/palimpsest-stack` itself as
`media:media 0775`; the per-app subdirectories are this layer's business.)

### 2. Fill in `.env`

```bash
cd /opt/palimpsest-stack
cp .env.example .env && chmod 600 .env && $EDITOR .env
```

Two things need real values:

- **`BIND_ADDR`** — set to this machine's tailnet address (`tailscale ip -4`).
  Read the long comment in `.env.example` before changing it; the default of
  `127.0.0.1` fails closed and is safe for bring-up over an SSH tunnel.
- **The VPN block** — provider name plus WireGuard key/address, from your
  provider's config download. `VPN_SERVICE_PROVIDER` is a fixed vocabulary
  gluetun recognises, not free text.

`.env` is gitignored (contract §6) and must stay that way.

### 3. Secrets you supply by hand, outside `.env`

Per contract §6, none of these ever land in a committed file. Most are entered
in a web UI after the service is up:

| Secret | Where it goes |
|---|---|
| Tailscale auth key | Host, not this stack — `tailscale up`, done by hand |
| VPN WireGuard key | `.env`, gluetun |
| Usenet provider (server, user, pass) | SABnzbd UI → Config → Servers |
| Indexer credentials / API keys | Prowlarr UI → Indexers |
| Prowlarr → Sonarr/Radarr app keys | Generated; Prowlarr UI → Settings → Apps |
| Sonarr/Radarr → download client | Their own UIs; qBittorrent password is set on first login |
| Jellyfin admin account | Jellyfin's first-run wizard |
| Jellyseerr → Jellyfin/Sonarr/Radarr | Jellyseerr's setup wizard, using the others' API keys |

---

## Bring-up — incrementally, in this order

Do not `up -d` the whole file. One service, confirm, next.

```bash
cd /opt/palimpsest-stack

# 1. Jellyfin alone. Confirm it serves before anything else exists.
docker compose up -d jellyfin
docker compose logs -f jellyfin          # ^C once it says it's listening
curl -sI http://127.0.0.1:8096/health    # expect 200
```

Then the automation layer, then the download clients:

```bash
# 2. Automation
docker compose up -d prowlarr sonarr radarr bazarr jellyseerr
docker compose ps

# 3. Usenet
docker compose up -d sabnzbd

# 4. Torrents — gluetun must go healthy before qbittorrent will start at all
docker compose up -d gluetun
docker compose logs -f gluetun           # look for the tunnel coming up
docker compose up -d qbittorrent
```

Verify the tunnel is actually carrying qBittorrent's traffic — this is the
whole point of gluetun, and it is worth one command:

```bash
docker compose exec gluetun sh -c 'wget -qO- https://ipinfo.io/ip'
# Must NOT be your home WAN address. Compare:
curl -s https://ipinfo.io/ip
```

## Application configuration, in order

**Prowlarr first**, then Sonarr/Radarr, then Jellyfin, then Jellyseerr last.
Each step depends on the previous one existing.

1. **Prowlarr** (`:9696`) — add indexers. Then Settings → Apps → add Sonarr
   (`http://sonarr:8989`) and Radarr (`http://radarr:7878`); Prowlarr pushes
   indexers into both from then on. Use container names, not `localhost`.
2. **Sonarr** (`:8989`) **and Radarr** (`:7878`):
   - Root folders: `/data/media/tv` and `/data/media/movies` respectively.
   - Download clients: SABnzbd at `http://sabnzbd:8080`, qBittorrent at
     `http://gluetun:8080` (**not** `http://qbittorrent:8080` — qBittorrent has
     no network identity of its own; it lives in gluetun's namespace).
   - **Delay profiles** — Settings → Profiles → Delay Profiles:
     preferred protocol **Usenet**, usenet delay **0**, torrent delay **45**
     minutes. Usenet gets first crack; torrents cover what retention missed.
   - Confirm "Use Hardlinks instead of Copy" is on (Settings → Media Management,
     shown with Advanced toggled). It is the default; confirm anyway.
3. **Jellyfin** (`:8096`) — libraries at `/data/media/movies` and
   `/data/media/tv`. Transcoding settings below.
4. **Jellyseerr** (`:5055`) — connects to everything. Jellyfin's URL here is
   **`http://host.docker.internal:8096`**, not `http://jellyfin:8096`: Jellyfin
   is on host networking and has no address on the bridge network. Sonarr and
   Radarr use their normal container names.

## Jellyfin transcoding

Dashboard → Playback → Transcoding:

- Hardware acceleration: **Video Acceleration API (VAAPI)**
- VA-API device: `/dev/dri/renderD128` (contract §4)
- Enable hardware decoding for **H264, HEVC, VP9, AV1**
- Enable **Intel Low-Power H.264/HEVC encoder** — materially lower power on
  Alder Lake
- Enable **hardware tone mapping** (VPP)
- Transcode path: `/transcode`

Then prove it, because this setting lies when it fails:

```bash
# Terminal 1 — on the host
sudo intel_gpu_top

# Terminal 2 — force a transcode from a client (pick a quality below source),
# then watch terminal 1.
```

You want activity on the **Video** and **VideoEnhance** engines. If those stay
at zero and the CPU cores light up instead, VAAPI silently fell back to software
and the checkbox is telling you a comfortable lie. First things to check in that
case: `docker compose exec jellyfin ls -l /dev/dri` (the container must see
`renderD128`), and `id` inside the container (group 303 must be present).

---

## Verification

### Contract §7 — run on palimpsest before anything else

```bash
id media                                                 # uid=1500 gid=1500
getent group render                                      # gid 303
stat -c '%u %g %a' /data /opt/palimpsest-stack           # 1500 1500 775
findmnt -no SOURCE /data /data/media                     # same source
vainfo | grep -c VAProfile                               # non-zero
docker compose -f /opt/palimpsest-stack/compose.yaml config   # parses
touch /data/torrents/x && ln /data/torrents/x /data/media/x && echo HARDLINK OK
rm -f /data/torrents/x /data/media/x
```

### The hardlink check, from inside a container

The host-side check above is necessary but **not sufficient**. What matters is
whether hardlinking works across the path mapping the *containers* see, because
that is where imports actually happen. A volume layout that breaks it looks
completely fine from the host:

```bash
docker compose exec sonarr sh -c '
  touch /data/torrents/tv/.hltest &&
  ln /data/torrents/tv/.hltest /data/media/tv/.hltest &&
  echo HARDLINK OK IN CONTAINER;
  stat -c "links=%h inode=%i" /data/torrents/tv/.hltest /data/media/tv/.hltest;
  rm -f /data/torrents/tv/.hltest /data/media/tv/.hltest'
```

Both paths must report the **same inode** and `links=2`. Repeat for `radarr`
and `qbittorrent` — each one has its own volume list and each can be wrong
independently.

If this fails, stop and fix it before importing anything. A broken hardlink path
does not error; it silently turns every import into a full copy, doubles disk
usage, and breaks seeding. You find out months later.

### Ownership after first import

```bash
stat -c '%U %G %a %n' /data/media/tv/* | head
```

Should be `media media 775`. If new files land as `root root` or `0644`, the
`PUID`/`PGID`/`UMASK` on that service did not take.

---

## When something breaks — first thing to check

| Symptom | Look here first |
|---|---|
| **Any container restart-looping** | `docker compose logs --tail=50 <svc>`. Most often the `/config` directory is root-owned — see "Pre-create" above. |
| **Jellyfin: no hardware transcode** | `docker compose exec jellyfin ls -l /dev/dri`, then `id` inside it — group 303 must be present. Then `vainfo` on the host. |
| **Jellyfin unreachable but running** | It is on host networking; there is no port mapping to be wrong. Check the NixOS firewall, not this stack. |
| **Admin UI unreachable over tailnet** | `BIND_ADDR` in `.env`. If it is `127.0.0.1` (the default), that is working as designed — set it to the tailnet IP and `docker compose up -d`. |
| **`docker compose up` fails: "cannot assign requested address"** | `BIND_ADDR` names an address that does not exist yet — tailscaled has not come up. See "Ordering" below. |
| **qBittorrent unreachable** | Check gluetun first: `docker compose ps gluetun` (must be `healthy`), then its logs. qBittorrent cannot start until gluetun is healthy, by design. |
| **qBittorrent reachable but downloads nothing** | Tunnel is up but the killswitch is eating traffic. Check `FIREWALL_OUTBOUND_SUBNETS` matches `DOCKER_SUBNET`. |
| **Sonarr/Radarr can't reach qBittorrent** | The host is `gluetun`, not `qbittorrent`. |
| **Jellyseerr can't reach Jellyfin** | The host is `host.docker.internal`, not `jellyfin`. |
| **Imports are slow / disk filling fast** | Hardlinking is broken. Run the in-container check above. This is the expensive failure. |
| **New files owned by root** | `PUID`/`PGID` did not apply — check you did not add `user:` to a LinuxServer image. |

---

## Two things for the palimpsest-system session

These are outside this repo's boundary (contract §0). I did not touch them.

1. **Ordering, if `BIND_ADDR` is a tailnet address.** Docker cannot bind an
   address that does not exist yet. The stack's systemd unit currently has
   `After=docker.service` and `RequiresMountsFor=/data /opt/palimpsest-stack`
   (contract §3); it likely also needs `After=tailscaled.service`. Worth
   confirming before enabling the unit at boot. Per-container
   `restart: unless-stopped` would eventually recover from this, but noisily.

2. **The `/data/transcode` tmpfs ownership.** Contract §2 says everything under
   `/data` is `media:media` (1500:1500). Note that the fstab example in
   `x17r2-jellyfin-build.md` §3 specifies `uid=1000,gid=1000` — that is the
   pre-contract draft and would give the tmpfs to `frank`, not `media`.
   Jellyfin runs as 1500 and would fail to write transcode segments. The mount
   options should be `uid=1500,gid=1500,mode=0775`. Please confirm which one
   the NixOS config actually has.

## Backups

Media is re-acquirable; the `/opt/palimpsest-stack/*/` directories are not —
they hold watch history, users, quality profiles and indexer configuration.
Back those up (restic was the plan) plus `.env`. Do it with the stack stopped,
or accept that SQLite databases are being copied live.
