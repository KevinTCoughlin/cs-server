#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Server health workflow: each configured port is queried, a challenge is
# completed on the same socket, and the issue opens, updates and closes from
# the set of ports that failed.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

WF="${ROOT}/.github/workflows/server-health.yml"
workflow=$(cat "${WF}")

assert_contains "health workflow reads the host variable" \
    "${workflow}" 'vars.CS_HEALTH_HOST'
assert_contains "health workflow defaults both game ports" \
    "${workflow}" "CS_HEALTH_PORTS || '27015 27016'"
assert_contains "health workflow can be run on demand" \
    "${workflow}" "workflow_dispatch:"
assert_contains "health workflow writes issues" \
    "${workflow}" "issues: write"
assert_contains "health workflow passes per-port detail" \
    "${workflow}" "steps.probe.outputs.detail"
assert_contains "health workflow still closes a recovered issue" \
    "${workflow}" "gh issue close"
dollar='$'
down_marker="port(s): **${dollar}{DOWN}**"
assert_contains "health workflow still names the failed ports" \
    "${workflow}" "${down_marker}"
assert_contains "health workflow still waits 6 hours between repeats" \
    "${workflow}" "21600"
assert_not_contains "health workflow pins no third-party action" \
    "${workflow}" "uses:"

# YAML's block scalar strips the run-step indent. The markers stay in the file
# and out of the script that actually runs.
extract_block() {
    local begin="$1" end="$2" dest="$3"
    awk -v begin="${begin}" -v end="${end}" '
        index($0, begin) { capture = 1; next }
        index($0, end) { capture = 0 }
        capture {
            sub(/^          /, "")
            print
        }
    ' "${WF}" > "${dest}"
}

extract_block "# cs-server-health-probe-begin" "# cs-server-health-probe-end" \
    "${WORK}/probe.py"
extract_block "# cs-server-health-issue-begin" "# cs-server-health-issue-end" \
    "${WORK}/issue.sh"

python3 -m py_compile "${WORK}/probe.py"
bash -n "${WORK}/issue.sh"
python3 "${ROOT}/tests/server_health_driver.py" "${WORK}/probe.py" "${WORK}"

# Issue open / update / close, with gh stubbed out.
STUB="${WORK}/bin"
mkdir -p "${STUB}"
cat > "${STUB}/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_LOG}"
jq_filter=""
args=("$@")
i=0
while [[ ${i} -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
        --jq)
            jq_filter="${args[$((i + 1))]}"
            i=$((i + 2))
            continue
            ;;
        --body)
            printf '%s\n' "${args[$((i + 1))]}" > "${GH_LAST_BODY}"
            i=$((i + 2))
            continue
            ;;
    esac
    i=$((i + 1))
done
cmd="${1:-}"
sub="${2:-}"
if [[ "${cmd}" == "label" ]]; then
    exit 0
fi
if [[ "${cmd}" == "issue" && "${sub}" == "list" ]]; then
    if [[ -z "${GH_OPEN_NUMBER:-}" ]]; then
        printf '[]\n' | jq -r "${jq_filter}"
    else
        printf '[{"number":%s}]\n' "${GH_OPEN_NUMBER}" | jq -r "${jq_filter}"
    fi
    exit 0
fi
if [[ "${cmd}" == "issue" && "${sub}" == "view" ]]; then
    jq -r "${jq_filter}" "${GH_VIEW_JSON}"
    exit 0
fi
if [[ "${cmd}" == "issue" && ( "${sub}" == "create" || "${sub}" == "comment" || "${sub}" == "close" ) ]]; then
    printf '%s\n' "${sub}" >> "${GH_ACTIONS}"
    exit 0
fi
printf 'stub gh: unhandled: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${STUB}/gh"

