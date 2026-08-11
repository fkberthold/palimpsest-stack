# palimpsest-stack — operator notes

Built against `contract.md` **v4 (2026-08-04)**. This file covers what is
configured, what you have to do by hand, how to verify it, and where to look
first when a service breaks.

**Status: deployed and verified on palimpsest, 2026-08-05.** The stack is
running (seven services, usenet-only), the download → import → library pipeline
has been exercised end-to-end with real requests, and the contract §7.2 checks
below have been run on the target — see each check for its recorded result.
Two items remain the operator's to run from off-box (the LAN `nmap` exposure
scan, and `intel_gpu_top` during a live transcode); both are noted where they
appear.

Target hardware, confirmed from the Dell factory build sheet (service tag
8GH5LR3): **i7-12700H** (Alder Lake-P, 14C/20T) with Intel UHD/Xe iGPU, RTX
3070 Ti dGPU, 32 GB DDR5, 2 TB KIOXIA NVMe. The iGPU is what QuickSync runs on;
Alder Lake-P does AV1 **decode only**, no AV1 encode, which is why the transcode
settings below enable AV1 decoding but nothing expects AV1 output.

---

## What's in the stack

| Service | Image | Pinned | Port | Reachable from (§5.1) |
|---|---|---|---|---|
| Jellyfin | `jellyfin/jellyfin` | `10.11.11` | 8096/tcp, host networking | LAN only |
| | | | 1900/udp, 7359/udp discovery | LAN only |
| Jellyseerr | `ghcr.io/fallenbagel/jellyseerr` | `2.7.3` | 5055 | LAN only |
| Prowlarr | `lscr.io/linuxserver/prowlarr` | `2.5.2` | 9696 | LAN only |
| Sonarr | `lscr.io/linuxserver/sonarr` | `4.0.19` | 8989 | LAN only |
| Radarr | `lscr.io/linuxserver/radarr` | `6.3.0` | 7878 | LAN only |
| Bazarr | `lscr.io/linuxserver/bazarr` | `1.6.0` | 6767 | LAN only |
| SABnzbd | `lscr.io/linuxserver/sabnzbd` | `5.0.4` | 8081 → 8080 in-container | LAN only |
| ~~qBittorrent~~ | `lscr.io/linuxserver/qbittorrent` | `5.2.3` | via gluetun | **profile `torrents` — not running** |
| ~~gluetun~~ | `qmcgaw/gluetun` | `v3.41.3` | publishes 8080 | **profile `torrents` — not running** |

**This deployment is usenet-only.** The last two rows are defined in
`compose.yaml` but carry `profiles: ["torrents"]`, so `docker compose up -d`
starts **seven** services and **six** ports listen — 8080 is not among them.
Turning them on is two lines in `.env` (`COMPOSE_PROFILES=torrents` plus the
VPN block) and needs no change in `palimpsest-system`; re-pin both image tags
first, since they rot unexercised. See the torrent-path comment in
`compose.yaml`.

**There is no VPN in this design.** Contract v4 removed Tailscale: this server
exists so a family member outside the house can watch on a **Roku**, which has
no Tailscale or WireGuard client, so a tailnet-based access model served nobody.
Everything is LAN-only, admin UIs included — with no tailnet there is nowhere
else to put them.

All seven Docker-published services bind `BIND_ADDR_LAN`, once each. Jellyfin
is host-networked and not published by Docker at all, so the host firewall
governs it and is its only protection.

The reason for the arrangement, in one line: Docker DNATs published ports in
`PREROUTING`, so they never reach `INPUT` and the host firewall is never
consulted for them. For anything Docker publishes, the bind address *is* the
enforcement — which is why none of them may bind `0.0.0.0`, and why there is
deliberately no firewall rule for any of them. An inert rule that reads as
protection is worse than no rule. See `.env.example`.

**Remote access is contract §5.3 and is not built here.** When it arrives it is
443/tcp forwarded to a host-side TLS reverse proxy in `palimpsest-system`. This
repo's obligation under §5.3 is a negative one: Jellyfin stays host-networked
and must never be given a `ports:` block. 8096 is plaintext, unrate-limited and
MFA-less; Docker-publishing it would bypass the host firewall and put it one
router forward from the open internet in the clear.

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

- **`BIND_ADDR_LAN`** — this machine's DHCP-reserved LAN address, and the bind
  address for all seven published services. It has **no default and must be
  set**; with it blank, compose aborts before starting anything:

  ```
  required variable BIND_ADDR_LAN is missing a value: no default — set to
  this machine's LAN address in .env, contract §5.2
  ```

  That is designed, not broken. It also means contract §7.2's
  `docker compose config` check fails until `.env` is filled — expected.
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

### 3b. Accounts you need to obtain before the stack does anything useful

The containers start fine with none of these. The *download path* does not work
without at least one of each of the first three.

