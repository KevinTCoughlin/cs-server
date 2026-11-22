// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
//
// 5v5 match flow for MODE=match. Loaded only from the mode's plugin list
// (addons/amxmodx/configs/modes/match.ini).
//
//   warmup   Everyone respawns, money is full, rounds do not end. Players say
//            .ready; when match_players of them are ready the knife round
//            starts.
//   knife    One round, knives only. The winning team picks its side.
//   choose   The knife winners say .stay or .switch (match_choose_time
//            seconds, then "stay").
//   live     modes/match.cfg applies. Sides swap after match_half rounds;
//            the score goes with the teams and money starts over.
//
// A pause (.pause) holds the next freeze time until .unpause; asked for
// during freeze time it holds that one. Every map starts in warmup.
//
// Chat (also with ! or /): .ready .notready .stay .switch .pause .unpause
// Server console / FIFO:   match_start    start the knife round now
//                          match_live     skip to live (no knife round)
//                          match_stay | match_switch
//                          match_pause | match_unpause
//                          match_reset    back to warmup
//                          match_status   print the state
//
// scoutzknivez.amxx execs server.cfg and modes/match.cfg on every map; this
// plugin then lays the warmup settings over them and execs modes/match.cfg
// again when the match goes live.

#pragma semicolon 1

#include <amxmodx>
#include <reapi>

#define MAX_CLIENTS 32
#define TASK_WARMUP 7401
#define TASK_CHOOSE 7402
#define TASK_HINT 7403

enum MatchState {
    STATE_WARMUP,
    STATE_KNIFE,
    STATE_CHOOSE,
    STATE_LIVE
};

new const g_szStateNames[MatchState][] = { "warmup", "knife", "choose", "live" };

new MatchState:g_iState = STATE_WARMUP;
new bool:g_bReady[MAX_CLIENTS + 1];
new bool:g_bPauseWanted;
new bool:g_bPaused;
new TeamName:g_iKnifeWinner = TEAM_UNASSIGNED;
new g_iLiveRounds;
new bool:g_bSwapped;

new g_pcvarPlayers;
new g_pcvarHalf;
new g_pcvarChooseTime;

public plugin_init() {
    register_plugin("Match", "1.0", "cs-server");

    g_pcvarPlayers = register_cvar("match_players", "10");
    g_pcvarHalf = register_cvar("match_half", "15");
    g_pcvarChooseTime = register_cvar("match_choose_time", "30");

    register_clcmd("say", "cmd_say");
    register_clcmd("say_team", "cmd_say");

    register_srvcmd("match_start", "cmd_start");
    register_srvcmd("match_live", "cmd_live");
    register_srvcmd("match_stay", "cmd_stay");
    register_srvcmd("match_switch", "cmd_switch");
    register_srvcmd("match_pause", "cmd_pause");
    register_srvcmd("match_unpause", "cmd_unpause");
    register_srvcmd("match_reset", "cmd_reset");
    register_srvcmd("match_status", "cmd_status");

    RegisterHookChain(RG_CBasePlayer_HasRestrictItem, "on_restrict_item");
    RegisterHookChain(RG_RoundEnd, "on_round_end", true);
    RegisterHookChain(RG_CSGameRules_OnRoundFreezeEnd, "on_freeze_end");
    RegisterHookChain(RG_CSGameRules_RestartRound, "on_restart_round", true);
}

public plugin_cfg() {
    // After scoutzknivez.amxx's exec of server.cfg and modes/match.cfg (0.5 s).
    set_task(1.5, "enter_warmup", TASK_WARMUP);
    set_task(30.0, "warmup_hint", TASK_HINT, .flags = "b");
}

// The map is changing, perhaps to another mode whose settings files know
// nothing of these: leave none of the warmup or match rules behind.
public plugin_end() {
    set_cvar_num("mp_forcerespawn", 0);
    set_cvar_num("mp_round_infinite", 0);
    set_cvar_num("mp_limitteams", 2);
    set_cvar_num("mp_maxrounds", 0);
    set_cvar_num("mp_winlimit", 0);
}

public client_disconnected(id) {
    g_bReady[id] = false;
}

// --- States -----------------------------------------------------------------

public enter_warmup() {
    g_iState = STATE_WARMUP;
    g_bPauseWanted = false;
    g_bPaused = false;
    g_iKnifeWinner = TEAM_UNASSIGNED;
    g_iLiveRounds = 0;
    g_bSwapped = false;
    arrayset(g_bReady, false, sizeof(g_bReady));
    remove_task(TASK_CHOOSE);
    warmup_settings();
    server_cmd("sv_restart 1");
    log_amx("[MATCH] state: warmup");
}

