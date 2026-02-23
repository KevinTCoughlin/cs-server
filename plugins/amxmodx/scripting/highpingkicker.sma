// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
//
// High Ping Kicker — Warns then kicks players who exceed a latency threshold.
// Uses averaging to avoid kicking players with temporary spikes.

#pragma semicolon 1

#include <amxmodx>

#define CHECK_INTERVAL 15.0
#define SAMPLES 4

new g_iPingSamples[33][SAMPLES];
new g_iSampleIndex[33];
new g_iWarnings[33];

new g_pcvarEnabled;
new g_pcvarMaxPing;
new g_pcvarMaxWarnings;
new g_pcvarGracePeriod;

new Float:g_fJoinTime[33];

public plugin_init() {
    register_plugin("High Ping Kicker", "1.0", "cs-server");

    g_pcvarEnabled = register_cvar("hpk_enabled", "1");
    g_pcvarMaxPing = register_cvar("hpk_max_ping", "150");
    g_pcvarMaxWarnings = register_cvar("hpk_max_warnings", "3");
    g_pcvarGracePeriod = register_cvar("hpk_grace_period", "60");

    set_task(CHECK_INTERVAL, "task_check_pings", _, _, _, "b");
}

public client_putinserver(id) {
    g_iWarnings[id] = 0;
    g_iSampleIndex[id] = 0;
    g_fJoinTime[id] = get_gametime();

    for (new i = 0; i < SAMPLES; i++)
        g_iPingSamples[id][i] = 0;
}

public client_disconnected(id) {
    g_iWarnings[id] = 0;
}

public task_check_pings() {
    if (!get_pcvar_num(g_pcvarEnabled))
        return;

    new iMaxPing = get_pcvar_num(g_pcvarMaxPing);
    new iMaxWarnings = get_pcvar_num(g_pcvarMaxWarnings);
    new Float:fGrace = float(get_pcvar_num(g_pcvarGracePeriod));

    new players[32], num;
    get_players(players, num, "ch");

    for (new i = 0; i < num; i++) {
        new id = players[i];

        if (is_user_bot(id))
            continue;

        // Grace period after joining
        if ((get_gametime() - g_fJoinTime[id]) < fGrace)
            continue;

        // Sample current ping
        new iPing, iLoss;
        get_user_ping(id, iPing, iLoss);

        new idx = g_iSampleIndex[id] % SAMPLES;
        g_iPingSamples[id][idx] = iPing;
        g_iSampleIndex[id]++;

        // Need at least SAMPLES readings before averaging
        if (g_iSampleIndex[id] < SAMPLES)
            continue;

        // Compute average
        new iSum = 0;
        for (new j = 0; j < SAMPLES; j++)
            iSum += g_iPingSamples[id][j];

        new iAvg = iSum / SAMPLES;

        if (iAvg > iMaxPing) {
            g_iWarnings[id]++;

            if (g_iWarnings[id] >= iMaxWarnings) {
                new szName[32];
                get_user_name(id, szName, charsmax(szName));
                client_print(0, print_chat, "[HPK] %s was kicked (avg ping: %dms).", szName, iAvg);
                server_cmd("kick #%d ^"High ping (%dms)^"", get_user_userid(id), iAvg);
            } else {
                client_print(id, print_chat, "[HPK] Warning %d/%d: Your ping is %dms (max: %dms).", g_iWarnings[id], iMaxWarnings, iAvg, iMaxPing);
            }
        } else {
            // Reset warnings if ping recovers
            if (g_iWarnings[id] > 0)
                g_iWarnings[id]--;
        }
    }
}
