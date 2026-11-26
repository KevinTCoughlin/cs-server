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
`ghcr.io/kevintcoughlin/cs-server:main`, which the image workflow publishes
on a push to `main` together with `:sha-<7 character commit>`. It pins
`:sha-<7>@sha256:<digest>` only when that commit's GitHub checks are green,
the commit message does not contain `[skip deploy]` or `[manual]`, and no
human is on a listed port. `CHANNEL=release` follows the latest stable GitHub
release instead. See the README section "On-box rollout".

The image workflow is path-filtered, so a commit that does not change the
server does not move `:main`. Podman auto-update is not used: a digest pin
does not move, and this timer is what rolls a new digest on purpose.

## Still done by hand

| Thing | Why it is not in the bootstrap |
| --- | --- |
| Movement server image | The box runs `localhost/cs-server:movement-cfd95fa`. The Quadlet templates use `localhost/cs-server:movement`. Retag the loaded image, or set both `Image=` lines to the sha tag. CI does not build or publish it. The config directory is backed up (`config-cs-server-movement-*.tar.gz`). The image itself is not. [`quadlet/cs-server-movement.container`](../quadlet/cs-server-movement.container) (`MODE=auto`, `mapcycle-movement.txt`, `27016/udp`) and [`quadlet/cs-fastdl-movement.container`](../quadlet/cs-fastdl-movement.container) share one `Image=` line: repoint both together. |
| Movement FastDL | Copy both Quadlets into `~cs/.config/containers/systemd/`, replace `HOST` in `FASTDL_URL` with the public address, and run the bootstrap with `CS_FASTDL=1` so `27080/tcp` is opened with the per-source limits (40 new connections a second, burst 80, at most 60 connections). The sidecar serves every map in that image, including manifest rows with `fastdl=no`, the same as the game server's own download. `just fastdl` (GitHub Pages) still skips those maps. |
| Provider panel | Hostname, firewall in front of the VM, rDNS, and the console live in the provider panel. A new VPS has a new address. |
| DNS and listings | Every place that names the public address: FastDL URL, the website, server-browser listings, `connect` strings, and `CS_HEALTH_HOST`. |
| `authorized_keys` | Only the key passed to `--ssh-key` is installed. Extra keys, including a rollout key, are copied by hand. |
| SSH host keys | Do not restore the old keys onto a new machine. Generate new ones (`--regenerate-host-keys` on a template image). |
| Off-site credentials | The four `OFFSITE_*` values. The script and the drop-in ship; the secret does not. |
| fail2ban incremental bans | Not part of this repository. The bootstrap enables the sshd jail only. |
