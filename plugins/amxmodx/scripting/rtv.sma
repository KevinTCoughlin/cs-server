// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
//
// Rock the Vote + Map Nominations
// Players type "rtv" to vote for a map change. When the threshold is reached,
// a vote menu appears. Players can "nominate <map>" to add maps to the vote.

#pragma semicolon 1

#include <amxmodx>
#include <amxmisc>

#define MAX_MAPS       32
#define MAX_NOMINATIONS 4
#define MAX_VOTE_OPTIONS 6
#define MENU_KEYS (MENU_KEY_1|MENU_KEY_2|MENU_KEY_3|MENU_KEY_4|MENU_KEY_5|MENU_KEY_6|MENU_KEY_7)

// Map pool loaded from mapcycle.txt
new g_szMaps[MAX_MAPS][32];
new g_iMapCount;

// Current map name
new g_szCurrentMap[32];

// RTV tracking
new bool:g_bPlayerVoted[33];
new g_iRtvCount;
new bool:g_bRtvTriggered;

// Nominations
new g_szNominations[MAX_NOMINATIONS][32];
new g_iNominatedBy[MAX_NOMINATIONS];
new g_iNominationCount;

// Vote state
new bool:g_bVoteInProgress;
new g_szVoteOptions[MAX_VOTE_OPTIONS][32];
new g_iVoteOptionCount;
new g_iVotes[MAX_VOTE_OPTIONS + 1]; // +1 for "Don't Change"
new g_iMenuId;

// Timing
new Float:g_fMapStartTime;

// CVARs
new g_pcvarRatio;
new g_pcvarMinPlayers;
new g_pcvarDelay;
new g_pcvarVoteDuration;
new g_pcvarChangeDelay;

public plugin_init() {
    register_plugin("RTV + Nominations", "1.0", "cs-server");

    register_clcmd("say", "on_say");
    register_clcmd("say_team", "on_say");

    g_pcvarRatio = register_cvar("rtv_ratio", "0.6");
    g_pcvarMinPlayers = register_cvar("rtv_min_players", "2");
    g_pcvarDelay = register_cvar("rtv_delay", "120");
    g_pcvarVoteDuration = register_cvar("rtv_vote_duration", "15");
    g_pcvarChangeDelay = register_cvar("rtv_change_delay", "5");

    g_iMenuId = register_menuid("RTVVoteMenu");
    register_menucmd(g_iMenuId, MENU_KEYS, "handle_vote");

    get_mapname(g_szCurrentMap, charsmax(g_szCurrentMap));
    g_fMapStartTime = get_gametime();

    load_mapcycle();
}

load_mapcycle() {
    new szFile[128];
    get_configsdir(szFile, charsmax(szFile));

    // Try AMX Mod X configs dir first, then fall back to mapcycle.txt in cstrike/
    new szMapcycle[128];
    formatex(szMapcycle, charsmax(szMapcycle), "%s/mapcycle.txt", szFile);

    new f;
    if (file_exists(szMapcycle)) {
        f = fopen(szMapcycle, "r");
    } else {
        f = fopen("mapcycle.txt", "r");
    }

    if (!f) {
        log_amx("[RTV] Could not open mapcycle.txt");
        return;
    }

    new szLine[64];
    while (fgets(f, szLine, charsmax(szLine)) && g_iMapCount < MAX_MAPS) {
        trim(szLine);

        // Skip empty lines and comments
        if (szLine[0] == 0 || szLine[0] == ';' || szLine[0] == '/')
            continue;

        // Skip current map
        if (equali(szLine, g_szCurrentMap))
            continue;

        // Validate map exists
        new szBsp[64];
        formatex(szBsp, charsmax(szBsp), "maps/%s.bsp", szLine);
        if (!file_exists(szBsp))
            continue;

        copy(g_szMaps[g_iMapCount], charsmax(g_szMaps[]), szLine);
        g_iMapCount++;
    }

    fclose(f);
    log_amx("[RTV] Loaded %d maps from mapcycle", g_iMapCount);
}

public client_disconnected(id) {
    // If this player had voted RTV, remove their vote and recheck
    if (g_bPlayerVoted[id]) {
        g_bPlayerVoted[id] = false;
        g_iRtvCount--;

        if (g_iRtvCount < 0)
            g_iRtvCount = 0;
    }

    // Remove their nomination
    for (new i = 0; i < g_iNominationCount; i++) {
        if (g_iNominatedBy[i] == id) {
            // Shift remaining nominations down
            for (new j = i; j < g_iNominationCount - 1; j++) {
                copy(g_szNominations[j], charsmax(g_szNominations[]), g_szNominations[j + 1]);
                g_iNominatedBy[j] = g_iNominatedBy[j + 1];
            }
            g_iNominationCount--;
            break;
        }
    }

    // Recheck RTV threshold (fewer players may lower the bar)
    if (!g_bRtvTriggered && !g_bVoteInProgress && g_iRtvCount > 0) {
        check_rtv_threshold();
    }
}

