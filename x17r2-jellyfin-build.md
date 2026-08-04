# Alienware x17 R2 → Jellyfin Appliance

Target: headless, single-purpose, wired, QuickSync transcoding, dGPU asleep.

---

## 1. BIOS (do this first)

| Setting | Value | Why |
|---|---|---|
| Graphics mode | **Hybrid / Optimus** (not discrete-only) | Discrete-only disables the iGPU and QuickSync disappears |
| AC power recovery | **On** | Comes back by itself after an outage |
| Battery charge configuration | **Primarily AC Use** | Charge ceiling; persists without AWCC |
| Secure Boot | Off | Removes a class of driver-signing annoyances you don't need |
| Wake on lid open / USB wake | Off | It's headless |

---

## 2. Distro

**Default: Debian 13 (trixie).** Kernel 6.12 has mature Alder Lake `i915` support, `non-free-firmware` is in the default installer, and stable means the box doesn't change under you.

Install with **no desktop environment** — just "SSH server" and "standard system utilities". Do not install the NVIDIA driver.

**Alternative: NixOS.** For a single-purpose appliance this is arguably the better fit given your background — the entire server becomes one `configuration.nix` you can version, roll back, and rebuild on different hardware. Real cost: the `nixos-hardware`/`i915` + VAAPI path takes an evening more than `apt install`, and OCI containers via `virtualisation.oci-containers` are slightly less copy-pasteable from community guides. If the box's job is to be boring, take Debian. If you'd enjoy the box being declarative, take NixOS.

---

## 3. Disk layout

The 2TB NVMe is the *system* drive, not the library.

```
/               100 GB   ext4     OS
/data           rest     ext4     containers, configs, download staging
```

Media library lives on external/second-slot storage, mounted **under `/data`** — see §5.

Put the transcode cache in RAM. You have 32 GB; give it 8:

```
# /etc/fstab
tmpfs  /data/transcode  tmpfs  defaults,size=8G,uid=1000,gid=1000,mode=0775  0 0
```

That eliminates the single largest source of NVMe write wear on a media server.

---

## 4. Host prep

```bash
# QuickSync userspace. The "non-free" iHD driver is REQUIRED for HEVC/VP9 encode.
sudo apt install intel-media-va-driver-non-free vainfo intel-gpu-tools

vainfo | grep -E 'VAProfile(H264|HEVC|VP9|AV1)'
# Expect: H264/HEVC/VP9 Enc+Dec, HEVC Main10 Enc+Dec, AV1 Dec only.

# Note the render group GID — you need it in compose.
getent group render
```

Keep the dGPU asleep. Install no NVIDIA driver and confirm it drops to D3cold:

```bash
sudo apt install powertop
cat /sys/bus/pci/devices/0000:01:00.0/power_state   # want D3cold
```

That's worth 10–15 W continuous.

Never sleep:

```bash
sudo sed -i 's/^#*HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/^#*HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
sudo systemctl restart systemd-logind
```

Wired networking: the Killer E3100G is RTL8125 silicon, driven by in-tree `r8169`. Set a DHCP reservation on the router. Don't serve over WiFi.

---

## 5. The one thing people get wrong: path layout

Automation tools hardlink or atomically move completed downloads into the library. Both require **source and destination on the same filesystem, exposed to every container under the same path**. Get this wrong and every import becomes a slow full copy that doubles your disk usage and breaks seeding.

Single mount root, mapped identically everywhere:

```
/data
├── torrents/{movies,tv}
├── usenet/{incomplete,complete}
└── media/{movies,tv}
```

In every container: `- /data:/data`. Not `/movies`, not `/downloads`. One volume, one path.

Create a shared service account so all containers agree on ownership:

```bash
sudo useradd -r -s /usr/sbin/nologin -u 1000 media
sudo mkdir -p /data/{torrents,usenet,media,transcode}
sudo chown -R media:media /data
sudo chmod -R 775 /data
```

Set `umask 002` in the *arr apps so group-writable is preserved.

---

## 6. Stack

`/opt/stack/compose.yaml`:

```yaml
x-env: &env
  PUID: 1000
  PGID: 1000
  TZ: America/New_York
  UMASK: "002"

services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    network_mode: host          # needed for DLNA + client auto-discovery
    user: "1000:1000"
    group_add:
      - "104"                   # <-- replace with your `getent group render` GID
    devices:
      - /dev/dri:/dev/dri
    volumes:
      - /opt/stack/jellyfin/config:/config
      - /opt/stack/jellyfin/cache:/cache
      - /data:/data
      - /data/transcode:/transcode
    restart: unless-stopped

  prowlarr:                     # indexer manager — configure this first
    image: lscr.io/linuxserver/prowlarr:latest
    environment: *env
    volumes: ["/opt/stack/prowlarr:/config"]
    ports: ["9696:9696"]
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    environment: *env
    volumes: ["/opt/stack/sonarr:/config", "/data:/data"]
    ports: ["8989:8989"]
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    environment: *env
    volumes: ["/opt/stack/radarr:/config", "/data:/data"]
    ports: ["7878:7878"]
    restart: unless-stopped

  bazarr:                       # subtitles
    image: lscr.io/linuxserver/bazarr:latest
    environment: *env
    volumes: ["/opt/stack/bazarr:/config", "/data:/data"]
    ports: ["6767:6767"]
    restart: unless-stopped

  jellyseerr:                   # family-facing request UI
    image: fallenbagel/jellyseerr:latest
    environment: *env
    volumes: ["/opt/stack/jellyseerr:/app/config"]
    ports: ["5055:5055"]
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    environment:
      <<: *env
      WEBUI_PORT: 8080
    volumes: ["/opt/stack/qbittorrent:/config", "/data:/data"]
    network_mode: "service:gluetun"
    depends_on: [gluetun]
    restart: unless-stopped

  gluetun:                      # VPN + killswitch for the download client only
    image: qmcgaw/gluetun:latest
    cap_add: [NET_ADMIN]
    devices: ["/dev/net/tun:/dev/net/tun"]
    environment:
      VPN_SERVICE_PROVIDER: "your-provider"
      VPN_TYPE: wireguard
      # WIREGUARD_PRIVATE_KEY / WIREGUARD_ADDRESSES / SERVER_COUNTRIES
    ports: ["8080:8080"]        # qBittorrent WebUI surfaces here
    restart: unless-stopped
```

If you're on usenet instead of torrents, swap qBittorrent + gluetun for a single `sabnzbd` container — no VPN plumbing needed, and it's a materially simpler stack.

**Setup order:** Prowlarr (add indexers) → Sonarr/Radarr (add root folders `/data/media/tv`, `/data/media/movies`; add download client; Prowlarr syncs indexers to both) → Jellyfin (libraries point at `/data/media/*`) → Jellyseerr (connects to Jellyfin + Sonarr/Radarr).

---

## 7. Jellyfin transcode settings

Dashboard → Playback → Transcoding:

- Hardware acceleration: **Video Acceleration API (VAAPI)**
- Device: `/dev/dri/renderD128`
- Enable decode for: H264, HEVC, VP9, AV1
- Enable **Intel Low-Power H.264/HEVC encoder** — significantly lower power on Alder Lake
- Enable hardware tone mapping (VPP)
- Transcode path: `/transcode`

Verify it's actually working: start a forced transcode, then `sudo intel_gpu_top` — you want activity on the Video/VideoEnhance engines. If the CPU cores light up instead, VAAPI silently fell back to software.

Then set the goal to *never see that screen again*: a client that direct-plays (Shield, recent Google TV, Apple TV + Infuse) means the server just serves bytes.

---

## 8. Access and security

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
```

Tailscale on the **host**, not in a container. Then:

```bash
sudo ufw default deny incoming
sudo ufw allow in on tailscale0
sudo ufw allow from 192.168.0.0/16 to any port 8096 proto tcp   # LAN Jellyfin
sudo ufw allow from 192.168.0.0/16 to any port 22 proto tcp
sudo ufw enable
```

Admin UIs (9696/8989/7878/8080) stay reachable only over `tailscale0`. Nothing port-forwarded from the router — Jellyfin has no native rate limiting or MFA and is not built to sit on the open internet.

---

## 9. Maintenance

```bash
sudo apt install unattended-upgrades smartmontools restic
```

- Pin container image tags rather than `:latest` once the stack is stable; update deliberately, not automatically.
- `smartd` on the media disk — external enclosures fail more often than the drives in them.
- Back up `/opt/stack/*/config` with restic. The media is re-acquirable; your users, watch history, and *arr configuration are not.
- Recyclarr is worth adding later to keep quality profiles in sync with TRaSH Guides.