| # | What | Needed for | Yields | Goes in |
|---|---|---|---|---|
| 1 | VPN provider | qBittorrent (gluetun killswitch) | WireGuard private key + address | `.env` |
| 2 | Usenet provider | SABnzbd — the thing that actually downloads | host, port 563, user, pass | SABnzbd UI |
| 3 | Usenet indexer(s) | Prowlarr — search over usenet | API key | Prowlarr UI |
| 4 | Torrent trackers | Prowlarr — torrent side | varies; public need nothing | Prowlarr UI |
| 5 | OpenSubtitles | Bazarr | username + password | Bazarr UI |
| 6 | Domain registrar | contract §5.3, later | domain + DNS control | `palimpsest-system` |

**A provider and an indexer are different things and you need both.** The
provider stores the articles and is where bytes come from; the indexer is a
search engine over what exists. One provider plus two or three indexers is the
normal shape — indexers each miss things, and they are cheap.

**1. VPN.** Only if you want the torrent half; usenet does not need it. The one
decision that matters is **port forwarding**, which you need to seed. ProtonVPN
and Private Internet Access both support it and gluetun can request it natively;
AirVPN supports it but you configure it on their site; **Mullvad removed it in
2023**, so it is a poor fit here despite otherwise being a good service. If you
pick a port-forwarding provider, `compose.yaml` needs `VPN_PORT_FORWARDING=on`
and a provider name added to the gluetun block — that is a change to make
deliberately, not a default.

**2. Usenet provider.** Unlimited accounts run ~$5–10/month, and the same
handful of *backbones* sit behind many resellers — buying two accounts on the
same backbone buys you nothing. Retention is ~5000+ days across the majors. A
cheap unlimited primary plus a small block account on a *different* backbone
covers what the first one is missing. Prices drop sharply around Black Friday;
if you are not in a hurry, wait for it.

**3. Usenet indexers.** ~$10–20/year each, some with lifetime tiers. Several are
invite-only or open registration only periodically, so take a slot when you see
one. You want more than one: coverage differs, and a single indexer is a single
point of failure for search.

**4. Torrent trackers.** Public trackers need no account and Prowlarr ships
definitions for them. Private trackers need signup or an invite and give you
either an API key, a passkey, or session cookies.

**5. Bazarr.** OpenSubtitles is the main one; the free tier has a daily download
cap that a bulk backfill will hit immediately, and VIP raises it for ~€20/year.
Several other providers need no account at all — enable a few, they cost nothing.

**6. Domain.** Only for contract §5.3 remote access, which is not built yet.
~$10–15/year. You need one you control DNS for, so ACME can issue a certificate.
That work lands in `palimpsest-system`, not here.

### 4. Secrets you supply by hand, outside `.env`

Per contract §6, none of these ever land in a committed file. Most are entered
in a web UI after the service is up:

| Secret | Where it goes |
|---|---|
| TLS certificate for §5.3, when built | Host, not this stack — ACME in `palimpsest-system` |
| VPN WireGuard key | `.env`, gluetun |
| Usenet provider (server, user, pass) | SABnzbd UI → Config → Servers |
| Indexer credentials / API keys | Prowlarr UI → Indexers |
| Prowlarr → Sonarr/Radarr app keys | Generated; Prowlarr UI → Settings → Apps |
| Sonarr/Radarr → download client | Their own UIs. qBittorrent's password is **generated at first start and printed to its log**, not chosen by you — see below |
| Jellyfin admin account | Jellyfin's first-run wizard |
| Prowlarr / Sonarr / Radarr / Bazarr admin logins | each app's first-run auth prompt — see "Authentication on the admin apps" |
| SABnzbd admin login | Config → General, alongside its API key |
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

Then the automation layer, then the download client:

```bash
# 2. Automation
docker compose up -d prowlarr sonarr radarr bazarr jellyseerr
docker compose ps

# 3. Usenet
docker compose up -d sabnzbd
docker compose ps                        # expect 7 services, all Up
```

That is the whole stack. gluetun and qbittorrent are behind the `torrents`
profile and will not appear — that is correct, not a failure.

---

## If you ever enable the torrent path

Everything in this section is inert while `COMPOSE_PROFILES` is unset. It is
kept because the reasoning is expensive to reconstruct, not because it runs.

**Re-pin `gluetun` and `qbittorrent` image tags first.** They were resolved
2026-08-03 and are not exercised while the profile is off. gluetun has renamed
provider environment variables across versions, so the `.env` VPN block may not
match whatever you pull.

```bash
# in .env: fill the VPN block, then add COMPOSE_PROFILES=torrents
docker compose up -d gluetun
docker compose logs -f gluetun           # look for the tunnel coming up
docker compose up -d qbittorrent         # blocked until gluetun is healthy
```

Then verify the tunnel actually carries the traffic — contract §7.2's VPN
egress check, which only applies when this profile is on:

```bash
docker compose exec gluetun sh -c 'wget -qO- https://ipinfo.io/ip'
# Must NOT be your home WAN address. Compare:
curl -s https://ipinfo.io/ip
```

