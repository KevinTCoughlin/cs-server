# Rebuilding the CS VPS

A fresh Debian 13 VPS, back to the public Counter-Strike server, from this
repository. Addresses, image digests, and extra ports are variables. Nothing
here is a specific host.

## What one bootstrap recreates

As root, with the operator's SSH public key:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/ops/bootstrap-vps.sh \
  | sudo bash -s -- --ssh-key "ssh-ed25519 AAAA... you@host"
```

That creates the deploy user (`cs` unless `--user` says otherwise), installs
Podman on Debian 13, fail2ban's sshd jail, unattended-upgrades that do not
reboot on their own, sysctl (`vm.swappiness=10` and the hardening file),
journald limits, an sshd OOM score of -900, the `cs` admin helper and the
login banner, the player-aware reboot timer, the nftables rules, and then
runs `install.sh` as that user. The Quadlet image is pinned to the digest of
the image just pulled, with `LOG_RETENTION_DAYS=30` and
`--oom-score-adj=500`. Daily state backups, a monthly restore test, and the
on-box rollout timer (`cs-server-update`, `CHANNEL=main`) are installed.
`CS_DOD=1` adds Day of Defeat on `27016/udp`.

After a second terminal can log in with a key:

```bash
sudo bash ops/bootstrap-vps.sh --harden-ssh
```

Password login turns off. Root key login stays. Add `--nopasswd-sudo` only
when the deploy user should be the admin and root SSH should turn off.

If `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` shows a provider
template comment (`nerdvm.com`), pass `--regenerate-host-keys` once. Clients
see a new fingerprint. The bootstrap warns when it sees that comment.

Set the repository variable `CS_HEALTH_HOST` to the new public IPv4 so the
uptime workflow has somewhere to send A2S. `CS_HEALTH_PORTS` is an optional
space-separated list of UDP ports. When it is unset, the check queries
`27015` and `27016`.

## What backups restore

`cs-server-backup` archives Podman volumes `cs-server-state*`,
`dod-server-state*`, and the matching config directories under
`~/.config` (`config-<name>-<utc>.tar.gz`). `offsite.env` is not in those
archives. Stop the server, then:

```bash
cs-server-backup --restore ~/cs-server-backups/cs-server-state-<utc>.tar.gz
cs-server-backup --restore ~/cs-server-backups/config-cs-server-<utc>.tar.gz
```

Off-site copies run only after `~/.config/cs-server/offsite.env` exists and
is mode 0600. The bucket and the token are created by hand.

## On-box rollout

`~cs/.config/cs-server/update.env` sets `CHANNEL=main`. The timer pulls
`ghcr.io/kevintcoughlin/cs-server:main` for the Counter-Strike unit, and the
`:main` tag of every other repository named in `update.units`. The image
workflows publish those tags on a push to `main` together with a
`:sha-<7 character commit>` tag. A unit is pinned to
`:sha-<7>@sha256:<digest>` only when that commit's GitHub checks are green,
the commit message does not contain `[skip deploy]` or `[manual]`, and no
human is on a listed port. `CHANNEL=release` follows the latest stable GitHub
release instead. See the README section "On-box rollout".

The image workflows are path-filtered, so a commit that does not change the
server does not move `:main`. Podman auto-update is not used: a digest pin
does not move, and this timer is what rolls a new digest on purpose.

`update.units` can name more than one image. The movement repository is
`ghcr.io/kevintcoughlin/cs-server-movement` (`:main`, `:sha-<7>`, and the
release version tags). A sidecar listed on that line is pinned to the same
digest and restarted in the same step; if the game port does not answer,
both go back.

## Still done by hand

| Thing | Why it is not in the bootstrap |
| --- | --- |
| Movement server image | CI publishes `ghcr.io/kevintcoughlin/cs-server-movement` (`:main`, `:sha-<7>`, and release version tags). It is the Counter-Strike build plus only the movement maps `scripts/cleared-maps.sh` lists. None of the current climb or surf maps are on that list, so `:main` does not contain them. The server reads those files from `~/cs-maps` (`/home/cs/cs-maps` for user `cs`). See "Movement maps from the host" below. |
| Movement FastDL | [`quadlet/cs-fastdl-movement.container`](../quadlet/cs-fastdl-movement.container) mounts the same `~/cs-maps` at `/maps-local` and serves a host file only when `maps/manifest.tsv` says `fastdl=yes`. The four climb maps (`kz_man_everest`, `bkz_goldbhop`, `bkz_toonworld`, `kz_climbers_b01`) stay off FastDL, and so does every other `fastdl=no` row. Players download those through the game connection. `27080/tcp` is the per-source limit from `CS_FASTDL=1` (40 new connections a second, burst 80, at most 60 connections). |
| Provider panel | Hostname, firewall in front of the VM, rDNS, and the console live in the provider panel. A new VPS has a new address. |
| DNS and listings | Every place that names the public address: FastDL URL, the website, server-browser listings, `connect` strings, and `CS_HEALTH_HOST`. |
| `authorized_keys` | Only the key passed to `--ssh-key` is installed. Extra keys, including a rollout key, are copied by hand. |
| SSH host keys | Do not restore the old keys onto a new machine. Generate new ones (`--regenerate-host-keys` on a template image). |
| Off-site credentials | The four `OFFSITE_*` values. The script and the drop-in ship; the secret does not. |
| fail2ban incremental bans | Not part of this repository. The bootstrap enables the sshd jail only. |

## Movement maps from the host

`~/cs-maps` is the host directory for maps the published image does not
contain. On this VPS that is `/home/cs/cs-maps`, owned by user `cs`, mode
`755` on directories and `644` on files so the rootless container user can
read them. Layout:

```text
/home/cs/cs-maps/maps/<name>.bsp
/home/cs/cs-maps/sound/  sprites/  models/  gfx/  overviews/
/home/cs/cs-maps/<name>.wad
```

The game unit bind-mounts the tree at `/maps-local` and each file onto its
path under `/hlds/cstrike` (a `.bsp` lands in `maps/`). Stock and baked files
stay where they are. The FastDL unit mounts only `/maps-local`. It does not
get those per-file mounts. `fastdl.sh` adds a host file to the HTTP tree only
when the manifest row is `fastdl=yes`.

`just fetch-maps-host` (or `bash scripts/fetch-maps-host.sh`) fills the
directory from `maps/manifest.tsv` for the movement rotation. Each download
is checked against its pinned SHA-256 before it is written. A later run
re-extracts from that checked archive. `MAPS_HOST` picks another directory.

A missing directory, or a `maps/` with no `.bsp`, makes the entrypoint and
the sidecar exit 1. The log names `~/cs-maps` and `just fetch-maps-host`.

### Roll the movement server onto current main

Do this after the image that contains this host-map support is on `:main`.
Do not copy the Quadlet templates over the live units: that would replace
the pinned `Image=` and the real `FASTDL_URL`. The commands below add the
mounts and leave those lines as they are. Nothing here restarts a server
until the `cs-server-update --now` line.

Packages first, as root:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl unzip git
```