public on_say(id) {
    new szMsg[128];
    read_args(szMsg, charsmax(szMsg));
    remove_quotes(szMsg);
    trim(szMsg);

    if (equali(szMsg, "rtv") || equali(szMsg, "/rtv")) {
        handle_rtv(id);
        return PLUGIN_CONTINUE;
    }

    if (equali(szMsg, "nominate", 8) || equali(szMsg, "/nominate", 9)) {
        new szMap[32];
        new iStart = (szMsg[0] == '/') ? 10 : 9;
        copy(szMap, charsmax(szMap), szMsg[iStart]);
        trim(szMap);

        if (szMap[0] != 0)
            handle_nominate(id, szMap);
        else
            client_print(id, print_chat, "[RTV] Usage: nominate <mapname>");

        return PLUGIN_CONTINUE;
    }

    return PLUGIN_CONTINUE;
}

handle_rtv(id) {
    if (is_user_bot(id))
        return;

    if (g_bRtvTriggered) {
        client_print(id, print_chat, "[RTV] Vote has already been triggered.");
        return;
    }

    if (g_bVoteInProgress) {
        client_print(id, print_chat, "[RTV] A vote is already in progress.");
        return;
    }

    new Float:fElapsed = get_gametime() - g_fMapStartTime;
    new Float:fDelay = float(get_pcvar_num(g_pcvarDelay));
    if (fElapsed < fDelay) {
        new iRemain = floatround(fDelay - fElapsed, floatround_ceil);
        client_print(id, print_chat, "[RTV] RTV available in %d seconds.", iRemain);
        return;
    }

    if (g_bPlayerVoted[id]) {
        new iNeeded = get_rtv_needed();
        client_print(id, print_chat, "[RTV] You already voted. %d of %d needed.", g_iRtvCount, iNeeded);
        return;
    }

    g_bPlayerVoted[id] = true;
    g_iRtvCount++;

    new szName[32];
    get_user_name(id, szName, charsmax(szName));

    new iNeeded = get_rtv_needed();
    client_print(0, print_chat, "[RTV] %s wants to rock the vote! (%d/%d)", szName, g_iRtvCount, iNeeded);

    check_rtv_threshold();
}

get_rtv_needed() {
    new iPlayers = get_human_count();
    new iMin = get_pcvar_num(g_pcvarMinPlayers);
    new Float:fRatio = get_pcvar_float(g_pcvarRatio);

    new iNeeded = floatround(float(iPlayers) * fRatio, floatround_ceil);
    if (iNeeded < iMin)
        iNeeded = iMin;

    return iNeeded;
}

get_human_count() {
    new players[32], num;
    get_players(players, num, "ch"); // connected, not bots
    return num;
}

check_rtv_threshold() {
    new iNeeded = get_rtv_needed();
    if (g_iRtvCount >= iNeeded) {
        g_bRtvTriggered = true;
        client_print(0, print_chat, "[RTV] Vote threshold reached! Starting map vote...");
        start_vote();
    }
}

start_vote() {
    g_bVoteInProgress = true;

    // Build vote options: nominations first, then fill from mapcycle
    g_iVoteOptionCount = 0;

    // Add nominated maps
    for (new i = 0; i < g_iNominationCount && g_iVoteOptionCount < MAX_VOTE_OPTIONS - 1; i++) {
        copy(g_szVoteOptions[g_iVoteOptionCount], charsmax(g_szVoteOptions[]), g_szNominations[i]);
        g_iVoteOptionCount++;
    }

    // Fill remaining slots from mapcycle (shuffled by picking random indices)
    for (new i = 0; i < g_iMapCount && g_iVoteOptionCount < MAX_VOTE_OPTIONS - 1; i++) {
        if (!is_map_in_vote(g_szMaps[i])) {
            copy(g_szVoteOptions[g_iVoteOptionCount], charsmax(g_szVoteOptions[]), g_szMaps[i]);
            g_iVoteOptionCount++;
        }
    }

    // Reset vote counts
    for (new i = 0; i <= MAX_VOTE_OPTIONS; i++) {
        g_iVotes[i] = 0;
    }

    // Show menu to all human players
    new players[32], num;
    get_players(players, num, "ch");

    for (new i = 0; i < num; i++) {
        show_vote_menu(players[i]);
    }

    // Set timer to end vote
    new Float:fDuration = float(get_pcvar_num(g_pcvarVoteDuration));
    if (fDuration <= 0.0)
        fDuration = 15.0;

    set_task(fDuration, "end_vote");
}

