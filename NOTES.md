# palimpsest-stack — operator notes

Built against `contract.md` **v2 (2026-08-04)**. This file covers what is
configured, what you have to do by hand, how to verify it, and where to look
first when a service breaks.

**Status: authored, not yet deployed.** Everything below was written and
syntax-verified on a workstation. Nothing in it has been run against palimpsest
itself. Contract §7.2 is the outstanding half of the work: until those commands
have been run on the target and their output read, nothing here is more than a
plausible claim.

Target hardware, confirmed from the Dell factory build sheet (service tag
8GH5LR3): **i7-12700H** (Alder Lake-P, 14C/20T) with Intel UHD/Xe iGPU, RTX
3070 Ti dGPU, 32 GB DDR5, 2 TB KIOXIA NVMe. The iGPU is what QuickSync runs on;
Alder Lake-P does AV1 **decode only**, no AV1 encode, which is why the transcode
settings below enable AV1 decoding but nothing expects AV1 output.

---

## What's in the stack

| Service | Image | Pinned | Port | Reachable from (§5.1) |
|---|---|---|---|---|
| Jellyfin | `jellyfin/jellyfin` | `10.11.11` | 8096/tcp, host networking | LAN + tailnet |
| | | | 1900/udp, 7359/udp discovery | LAN only |
| Jellyseerr | `ghcr.io/fallenbagel/jellyseerr` | `2.7.3` | 5055 | **LAN + tailnet** |
| Prowlarr | `lscr.io/linuxserver/prowlarr` | `2.5.2` | 9696 | tailnet only |
| Sonarr | `lscr.io/linuxserver/sonarr` | `4.0.19` | 8989 | tailnet only |
| Radarr | `lscr.io/linuxserver/radarr` | `6.3.0` | 7878 | tailnet only |
| Bazarr | `lscr.io/linuxserver/bazarr` | `1.6.0` | 6767 | tailnet only |
| SABnzbd | `lscr.io/linuxserver/sabnzbd` | `5.0.4` | 8081 → 8080 in-container | tailnet only |
| qBittorrent | `lscr.io/linuxserver/qbittorrent` | `5.2.3` | via gluetun | tailnet only |
| gluetun | `qmcgaw/gluetun` | `v3.41.3` | publishes 8080 for qBittorrent | tailnet only |

Everything in the "tailnet only" rows binds `BIND_ADDR_TAILNET`. Jellyseerr
alone binds `BIND_ADDR_LAN`. Jellyfin is host-networked and is not published by
Docker at all, so the host firewall is its only protection. See contract §5.2
and the long comment in `.env.example` — the two bind variables are not
interchangeable and collapsing them back into one breaks the policy silently.

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

- **`BIND_ADDR_TAILNET`** — set to this machine's tailnet address
  (`tailscale ip -4`). The default of `127.0.0.1` fails closed and is safe for
  bring-up over an SSH tunnel. Leave **`BIND_ADDR_LAN`** at `0.0.0.0`; that is
  correct, not an oversight. Read the comment in `.env.example` before touching
  either.
- **The VPN block** — provider name plus WireGuard key/address, from your
  provider's config download. `VPN_SERVICE_PROVIDER` is a fixed vocabulary
  gluetun recognises, not free text.

`.env` is gitignored (contract §6) and must stay that way.

### 3. Pull all nine images before starting anything

The tags were resolved from registry state at authoring time and nobody has
re-checked them since. Pull first, as a discrete step — a wrong or withdrawn
tag is cheap to fix on its own and confusing to hit halfway through a bring-up
sequence:

```bash
docker compose pull
```

All nine must succeed. If one fails, fix that tag before going further; do not
start the services that did pull and come back to it.

### 4. Secrets you supply by hand, outside `.env`

Per contract §6, none of these ever land in a committed file. Most are entered
in a web UI after the service is up:

| Secret | Where it goes |
|---|---|
| Tailscale auth key | Host, not this stack — `tailscale up`, done by hand |
| VPN WireGuard key | `.env`, gluetun |
| Usenet provider (server, user, pass) | SABnzbd UI → Config → Servers |
| Indexer credentials / API keys | Prowlarr UI → Indexers |
| Prowlarr → Sonarr/Radarr app keys | Generated; Prowlarr UI → Settings → Apps |
| Sonarr/Radarr → download client | Their own UIs. qBittorrent's password is **generated at first start and printed to its log**, not chosen by you — see below |
| Jellyfin admin account | Jellyfin's first-run wizard |
| Jellyseerr → Jellyfin/Sonarr/Radarr | Jellyseerr's setup wizard, using the others' API keys |

---

## Bring-up — incrementally, in this order

Do not `up -d` the whole file. One service, confirm, next. `docker compose pull`
(step 3 above) must have succeeded for all nine first.

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
whole point of gluetun, and it is contract §7.2's VPN egress check:

```bash
docker compose exec gluetun sh -c 'wget -qO- https://ipinfo.io/ip'
# Must NOT be your home WAN address. Compare:
curl -s https://ipinfo.io/ip
```

### Getting into qBittorrent the first time — two 5.x gotchas

**The password is generated, not chosen.** qBittorrent 5.x no longer ships the
old `admin`/`adminadmin` default. It prints a temporary password to the log on
first start:

```bash
docker compose logs qbittorrent | grep -i password
```

Log in as `admin` with that, then set a permanent password immediately in
Options → Web UI. The temporary one is regenerated on every restart until you
do, which makes "it worked yesterday" a confusing morning.

**"Unauthorized" even with the right credentials.** qBittorrent 5.x validates
the HTTP `Host` header and rejects anything it does not recognise, so reaching
the WebUI at `http://100.x.y.z:8080` fails with `Unauthorized` before your
credentials are even considered — the failure looks like a bad password and is
not one. Fix it once you are in, via an SSH tunnel to `127.0.0.1:8080` if
needed. Options → Web UI, either:

- add the tailnet address (and any hostname you use) to **"Server domains"**, or
- untick **"Validate HTTP Host header"**.

Prefer the first: it keeps the DNS-rebinding protection the check exists to
provide. The equivalent keys in `qBittorrent.conf` are
`WebUI\ServerDomains` and `WebUI\HostHeaderValidation`.

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

### Contract §7.1 — system layer, before the stack exists

Owned by palimpsest-system, which implements it as `scripts/verify-contract`.
Run it and read the output before doing anything in this repo; if any of it
fails, the stack is being built on sand.

```bash
id media                                                 # uid=1500 gid=1500
getent group render                                      # gid 303
stat -c '%u %g %a' /data /opt/palimpsest-stack           # 1500 1500 775
findmnt -no SOURCE /data /data/media                     # same source
mountpoint -q /data/transcode                            # tmpfs actually mounted
stat -c '%g' /dev/dri/renderD128                         # 303
vainfo | grep -c VAProfile                               # non-zero
touch /data/torrents/x && ln /data/torrents/x /data/media/x && echo HARDLINK OK
rm -f /data/torrents/x /data/media/x
```

### Contract §7.2 — stack layer, after bring-up

**This is the outstanding half of the job.** Four checks, and all four have to
be run on palimpsest with their output read:

```bash
docker compose -f /opt/palimpsest-stack/compose.yaml config   # parses
```

That one has been run (on a workstation, exit 0). The other three have not.

#### 1. Hardlinking, from inside a container

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

#### 2. Exposure scan — this is what proves §5.2 works

Run **from a LAN host that is not on the tailnet**. Running it from palimpsest
itself, or from a tailnet peer, proves nothing — the whole point is to see what
an ordinary machine on the home network can reach.

```bash
nmap -Pn -p 22,5055,6767,7878,8080,8081,8096,8989,9696 <palimpsest-lan-ip>
```

Exactly three may answer: **22, 5055, 8096**. Everything else must be filtered
or closed.

If an admin UI responds, the bind address is wrong — check `BIND_ADDR_TAILNET`
in `.env` before looking at anything else. A firewall rule that appears correct
is not evidence here: Docker's DNAT means the rule is never consulted
(contract §5.2). Confirm what is actually bound:

```bash
ss -ltnp | grep -E ':(5055|6767|7878|8080|8081|8989|9696)'
```

Admin UIs should show the tailnet address, not `0.0.0.0`. Jellyseerr on 5055 is
the one legitimate `0.0.0.0`.

#### 3. VPN egress

```bash
docker compose exec gluetun sh -c 'wget -qO- https://ipinfo.io/ip'
curl -s https://ipinfo.io/ip     # must differ
```

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
| **Admin UI unreachable over tailnet** | `BIND_ADDR_TAILNET` in `.env`. If it is `127.0.0.1` (the default), that is working as designed — set it to the tailnet IP and `docker compose up -d`. |
| **Admin UI reachable from the LAN** | Same variable, opposite failure, and the serious one. `ss -ltnp` to see what is actually bound. Do not look at the firewall — Docker's DNAT means it is never consulted (§5.2). |
| **Jellyseerr unreachable from the LAN** | `BIND_ADDR_LAN` should be `0.0.0.0`. If it is, the problem is the host firewall, which is palimpsest-system's. |
| **`docker compose up` fails: "cannot assign requested address"** | `BIND_ADDR_TAILNET` names an address that does not exist yet — tailscaled has not come up. Contract §3 makes this a start precondition on the unit. |
| **Jellyfin clients don't auto-discover** | UDP 1900/7359 inbound, LAN only. Opened in palimpsest-system, not here. TCP 8096 working tells you nothing about this. |
| **qBittorrent unreachable** | Check gluetun first: `docker compose ps gluetun` (must be `healthy`), then its logs. qBittorrent cannot start until gluetun is healthy, by design. |
| **qBittorrent says "Unauthorized" with correct credentials** | Host-header validation, not authentication. Add the tailnet address to Server domains, or untick "Validate HTTP Host header". See the bring-up section. |
| **qBittorrent password rejected after a restart** | The generated temporary password is regenerated every start until you set a permanent one. `docker compose logs qbittorrent \| grep -i password`. |
| **qBittorrent reachable but downloads nothing** | Tunnel is up but the killswitch is eating traffic. Check `FIREWALL_OUTBOUND_SUBNETS` matches `DOCKER_SUBNET`. |
| **Sonarr/Radarr can't reach qBittorrent** | The host is `gluetun`, not `qbittorrent`. |
| **Jellyseerr can't reach Jellyfin** | The host is `host.docker.internal`, not `jellyfin`. |
| **Imports are slow / disk filling fast** | Hardlinking is broken. Run the in-container check above. This is the expensive failure. |
| **New files owned by root** | `PUID`/`PGID` did not apply — check you did not add `user:` to a LinuxServer image. |

---

## What this layer depends on palimpsest-system for

Outside this repo's boundary (contract §0). Both items this repo raised against
v1 were resolved in contract v2 and are now the system layer's obligations, not
open questions:

1. **The stack unit waits for `tailscale0` to have an address** — contract §3,
   a bounded `ExecStartPre` poll that fails on timeout, not merely
   `After=tailscaled.service`. Required because `BIND_ADDR_TAILNET` names an
   address that does not exist at early boot.
2. **`/data/transcode` is in `RequiresMountsFor`** — contract §3. Without it a
   failed tmpfs mount leaves the underlying directory in place with correct
   ownership, and Jellyfin transcodes to the NVMe instead of RAM, silently.
   (The conflicting `uid=1000` fstab example that prompted this lived in
   `x17r2-jellyfin-build.md`, which contract v2 §0 deletes from both repos.)

Still the system layer's, and not verifiable from here:

- Firewall source rules for 5055 and 8096 (RFC1918 only) and the UDP discovery
  ports 1900/7359. §5.2's bind-address split is the first layer; these are the
  second, and they are Jellyfin's *only* layer.
- `/dev/dri/renderD128` group-owned by 303, and the iHD driver installed.

## Backups

Media is re-acquirable; the `/opt/palimpsest-stack/*/` directories are not —
they hold watch history, users, quality profiles and indexer configuration.
Back those up (restic was the plan) plus `.env`. Do it with the stack stopped,
or accept that SQLite databases are being copied live.
