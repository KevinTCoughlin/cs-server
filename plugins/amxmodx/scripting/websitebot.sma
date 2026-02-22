// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
//
// Website Bot — Adds a spectator bot to the scoreboard displaying the server
// website URL. Auto-kicks when the server is near capacity.

#include <amxmodx>
#include <fakemeta>

#define BOT_DEFAULT_NAME "kevintcoughlin.com/cs-server/"

new g_iBotId;
new g_pcvarBotName;
new g_pcvarEnabled;
new g_pcvarKickSlots;

public plugin_init() {
    register_plugin("Website Bot", "1.0", "cs-server");

    g_pcvarEnabled = register_cvar("websitebot_enabled", "1");
    g_pcvarBotName = register_cvar("websitebot_name", BOT_DEFAULT_NAME);
    g_pcvarKickSlots = register_cvar("websitebot_kick_slots", "2");

    set_task(10.0, "task_create_bot");
    set_task(30.0, "task_check_capacity", _, _, _, "b");
}

public task_create_bot() {
    if (!get_pcvar_num(g_pcvarEnabled))
        return;

    if (g_iBotId > 0 && is_user_connected(g_iBotId))
        return;

    new szName[64];
    get_pcvar_string(g_pcvarBotName, szName, charsmax(szName));

    g_iBotId = engfunc(EngFunc_CreateFakeClient, szName);

    if (g_iBotId == 0) {
        log_amx("[WebsiteBot] Failed to create bot (retrying in 30s)");
        set_task(30.0, "task_create_bot");
        return;
    }

    // Set up client info before connecting
    set_user_info(g_iBotId, "rate", "3500");
    set_user_info(g_iBotId, "cl_updaterate", "25");
    set_user_info(g_iBotId, "cl_lw", "1");
    set_user_info(g_iBotId, "cl_lc", "1");
    set_user_info(g_iBotId, "_vgui_menus", "0");
    set_user_info(g_iBotId, "*bot", "1");

    // Connect the bot to the server
    new szReject[128];
    dllfunc(DLLFunc_ClientConnect, g_iBotId, szName, "127.0.0.1", szReject);

    if (!is_user_connected(g_iBotId)) {
        engfunc(EngFunc_FreeEntPrivateData, g_iBotId);
        g_iBotId = 0;
        log_amx("[WebsiteBot] Bot rejected (retrying in 30s)");
        set_task(30.0, "task_create_bot");
        return;
    }

    dllfunc(DLLFunc_ClientPutInServer, g_iBotId);

    // Join spectator team (team 6 = spectator in CS 1.6)
    engclient_cmd(g_iBotId, "jointeam", "6");

    log_amx("[WebsiteBot] Created bot: %s (id %d)", szName, g_iBotId);
}

public task_check_capacity() {
    if (g_iBotId == 0 || !is_user_connected(g_iBotId))
        return;

    new iMaxPlayers = get_maxplayers();
    new iPlayers = get_playersnum();
    new iThreshold = get_pcvar_num(g_pcvarKickSlots);

    // Kick bot if server is near capacity
    if (iPlayers >= (iMaxPlayers - iThreshold)) {
        server_cmd("kick #%d", get_user_userid(g_iBotId));
        g_iBotId = 0;
        log_amx("[WebsiteBot] Kicked bot (server near capacity)");

        // Try to re-add when a slot opens
        set_task(30.0, "task_create_bot");
    }
}

public client_disconnected(id) {
    if (id == g_iBotId) {
        g_iBotId = 0;
        set_task(10.0, "task_create_bot");
        return;
    }

    // A real player left — try to re-add bot if it was kicked for capacity
    if (g_iBotId == 0) {
        set_task(5.0, "task_create_bot");
    }
}
