#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
"""Exercise the server-health probe against local UDP peers.

The probe is the Python block extracted from .github/workflows/server-health.yml.
Nothing here contacts the public servers.
"""

import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

INFO_QUERY = b"\xff\xff\xff\xffTSource Engine Query\x00"
PING_QUERY = b"\xff\xff\xff\xffi"
CHALLENGE = b"\x00\x01\xff\x00"


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def info_packet(name, mapname, legacy=False):
    if legacy:
        return (
            b"\xff\xff\xff\xffm"
            + b"192.0.2.10:27015\x00"
            + name.encode("utf-8")
            + b"\x00"
            + mapname.encode("utf-8")
            + b"\x00"
        )
    return (
        b"\xff\xff\xff\xffI\x30"
        + name.encode("utf-8")
        + b"\x00"
        + mapname.encode("utf-8")
        + b"\x00"
        + b"cstrike\x00Counter-Strike\x00"
    )


def peer(mode, packet, ready, errors, stats):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    stats["port"] = sock.getsockname()[1]
    ready.set()
    sock.settimeout(0.2)
    deadline = time.time() + 8
    first_addr = None
    try:
        while time.time() < deadline:
            try:
                data, addr = sock.recvfrom(2048)
            except socket.timeout:
                if mode == "blackhole":
                    continue
                if stats.get("done"):
                    return
                continue
            if data.startswith(INFO_QUERY):
                stats["info"] = stats.get("info", 0) + 1
                if mode in ("blackhole", "ping-only"):
                    continue
                if mode == "flaky" and stats["info"] == 1:
                    continue
                if mode == "challenge":
                    if first_addr is None:
                        first_addr = addr
                    if addr != first_addr:
                        errors.append(
                            f"challenge follow-up came from {addr}, not {first_addr}"
                        )
                        return
                    if data == INFO_QUERY:
                        sock.sendto(b"\xff\xff\xff\xffA" + CHALLENGE, addr)
                        continue
                    if data != INFO_QUERY + CHALLENGE:
                        errors.append(f"challenge bytes dropped: {data!r}")
                        return
                    sock.sendto(packet, addr)
                    stats["done"] = True
                    return
                if mode == "challenge-drop":
                    if data == INFO_QUERY:
                        sock.sendto(b"\xff\xff\xff\xffA" + CHALLENGE, addr)
                    continue
                sock.sendto(packet, addr)
                stats["done"] = True
                return
            if data == PING_QUERY or data.startswith(PING_QUERY):
                stats["ping"] = stats.get("ping", 0) + 1
                if mode == "ping-only":
                    sock.sendto(b"\xff\xff\xff\xffj\x00", addr)
                    stats["done"] = True
                    return
    finally:
        sock.close()


def start_peer(mode, packet):
    ready = threading.Event()
    errors = []
    stats = {}
    thread = threading.Thread(
        target=peer,
        args=(mode, packet, ready, errors, stats),
        daemon=True,
    )
    thread.start()
    if not ready.wait(2):
        fail(f"{mode} peer did not bind")
    return thread, errors, stats


def parse_output(text):
    down = None
    detail = None
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.startswith("detail<<"):
            end = line.split("<<", 1)[1]
            body = []
            index += 1
            while index < len(lines) and lines[index] != end:
                body.append(lines[index])
                index += 1
            detail = "\n".join(body)
        elif line.startswith("down="):
            down = line.split("=", 1)[1]
        elif line.startswith("detail="):
            detail = line.split("=", 1)[1]
        index += 1
    return down, detail