Sonarr and Radarr would then need qBittorrent added at `http://gluetun:8080`
(**not** `http://qbittorrent:8080` — it has no network identity of its own),
and their delay profiles changed from usenet-only to preferred-usenet with a
45-minute torrent delay.

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
the WebUI at `http://192.168.x.y:8080` fails with `Unauthorized` before your
credentials are even considered — the failure looks like a bad password and is
not one. Fix it once you are in, via an SSH tunnel to `127.0.0.1:8080` if
needed. Options → Web UI, either:

- add the LAN address (and any hostname you use) to **"Server domains"**, or
- untick **"Validate HTTP Host header"**.

Prefer the first: it keeps the DNS-rebinding protection the check exists to
provide. The equivalent keys in `qBittorrent.conf` are
`WebUI\ServerDomains` and `WebUI\HostHeaderValidation`.

## Application configuration, in order

**SABnzbd first**, then Prowlarr, then Sonarr/Radarr, then Jellyfin, then
Bazarr and Jellyseerr. Each step depends on the previous one existing.

Every URL below uses a **container name**, never `localhost` — these services
talk to each other on the compose bridge network, where `localhost` is the
container itself.

1. **SABnzbd** (`:8081`) — the provider connection and, critically, the paths.
   - **Config → Servers → Add**: your usenet provider's hostname, port **563**,
     **SSL on**, username, password, and a connection count that **matches your
     plan's limit** — more will get you throttled or blocked, fewer caps speed.
     Test the server before saving.
   - **Config → Folders** — this is the step that silently breaks everything if
     skipped. SABnzbd defaults both folders to `/config/…`, which is on the
     **root filesystem**, not `/data`. Imports would then be cross-filesystem
     copies: slow, disk-doubling, and exactly what contract §2 exists to
     prevent. Set them to:
     - Temporary Download Folder: `/data/usenet/incomplete`
     - Completed Download Folder: `/data/usenet/complete`
   - **Config → General**: copy the **API key**. Sonarr and Radarr need it.
2. **Prowlarr** (`:9696`) — add your indexer(s) with the API key from each
   indexer's own profile page. Then Settings → Apps → add Sonarr
   (`http://sonarr:8989`) and Radarr (`http://radarr:7878`), each with that
   app's API key; Prowlarr pushes indexers into both from then on.
3. **Sonarr** (`:8989`) **and Radarr** (`:7878`):
   - Root folders: `/data/media/tv` and `/data/media/movies` respectively.
   - Download client: SABnzbd at `http://sabnzbd:8080` — **8080, the in-container
     port, not 8081.** 8081 is the host-side mapping and means nothing here.
     Paste SABnzbd's API key.
   - **Delay profiles** — Settings → Profiles → Delay Profiles: preferred
     protocol **Usenet**, usenet delay **0**. There is no torrent client, so the
     torrent delay is irrelevant; if you later enable the torrents profile, set
     it to 45 minutes so usenet keeps first crack.
   - Confirm "Use Hardlinks instead of Copy" is on (Settings → Media Management,
     with Advanced shown). With usenet there is nothing to seed, so the practical
     effect is that same-filesystem imports stay instant instead of becoming
     copies. Confirm it anyway.
4. **Jellyfin** — reached at **`http://<palimpsest-lan-ip>:8096`**, and it is
   the one service in the stack you reach by a different mechanism than all the
   others. It is host-networked, so it binds the host's interfaces itself, as
   though installed by a package manager: no Docker port mapping, and
   `BIND_ADDR_LAN` has nothing to do with it. What keeps it LAN-only is the host
   firewall — the one firewall rule here that is genuinely load-bearing, because
   §5.2's bind enforcement cannot reach a container Docker does not publish.

   Confirm before browsing: `curl -sI http://127.0.0.1:8096/health` → 200.

   **In the first-run wizard, decline "Enable automatic port mapping" / UPnP.**
   That asks the router to open a port from the internet straight to Jellyfin,
   and if the router has UPnP on, it may succeed — publishing **8096, plaintext,
   no rate limiting, no MFA** to the world. Contract §5.3 permits exactly one
   forwarded port, 443, terminating at a TLS proxy that does not exist yet. The
   wizard's contents vary by version, so confirm afterwards in **Dashboard →
   Networking** that automatic port mapping is off.

   Libraries: **Movies** → `/data/media/movies`, **Shows** → `/data/media/tv`.
   In-container paths identical to host paths, per contract §2 — which is what
   lets Sonarr hardlink an import into a folder Jellyfin is already watching.

   Transcoding settings below.
