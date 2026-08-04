# palimpsest — Interface Contract

**Version 3 — 2026-08-04.** Supersedes v2 entirely. See §8 for what changed and why.

**This is the source of truth.** Both the NixOS configuration and the container stack are built against it. Neither agent may change a value here; if an agent believes a value is wrong, it stops and tells me. Amendments are made by me, in this file, and handed to both sessions — that is how v2 came to exist.

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
- **No pre-contract design docs.** `x17r2-jellyfin-build.md` predates this contract and contradicts it — UID 1000, `/opt/stack`, wrong tmpfs ownership. Delete it from both repos. Anything worth keeping from it already lives in each repo's `NOTES.md`.

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

Containers run as `1500:1500` with supplementary group `303`. Every container in the stack uses the same values — no per-service variation. The *mechanism* varies by image family (LinuxServer images take `PUID`/`PGID`; Jellyfin and Jellyseerr take `user:`), but the identity does not.

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
| Unit ordering | `After=docker.service tailscaled.service` |
| Unit mount deps | `RequiresMountsFor=/data /data/transcode /opt/palimpsest-stack` |
| Unit start precondition | `tailscale0` must have an IPv4 address before the unit starts — see below |
| Unit type | `oneshot` with `RemainAfterExit=yes` |
| Unit restart policy, while shipped disabled | **None.** Per-container `restart: unless-stopped` handles recovery. |
| Unit restart policy, once enabled at boot | `Restart=on-failure`, `RestartSec=30`, `StartLimitIntervalSec=600`, `StartLimitBurst=5` |
| Enabled at boot | **No, initially.** Ships disabled; I enable it once the stack works. |

The compose file stays outside the Nix store deliberately: it is the thing that changes most often, and requiring a `nixos-rebuild` per tweak would make the iteration loop miserable. It lives in its own git repo.

**`/data/transcode` is in `RequiresMountsFor` for a specific reason.** If the tmpfs fails to mount, the directory beneath it still exists with correct ownership, so Jellyfin would silently transcode to the NVMe instead of RAM. That is exactly the write-wear this design exists to prevent, and nothing else catches it.

**The restart policy changes when the unit is enabled at boot, and this is not a contradiction.** The "no restart" rule exists so that systemd does not fight Docker over *already-running* containers — that is what per-container `restart: unless-stopped` is for. It says nothing about a unit that failed to start at all, which is a different failure with no other recovery path: a slow tailnet at boot would otherwise leave the stack down until someone noticed. `Restart=on-failure` with a 30s gap covers that, and `StartLimitBurst=5` over ten minutes means a genuinely broken stack gives up and stays failed instead of looping. While `enableAtBoot` is `false`, no restart policy is set at all — a hand-started unit should fail in front of you.

**Waiting for `tailscale0` is a start precondition, not just ordering.** The stack publishes admin UIs on the tailnet address (§5), and Docker cannot bind an address that does not yet exist. `After=tailscaled.service` is necessary but insufficient — the daemon reaching active does not mean the interface has an address. The unit needs a bounded `ExecStartPre` poll (60s is ample) that **fails** on timeout. Failing loudly produces one clear journal line; succeeding anyway produces a half-started stack and a confusing morning.

## 4. Hardware passthrough

| Thing | Value |
|---|---|
| Transcode device | `/dev/dri` — passed to the Jellyfin container only |
| VAAPI device node | `/dev/dri/renderD128`, group-owned by `render` (303) |
| Driver | Intel iHD (`intel-media-driver`); **not** legacy i965 |
| Transcode temp path | `/data/transcode`, mounted into Jellyfin as `/transcode` |
| NVIDIA | Not installed, not configured. dGPU stays in D3cold. |

## 5. Network exposure

### 5.1 Policy

The **Enforced by** column is not commentary. It is the difference between a rule that constrains traffic and a rule that is never consulted — see §5.2.

| Port | Service | Reachable from | Enforced by |
|---|---|---|---|
| 22/tcp | SSH | LAN + tailscale0 | Host firewall (sshd binds on the host) |
| 8096/tcp | Jellyfin | LAN + tailscale0 | Host firewall (host networking) |
| 1900/udp, 7359/udp | Jellyfin client auto-discovery | LAN only | Host firewall (host networking) |
| 5055/tcp | Jellyseerr | LAN + tailscale0 | **Bind address** (Docker-published) |
| 6767/tcp | Bazarr | tailscale0 only | **Bind address** (Docker-published) |
| 7878/tcp | Radarr | tailscale0 only | **Bind address** (Docker-published) |
| 8080/tcp | qBittorrent WebUI (published by gluetun) | tailscale0 only | **Bind address** (Docker-published) |
| 8081/tcp | SABnzbd | tailscale0 only | **Bind address** (Docker-published) |
| 8989/tcp | Sonarr | tailscale0 only | **Bind address** (Docker-published) |
| 9696/tcp | Prowlarr | tailscale0 only | **Bind address** (Docker-published) |
| 41641/udp | Tailscale transport (not an application port) | all interfaces | — (disclosed, not restricted) |