Then open a shell as `cs` (`sudo -iu cs`) and run:

```bash
git clone --depth 1 https://github.com/KevinTCoughlin/cs-server.git ~/src/cs-server
cd ~/src/cs-server
bash scripts/fetch-maps-host.sh
# Expect nine .bsp files under /home/cs/cs-maps/maps, and a line that the
# download checksums verified. If the script prints extra Volume= lines,
# a map shipped a file the unit does not mount yet. Add those lines to
# cs-server-movement.container only, inside the maps-local block.
bash scripts/overlay-host-maps.sh install-unit \
  ~/.config/containers/systemd/cs-server-movement.container
bash scripts/overlay-host-maps.sh install-unit --fastdl \
  ~/.config/containers/systemd/cs-fastdl-movement.container
systemctl --user daemon-reload
```

Confirm `update.units` has the movement line uncommented:

```text
cs-server-movement 27016 ghcr.io/kevintcoughlin/cs-server-movement cs-fastdl-movement
```

Roll both units to the current `:main` digest. This restarts the movement
server and the sidecar when the digest changes. It does not touch the
Counter-Strike server on 27015 unless that image also moved.

```bash
/home/cs/.local/bin/cs-server-update --dry-run
/home/cs/.local/bin/cs-server-update --now
```

Verify, still as `cs`:

```bash
systemctl --user is-active cs-server-movement cs-fastdl-movement
podman exec cs-server-movement test -f /hlds/cstrike/maps/kz_man_everest.bsp
podman exec cs-server-movement test -f /hlds/cstrike/maps/surf_ski_5.bsp
podman exec cs-server-movement test -f /hlds/cstrike/maps/de_dust2.bsp
podman logs --tail 30 cs-server-movement
# The log should name the host map it started on, not "none of the maps".
podman exec cs-fastdl-movement /fastdl.sh check
# 200 for a baked map, 404 for the four climb maps and the surf maps
# while they remain fastdl=no:
podman exec cs-fastdl-movement bash -c 'exec 3<>/dev/tcp/127.0.0.1/27080 && printf "HEAD /cstrike/maps/scoutzknivez.bsp HTTP/1.0\r\n\r\n" >&3 && head -1 <&3'
podman exec cs-fastdl-movement bash -c 'exec 3<>/dev/tcp/127.0.0.1/27080 && printf "HEAD /cstrike/maps/kz_man_everest.bsp HTTP/1.0\r\n\r\n" >&3 && head -1 <&3'
podman exec cs-fastdl-movement bash -c 'exec 3<>/dev/tcp/127.0.0.1/27080 && printf "HEAD /cstrike/maps/bkz_goldbhop.bsp HTTP/1.0\r\n\r\n" >&3 && head -1 <&3'
podman exec cs-fastdl-movement bash -c 'exec 3<>/dev/tcp/127.0.0.1/27080 && printf "HEAD /cstrike/maps/bkz_toonworld.bsp HTTP/1.0\r\n\r\n" >&3 && head -1 <&3'
podman exec cs-fastdl-movement bash -c 'exec 3<>/dev/tcp/127.0.0.1/27080 && printf "HEAD /cstrike/maps/kz_climbers_b01.bsp HTTP/1.0\r\n\r\n" >&3 && head -1 <&3'
```

`scoutzknivez.bsp` answers `200`. Each climb map answers `404`. A connect
to port 27016 should land on the first map of `mapcycle-movement.txt` that
is now on disk (`kz_man_everest`).

Re-enable the rollout timer (it is disabled on this box):

```bash
systemctl --user enable --now cs-server-update.timer
systemctl --user is-enabled cs-server-update.timer
```

After the movement units are on the new digest and no unit file still
mentions `sha-dfd9221`, delete that package version. It is the movement
image that contained uncleared maps. Do not delete a version whose tags
include `main`.

```bash
gh api --paginate \
  "/users/KevinTCoughlin/packages/container/cs-server-movement/versions" \
  --jq '.[] | {id, tags: .metadata.container.tags}'
# Pick the id whose tags include sha-dfd9221 and do not include main.
gh api --method DELETE \
  -H "Accept: application/vnd.github+json" \
  "/users/KevinTCoughlin/packages/container/cs-server-movement/versions/VERSION_ID"
```
