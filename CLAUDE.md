# CLAUDE.md — palimpsest-stack

Guidance for future sessions working in this repo. Read `contract.md` first
(currently **v4, 2026-08-04** — check §8's changelog); this file assumes it.

## What this repo is

The **application layer** of palimpsest, a headless home media server. It owns
`compose.yaml`, `.env.example`, and per-app configuration. It is checked out at
`/opt/palimpsest-stack` on the target machine.

The **system layer** lives in a separate repo, `palimpsest-system`, checked out
at `/opt/palimpsest-system`. It owns boot, drivers, users, filesystems,
networking, firewall, and the systemd unit that runs this stack.

## The boundary is hard

**A session working in this repo does not edit `palimpsest-system`, and does not
edit anything under `/etc/nixos`.** If the stack needs a firewall port opened, a
UID changed, a mount option fixed, or a systemd ordering dependency added: stop
and say so. Do not reach across.

This matters because these sessions run with permissions skipped. A boundary an
agent cannot cross is worth more than the convenience of crossing it.

Open cross-boundary items are collected at the end of `NOTES.md`.

## `contract.md` is not yours to change

The copy of `contract.md` in this repo is **authoring reference only**. The
authoritative copy lives in `palimpsest-system`. Every value in it — UIDs,
GIDs, paths, ports, the render GID — is fixed. If a value looks wrong, stop and
say so; do not work around it, and do not edit the copy.

At runtime, read the live system rather than this copy: `id media`,
`getent group render`, `findmnt /data`. Copies drift; the running system cannot.

## Contract values this repo consumes

| Value | Where it appears here |
|---|---|
| `media` = 1500:1500 | `PUID`/`PGID` on LinuxServer images; `user:` on Jellyfin and Jellyseerr |
| `render` = GID 303 | `group_add` on Jellyfin |
| umask 002 | `UMASK` on LinuxServer images |
| `/data` mounted as `/data` | every service that touches media |
| `/data/transcode` → `/transcode` | Jellyfin |
| `/dev/dri` | Jellyfin only |
| Ports 8096/5055/6767/7878/8080/8081/8989/9696 | `ports:` and `network_mode: host` |
| §5.2 bind-address enforcement | `BIND_ADDR_LAN` in `.env`, all seven published ports |
| §5.3 Jellyfin never Docker-published | absence of a `ports:` block on `jellyfin` |

These are hardcoded in `compose.yaml` rather than pushed into `.env`
deliberately: they belong in the tracked file, where a change to one is visible
in a diff. `.env` is for secrets and site-specific values only.

## Deliberate, not incidental

Things that look like they could be simplified, and should not be:

- **Jellyfin is on host networking.** Required for DLNA and client
  auto-discovery. The consequence is that Jellyfin has no address on the bridge
  network — other containers reach it at `host.docker.internal:8096`, which is
  why Jellyseerr carries an `extra_hosts` entry.
- **`/data` is mounted at the identical path inside and out**, with no
  `/movies` or `/downloads` aliases. This is what makes hardlinking work across
  the torrent → media import. It is the single most consequential decision in
  the file, and it fails silently when broken.
- **The bridge subnet is pinned.** gluetun's `FIREWALL_OUTBOUND_SUBNETS` has to
  name it explicitly, so it cannot be left to Docker's allocator. One `.env`
  value feeds both.
- **qBittorrent has no `ports:` and no `networks:`.** It lives in gluetun's
  network namespace. Its WebUI is published on gluetun. Sonarr and Radarr reach
  it at `http://gluetun:8080`.
- **`depends_on: service_healthy` on gluetun.** Keeps the torrent client from
  ever seeing a bare WAN route during startup.
- **No published port binds `0.0.0.0`** (contract §5.2). Docker publishes by
  DNAT in `PREROUTING`; the destination is rewritten before the packet reaches
  `INPUT`, where the host firewall lives. A firewall rule naming a
  Docker-published port is never consulted — it passes review and constrains
  nothing. For published ports the bind address is the only enforcement, so all
  seven bind `BIND_ADDR_LAN` explicitly. Jellyfin is host-networked, so §5.2
  does not apply to it and cannot protect it; the firewall is its only layer,
  and that rule is real.
- **`${BIND_ADDR_LAN:?...}` is load-bearing, not decoration.** Do not replace it
  with a default and do not simplify it to a bare `${BIND_ADDR_LAN}`. Verified:
  bare-and-unset does **not** fail — compose warns, exits 0, and renders the
  mapping with no host address at all, which binds every interface. That is the
  v2 defect, reached silently. `:?` is the only construct that aborts.
- **No VPN, and Jellyfin is never Docker-published** (contract §5.1, §5.3). v4
  removed Tailscale because the family member this server exists for watches on
  a Roku, which has no VPN client. Remote access will be 443/tcp to a host-side
  TLS proxy in `palimpsest-system`. This repo's whole §5.3 obligation is the
  negative one: no `ports:` block on `jellyfin`, ever. 8096 is plaintext, has
  no rate limiting and no MFA, and publishing it would bypass the host firewall
  and sit one router forward from the internet in the clear.
- **The torrent path is behind a compose profile, not deleted.** gluetun and
  qbittorrent carry `profiles: ["torrents"]`; this deployment is usenet-only, so
  7 services run and 6 ports listen. It is a profile rather than a second
  compose file specifically because `COMPOSE_PROFILES` in `.env` activates it —
  meaning enabling torrents never requires touching the systemd unit in
  `palimpsest-system`. Verified. Re-pin both image tags before enabling; they
  rot while unexercised.
- **The compose file is a plain file, not in the Nix store** (contract §3). It
  is the thing that changes most often; requiring a `nixos-rebuild` per tweak
  would make iteration miserable.
- **Three different mechanisms deliver the same UID.** Not an inconsistency —
  LinuxServer images, Jellyfin, and Jellyseerr each handle identity
  differently. See NOTES.md. Do not "normalise" these; adding `user:` to a
  LinuxServer image breaks its s6 init.

## Known-fragile areas

- **Hardlinking.** Breaks silently. Never verify it only from the host — run
  the in-container check in `NOTES.md`. Every service with a `/data` mount can
  be wrong independently.
- **Per-app config directory ownership.** Docker creates missing bind-mount
  sources as root. The resulting failures point at the application, not at
  ownership. Pre-create them as `media:media`.
- **VAAPI silently falling back to software.** The Jellyfin setting reports
  success either way. Only `intel_gpu_top` tells the truth.
- **SABnzbd's port mapping is asymmetric** (8081 on the host → 8080 inside,
  per contract §5). Changing the port inside SABnzbd's own settings breaks it.
- **`BIND_ADDR_LAN` and boot ordering.** Docker cannot bind an address the host
  does not have yet; at boot, DHCP may not have returned a lease. Contract §3
  makes waiting for a *global-scope* IPv4 a start precondition on the systemd
  unit, in palimpsest-system — global scope specifically, because link-local is
  what a failed DHCP leaves behind.
- **qBittorrent 5.x host-header validation.** Rejects unrecognised `Host`
  headers with `Unauthorized`, which reads as a wrong password and is not one.
  Its first-start password is also generated into the log, not a fixed default.

## Working practice

- **Pin every image tag.** No `:latest`, and no project's nightly/develop/
  unstable branch — several of these push those tags such that they sort to the
  top of a "recently updated" listing. Resolve what `latest` actually points at
  before pinning. Update one service at a time.
- **Verify, don't assert.** Writing a value into a file is not evidence. After
  a change: `docker compose ps`, the service's logs, an HTTP request to it.
- **No secrets in any tracked file** (contract §6). `.env` is gitignored;
  per-app config directories are gitignored because they accumulate generated
  API keys and tokens.
- **Bring services up incrementally.** A stack that comes up broken all at once
  is far harder to diagnose than one service that fails alone.
