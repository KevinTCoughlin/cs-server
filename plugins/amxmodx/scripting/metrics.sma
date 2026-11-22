// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
//
// Server metrics in Prometheus text format, for any game.
//
// Every metrics_interval seconds (default 5) the plugin rewrites
// addons/amxmodx/data/metrics.prom, which the image links to
// /hlds/.runtime/metrics.prom (a tmpfs). entrypoint.sh serves that file over
// HTTP when METRICS_PORT is set (scripts/metrics.pl); without it the file is
// still there for `podman exec <name> cat /hlds/.runtime/metrics.prom`.
//
// The numbers come from the game itself, so they are the same with and
// without Steam (NOMASTER=1), where the server-browser query goes unanswered.
//
//   hlds_players{type="human"|"bot"}   connected clients
//   hlds_max_players                   slots
//   hlds_map_info{map="..."}           1 for the running map
//   hlds_map_seconds                   time on this map
//   hlds_uptime_seconds                time since the server's first map
//   hlds_server_fps                    frames per second over the interval
//                                      (metrics_fps 0 turns the frame hook off)
//   hlds_updated_timestamp_seconds     when this file was written

#pragma semicolon 1

#include <amxmodx>
#include <fakemeta>

new const METRICS_FILE[] = "addons/amxmodx/data/metrics.prom";

new g_pcvarInterval;
new g_iFrames;
new Float:g_fLastWrite;
new g_iStarted;
new bool:g_bCountFrames;

public plugin_init() {
    register_plugin("Metrics", "1.0", "cs-server");

    g_pcvarInterval = register_cvar("metrics_interval", "5");
    new pcvarFps = register_cvar("metrics_fps", "1");

    // The start of the first map, kept across map changes.
    new szStarted[16];
    get_localinfo("metrics_start", szStarted, charsmax(szStarted));
    g_iStarted = str_to_num(szStarted);
    if (g_iStarted <= 0) {
        g_iStarted = get_systime();
        num_to_str(g_iStarted, szStarted, charsmax(szStarted));
        set_localinfo("metrics_start", szStarted);
    }

    if (get_pcvar_num(pcvarFps)) {
        g_bCountFrames = true;
        register_forward(FM_StartFrame, "on_frame");
    }
    g_fLastWrite = get_gametime();
    set_task(1.0, "schedule");
}

public on_frame() {
    g_iFrames++;
    return FMRES_IGNORED;
}

// Not a repeating task: the interval is read each time, so the cvar can
// change while the server runs.
public schedule() {
    write_metrics();
    set_task(floatmax(1.0, get_pcvar_float(g_pcvarInterval)), "schedule");
}

write_metrics() {
    new iHumans, iBots;
    new iMax = get_maxplayers();
    for (new id = 1; id <= iMax; id++) {
        if (!is_user_connected(id) || is_user_hltv(id))
            continue;
        if (is_user_bot(id)) {
            iBots++;
        } else {
            iHumans++;
        }
    }

    new Float:fNow = get_gametime();
    new Float:fElapsed = fNow - g_fLastWrite;
    new Float:fFps = (g_bCountFrames && fElapsed > 0.0) ? float(g_iFrames) / fElapsed : 0.0;
    g_iFrames = 0;
    g_fLastWrite = fNow;

    new szMap[64];
    get_mapname(szMap, charsmax(szMap));
    new iSystime = get_systime();

    new f = fopen(METRICS_FILE, "wt");
    if (!f)
        return;
    fprintf(f, "# HELP hlds_players Connected clients.^n# TYPE hlds_players gauge^n");
    fprintf(f, "hlds_players{type=^"human^"} %d^nhlds_players{type=^"bot^"} %d^n", iHumans, iBots);
    fprintf(f, "# HELP hlds_max_players Player slots.^n# TYPE hlds_max_players gauge^nhlds_max_players %d^n", iMax);
    fprintf(f, "# HELP hlds_map_info The running map.^n# TYPE hlds_map_info gauge^nhlds_map_info{map=^"%s^"} 1^n", szMap);
    fprintf(f, "# HELP hlds_map_seconds Time on the running map.^n# TYPE hlds_map_seconds gauge^nhlds_map_seconds %d^n", floatround(fNow));
    fprintf(f, "# HELP hlds_uptime_seconds Time since the server's first map.^n# TYPE hlds_uptime_seconds gauge^nhlds_uptime_seconds %d^n", iSystime - g_iStarted);
    if (g_bCountFrames) {
        fprintf(f, "# HELP hlds_server_fps Server frames per second.^n# TYPE hlds_server_fps gauge^nhlds_server_fps %.1f^n", fFps);
    }
    fprintf(f, "# HELP hlds_updated_timestamp_seconds When these values were written.^n# TYPE hlds_updated_timestamp_seconds gauge^nhlds_updated_timestamp_seconds %d^n", iSystime);
    fclose(f);
}
