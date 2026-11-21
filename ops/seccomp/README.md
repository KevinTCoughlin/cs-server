# Seccomp profile for Docker

`docker-default.json` is Docker's own default seccomp profile, unchanged,
from [moby/profiles](https://github.com/moby/profiles/blob/9ee3204f0d0cfa19ca2c6a7b0fcf5a2b353954ae/seccomp/default.json)
(commit `9ee3204f0d0c`, Apache-2.0).

Why ship a copy of the default: the profile built into Docker 29 (seen with
29.4.2) answers the 32-bit `socket()` call of the i386 HLDS binary with
`ENOSYS`, so the server cannot open its port. The upstream profile at this
commit does not have that fault. Passing it as a file gives the server
Docker's intended default confinement instead of `seccomp=unconfined`, which
is what this project used before.

Used by `compose.yml`, `install.sh` (Docker path; the file is read out of the
image, where it is `/usr/local/share/cs-server/seccomp.json`),
`tests/e2e_test.sh` and the CI smoke test. Podman's default profile does not
have the fault, so the Quadlet unit sets none.

```bash
docker run -d --security-opt seccomp=ops/seccomp/docker-default.json ... ghcr.io/kevintcoughlin/cs-server:latest
```

To refresh: download the file again from a newer moby/profiles commit, update
the commit above, and let CI run (the smoke and end-to-end tests start the
server under it on amd64 and arm64). Drop the copy once a fixed Docker is
common; the image then runs under the built-in default.
