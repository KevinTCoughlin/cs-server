#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# ops/scripts/cs-records-export: TSV rows become records.json, comments and
# short rows are dropped the way movement.sma load_records() drops them, and
# a second run with the same lists does not rewrite the file. The records
# directory is only read. Nothing here talks to a game server.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

BIN="${ROOT}/ops/scripts/cs-records-export"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
REC="${WORK}/records"
OUT="${WORK}/out/records.json"
mkdir -p "${REC}" "${WORK}/out"

python3 - "${REC}" <<'PY'
import pathlib, sys
rec = pathlib.Path(sys.argv[1])
rec.joinpath("kz_sample.tsv").write_text(
    "\n".join([
        "# a comment",
        "",
        "   # indented comment",
        "pro\t12abc\t0\t0\t1700000008\tSTEAM_0:0:3\tPartial",
        'pro\t9050\t2\t0\t1700000000\tSTEAM_0:1:12345\tAda "A" <b>',
        "pro\t1\t2",
        "pro\t8000\t0\t0\t1700000002\tSTEAM_0:0:9\tOutOfOrder",
        "pro\t10000\t1\t0\t1700000003\tname:LAN\tLAN Player\textra",
        "pro\t10000\t0\t0\t1700000004\tSTEAM_0:0:4\tTied",
        "pro\t0\t0\t0\t1700000005\tSTEAM_0:0:5\tZero",
        "CP\t11000\t0\t0\t1700000006\tSTEAM_0:0:6\tUpper",
        "cp\t12000\t4\t2\t1700000007\tSTEAM_0:0:8\tBea",
        "cp\t13000\t1\t1\t1700000009\tSTEAM_0:0:11\tJosé",
        "",
    ]) + "\n",
    encoding="utf-8",
)
# A name the plugin could have written in the game's single-byte encoding.
rec.joinpath("latin_map.tsv").write_bytes(
    b"pro\t5000\t0\t0\t1700000011\tSTEAM_0:0:20\tCaf\xe9\n"
)
rec.joinpath("surf_lanes.tsv").write_text(
    "cp\t4520\t1\t1\t1700000010\tname:LAN\tSurf LAN\n",
    encoding="utf-8",
)
rec.joinpath("only_notes.tsv").write_text(
    "# just a comment\n\n   # indented\nshort row\npro\t0\t0\t0\t1\tSTEAM_0:0:1\tZero\n",
    encoding="utf-8",
)
lines = ["# full list"]
for i in range(1, 17):
    lines.append(f"pro\t{i * 100}\t0\t0\t1700000000\tSTEAM_0:0:{i}\tP{i:02d}")
rec.joinpath("kz_full.tsv").write_text("\n".join(lines) + "\n", encoding="utf-8")
rec.joinpath("notes.txt").write_text("NotAMap\n", encoding="utf-8")
rec.joinpath(".hidden.tsv").write_text(
    "pro\t4000\t0\t0\t1700000000\tSTEAM_0:0:1\tHidden\n",
    encoding="utf-8",
)
PY

fingerprint() {
    find "$1" -print | sort
    find "$1" -type f -print0 | sort -z | xargs -0 -r sha256sum
}

before=$(fingerprint "${REC}")

run_export() {
    local err="${WORK}/err"
    set +e
    output=$(env -u CS_RECORDS_DIR -u CS_RECORDS_OUT "$@" 2>"${err}")
    status=$?
    set -e
    err_text=$(cat "${err}")
}

run_export "${BIN}" --records "${REC}" --output "${OUT}"
[[ "${status}" -eq 0 ]] || fail "export failed: ${err_text}"
assert_contains "first run writes" "${output}" "wrote ${OUT}"
assert_eq "records directory was not modified" "${before}" "$(fingerprint "${REC}")"
tmp_left=$(find "${WORK}/out" -name '*.tmp' -print)
[[ -z "${tmp_left}" ]] || fail "temp file left behind: ${tmp_left}"

python3 - "${OUT}" <<'PY'
import json, sys
from datetime import datetime, timezone

doc = json.load(open(sys.argv[1], encoding="utf-8"))

def die(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)

