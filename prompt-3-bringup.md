# Prompt 3 — Bring-up and verification

Run this **on palimpsest**, after the system layer is installed and contract
§7.1 passes. Attach `contract.md` (v2).

Prompt 2 authored the stack; nothing in it has been executed. This session is
the empirical half — you are starting containers, reading logs, and turning
`NOTES.md`'s claims into verified fact or into bugs.

---

I am bringing up the container stack on a headless NixOS media server. The
compose file and documentation already exist in `palimpsest-stack` and were
written against `contract.md` v2, which I have attached. **Every value in the
contract is fixed.** If one appears wrong, stop and tell me; do not work around
it. Amendments happen in the contract, by me.

Your scope is bringing the stack up and satisfying **contract §7.2**. You are
not touching the NixOS config; if something needs to change there, say so and
I will handle it in the other session.

## Ground rules

1. **Run §7.1 first.** If any of it fails, stop — the system layer is wrong and
   building on it wastes both our time.
2. **Verify before asserting.** Do not tell me a thing works because a file
   says so. `docker compose ps`, container logs, an actual HTTP request. Every
   claim in this session should be backed by output you have read.
3. **Bring services up incrementally** in the order `NOTES.md` gives — Jellyfin
   alone first, then automation, then download clients. A stack that comes up
   broken all at once is much harder to diagnose than one service that fails on
   its own.
4. **Do not modify anything under `/etc/nixos` or `/opt/palimpsest-system`.**
5. **Ask me** rather than guessing on anything involving my accounts,
   providers, or preferences. Do not ask me for credentials in chat — I will
   edit `.env` myself.

## Method

```bash
sudo git clone git@github.com:fkberthold/palimpsest-stack.git /opt/palimpsest-stack
```

Then follow `NOTES.md` § "Things you must do by hand" in order — the per-app
config directories must be pre-created as `media:media` before the first `up`,
or Docker creates them root-owned and every container fails to write its
database in a way whose logs blame the application.

`docker compose pull` all nine images as a discrete step before starting
anything. The tags were resolved at authoring time and nobody has re-checked
them; a withdrawn tag is cheap to fix alone and confusing mid-sequence.

Then bring-up, then the application configuration in the order `NOTES.md`
specifies (Prowlarr → Sonarr/Radarr → Jellyfin → Jellyseerr), including the
delay profiles.

## What must be verified

**Contract §7.2, all four checks, with output:**

1. `docker compose config` parses.
2. **Hardlinking from inside a container** — `sonarr`, `radarr` and
   `qbittorrent` each separately. Same inode, `links=2`. This is the important
   one: a broken path mapping does not error, it silently turns every import
   into a full copy and you find out months later.
3. **Exposure scan from a LAN host that is not on the tailnet.** Only 22, 5055
   and 8096 may answer. If an admin UI responds, `BIND_ADDR_TAILNET` is wrong —
   check contract §5.2 before looking at the firewall, which Docker's DNAT
   means is never consulted for published ports.
4. **VPN egress** — gluetun's public IP must differ from the host's.

**Plus the hardware transcode proof**, which is not in §7.2 but is the other
thing that lies when it fails: force a transcode and watch `intel_gpu_top` for
activity on the Video and VideoEnhance engines. If the CPU cores light up
instead, VAAPI fell back to software and the Jellyfin setting is telling you a
comfortable lie. Target is an i7-12700H (Alder Lake-P): enable the Intel
low-power H.264/HEVC encoder, and expect AV1 decode but not AV1 encode.

## Deliverables

1. Actual command output for all four §7.2 checks and the transcode proof —
   pasted, not summarised, and not a claim that you ran them.
2. `NOTES.md` updated: replace the "authored, not yet deployed" status block
   with what was actually verified and when. Correct anything bring-up proved
   wrong — that file was written blind and is the best guess of a session that
   could not run a single command.
3. Anything the contract got wrong, flagged for me rather than worked around.
   Both of v1's defects were found this way.
4. Commits per working milestone.
