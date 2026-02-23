// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
//
// AFK Kicker — Moves idle players to spectator, then kicks them if still
// inactive. Keeps slots open for active players on bot-filled servers.

#include <amxmodx>
#include <fakemeta>
#include <cstrike>

#define CHECK_INTERVAL 10.0

new Float:g_fLastPos[33][3];
new Float:g_fAfkTime[33];

new g_pcvarEnabled;
new g_pcvarSpecTime;
new g_pcvarKickTime;
new g_pcvarMinPlayers;

public plugin_init() {
    register_plugin("AFK Kicker", "1.0", "cs-server");

    g_pcvarEnabled = register_cvar("afk_enabled", "1");
    g_pcvarSpecTime = register_cvar("afk_spec_time", "60");
    g_pcvarKickTime = register_cvar("afk_kick_time", "180");
    g_pcvarMinPlayers = register_cvar("afk_min_players", "4");

    set_task(CHECK_INTERVAL, "task_check_afk", _, _, _, "b");
}

public client_putinserver(id) {
    g_fAfkTime[id] = 0.0;
    pev(id, pev_origin, g_fLastPos[id]);
}

public client_disconnected(id) {
    g_fAfkTime[id] = 0.0;
}

public task_check_afk() {
    if (!get_pcvar_num(g_pcvarEnabled))
        return;

    new Float:fSpecTime = float(get_pcvar_num(g_pcvarSpecTime));
    new Float:fKickTime = float(get_pcvar_num(g_pcvarKickTime));
    new iMinPlayers = get_pcvar_num(g_pcvarMinPlayers);

    // Count human players
    new players[32], num;
    get_players(players, num, "ch");

    if (num < iMinPlayers)
        return;

    for (new i = 0; i < num; i++) {
        new id = players[i];

        if (is_user_bot(id))
            continue;

        // Check if player has moved
        new Float:fPos[3];
        pev(id, pev_origin, fPos);

        new Float:fDist = get_distance_f(fPos, g_fLastPos[id]);
        g_fLastPos[id] = fPos;

        if (fDist > 5.0) {
            g_fAfkTime[id] = 0.0;
            continue;
        }

        g_fAfkTime[id] += CHECK_INTERVAL;

        // Kick if past kick threshold
        if (g_fAfkTime[id] >= fKickTime) {
            new szName[32];
            get_user_name(id, szName, charsmax(szName));
            server_cmd("kick #%d ^"AFK for too long^"", get_user_userid(id));
            client_print(0, print_chat, "[AFK] %s was kicked for being AFK.", szName);
            g_fAfkTime[id] = 0.0;
            continue;
        }

        // Move to spectator if past spec threshold and still playing
        if (g_fAfkTime[id] >= fSpecTime && is_user_alive(id)) {
            new szName[32];
            get_user_name(id, szName, charsmax(szName));
            cs_set_user_team(id, CS_TEAM_SPECTATOR);
            client_print(id, print_chat, "[AFK] You were moved to spectator for being idle.");
            client_print(0, print_chat, "[AFK] %s moved to spectator (idle).", szName);
        }
    }
}