// Respawn, full money and endless rounds; modes/match.cfg undoes all of it.
warmup_settings() {
    server_cmd("mp_forcerespawn 1");
    server_cmd("mp_round_infinite 1");
    server_cmd("mp_freezetime 0");
    server_cmd("mp_buytime -1");
    server_cmd("mp_startmoney 16000");
}

start_knife() {
    g_iState = STATE_KNIFE;
    remove_task(TASK_CHOOSE);
    server_cmd("exec modes/match.cfg");
    server_cmd("mp_freezetime 5");
    server_cmd("sv_restart 3");
    client_print(0, print_chat, "[MATCH] Knife round! The winners pick their side.");
    log_amx("[MATCH] state: knife");
}

start_choose(TeamName:winner) {
    g_iState = STATE_CHOOSE;
    g_iKnifeWinner = winner;
    warmup_settings();
    new szTeam[16];
    copy(szTeam, charsmax(szTeam), winner == TEAM_CT ? "Counter-Terrorists" : "Terrorists");
    client_print(0, print_chat, "[MATCH] %s won the knife round: say .stay or .switch", szTeam);
    set_task(get_pcvar_float(g_pcvarChooseTime), "choose_timeout", TASK_CHOOSE);
    log_amx("[MATCH] state: choose (%s)", winner == TEAM_CT ? "CT" : "TERRORIST");
}

public choose_timeout() {
    if (g_iState == STATE_CHOOSE) {
        go_live(false);
    }
}

go_live(bool:swap) {
    remove_task(TASK_CHOOSE);
    g_iState = STATE_LIVE;
    g_iLiveRounds = 0;
    g_bSwapped = false;
    g_bPauseWanted = false;
    g_bPaused = false;
    if (swap) {
        rg_swap_all_players();
    }
    server_cmd("exec modes/match.cfg");
    server_cmd("sv_restart 3");
    client_print(0, print_chat, "[MATCH] %s. LIVE after the restart. Good luck!", swap ? "Sides switched" : "Sides stay");
    log_amx("[MATCH] state: live (%s)", swap ? "switched" : "stayed");
}

// --- Game hooks -------------------------------------------------------------

// Knife round: nothing but the knife can be bought, picked up or handed out.
public on_restrict_item(const id, ItemID:item, ItemRestType:type) {
    if (g_iState != STATE_KNIFE || item == ITEM_KNIFE)
        return HC_CONTINUE;
    SetHookChainReturn(ATYPE_BOOL, true);
    return HC_SUPERCEDE;
}

public on_round_end(WinStatus:status, ScenarioEventEndRound:event, Float:tmDelay) {
    if (g_iState == STATE_KNIFE) {
        if (status == WINSTATUS_CTS) {
            start_choose(TEAM_CT);
        } else if (status == WINSTATUS_TERRORISTS) {
            start_choose(TEAM_TERRORIST);
        }
        // A draw or a restart: the knife round is played again.
        return HC_CONTINUE;
    }
    if (g_iState != STATE_LIVE || (status != WINSTATUS_CTS && status != WINSTATUS_TERRORISTS))
        return HC_CONTINUE;

    g_iLiveRounds++;
    if (!g_bSwapped && g_iLiveRounds == get_pcvar_num(g_pcvarHalf)) {
        half_time();
    }
    return HC_CONTINUE;
}

// The round has been decided and its win counted; the next one has not begun.
half_time() {
    g_bSwapped = true;
    new iCt = get_member_game(m_iNumCTWins);
    new iT = get_member_game(m_iNumTerroristWins);
    rg_swap_all_players();
    rg_update_teamscores(iT, iCt, false);

    new iMoney = get_cvar_num("mp_startmoney");
    new iPlayers[MAX_CLIENTS], iNum;
    get_players(iPlayers, iNum);
    for (new i = 0; i < iNum; i++) {
        new id = iPlayers[i];
        rg_add_account(id, iMoney, AS_SET);
        if (is_user_alive(id)) {
            rg_remove_all_items(id);
            rg_give_default_items(id);
        }
    }
    client_print(0, print_chat, "[MATCH] Half time: %d - %d. Sides switched.", iCt, iT);
    log_amx("[MATCH] half time (CT %d, T %d before the swap)", iCt, iT);
}

// A new round's freeze time begins: a pause asked for earlier takes hold.
public on_restart_round() {
    if (g_bPauseWanted && !g_bPaused) {
        begin_pause();
    }
}

public on_freeze_end() {
    return g_bPaused ? HC_SUPERCEDE : HC_CONTINUE;
}

begin_pause() {
    g_bPaused = true;
    g_bPauseWanted = false;
    client_print(0, print_chat, "[MATCH] Paused. Say .unpause to go on.");
    log_amx("[MATCH] paused");
}

