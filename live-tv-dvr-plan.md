# Live TV & DVR — in-bounds plan

Draft plan, 2026-08-05. Scope: enable Jellyfin's Live TV & DVR for the family,
using only what this repo (the application layer) is allowed to touch. Assumes
`contract.md` v4 and the boundary rules in `CLAUDE.md`.

This document is deliberately limited to the **legal, in-bounds** build:
over-the-air broadcast reception, time-shifted recording, and place-shifting the
household's own tuner. It does not cover sourcing live streams by any other
means — that is out of scope for this plan and not something this setup does.

## What we're enabling, and why it covers the real need

A network tuner + antenna feeds Jellyfin, which can live-stream channels and
record them to `/data`. Three concrete outcomes:

- **Home NFL** — local **CBS / FOX / NBC / ABC** broadcasts, watched live or
  DVR'd. Time-shifting a broadcast you can already receive is settled, ordinary
  home-DVR behaviour.
- **Olympics in broadcast quality** — NBC's over-the-air feed is an unthrottled
  ~1080i signal (4K with an ATSC 3.0 tuner, where not DRM-locked), recorded to
  disk. Typically better picture than a bandwidth-capped stream.
- **NFL while travelling** — reach the home Jellyfin remotely (the planned
  §5.3 access) and watch the home tuner live. This is place-shifting the
  household's own broadcast feed for personal use — the Slingbox pattern — not
  redistribution.

**Honest gap:** exclusives that are never broadcast — Thursday Night Football
(Amazon), ESPN-only games, Peacock-exclusive Olympic feeds — are not reachable
by an antenna or a home DVR. That is a rights wall, not a config gap, and this
plan does not pretend to close it.

## The boundary — what this plan touches and what it must not

**In-bounds (this repo / app layer), safe to do here:**

- A recording directory under `/data` (contract §2 already mounts `/data` into
  Jellyfin at the identical path).
- Jellyfin's Live TV configuration: tuner, guide provider, DVR path, timers.
- Hardware transcoding for live TV — already configured and verified (VAAPI on
  the iGPU, see `NOTES.md` → "Jellyfin transcoding"). Live TV leans on it.

**Out of bounds — physical / hardware (yours to acquire and place):**

- The HDHomeRun tuner, the antenna, and the signal itself. No software fixes a
  weak signal; I can only read the tuner's signal-strength meter back to you.

**Out of bounds — `palimpsest-system` (never touched from this repo):**

- **Tuner discovery firewall rule.** HDHomeRun auto-discovery is a LAN UDP
  broadcast (port 65001). We **avoid needing it** by adding the tuner to
  Jellyfin **by IP** — a plain outbound TCP connection that needs no rule. This
  is the specific reason to prefer a network tuner over a USB one: a USB tuner
  would drag in a kernel driver, a `/dev` node, a udev permission rule, and a
  `devices:` passthrough — all system-layer and out of reach here.
- **§5.3 remote access** (443/tcp → TLS reverse proxy) is what makes travelling
  place-shift work. It is separate, already-planned system-layer work; this plan
  depends on it but does not build it.
- Live TV needs **no new inbound port** of its own — Jellyfin is host-networked
  and reaches the tuner outbound on the LAN.

If any of these system-layer items ever becomes genuinely necessary, it goes in
the cross-boundary list at the end of `NOTES.md`, not done from here.

## Design decisions (fixed for this plan)

- **Network tuner (HDHomeRun), not USB** — keeps the whole feature in the app
  layer; no driver or device passthrough.
- **Add the tuner by IP, not by discovery** — sidesteps the host firewall.
- **Recordings live on `/data`** at `/data/dvr`, owned `media:media 0775` — same
  per-app-directory pattern used everywhere else in this stack, so imports and
  Jellyfin both see them under the identical path (contract §2).
- **Guide via Schedules Direct** (~$35/yr, your account) — reliable listings
  with sports metadata, which is what makes "record every Patriots game" and
  "record NBC Olympic primetime" work as standing timers rather than one-offs.
  A free XMLTV source is the fallback if you'd rather not pay.

## Step 1 — in-bounds prep (now, no hardware required)

1. Create the recording directory:

   ```bash
   sudo install -d -o media -g media -m 0775 /data/dvr
   ```

   (Owned `media:media` so Jellyfin, running as `1500:1500`, can write
   recordings — the same ownership rule as every other `/data` path.)

2. Optionally add a Jellyfin library pointing at `/data/dvr` so finished
   recordings also appear as ordinary library items, not only under the Live TV
   → Recordings view. Decide this when we see how you want them organised.

Nothing else can be done until a tuner exists on the LAN.

## Step 2 — once the tuner is on the network

1. **Add the tuner** — Jellyfin → Dashboard → Live TV → **Tuner Devices** → add
   the HDHomeRun **by its IP** (not "discover").
2. **Add the guide** — Live TV → **TV Guide Data Providers** → Schedules Direct
   (your login) or an XMLTV URL; map its lineup to the tuner's channels.
3. **Point the DVR at `/data/dvr`** — Live TV → **DVR / Recording** settings:
   recording path `/data/dvr`, plus keep/retention and post-processing choices.
4. **Set the standing recordings** — series/timer entries for the Patriots and
   for NBC's Olympic coverage, using the guide's metadata.
5. **Verify hardware transcode on a live channel** — force a live-TV transcode
   and confirm the GPU engines light up (`intel_gpu_top` on the host — the one
   check that has to run there; see `NOTES.md`).

## Storage & retention

HD recordings run ~3.5–7 GB/hour; Olympic primetime is ~4 hrs/night for two-plus
weeks. `/data` has ~1.6 TB free today — plenty — but set a retention/auto-delete
policy in the DVR settings so a fortnight of the Olympics plus a season of Sunday
games doesn't quietly fill the disk.

## Hardware & accounts for you to acquire (out of my hands)

- **HDHomeRun** — a **Flex 4K** if you want a shot at ATSC 3.0 / NextGen 4K;
  a Flex/Connect for standard ATSC 1.0 HD.
- **Antenna** — sized to your distance and direction from the broadcast towers.
- **Schedules Direct** — ~$35/yr, for the guide (optional but recommended).

## Verification checklist (when live)

- A live channel plays in a client.
- A scheduled recording lands in `/data/dvr`, owned `media:media`.
- A live-TV transcode uses the GPU (Video / VideoEnhance engines active), not the
  CPU — the silent-software-fallback check from `NOTES.md`.
- New recordings surface in Jellyfin (the webhook / scan path already in place).