server = doc["server"]
if server["name"] != "Slopes & Ladders | Surf + Climb":
    die("server name")
if server["addr"] != "23.95.254.87:27016":
    die("addr")
if server["connect"] != "connect 23.95.254.87:27016":
    die("connect")
if server["fastdl"] != "http://23.95.254.87:27080/cstrike/":
    die("fastdl")
if doc["disclaimer"] != "Times from this server only. Not official Kreedz or KZ-Rush records.":
    die("disclaimer")
if "sample" in doc or "note" in doc:
    die("live export must not be marked as sample data")
if not isinstance(doc["updated_at"], str) or len(doc["updated_at"]) != 20:
    die("updated_at shape: %r" % doc["updated_at"])

def at(unix):
    return datetime.fromtimestamp(unix, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

maps = doc["maps"]
if "only_notes" in maps or "notes" in maps or ".hidden" in maps:
    die("skipped files were exported: %s" % sorted(maps))
pro = maps["kz_sample"]["pro"]
cp = maps["kz_sample"]["cp"]
names = [row["name"] for row in pro]
if names != ["Partial", 'Ada "A" <b>', "LAN Player", "Tied", "Upper"]:
    die("pro names: %s" % names)
if any(row["name"] in {"OutOfOrder", "Zero", "Hidden", "NotAMap"} for row in pro + cp):
    die("dropped row was kept")
ada = pro[1]
if ada["player"] != "STEAM_0:1:12345" or ada["time_cs"] != 9050 or ada["time"] != "01:30.50":
    die("ada row: %s" % ada)
if ada["checkpoints"] != 2 or ada["teleports"] != 0 or ada["rank"] != 2:
    die("ada stats: %s" % ada)
if ada["at"] != at(1700000000):
    die("ada at: %s" % ada["at"])
lan = pro[2]
if lan["player"] != "name:LAN" or lan["name"] != "LAN Player" or lan["time"] != "01:40.00":
    die("LAN row: %s" % lan)
if pro[0]["time_cs"] != 12 or pro[0]["time"] != "00:00.12":
    die("partial digits: %s" % pro[0])
if pro[3]["time_cs"] != 10000 or pro[4]["name"] != "Upper":
    die("tie or uppercase category: %s" % pro)
if [row["name"] for row in cp] != ["Bea", "José"]:
    die("cp names: %s" % cp)
if cp[0]["teleports"] != 2 or cp[0]["checkpoints"] != 4 or cp[0]["time"] != "02:00.00":
    die("bea: %s" % cp[0])
if maps["latin_map"]["pro"][0]["name"] != "Café":
    die("latin-1 name: %s" % maps["latin_map"])
surf = maps["surf_lanes"]
if surf["pro"] or surf["cp"][0]["player"] != "name:LAN" or surf["cp"][0]["name"] != "Surf LAN":
    die("surf: %s" % surf)
full = maps["kz_full"]["pro"]
if len(full) != 15 or full[0]["name"] != "P01" or full[-1]["name"] != "P15":
    die("top 15: %s" % [row["name"] for row in full])
if full[-1]["rank"] != 15 or full[-1]["time_cs"] != 1500:
    die("15th row: %s" % full[-1])
if any(row["name"] == "P16" for row in full):
    die("16th row was kept")
print("json ok")
PY

hash1=$(sha256sum "${OUT}")
sleep 1.2
run_export "${BIN}" --records "${REC}" --output "${OUT}"
[[ "${status}" -eq 0 ]] || fail "second export failed: ${err_text}"
assert_contains "second run skips the rewrite" "${output}" "unchanged ${OUT}"
assert_eq "file bytes stay put when lists are unchanged" "${hash1}" "$(sha256sum "${OUT}")"
assert_eq "records directory stays unchanged after the second run" "${before}" "$(fingerprint "${REC}")"

# A hand-edited file with the same lists, a sample flag and a different
# timestamp is not rewritten, so the flag and the old updated_at survive.
python3 - "${OUT}" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
doc["sample"] = True
doc["note"] = "SAMPLE DATA"
doc["updated_at"] = "2000-01-01T00:00:00Z"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(doc, handle, indent=4, ensure_ascii=False)
    handle.write("\n")
PY
marked=$(sha256sum "${OUT}")
sleep 1.2
run_export "${BIN}" --records "${REC}" --output "${OUT}"
[[ "${status}" -eq 0 ]] || fail "marked file export failed: ${err_text}"
assert_contains "sample file with the same lists is left alone" "${output}" "unchanged ${OUT}"
assert_eq "marked file was not rewritten" "${marked}" "$(sha256sum "${OUT}")"

# A new row changes the file and the timestamp.
printf 'pro\t12000\t0\t0\t1700000099\tSTEAM_0:0:30\tNewcomer\n' >> "${REC}/kz_sample.tsv"
before=$(fingerprint "${REC}")
sleep 1.2
run_export "${BIN}" --records "${REC}" --output "${OUT}"
[[ "${status}" -eq 0 ]] || fail "export after a new row failed: ${err_text}"
assert_contains "a new row rewrites" "${output}" "wrote ${OUT}"
assert_eq "records directory stays read-only after a rewrite" "${before}" "$(fingerprint "${REC}")"
updated2=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["updated_at"])' "${OUT}")
[[ "${updated2}" != "2000-01-01T00:00:00Z" ]] || fail "updated_at was not refreshed"
python3 - "${OUT}" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
names = [row["name"] for row in doc["maps"]["kz_sample"]["pro"]]
if "Newcomer" not in names or "sample" in doc:
    print("FAIL: newcomer row: %s" % names, file=sys.stderr)
    sys.exit(1)
