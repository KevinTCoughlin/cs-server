# Seccomp profile kept for older installers

Nothing in this repository passes a seccomp profile any more: Docker and
Podman run the server under their own built-in profiles.

`docker-default.json` is Docker's default profile, unchanged, from
[moby/profiles](https://github.com/moby/profiles/blob/9ee3204f0d0cfa19ca2c6a7b0fcf5a2b353954ae/seccomp/default.json)
(commit `9ee3204f0d0c`, Apache-2.0). The image still carries it as
`/usr/local/share/cs-server/seccomp.json` for one reason: `install.sh` from
1.1.0 to 1.4.0 reads it out of the image for `docker run`, and falls back to
`seccomp=unconfined` when an image has none. Keeping the file means such an
installer, run against a newer image, still confines the server.

**Remove it** (this directory, the `COPY` in the Containerfile and the check
in `tests/mounts_test.sh`) once installers that old are no longer a concern;
1.6.0 is a reasonable point.

## Why it was needed

Docker Engine **29.4.2** (2026-05-01) blocked the `socketcall(2)` system call
in its built-in profile as a mitigation for CVE-2026-31431. 32-bit programs
open sockets through that call, so the i386 game server could not open its
port (`UDP_OpenSocket … Function not implemented`). Reported as
[moby/moby#52506](https://github.com/moby/moby/issues/52506) and undone in
**29.4.3** (2026-05-06, [moby/moby#52537](https://github.com/moby/moby/pull/52537)).
Only 29.4.2 is affected; `install.sh` refuses to install on it and names the
fix.

`.github/workflows/docker-latest.yml` starts the published image on the newest
Docker Engine under the built-in profile every week, so a repeat shows up
there. The hosted runners' own Docker (28.0.4 when this was written) predates
the fault.