5. **Bazarr** (`:6767`) — Settings → Sonarr and Settings → Radarr, using
   `http://sonarr:8989` and `http://radarr:7878` plus their API keys.

   **Providers** — a small set beats a large one. More providers means slower
   searches, rate-limiting, and worse matches, because low-quality sources
   return plausible but mistimed subtitles. For English, start with:
   **Embedded Subtitles** (no account, no network — pulls subs already inside
   the file, and solves a good share of cases before anything is queried),
   **OpenSubtitles.com** (free account; note `.com`, the legacy `.org` provider
   is largely dead), **Podnapisi**, **TVSubtitles**, **Subdl**. Skip Addic7ed
   unless you need it — good TV coverage, aggressive rate limits, blocks
   readily. OpenSubtitles' free tier caps daily downloads, which a bulk
   backfill hits in minutes; backfill over several days or take VIP for the
   first pass.

   **A language profile is required, and its absence is silent.** Providers
   alone do nothing. Settings → Languages → create a profile, add your
   language, set it as default for Series and Movies — then check Bazarr's own
   Series and Movies lists, because items already synced from Sonarr/Radarr can
   arrive with **no profile assigned** and anything without one is skipped
   without comment. Same shape as Sonarr's monitoring switch: present,
   apparently configured, deliberately ignored.

   **Added series before creating the profile?** Nothing is lost — subtitles
   are fetched independently of the download, at any time afterwards. Setting a
   profile as default only affects items added from then on, so assign it
   retroactively: Series → **Mass Edit** → select → set profile → Save. Then
   System → **Tasks** → run *Sync with Sonarr*, and **Wanted → Search All**. An
   empty Wanted list with profiles assigned means Bazarr believes nothing is
   missing, usually because the files already carry embedded subtitles.

   Worth enabling while you are there: **subtitle synchronization**, which
   time-shifts a subtitle to match your specific release and removes most
   "subs are two seconds off" complaints.
6. **Jellyseerr** (`:5055`) — connects to everything, which is why it is last.
   Jellyfin's URL here is **`http://host.docker.internal:8096`**, not
   `http://jellyfin:8096`: Jellyfin is on host networking and has no address on
   the bridge network. Sonarr and Radarr use their normal container names and
   API keys.

### Host-header validation — an auth-shaped error that is not about auth

**Symptom:** one service cannot reach another by container name and fails with
`403 Forbidden` or `Unauthorized`. It looks like a wrong API key or password.
It is not.

**Cause:** several of these apps validate the HTTP `Host` header as
DNS-rebinding protection, and their default whitelists accept IP addresses and
`localhost` but not arbitrary hostnames. Every inter-service call in this stack
uses a **container name** — `http://sabnzbd:8080`, `http://sonarr:8989` — so the
header carries a name the receiving app has never been told about, and the
request is rejected before the credential is examined.

The tell: it works in your browser at `http://192.168.x.y:8081` (Host header is
an IP, which passes) and fails from another container (Host header is a name).
Same service, same key, different name.

**Known cases in this stack:**

| Service | Setting | Add |
|---|---|---|
| SABnzbd | `host_whitelist` — Config → General, security section, or Config → Special | `sabnzbd` |
| qBittorrent | "Server domains" — Options → Web UI (`WebUI\ServerDomains`) | `gluetun`, and any hostname you use |

Both files are on the host, under `/opt/palimpsest-stack/<app>/`, so they can be
edited without the UI. Restart the container afterwards.

**Do not work around it by pointing at a container IP** — those are reassigned
on recreate, so it breaks on the next `docker compose up` and does so silently.
**Do not disable the validation** either; whitelisting the one legitimate name
keeps the protection intact. Expect to hit this again with any service added
later that talks to another by name.

### Authentication on the admin apps — one trap

Prowlarr, Sonarr, Radarr and Bazarr each demand an authentication choice on
first run. Two settings, and the second one matters more than it looks:

- **Authentication Method** → username and password. Prefer **Forms** (login
  page) over **Basic** (browser popup); Basic is handled badly by some tools.
- **Authentication Required** → leave at **Enabled**. **Do not** select
  "Disabled for Local Addresses."

That second option exempts requests from private/RFC1918 addresses. Under
contract v4 every service binds the **LAN address** and there is no remote path
at all, so every request that can reach these apps comes from a local address.
On this deployment, "disabled for local addresses" and "disabled" are the same
setting — it reads like a convenience and is a complete removal.

§5.2's bind addresses govern *what can reach the port*. They say nothing about
*who may use the service* once it is reachable. The LAN is not a trust boundary:
televisions, guest phones and everything else on it reach these ports by design.

**Enabling auth does not break the app wiring.** Inter-app calls authenticate
with the `X-Api-Key` header, which bypasses forms auth entirely. The only cost
is a browser login.

Each app's password is a §6 secret: password manager, not `.env`, not git.

**Locked out?** Stop the container, edit that app's `config.xml` in its config
directory on the host — e.g. `/opt/palimpsest-stack/prowlarr/config.xml` — and
change the `<AuthenticationMethod>` element, then start it again. Older builds
accept `None`, recent ones use `External`. Being able to do this from the host
is a side benefit of the bind-mounted config directories.

### Where each API key comes from

Nothing here is purchased — these are generated by the apps themselves and
pasted between them.