PY

# Missing records directory: do not create an empty JSON file.
home="${WORK}/home"
mkdir -p "${home}"
run_export env HOME="${home}" "${BIN}"
[[ "${status}" -ne 0 ]] || fail "missing records directory was accepted: ${output}"
assert_contains "missing directory is reported" "${err_text}" "records directory not found"
[[ ! -e "${home}/.local/share/cs-server/records.json" ]] || fail "missing directory still wrote JSON"
[[ ! -d "${home}/.local/share/containers/storage" ]] || fail "missing directory was created"

# Refuse to write the JSON into the records directory.
run_export "${BIN}" --records "${REC}" --output "${REC}/records.json"
[[ "${status}" -ne 0 ]] || fail "write inside the records directory was accepted"
assert_contains "inside write is refused" "${err_text}" "refusing to write inside the records directory"
[[ ! -e "${REC}/records.json" ]] || fail "JSON was written into the records directory"

# A records file that cannot be read fails without replacing a good export.
if [[ "$(id -u)" -ne 0 ]]; then
    good=$(sha256sum "${OUT}")
    chmod 000 "${REC}/kz_sample.tsv"
    run_export "${BIN}" --records "${REC}" --output "${OUT}"
    chmod 644 "${REC}/kz_sample.tsv"
    [[ "${status}" -ne 0 ]] || fail "unreadable TSV was accepted"
    assert_eq "failed read leaves the previous JSON" "${good}" "$(sha256sum "${OUT}")"
    tmp_left=$(find "${WORK}/out" -name '*.tmp' -print)
    [[ -z "${tmp_left}" ]] || fail "temp file left after a failed read: ${tmp_left}"
fi

# Parent of the output is not a directory: the previous JSON stays.
blocker="${WORK}/blocker"
printf 'keep\n' > "${blocker}"
run_export "${BIN}" --records "${REC}" --output "${blocker}/records.json"
[[ "${status}" -ne 0 ]] || fail "output under a file was accepted"
assert_eq "blocker file was not replaced" "keep" "$(cat "${blocker}")"

# --- Units, page, workflow ---------------------------------------------------

