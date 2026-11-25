// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
//
// Website Bot — Adds a spectator bot to the scoreboard displaying the server
// website URL. Steps aside when the server is within websitebot_kick_slots
// of full, and does not come back until it would sit below that same line.

#pragma semicolon 1

#include <amxmodx>
#include <fakemeta>

#define BOT_DEFAULT_NAME "kevintcoughlin.com/cs-server/"
#define TASK_CREATE_BOT 7101

new g_iBotId;
new g_pcvarBotName;
new g_pcvarEnabled;
new g_pcvarKickSlots;

// Kick, a failed connect and every disconnect all ask for a bot. One pending
// task, replaced rather than stacked: a pile of timers each used to spawn
// another client on a server that was already full.
schedule_create(Float:delay) {
    remove_task(TASK_CREATE_BOT);
    set_task(delay, "task_create_bot", TASK_CREATE_BOT);
}

// The kick line is maxplayers - websitebot_kick_slots. get_playersnum()
// counts the bot only once it has joined, so a check made before creating
// it has to include the slot it is about to take. Otherwise the bot joins
// one player under the line and the next capacity check kicks it.
bool:over_capacity() {
    new iPlayers = get_playersnum();
    if (g_iBotId <= 0 || !is_user_connected(g_iBotId))
        iPlayers++;

    new iLimit = get_maxplayers() - get_pcvar_num(g_pcvarKickSlots);
    if (iPlayers >= iLimit)
        return true;
    return false;
}

public plugin_init() {
    register_plugin("Website Bot", "1.0", "cs-server");

    g_pcvarEnabled = register_cvar("websitebot_enabled", "1");
    g_pcvarBotName = register_cvar("websitebot_name", BOT_DEFAULT_NAME);
    g_pcvarKickSlots = register_cvar("websitebot_kick_slots", "2");

    schedule_create(10.0);
    set_task(30.0, "task_check_capacity", _, _, _, "b");
}

public task_create_bot() {
    if (!get_pcvar_num(g_pcvarEnabled))
        return;

    if (g_iBotId > 0 && is_user_connected(g_iBotId))
        return;

    if (over_capacity()) {
        log_amx("[WebsiteBot] Not creating bot (server near capacity)");
        return;
    }

    new szName[64];
    get_pcvar_string(g_pcvarBotName, szName, charsmax(szName));

    g_iBotId = engfunc(EngFunc_CreateFakeClient, szName);

    if (g_iBotId == 0) {
        log_amx("[WebsiteBot] Failed to create bot (retrying in 30s)");
        schedule_create(30.0);
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
        schedule_create(30.0);
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

    // Kick bot if server is near capacity. g_iBotId stays set until the
    // disconnect lands, so that departure is the bot's and not a player
    // leaving (which would retry in 5s and put the client straight back).
    if (over_capacity()) {
        server_cmd("kick #%d", get_user_userid(g_iBotId));
        log_amx("[WebsiteBot] Kicked bot (server near capacity)");
        schedule_create(30.0);
    }
}

public client_disconnected(id) {
    if (id == g_iBotId) {
        g_iBotId = 0;
        schedule_create(10.0);
        return;
    }

    // A real player left — try to re-add bot if it was kicked for capacity
    if (g_iBotId == 0 || !is_user_connected(g_iBotId))
        schedule_create(5.0);
}