| Key | Found in | Needed by |
|---|---|---|
| SABnzbd | Config → General | Sonarr, Radarr |
| Sonarr | Settings → General | Prowlarr, Bazarr, Jellyseerr |
| Radarr | Settings → General | Prowlarr, Bazarr, Jellyseerr |
| Indexer | the indexer's own website profile | Prowlarr |

## Using it — where things are requested and where they appear

The stack has two front doors and they are not interchangeable:

- **Jellyseerr** (`:5055`) — for *wanting* things. Search, click Request, done.
  This is what family members use; they sign in with their Jellyfin accounts.
- **Jellyfin** (`:8096`) — for *watching* what has already arrived. It is not a
  place to look for new material.

Sonarr and Radarr are the admin view behind Jellyseerr. Day to day you should
not need them; you go there when something needs a nudge.

```
Jellyseerr  →  Sonarr / Radarr  →  Prowlarr → indexer  →  SABnzbd
                                                             ↓
                         Jellyfin  ←  /data/media  ←  import
```

**Adding something directly**, which is worth doing once to see the machinery:
Sonarr → Series → Add New (root folder `/data/media/tv`), or Radarr → Movies →
Add New (`/data/media/movies`). Two settings account for most confusion:

- **Monitoring** is the "do I want this?" switch. Nothing unmonitored is ever
  searched for. A show sitting in the list doing nothing is usually this.
- **Quality Profile** is the accepted range. Stay at 1080p without a specific
  reason: 4K forces a transcode on most clients, which is a thing the iGPU
  passthrough exists to survive, not to do continuously.

**Test with something old and popular first.** Retention and indexer coverage
are best for well-known older material, so a ten-year-old film tests your
pipeline rather than testing whether the release exists at all.

**Following a request through:** Activity → Queue (did it grab?), SABnzbd
(is it downloading?), Activity → History (did it import?), then
`ls /data/media/movies`. If the queue stays empty, use **Interactive Search**
— the magnifying glass on an episode or film. It lists every release the
indexer returned and why each was rejected, and it is the most useful
diagnostic page in the stack.

### Telling Jellyfin about new files

**Status: wired and verified, 2026-08-05 — via a Webhook, NOT the built-in
Emby/Jellyfin connection. The obvious approach does not work here; read on
before "simplifying" it back.**

Jellyfin's real-time folder monitoring is supposed to notice imports on its own,
but on this box it misses them — it does not reliably see a hardlink appear
inside a bind mount. So the import path has to poke Jellyfin explicitly. The
catch is *which* poke:

- The built-in **Sonarr/Radarr → Connect → Emby/Jellyfin** connection sends
  `POST /Library/Media/Updated` (a *targeted* update) on import. This Jellyfin
  (10.11.11) answers `204` and then does **nothing** with it — verified by
  replaying the exact call with a throwaway file, which never appeared. That
  endpoint is hard-coded in the connection, so the connection cannot be made to
  work. Do not re-add it.
- Only a full **`POST /Library/Refresh`** actually scans. It accepts query-param
  auth and ignores the request body, so a plain **Webhook** notification can
  call it.

What is configured, in both Sonarr and Radarr (Settings → Connect → **Webhook**,
On Import + On Upgrade + On Rename):

```
URL:    http://host.docker.internal:8096/Library/Refresh?api_key=<jellyfin-key>
Method: POST
```

Get `<jellyfin-key>` from Jellyfin → Dashboard → **API Keys**. It ends up in the
webhook URL, which lives in the gitignored arr config dirs alongside their own
keys — a §6 secret, not a tracked file. Verified end-to-end: firing either app's
webhook makes Jellyfin pick up a new file with no manual scan.

Trade-off: this triggers a *full* library scan per import rather than a targeted
one. At this library size that is trivial, and Jellyfin coalesces rapid repeats
(a season pack importing ten episodes does not cause ten real scans). The 12-hour
scheduled **Scan Media Library** task stays on as a backstop; there is no need to
shorten it while the webhook is doing its job.

`sonarr`, `radarr` and `jellyseerr` carry an `extra_hosts` entry mapping
`host.docker.internal` to the bridge gateway, which is what makes that hostname
resolve at all. A container without that entry cannot reach Jellyfin by name.

## Jellyfin transcoding

**Status: applied and verified, 2026-08-05.** The initial bring-up left the
encoding config at its defaults — `HardwareAccelerationType` was `none` (all
transcoding on CPU) and the transcode temp path was unset, so segments were
being written to `/cache` on the NVMe instead of the `/transcode` tmpfs (the
exact silent-fallback this section warns about, reached from the config side
rather than the mount side). The settings below have since been applied and
confirmed: a forced transcode now spawns ffmpeg with `-hwaccel vaapi
-hwaccel_output_format vaapi`, `scale_vaapi`, the `h264_vaapi` encoder, and
output under `/transcode`. `vainfo` inside the container reports the Intel iHD
driver on the Alder Lake-P iGPU with full decode/encode profiles. The one check
still worth doing from the host is `intel_gpu_top` during a real client
transcode (below) — it is the only thing that distinguishes a working GPU path
from a silent software fallback.

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