bool:is_map_in_vote(const szMap[]) {
    for (new i = 0; i < g_iVoteOptionCount; i++) {
        if (equali(g_szVoteOptions[i], szMap))
            return true;
    }
    return false;
}

show_vote_menu(id) {
    new szMenu[512];
    new iLen = 0;

    iLen += formatex(szMenu[iLen], charsmax(szMenu) - iLen, "\yRock the Vote^n^n");

    for (new i = 0; i < g_iVoteOptionCount; i++) {
        iLen += formatex(szMenu[iLen], charsmax(szMenu) - iLen, "\w%d. %s^n", i + 1, g_szVoteOptions[i]);
    }

    iLen += formatex(szMenu[iLen], charsmax(szMenu) - iLen, "^n\w%d. Don't Change^n", g_iVoteOptionCount + 1);

    show_menu(id, MENU_KEYS, szMenu, -1, "RTVVoteMenu");
}

public handle_vote(id, key) {
    if (!g_bVoteInProgress)
        return PLUGIN_HANDLED;

    // key is 0-indexed (key 0 = option 1, etc.)
    if (key >= 0 && key <= g_iVoteOptionCount) {
        g_iVotes[key]++;

        new szName[32];
        get_user_name(id, szName, charsmax(szName));

        if (key < g_iVoteOptionCount)
            client_print(0, print_chat, "[RTV] %s voted for %s.", szName, g_szVoteOptions[key]);
        else
            client_print(0, print_chat, "[RTV] %s voted for Don't Change.", szName);
    }

    return PLUGIN_HANDLED;
}

public end_vote() {
    if (!g_bVoteInProgress)
        return;

    g_bVoteInProgress = false;

    // Find winner (highest votes, ties go to first option)
    new iWinner = g_iVoteOptionCount; // Default to "Don't Change"
    new iMaxVotes = 0;

    for (new i = 0; i <= g_iVoteOptionCount; i++) {
        if (g_iVotes[i] > iMaxVotes) {
            iMaxVotes = g_iVotes[i];
            iWinner = i;
        }
    }

    // "Don't Change" won or no votes cast
    if (iWinner == g_iVoteOptionCount || iMaxVotes == 0) {
        client_print(0, print_chat, "[RTV] Vote result: Map stays! (Don't Change won)");
        return;
    }

    new Float:fDelay = float(get_pcvar_num(g_pcvarChangeDelay));
    if (fDelay <= 0.0)
        fDelay = 5.0;

    client_print(0, print_chat, "[RTV] Vote result: %s wins! Changing in %.0f seconds...", g_szVoteOptions[iWinner], fDelay);

    new szCmd[64];
    formatex(szCmd, charsmax(szCmd), "changelevel %s", g_szVoteOptions[iWinner]);
    set_task(fDelay, "do_changelevel", 0, szCmd, sizeof(szCmd));
}

public do_changelevel(szCmd[], taskId) {
    server_cmd("%s", szCmd);
}

handle_nominate(id, const szMap[]) {
    if (is_user_bot(id))
        return;

    if (g_bRtvTriggered || g_bVoteInProgress) {
        client_print(id, print_chat, "[RTV] Cannot nominate — vote already started.");
        return;
    }

    // Check if map is in our pool
    new iFound = -1;
    for (new i = 0; i < g_iMapCount; i++) {
        if (equali(g_szMaps[i], szMap)) {
            iFound = i;
            break;
        }
    }

    if (iFound == -1) {
        client_print(id, print_chat, "[RTV] Map '%s' not found in map pool.", szMap);
        return;
    }

    // Check if already nominated
    for (new i = 0; i < g_iNominationCount; i++) {
        if (equali(g_szNominations[i], g_szMaps[iFound])) {
            client_print(id, print_chat, "[RTV] '%s' is already nominated.", g_szMaps[iFound]);
            return;
        }
    }

    // Check if this player already nominated something — replace it
    for (new i = 0; i < g_iNominationCount; i++) {
        if (g_iNominatedBy[i] == id) {
            new szName[32];
            get_user_name(id, szName, charsmax(szName));
            client_print(0, print_chat, "[RTV] %s changed nomination to %s.", szName, g_szMaps[iFound]);
            copy(g_szNominations[i], charsmax(g_szNominations[]), g_szMaps[iFound]);
            return;
        }
    }

    // Add nomination
    if (g_iNominationCount >= MAX_NOMINATIONS) {
        client_print(id, print_chat, "[RTV] Nomination slots are full.");
        return;
    }

    copy(g_szNominations[g_iNominationCount], charsmax(g_szNominations[]), g_szMaps[iFound]);
    g_iNominatedBy[g_iNominationCount] = id;
    g_iNominationCount++;

    new szName[32];
    get_user_name(id, szName, charsmax(szName));
    client_print(0, print_chat, "[RTV] %s nominated %s.", szName, g_szMaps[iFound]);
}