Firewall default-deny inbound. LAN means RFC1918 only. **Nothing is port-forwarded from the router, ever.**

**Jellyseerr is LAN-reachable on purpose.** It is the family-facing request UI; confining it to the tailnet would put it out of reach of the people it exists for.

**Discovery is UDP and does not run on 8096.** Host networking lets Jellyfin *send* discovery traffic; inbound probes from LAN clients still have to be allowed, or auto-discovery silently does not work and every client has to be pointed at an IP by hand.

**41641/udp is listed for disclosure, not because an application needs it.** It is Tailscale's own transport, opened by `services.tailscale.openFirewall`. Without it, peer traffic relays through DERP — slow for video. Nothing is forwarded at the router, so in practice it is only reachable from the LAN.

### 5.2 Docker bypasses the host firewall — bind addresses are the enforcement

**This is the rule that makes §5.1 real rather than decorative. Read it before writing a firewall rule or a port mapping.**

Docker publishes ports by DNAT in `PREROUTING`. The destination address is rewritten to the container before the packet reaches `INPUT`, so published-port traffic **never enters the chain where the host firewall lives**. A host-firewall rule naming a Docker-published port is not wrong — it is never consulted.

Two consequences, and the second one is the one that catches people:

1. For anything Docker publishes, **the bind address is the only enforcement.** A socket bound to the tailnet address is not listening on the LAN, firewall or no firewall.
2. **`0.0.0.0` is never an acceptable bind address in this stack** — not even for a service that is *supposed* to be LAN-reachable. Publishing on `0.0.0.0` and expecting a host-firewall source rule to narrow it is the exact mistake this section exists to prevent: the rule passes review, passes a grep of the ruleset, and constrains nothing.

Therefore **every published port binds an explicit address**, and a service reachable from two places is published twice:

| Class | Bind | Services |
|---|---|---|
| Tailnet-only | `${BIND_ADDR_TAILNET}:<port>:<port>` | 6767, 7878, 8080, 8081, 8989, 9696 |
| LAN + tailnet | two mappings: `${BIND_ADDR_LAN}` **and** `${BIND_ADDR_TAILNET}` | 5055 |
| Host-networked | not published by Docker; host firewall governs | 8096, 1900, 7359 |

`BIND_ADDR_TAILNET` **defaults to `127.0.0.1`** so an unconfigured stack fails closed, reachable only over an SSH tunnel. This is also why the stack unit must wait for `tailscale0` (§3).

`BIND_ADDR_LAN` **has no default.** It must be set to this machine's DHCP-reserved LAN address. If it is unset, Docker attempts two bindings on `127.0.0.1:5055` and refuses the duplicate — which is the correct failure: loud, immediate, at bring-up, rather than a service quietly listening somewhere nobody intended.

**Host-firewall rules exist only for host-networked services.** `INPUT` rules for 22, 8096, 1900 and 7359 are real and load-bearing. There is deliberately **no** `INPUT` rule for 5055 or any other Docker-published port: an inert rule that reads as protection is worse than no rule. If a service ever moves from Docker to host networking, it needs a firewall rule added at that time.

## 6. Secrets

No secret appears in either the Nix config or the compose file. Placeholders only, documented in each half's `NOTES.md`:

- Tailscale auth key — authenticated by hand, `tailscale up --ssh`
- WireGuard/VPN credentials for the download client — `.env`, gitignored
- Usenet provider and indexer credentials — entered in each app's web UI
- Any API keys the automation tools generate for each other — likewise

No password or key is baked into the Nix store, including placeholders: the store is world-readable.

## 7. Verification

The contract is satisfied when all of these pass on the real machine.

### 7.1 System layer — run before the stack exists

```bash
id media                                    # uid=1500 gid=1500
getent group render                         # gid 303
stat -c '%u %g %a' /data /opt/palimpsest-stack   # 1500 1500 775
findmnt -no SOURCE /data /data/media        # same source
mountpoint -q /data/transcode               # the tmpfs is actually mounted
stat -c '%g' /dev/dri/renderD128            # 303
vainfo | grep -c VAProfile                  # non-zero
touch /data/torrents/x && ln /data/torrents/x /data/media/x && echo HARDLINK OK
rm -f /data/torrents/x /data/media/x
```

`scripts/verify-contract` in `palimpsest-system` implements these.

### 7.2 Stack layer — run after bring-up

```bash
docker compose -f /opt/palimpsest-stack/compose.yaml config   # parses
```

**Hardlinking must be verified from inside a container, not just from the host.** The host check proves the filesystem allows it; only the in-container check proves the *volume mapping* preserves it, and that is where imports actually happen. Run it for `sonarr`, `radarr`, and `qbittorrent` — each has its own volume list and each can be wrong independently:

```bash
docker compose exec sonarr sh -c '
  touch /data/torrents/tv/.hltest &&
  ln /data/torrents/tv/.hltest /data/media/tv/.hltest &&
  stat -c "links=%h inode=%i" /data/torrents/tv/.hltest /data/media/tv/.hltest;
  rm -f /data/torrents/tv/.hltest /data/media/tv/.hltest'
```