## Jellyfin plugins — installed in the UI, not in this repo

**Plugins are runtime state, not source.** They are installed through Jellyfin's
own Dashboard and land in `/opt/palimpsest-stack/jellyfin/config/plugins`, which
is a bind mount and is gitignored. Nothing in `compose.yaml` changes, no image
changes, and nothing about a plugin is tracked here.

The consequence worth knowing: **a fresh clone of this repo does not reproduce
your plugins.** They survive `docker compose up -d` and container recreation
because the config directory is a bind mount, but they live and die with that
directory — so they are covered by the config-directory backup described at the
end of this file, and by nothing else. A plugin's own settings (SmartLists rules,
for instance) live in the same place and have the same property.

### Installing one

Dashboard → Plugins → **Repositories** → add the repository URL, then Dashboard
→ Plugins → **Catalog** → install → restart Jellyfin.

Adding a third-party repository means Jellyfin fetches and executes code from
that source on every update check. That is a real trust decision on an otherwise
carefully-scoped box; weigh it per plugin rather than by habit.

### SmartLists — dynamic playlists and collections from rules

Fills the one real gap in Jellyfin's native list features. Tags, Collections and
Playlists all exist natively but are **manual** — nothing auto-populates. This
plugin builds playlists *and* collections from rules that re-evaluate as the
library changes.

- Repository: `https://raw.githubusercontent.com/jyourstone/jellyfin-plugin-manifest/main/manifest.json`
- Source: `jyourstone/jellyfin-smartlists-plugin`, AGPL-3.0
- Docs: <https://jellyfin-smartlists-plugin.dinsten.se> — much deeper than the
  README; field descriptions, operators, examples
- UI: "SmartLists" in the sidebar under Plugins. Tabs: Create, Manage, Status,
  Settings. **Tag-driven lists are the main use here**: tag items in Edit
  Metadata → Tags, then a rule of `Tags contains <x>` produces a collection or
  playlist that re-evaluates on library updates and playback changes. Collections
  browse alongside libraries; playlists are ordered and can be per-user.
- The author discloses that recent work is substantially AI-assisted, with
  releases and docs reviewed by the project owner. Noted because everything else
  running on this box was chosen deliberately.
- **Not** `ankenyr/jellyfin-smartplaylist-plugin`, which most search results
  still point at and which is dead — last release 2021, last commit mid-2024.

**Version coupling.** The plugin numbers releases to match the Jellyfin major it
targets. The published manifest currently carries only `targetAbi` 10.10.0 and
10.11.0 (newest 10.11.30.2), so the catalogue will offer this server nothing but
10.11-compatible builds — the `v12.0.0.x-rc` builds exist only as GitHub release
downloads and cannot arrive through the UI. **This means: install via the
catalogue, never by hand from GitHub releases.** Doing it by hand is the only way
to get a v12 build onto a 10.11 server.

If you come to depend on this plugin, Jellyfin is no longer independently
upgradable — moving to Jellyfin 12 breaks it until the plugin's v12 line ships
stable and reaches the manifest. Check the manifest's `targetAbi` values before
bumping the `jellyfin` image tag in `compose.yaml`.

### Hand-applied tags can be wiped by a metadata refresh

Tags set by hand in the metadata editor are provider-overwritable. A refresh run
with "overwrite all metadata" replaces them. Lock the Tags field on anything
tagged manually, or keep tags in `.nfo` sidecars, which survive refreshes. This
matters more once rule-based lists depend on those tags, because the lists go
quietly empty rather than erroring.

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

**Run on palimpsest, 2026-08-05.** Results: `config` parses; in-container
hardlinking confirmed for sonarr (`/data/usenet/complete` → `/data/media/tv`)
and radarr (→ `/data/media/movies`), same inode + `links=2`; the listener check
shows the expected six LAN-bound ports and nothing on `0.0.0.0` (plus 8096 on
`0.0.0.0`, correct for host-networked Jellyfin). The VPN-egress check is N/A
(torrents profile off). The off-box `nmap` scan is still the operator's to run:

```bash
docker compose -f /opt/palimpsest-stack/compose.yaml config   # parses
```

That one has been run on a workstation (exit 0) — but note it now requires
`BIND_ADDR_LAN` to be set, so it doubles as a check that `.env` is complete.
The other four have not been run at all.

#### 1. Hardlinking, from inside a container

The host-side check above is necessary but **not sufficient**. What matters is
whether hardlinking works across the path mapping the *containers* see, because
that is where imports actually happen. A volume layout that breaks it looks
completely fine from the host:

**Test the path imports actually use.** Contract §7.2 writes this check against
`/data/torrents`, which is correct for a torrent deployment and wrong for this
one — nothing is downloaded there. On a usenet-only stack the path that matters
is SABnzbd's completed folder into the library:

```bash
docker compose exec sonarr sh -c '
  touch /data/usenet/complete/.hltest &&
  ln /data/usenet/complete/.hltest /data/media/tv/.hltest &&
  echo HARDLINK OK IN CONTAINER;
  stat -c "links=%h inode=%i" /data/usenet/complete/.hltest /data/media/tv/.hltest;
  rm -f /data/usenet/complete/.hltest /data/media/tv/.hltest'
```

Both paths must report the **same inode** and `links=2`. Repeat for `radarr`
against `/data/media/movies` — each service has its own volume list and each can
be wrong independently. (Run the `/data/torrents` version too, and for
`qbittorrent`, only if you enable the torrents profile.)

If this fails, stop and fix it before importing anything. A broken hardlink path
does not error; it silently turns every import into a full copy, doubles disk
usage, and breaks seeding. You find out months later.

#### 2. Listener check — the one with teeth

Run **on palimpsest**. This is the check that would have caught the v2 defect,
and it is the only one in §7.2 that cannot pass while §5.2 is violated:

```bash
ss -ltnp | awk '$4 !~ /^\[/ {print $4}' | sort -u
```

One thing must hold, for every published port:

- **Every one appears on this machine's LAN address and nowhere else.** None may
  show `0.0.0.0:` or `*:`. A listener on `0.0.0.0` is the v2 defect returning —
  it is listening on every interface and no firewall rule will constrain it.

**Expect six, not seven: 5055, 6767, 7878, 8081, 8989, 9696.** Contract §7.2
says seven because it counts 8080, qBittorrent's WebUI — which is behind the
`torrents` profile and not running here. Six is correct for this deployment;
seven only if you enable that profile.

**8096 will show as `0.0.0.0:8096` and that is correct.** Jellyfin is
host-networked, so it binds the host's interfaces itself and the rule above does
not apply to it — the rule exists because for *Docker-published* ports the bind
address is the only enforcement. Jellyfin's exposure is bounded by the host
firewall instead. Do not "fix" this; the only way to change it would be to
Docker-publish Jellyfin, which contract §5.3 forbids outright.

The `awk` filter drops IPv6 listeners so the output stays readable; if you want
to see those too, drop it.

#### 3. Exposure scan

Run **from another host on the LAN**.

```bash
nmap -Pn -p 22,5055,6767,7878,8080,8081,8096,8989,9696 <palimpsest-lan-ip>
```

All of them should answer — everything is LAN-reachable by design under v4.

**This check proves almost nothing about §5.2, and it is important to know why.**
A service bound to `0.0.0.0` and one bound correctly to the LAN address look
*identical* from the LAN. That is exactly how the v2 defect survived review.
Check 2 above is the one that distinguishes them. Run this anyway — it catches
a service that failed to start, or a port mapping that never took — but do not
read a clean scan as evidence that the bind addresses are right.

Once contract §5.3 is built, the meaningful version of this scan is from
**outside** the network, where only 443 may answer.

#### 4. VPN egress

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
| **Admin UI unreachable from the LAN** | `BIND_ADDR_LAN` in `.env` — it must be this machine's actual LAN address. `ss -ltnp` to see what took. |
| **Admin UI reachable from the LAN** | Same variable, opposite failure, and the serious one. `ss -ltnp` to see what is actually bound; anything on `0.0.0.0` is the bug. Do not look at the firewall — Docker's DNAT means it is never consulted (§5.2). |
| **Jellyseerr unreachable from the LAN** | Same as any other published service now — check `BIND_ADDR_LAN`. Not a firewall problem: there is deliberately no firewall rule for any Docker-published port. |
| **`required variable BIND_ADDR_LAN is missing a value`** | Working as designed — it has no default. Set it to the DHCP-reserved LAN address in `.env`. |
| **`docker compose up` fails: "cannot assign requested address"** | `BIND_ADDR_LAN` names an address the host does not have yet — at boot, DHCP has not returned a lease. Contract §3 makes waiting for a global-scope IPv4 a start precondition on the unit. |
| **Jellyfin clients don't auto-discover** | UDP 1900/7359 inbound, LAN only. Opened in palimpsest-system, not here. TCP 8096 working tells you nothing about this. |
| **qBittorrent unreachable** | Check gluetun first: `docker compose ps gluetun` (must be `healthy`), then its logs. qBittorrent cannot start until gluetun is healthy, by design. |
| **qBittorrent says "Unauthorized" with correct credentials** | Host-header validation, not authentication. Add the LAN address to Server domains, or untick "Validate HTTP Host header". See the bring-up section. |
| **qBittorrent password rejected after a restart** | The generated temporary password is regenerated every start until you set a permanent one. `docker compose logs qbittorrent \| grep -i password`. |
| **qBittorrent reachable but downloads nothing** | Tunnel is up but the killswitch is eating traffic. Check `FIREWALL_OUTBOUND_SUBNETS` matches `DOCKER_SUBNET`. |
| **Sonarr/Radarr can't reach qBittorrent** | The host is `gluetun`, not `qbittorrent`. |
| **Jellyseerr can't reach Jellyfin** | The host is `host.docker.internal`, not `jellyfin`. |
| **Imports are slow / disk filling fast** | Hardlinking is broken. Run the in-container check above. This is the expensive failure. |
| **New files owned by root** | `PUID`/`PGID` did not apply — check you did not add `user:` to a LinuxServer image. |