service=$(cat "${ROOT}/ops/systemd/cs-records-export.service")
timer=$(cat "${ROOT}/ops/systemd/cs-records-export.timer")
assert_contains "service is a oneshot" "${service}" "Type=oneshot"
assert_contains "service runs the exporter" "${service}" "ExecStart=%h/.local/bin/cs-records-export"
assert_contains "service reads the movement volume" "${service}" "cs-server-state-movement/_data/amxmodx/records"
assert_contains "service writes records.json beside the home directory" "${service}" "CS_RECORDS_OUT=%h/.local/share/cs-server/records.json"
assert_not_contains "service does not call systemctl" "${service}" "systemctl"
assert_not_contains "service does not call podman" "${service}" "podman"
assert_not_contains "service does not call docker" "${service}" "docker"
assert_not_contains "service does not restart itself" "${service}" $'\nRestart='
assert_not_contains "service does not name the game unit" "${service}" "scoutzknivez"
assert_contains "timer is every 10 minutes" "${timer}" "OnCalendar=*:0/10"
assert_contains "timer starts the export service" "${timer}" "Unit=cs-records-export.service"
assert_contains "timer is a user timer" "${timer}" "WantedBy=timers.target"
assert_not_contains "timer does not call systemctl" "${timer}" "systemctl"
assert_not_contains "timer does not call podman" "${timer}" "podman"
assert_not_contains "timer does not name the game unit" "${timer}" "scoutzknivez"
if command -v systemd-analyze >/dev/null 2>&1; then
    calendar=$(systemd-analyze calendar -- '*:0/10')
    assert_contains "calendar is every 10 minutes" "${calendar}" "*-*-* *:00/10:00"
fi

script=$(cat "${BIN}")
assert_not_contains "exporter does not call systemctl" "${script}" "systemctl"
assert_not_contains "exporter does not call podman" "${script}" "podman"
assert_not_contains "exporter does not call docker" "${script}" "docker"
assert_not_contains "exporter does not import subprocess" "${script}" "subprocess"

page=$(cat "${ROOT}/docs/records/index.html")
assert_contains "page fetches the local JSON" "${page}" 'fetch("./records.json"'
assert_eq "page fetches only that JSON" "1" "$(grep -c 'fetch(' "${ROOT}/docs/records/index.html")"
assert_contains "page has the empty state" "${page}" "No times yet."
assert_contains "page names the two lists" "${page}" "With checkpoints"
assert_contains "footer notes LAN demos" "${page}" "Official world records are LAN demos."
assert_contains "footer links the repo" "${page}" "https://github.com/KevinTCoughlin/cs-server"
assert_contains "page uses the site background" "${page}" "--bg:#0b0c0f"
assert_contains "page uses the site accent" "${page}" "--accent:#ff9a1f"
assert_contains "page is phone-width aware" "${page}" 'name="viewport"'
assert_not_contains "page does not fetch the FastDL tree" "${page}" "docs/cstrike"

sample=$(cat "${ROOT}/docs/records/records.json")
assert_contains "sample is marked" "${sample}" '"sample": true'
assert_contains "sample note says so" "${sample}" "SAMPLE DATA"
assert_contains "sample has a LAN player key" "${sample}" '"player": "name:LAN"'
python3 - "${ROOT}/docs/records/records.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
if doc["server"]["connect"] != "connect 23.95.254.87:27016":
    sys.exit("sample connect string")
if doc["disclaimer"] != "Times from this server only. Not official Kreedz or KZ-Rush records.":
    sys.exit("sample disclaimer")
if "kz_sample" not in doc["maps"] or "surf_sample" not in doc["maps"]:
    sys.exit("sample maps")
PY

if find "${ROOT}/docs/cstrike" -name 'records.json' -print -quit | grep -q .; then
    fail "records.json must not live under docs/cstrike"
fi

pages=$(cat "${ROOT}/.github/workflows/pages.yml")
assert_contains "pages builds the docs tree" "${pages}" "source: ./docs"
assert_contains "pages checks the records html" "${pages}" "test -s _site/records/index.html"
assert_contains "pages checks the records json" "${pages}" "test -s _site/records/records.json"

readme=$(cat "${ROOT}/README.md")
assert_contains "readme links the records page" "${readme}" "https://kevintcoughlin.com/cs-server/records/"
assert_contains "readme has the one-line enable" "${readme}" "systemctl --user enable --now cs-records-export.timer"
assert_contains "readme installs the exporter" "${readme}" "install -Dm755 ops/scripts/cs-records-export ~/.local/bin/cs-records-export"

echo "records export tests passed"