def run_probe(probe, ports, output, tries="1", timeout="0.4", gap="0"):
    env = {
        "CS_HOST": "127.0.0.1",
        "CS_HEALTH_TRIES": tries,
        "CS_HEALTH_TIMEOUT": timeout,
        "CS_HEALTH_GAP": gap,
        "GITHUB_OUTPUT": str(output),
        "PATH": os.environ.get("PATH", ""),
    }
    if ports is not None:
        env["CS_PORTS"] = ports
    if output.exists():
        output.unlink()
    return subprocess.run(
        [sys.executable, str(probe)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def expect_up(name, proc, needle):
    if proc.returncode != 0:
        fail(f"{name}: exit {proc.returncode}\n{proc.stderr}\n{proc.stdout}")
    if needle not in proc.stdout:
        fail(f"{name}: stdout missing {needle!r}\n{proc.stdout}")


def main():
    if len(sys.argv) != 3:
        fail("usage: server_health_driver.py PROBE OUTPUT_DIR")
    probe = Path(sys.argv[1])
    work = Path(sys.argv[2])

    # Challenge with an embedded NUL, plus a direct info reply on another port.
    movement = info_packet("Slopes & Ladders | Surf + Climb", "kz_man_everest")
    scout = info_packet("ScoutzKnivez", "scoutzknivez")
    move_thread, move_errors, move_stats = start_peer("challenge", movement)
    scout_thread, scout_errors, scout_stats = start_peer("info", scout)
    out = work / "both.txt"
    proc = run_probe(
        probe,
        f"{move_stats['port']} {scout_stats['port']}",
        out,
    )
    move_thread.join(2)
    scout_thread.join(2)
    if move_errors or scout_errors:
        fail(f"peers: {move_errors} {scout_errors}")
    expect_up(
        "both up",
        proc,
        f"127.0.0.1:{move_stats['port']} up Slopes & Ladders | Surf + Climb (kz_man_everest)",
    )
    if f"127.0.0.1:{scout_stats['port']} up ScoutzKnivez (scoutzknivez)" not in proc.stdout:
        fail(f"scout name missing\n{proc.stdout}")
    down, detail = parse_output(out.read_text(encoding="utf-8"))
    if down != "":
        fail(f"both up should leave down empty, got {down!r}")
    if f"- {move_stats['port']} up: Slopes & Ladders | Surf + Climb, map kz_man_everest" not in detail:
        fail(f"movement detail missing\n{detail}")
    if move_stats.get("info") != 2:
        fail(f"challenge exchange should be two queries, got {move_stats}")
    print("ok: challenge with a NUL, then both ports up")

    # One port answers, the other never does. Only the silent port is down.
    good_thread, good_errors, good_stats = start_peer("info", scout)
    bad_thread, _bad_errors, bad_stats = start_peer("blackhole", b"")
    out = work / "partial.txt"
    proc = run_probe(
        probe,
        f"{good_stats['port']} {bad_stats['port']}",
        out,
    )
    good_thread.join(2)
    if good_errors:
        fail(f"partial peer: {good_errors}")
    if proc.returncode != 0:
        fail(f"partial exit {proc.returncode}: {proc.stderr}")
    down, detail = parse_output(out.read_text(encoding="utf-8"))
    if down != str(bad_stats["port"]):
        fail(f"partial down={down!r}, wanted only {bad_stats['port']}")
    if f"- {good_stats['port']} up: ScoutzKnivez, map scoutzknivez" not in detail:
        fail(f"partial missing the live port\n{detail}")
    if f"- {bad_stats['port']} down: no A2S_INFO or ping reply" not in detail:
        fail(f"partial missing the dead port\n{detail}")
    if "DOWN" not in proc.stdout:
        fail(f"partial stdout did not mark DOWN\n{proc.stdout}")
    bad_thread.join(0.2)
    print("ok: only the silent port is reported down")

    # Info is silent, ping answers.
    ping_thread, ping_errors, ping_stats = start_peer("ping-only", b"")
    out = work / "ping.txt"
    proc = run_probe(probe, str(ping_stats["port"]), out)
    ping_thread.join(2)
    if ping_errors:
        fail(f"ping peer: {ping_errors}")
    expect_up("ping fallback", proc, f"127.0.0.1:{ping_stats['port']} up (ping)")
    down, detail = parse_output(out.read_text(encoding="utf-8"))
    if down != "":
        fail(f"ping fallback counted as down: {down!r}")
    if f"- {ping_stats['port']} up: answered ping" not in detail:
        fail(f"ping detail missing\n{detail}")
    print("ok: A2A_PING fallback")

    # First info query is dropped; the retry gets a reply.
    flaky_thread, flaky_errors, flaky_stats = start_peer("flaky", scout)
    out = work / "flaky.txt"
    proc = run_probe(probe, str(flaky_stats["port"]), out, tries="2", gap="0")
    flaky_thread.join(2)
    if flaky_errors:
        fail(f"flaky peer: {flaky_errors}")
    expect_up("retry", proc, f"127.0.0.1:{flaky_stats['port']} up ScoutzKnivez")
    if flaky_stats.get("info", 0) < 2:
        fail(f"retry did not ask twice: {flaky_stats}")
    print("ok: a dropped query is retried")

    # A challenge with no follow-up info and no ping is down, not "any header".
    drop_thread, drop_errors, drop_stats = start_peer("challenge-drop", movement)
    out = work / "drop.txt"
    proc = run_probe(probe, str(drop_stats["port"]), out)
    drop_thread.join(1)
    if drop_errors:
        fail(f"challenge-drop peer: {drop_errors}")
    if proc.returncode != 0:
        fail(f"challenge-drop exit {proc.returncode}: {proc.stderr}")
    down, _detail = parse_output(out.read_text(encoding="utf-8"))
    if down != str(drop_stats["port"]):
        fail(f"unfinished challenge should be down, got {down!r}\n{proc.stdout}")
    print("ok: an unfinished challenge is not treated as up")

    # Legacy GoldSrc info (type m) counts, and the hostname is the second string.
    legacy = info_packet("Old Server", "de_dust", legacy=True)
    legacy_thread, legacy_errors, legacy_stats = start_peer("info", legacy)
    out = work / "legacy.txt"
    proc = run_probe(probe, str(legacy_stats["port"]), out)
    legacy_thread.join(2)
    if legacy_errors:
        fail(f"legacy peer: {legacy_errors}")
    expect_up("legacy info", proc, "up Old Server (de_dust)")
    print("ok: legacy GoldSrc info")

    # Unset CS_PORTS checks 27015 and 27016, and does not need a public host.
    # Bind both so a local process cannot answer and flip the result.
    holders = []
    for port in (27015, 27016):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.bind(("127.0.0.1", port))
            holders.append(sock)
        except OSError as exc:
            fail(f"could not hold 127.0.0.1:{port}: {exc}")
    out = work / "default.txt"
    proc = run_probe(probe, None, out, timeout="0.2")
    for sock in holders:
        sock.close()
    if proc.returncode != 0:
        fail(f"default ports exit {proc.returncode}: {proc.stderr}")
    down, detail = parse_output(out.read_text(encoding="utf-8"))
    if down != "27015 27016":
        fail(f"default down list is {down!r}\n{proc.stdout}")
    if "- 27015 down:" not in detail or "- 27016 down:" not in detail:
        fail(f"default detail missing a port\n{detail}")
    print("ok: unset CS_PORTS checks 27015 and 27016")

    # Configuration problems fail the step instead of opening an issue.
    missing = subprocess.run(
        [sys.executable, str(probe)],
        env={"PATH": os.environ.get("PATH", ""), "CS_PORTS": "27015"},
        capture_output=True,
        text=True,
        check=False,
    )
    if missing.returncode == 0 or "CS_HEALTH_HOST is unset" not in missing.stderr:
        fail(f"missing host should fail\n{missing.stderr}")
    bad = run_probe(probe, "nope", work / "bad.txt")
    if bad.returncode == 0 or "not a number" not in bad.stderr:
        fail(f"bad port should fail\n{bad.stderr}")
    print("ok: a broken configuration exits 1")

    # Silence an unused import warning if a slow peer is still winding down.
    time.sleep(0.05)
    print("server health probe tests passed")


if __name__ == "__main__":
    main()