Same inode, `links=2`. If this fails, stop — every import silently becomes a full copy, disk usage doubles, seeding breaks, and you find out months later.

**Bind addresses match §5.2.** On palimpsest — this is the check that would have caught the v2 defect:

```bash
ss -ltnp | awk '$4 !~ /^\[/ {print $4}' | sort -u
```

No listener on a Docker-published port may show `0.0.0.0:` or `*:`. 5055 must appear **twice**, once on the LAN address and once on the tailnet address. The six tailnet-only ports must appear only on the tailnet address.

**Exposure matches §5.1.** From a LAN host that is *not* on the tailnet:

```bash
nmap -Pn -p 22,5055,6767,7878,8080,8081,8096,8989,9696 <palimpsest-lan-ip>
```

Open: 22, 5055, 8096. Everything else filtered or closed. Note this scan passes whether or not §5.2 is implemented correctly — it is necessary, not sufficient. The `ss` check above is the one with teeth.

**The VPN tunnel actually carries torrent traffic:**

```bash
docker compose exec gluetun sh -c 'wget -qO- https://ipinfo.io/ip'
curl -s https://ipinfo.io/ip     # must differ
```

## 8. Changelog

### v3 — 2026-08-04

v2 introduced a defect and both sessions implemented it faithfully, which is worth recording as its own lesson: a wrong contract propagates *because* both halves trust it. Neither agent erred.

1. **§5.2 — Jellyseerr's stated enforcement was wrong.** v2's table claimed LAN-published services were bounded by host-firewall source rules. §5.2's own opening paragraph explains why that cannot be true: Docker DNATs in `PREROUTING`, so a published port never reaches `INPUT`. The `tcp dport { 22, 8096, 5055 }` rule was therefore inert for 5055, `BIND_ADDR_LAN=0.0.0.0` left Jellyseerr listening on every interface, and both the verifier's port assertion and §7's `nmap` passed while proving nothing. Real exposure was unchanged — no inbound path exists to this host — but a documented mechanism that does not exist is worse over a five-year life than a known gap.
2. **§5.2 — `0.0.0.0` is now forbidden outright,** and services reachable from two places are published twice on two explicit addresses. `BIND_ADDR_LAN` loses its default so that an unset value fails loudly at bring-up instead of binding somewhere unintended.
3. **§5.1 — added an "Enforced by" column.** The v2 defect was possible because the enforcement mechanism was described a section away from the policy table. Now it is in the row.
4. **§5.2 — no `INPUT` rule for any Docker-published port.** 5055 comes out of the RFC1918 rule, and the verifier's assertion on it goes too. A check that passes while proving nothing is worse than no check.
5. **§3 — restart policy specified for the enabled-at-boot case.** `Restart=on-failure` with a bounded burst, so a slow tailnet at boot self-heals rather than leaving the stack down until someone notices. This does not conflict with per-container recovery; it governs a unit that failed to start, not containers that failed while running.
6. **§7.2 — added an `ss` listener check.** v2's checks could all pass with the defect present. This one cannot.

### v2 — 2026-08-04

Every change below originates in a conflict one of the two agent sessions found and **flagged instead of working around**. That was the correct behaviour and is why these are fixable here rather than discoverable in six months.

1. **§5.1 — Jellyseerr moved to LAN + tailscale0.** v1 confined the family-facing request UI to the tailnet, putting it out of reach of the family. Design error.
2. **§5.1 — DLNA/Jellyfin discovery ports added (UDP 1900, 7359), LAN only.** v1 justified host networking for Jellyfin by citing auto-discovery, then opened only TCP 8096, so discovery could not work. Flagged by the system session.
3. **§5.1 — UDP 41641 documented.** Opened by `services.tailscale.openFirewall`; an undocumented open port on a default-deny box. Flagged by the system session.
4. **§5.2 — new section on Docker's firewall bypass and bind-address policy.** Docker's DNAT publishing skips the `INPUT` chain, so v1's port scoping was decorative for every published service. Found by the stack session, which fixed it in its own layer; now promoted to a contract-level rule because both halves must agree on it. Introduces `BIND_ADDR_TAILNET` (default `127.0.0.1`, fails closed) and `BIND_ADDR_LAN`.
5. **§3 — `After=tailscaled.service` plus a bounded start precondition.** Consequence of (4): the stack binds a tailnet address that does not exist at early boot. Handed over by the stack session.
6. **§3 — `/data/transcode` added to `RequiresMountsFor`.** Without it, a failed tmpfs mount silently redirects transcoding to the NVMe.
7. **§7 — split into system and stack halves; added the in-container hardlink check, the LAN exposure scan, and the VPN egress check.** v1's checks all ran on the host and could pass while the container path mapping was broken.
8. **§0 — pre-contract design docs are not to be committed.** `x17r2-jellyfin-build.md` contradicts this contract and both sessions correctly ignored it; it should not survive to mislead a later one.