request_pause() {
    if (g_iState != STATE_LIVE) {
        return 0;
    }
    if (g_bPaused || g_bPauseWanted) {
        return 1;
    }
    if (get_member_game(m_bFreezePeriod)) {
        begin_pause();
    } else {
        g_bPauseWanted = true;
        client_print(0, print_chat, "[MATCH] Pause at the next freeze time.");
        log_amx("[MATCH] pause queued");
    }
    return 1;
}

end_pause() {
    if (!g_bPaused && !g_bPauseWanted) {
        return;
    }
    g_bPaused = false;
    g_bPauseWanted = false;
    client_print(0, print_chat, "[MATCH] Unpaused.");
    log_amx("[MATCH] unpaused");
}

// --- Chat -------------------------------------------------------------------

public cmd_say(id) {
    new szText[32];
    read_args(szText, charsmax(szText));
    remove_quotes(szText);
    trim(szText);
    if (szText[0] != '.' && szText[0] != '!' && szText[0] != '/')
        return PLUGIN_CONTINUE;

    if (equali(szText[1], "ready")) {
        set_ready(id, true);
    } else if (equali(szText[1], "notready") || equali(szText[1], "unready")) {
        set_ready(id, false);
    } else if (equali(szText[1], "stay") || equali(szText[1], "switch")) {
        if (g_iState == STATE_CHOOSE && get_member(id, m_iTeam) == g_iKnifeWinner) {
            go_live(bool:equali(szText[1], "switch"));
        }
    } else if (equali(szText[1], "pause")) {
        if (!request_pause()) {
            client_print(id, print_chat, "[MATCH] Pausing is for the live match.");
        }
    } else if (equali(szText[1], "unpause")) {
        end_pause();
    }
    return PLUGIN_CONTINUE;
}

set_ready(id, bool:ready) {
    if (g_iState != STATE_WARMUP || g_bReady[id] == ready)
        return;
    new TeamName:team = get_member(id, m_iTeam);
    if (team != TEAM_CT && team != TEAM_TERRORIST)
        return;

    g_bReady[id] = ready;
    new szName[32];
    get_user_name(id, szName, charsmax(szName));
    new iNeeded = get_pcvar_num(g_pcvarPlayers);
    new iReady = ready_count();
    client_print(0, print_chat, "[MATCH] %s is %s (%d/%d)", szName, ready ? "ready" : "not ready", iReady, iNeeded);
    if (iReady >= iNeeded) {
        start_knife();
    }
}

ready_count() {
    new iCount;
    for (new id = 1; id <= MAX_CLIENTS; id++) {
        if (g_bReady[id] && is_user_connected(id)) {
            iCount++;
        }
    }
    return iCount;
}

public warmup_hint() {
    if (g_iState == STATE_WARMUP) {
        client_print(0, print_chat, "[MATCH] Warmup. Say .ready when you are (%d/%d).", ready_count(), get_pcvar_num(g_pcvarPlayers));
    } else if (g_bPaused) {
        client_print(0, print_chat, "[MATCH] Paused. Say .unpause to go on.");
    }
}

// --- Server commands --------------------------------------------------------

public cmd_start() {
    if (g_iState == STATE_WARMUP) {
        start_knife();
    } else {
        server_print("[MATCH] already past warmup (%s)", g_szStateNames[g_iState]);
    }
    return PLUGIN_HANDLED;
}

public cmd_live() {
    go_live(false);
    return PLUGIN_HANDLED;
}

public cmd_stay() {
    if (g_iState == STATE_CHOOSE) {
        go_live(false);
    } else {
        server_print("[MATCH] no side choice pending (%s)", g_szStateNames[g_iState]);
    }
    return PLUGIN_HANDLED;
}

public cmd_switch() {
    if (g_iState == STATE_CHOOSE) {
        go_live(true);
    } else {
        server_print("[MATCH] no side choice pending (%s)", g_szStateNames[g_iState]);
    }
    return PLUGIN_HANDLED;
}

public cmd_pause() {
    if (!request_pause()) {
        server_print("[MATCH] pausing is for the live match (%s)", g_szStateNames[g_iState]);
    }
    return PLUGIN_HANDLED;
}

public cmd_unpause() {
    end_pause();
    return PLUGIN_HANDLED;
}

public cmd_reset() {
    enter_warmup();
    return PLUGIN_HANDLED;
}

public cmd_status() {
    server_print("[MATCH] status: %s, %d ready, %s, round %d, CT %d T %d",
        g_szStateNames[g_iState], ready_count(),
        g_bPaused ? "paused" : (g_bPauseWanted ? "pause queued" : "running"),
        g_iLiveRounds, get_member_game(m_iNumCTWins), get_member_game(m_iNumTerroristWins));
    return PLUGIN_HANDLED;
}