run_issue() {
    local number="$1" down="$2" detail="$3"
    : > "${WORK}/gh.log"
    : > "${WORK}/actions"
    : > "${WORK}/body"
    env -i PATH="${STUB}:/usr/bin:/bin" \
        GH_LOG="${WORK}/gh.log" \
        GH_LAST_BODY="${WORK}/body" \
        GH_ACTIONS="${WORK}/actions" \
        GH_OPEN_NUMBER="${number}" \
        GH_VIEW_JSON="${WORK}/view.json" \
        ISSUE_TITLE="Server down" \
        ISSUE_LABEL="server-down" \
        GITHUB_REPOSITORY="KevinTCoughlin/cs-server" \
        GITHUB_SERVER_URL="https://github.com" \
        GITHUB_RUN_ID="99" \
        CS_HOST="23.95.254.87" \
        CS_PORTS="27015 27016" \
        DOWN="${down}" \
        DETAIL="${detail}" \
        bash "${WORK}/issue.sh" > "${WORK}/issue.out" 2> "${WORK}/issue.err"
}

detail=$'- 27015 up: ScoutzKnivez, map scoutzknivez\n- 27016 down: no A2S_INFO or ping reply'

printf '%s\n' '{"comments":[]}' > "${WORK}/view.json"
run_issue "" "" "${detail}"
assert_eq "healthy run with no issue does nothing" "" "$(cat "${WORK}/actions")"

run_issue "41" "" "${detail}"
assert_contains "recovery comments" "$(cat "${WORK}/actions")" "comment"
assert_contains "recovery closes" "$(cat "${WORK}/actions")" "close"
assert_contains "recovery names every port" "$(cat "${WORK}/body")" "all of 27015 27016"
assert_contains "recovery keeps the per-port lines" "$(cat "${WORK}/body")" "ScoutzKnivez"
assert_not_contains "recovery is not a down comment" "$(cat "${WORK}/body")" "port(s):"

run_issue "" "27016" "${detail}"
assert_eq "first failure opens one issue" "create" "$(cat "${WORK}/actions")"
body=$(cat "${WORK}/body")
assert_contains "failure names the dead port" "${body}" "port(s): **27016**"
assert_contains "failure shows the live port" "${body}" "27015 up: ScoutzKnivez"
assert_contains "failure shows the dead port" "${body}" "27016 down: no A2S_INFO or ping reply"
assert_contains "failure still points at the run" "${body}" "actions/runs/99"

recent=$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
cat > "${WORK}/view.json" <<EOF
{"comments":[
  {"body":"Recovered at 2020-01-01 00:00 UTC","createdAt":"2020-01-01T00:00:00Z"},
  {"body":"Down at 2026-11-26 00:00 UTC: no A2S_INFO or ping reply from 23.95.254.87 on port(s): **27016** after 3 tries.","createdAt":"${recent}"}
]}
EOF
run_issue "41" "27016" "${detail}"
assert_eq "same ports inside 6 hours do not comment again" "" "$(cat "${WORK}/actions")"

old=$(date -u -d '8 hours ago' +%Y-%m-%dT%H:%M:%SZ)
cat > "${WORK}/view.json" <<EOF
{"comments":[
  {"body":"Down at 2026-11-26 00:00 UTC: no A2S_INFO or ping reply from 23.95.254.87 on port(s): **27016** after 3 tries.","createdAt":"${old}"}
]}
EOF
run_issue "41" "27016" "${detail}"
assert_eq "same ports after 6 hours comment again" "comment" "$(cat "${WORK}/actions")"

cat > "${WORK}/view.json" <<EOF
{"comments":[
  {"body":"Down at 2026-11-26 00:00 UTC: no A2S_INFO or ping reply from 23.95.254.87 on port(s): **27016** after 3 tries.","createdAt":"${recent}"}
]}
EOF
run_issue "41" "27015" "${detail}"
assert_eq "a different dead port comments" "comment" "$(cat "${WORK}/actions")"
assert_contains "the new dead port is named" "$(cat "${WORK}/body")" "port(s): **27015**"

cat > "${WORK}/view.json" <<EOF
{"comments":[
  {"body":"Down at 2026-11-26 00:00 UTC: no A2S_INFO or ping reply from 23.95.254.87 on port(s): **27015 27016** after 3 tries.","createdAt":"${recent}"}
]}
EOF
run_issue "41" "27015 27016" "${detail}"
assert_eq "both ports still down does not comment again" "" "$(cat "${WORK}/actions")"

echo "server health issue tests passed"
