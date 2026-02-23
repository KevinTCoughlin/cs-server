// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
//
// Advertisements — Rotating chat messages for server info, commands, and links.

#pragma semicolon 1

#include <amxmodx>

new const g_szAds[][] = {
    "Visit ^x04kevintcoughlin.com/cs-server/^x01 for server info",
    "Support & sponsor this server on GitHub: ^x04github.com/sponsors/KevinTCoughlin",
    "Type ^x04rtv^x01 to vote for a map change, ^x04nominate <map>^x01 to add a map",
    "Type ^x04!sounds^x01 in chat to toggle kill sound announcements",
    "Auto bunny hop is ^x04enabled^x01 — hold jump to bhop"
};

new g_iAdIndex;
new g_pcvarEnabled;
new g_pcvarInterval;

public plugin_init() {
    register_plugin("Advertisements", "1.0", "cs-server");

    g_pcvarEnabled = register_cvar("ads_enabled", "1");
    g_pcvarInterval = register_cvar("ads_interval", "120");

    g_iAdIndex = 0;

    // Delay first ad so it doesn't fire right at map start
    new Float:fInterval = float(get_pcvar_num(g_pcvarInterval));
    if (fInterval < 30.0)
        fInterval = 120.0;

    set_task(fInterval, "task_show_ad", _, _, _, "b");
}

public task_show_ad() {
    if (!get_pcvar_num(g_pcvarEnabled))
        return;

    new players[32], num;
    get_players(players, num, "ch");

    if (num == 0)
        return;

    // Send colored message via SayText
    new szMsg[192];
    formatex(szMsg, charsmax(szMsg), "^x01[^x04SERVER^x01] %s", g_szAds[g_iAdIndex]);

    for (new i = 0; i < num; i++) {
        message_begin(MSG_ONE, get_user_msgid("SayText"), _, players[i]);
        write_byte(players[i]);
        write_string(szMsg);
        message_end();
    }

    g_iAdIndex = (g_iAdIndex + 1) % sizeof(g_szAds);
}