---

## Turning on torrents (PIA)

The torrent path is configured and off, behind `profiles: ["torrents"]`. Three
services join the stack when it is on: gluetun, qbittorrent, and
qbittorrent-port-sync.

**How it is wired.** PIA over OpenVPN, verified against gluetun v3.41.3 on
2026-08-11. The provider, protocol, region (`CA Montreal`) and port forwarding
are hardcoded in `compose.yaml`; only the PIA account credentials live in
`.env`. OpenVPN, not WireGuard: PIA hands out no static WireGuard config, and
OpenVPN is the path gluetun natively integrates with PIA's port-forwarding API.
`VPN_PORT_FORWARDING_PROVIDER` has to be named even though the provider already
is, or no port is requested. The `/opt/palimpsest-stack/gluetun` mount persists
the auth token and the forwarded-port lease, so the same port survives restarts
and refreshes before its 60-day expiry.

**Turn it on:**

1. Set `OPENVPN_USER` and `OPENVPN_PASSWORD` in `.env` (the PIA `p#######`
   username and its password, not the email login).
2. Add `COMPOSE_PROFILES=torrents` to `.env`.
3. Restart the stack. Nothing in palimpsest-system changes.

**The one runtime step the sync depends on.** qbittorrent-port-sync sets
qBittorrent's listen port to PIA's forwarded port over the WebUI API from inside
gluetun's namespace, as an unauthenticated localhost call. That call is refused
until qBittorrent has "bypass authentication for clients on localhost" on
(`WebUI\LocalHostAuth=false`). Set it in the WebUI under Options, Web UI, or in
`qBittorrent.conf`. Until then the sync loop retries without harm. qBittorrent
5.x also validates the `Host` header (see the fragile-areas list), so a manual
API call from the LAN needs `-H "Host: localhost"`.

**Verify** from a LAN host:

- Exit IP is in Canada, not your Comcast address:
  `docker compose exec gluetun sh -c 'wget -qO- https://ipinfo.io/ip'`
- A port is forwarded: `curl -s http://<BIND_ADDR_LAN>:8080` reachable, and
  `docker logs qbittorrent-port-sync` shows `set listen_port=<n>`.
- Killswitch holds: stop gluetun and qBittorrent loses all network, rather than
  falling back to the bare WAN link.

The `/gluetun` directory holds only a re-fetchable PIA token, so it does not
need backing up. The old WireGuard and `SERVER_COUNTRIES` lines left in a live
`.env` from before this change are unused now and can be deleted.

## What this layer depends on palimpsest-system for

Outside this repo's boundary (contract §0). Both items this repo raised against
v1 were resolved in contract v2 and are now the system layer's obligations, not
open questions:

1. **The stack unit waits for a global-scope IPv4 address** — contract §3, a
   bounded `ExecStartPre` poll that fails on timeout. Required because
   `BIND_ADDR_LAN` names an address that does not exist until DHCP returns a
   lease. The poll must match on *global* scope specifically: link-local
   `169.254.0.0/16` is what a failed DHCP negotiation leaves behind, and
   accepting it would defeat the check.
2. **`/data/transcode` is in `RequiresMountsFor`** — contract §3. Without it a
   failed tmpfs mount leaves the underlying directory in place with correct
   ownership, and Jellyfin transcodes to the NVMe instead of RAM, silently.
   (The conflicting `uid=1000` fstab example that prompted this lived in
   `x17r2-jellyfin-build.md`, which contract v2 §0 deletes from both repos.)

Still the system layer's, and not verifiable from here:

- Firewall source rules for 22, 8096 and the UDP discovery ports 1900/7359
  (RFC1918 only). These are Jellyfin's *only* protection — it is host-networked,
  so §5.2's bind-address rule does not reach it. There is deliberately no rule
  for any Docker-published port.
- `/dev/dri/renderD128` group-owned by 303, and the iHD driver installed.
- **Contract §5.3, when it is built**: the 443/tcp forward, the TLS reverse
  proxy, and ACME. None of it lives here. This repo's only §5.3 obligation is
  to keep Jellyfin host-networked and unpublished — see the `jellyfin` block in
  `compose.yaml`.

## Backups

Media is re-acquirable; the `/opt/palimpsest-stack/*/` directories are not —
they hold watch history, users, quality profiles and indexer configuration.
Back those up (restic was the plan) plus `.env`. Do it with the stack stopped,
or accept that SQLite databases are being copied live.
