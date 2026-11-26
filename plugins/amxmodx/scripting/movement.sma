// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
//
// Movement modes: a run timer, checkpoints and a top list. Loaded only from a
// movement mode's plugin list (plugins/amxmodx/modes/climb.ini, surf.ini).
//
// Timer, buttons. A climb (KZ) map has a start and a stop button: a
// func_button whose target is one of the names the mapping community settled
// on (START_TARGETS, STOP_TARGETS below). Pressing start begins a run,
// pressing stop ends it.
//
// Timer, zones. Surf maps have no such buttons, so a run there goes from a
// start zone to an end zone, two boxes kept per map in
// addons/amxmodx/data/zones/<map>.txt (linked into the state volume):
//
//   start  x1 y1 z1  x2 y2 z2
//   end    x1 y1 z1  x2 y2 z2
//
// Leaving the start zone begins a run; touching the end zone ends it; going
// back into the start zone cancels it. On a surf_ map with no start zone
// saved, the box around the spawn points is the start zone, so an admin only
// has to mark the end. An admin (flag "h", ADMIN_CFG) marks zones in game
// from the client console, standing on two opposite corners in turn:
//
//   mv_zone start     first call: one corner; second call: the other, saved
//   mv_zone end       the same for the end zone
//   mv_zone show      draw both boxes for a few seconds
//   mv_zone clear     forget this map's zones
//
// A map with neither buttons nor zones still plays; it has no timer.
//
// Checkpoints (say, or say_team):
//   /cp       save the spot you stand on (on the ground only)
//   /tp       back to the last checkpoint (also /gc)
//   /stuck    back to the checkpoint before that one
//   /start    back to the start button, timer off (also /restart)
//   /top      this map's best times
//
// A run that never teleported is a "pro" run; one that did is a "cp" run.
// Each has its own top list (MAX_TOP per map), one row per player, kept in
// addons/amxmodx/data/records/<map>.tsv, which the image links into the state
// volume. Columns, tab-separated:
//
//   category  centiseconds  checkpoints  teleports  unix_time  player  name
//
// `player` is the Steam id, or `name:<name>` where there is none (LAN mode).
//
// Dying during a run with a checkpoint saved puts you back on that checkpoint
// when you respawn and counts as a teleport. Without one, the run is over.
//
// Players never block or hurt each other (mv_semiclip 0 turns the first off).
//
// Server console (FIFO) only:
//   mv_zone_set <start|end> <x1> <y1> <z1> <x2> <y2> <z2>
//                                 save a zone from numbers
//   mv_top                        print this map's lists
//   mv_record <player> <name> <centiseconds> <checkpoints> <teleports>
//                                 enter a time, e.g. one carried over from
//                                 another server; the same rules apply as for
//                                 a run (one row per player, best time wins).
//                                 Quote a Steam id: the console splits on `:`
//
// `localinfo mv_runs` and `mv_bests` count finished runs and list entries
// since the server started; metrics.amxx publishes them.
//
// The mode's cfg turns on respawning and endless rounds. Those cvars are not
// in server.cfg, so plugin_end puts them back for the next mode.
//
// Which timer a map uses. A name starting with surf_ is zones. Under
// MODE=auto, scoutzknivez.amxx has already set localinfo sk_mapmode to surf
// or climb (it is loaded first), and that wins, so an override in
// modes/map-modes.ini changes the timer as well as the physics. MODE=climb
// and MODE=surf leave this decision on the map name.

#pragma semicolon 1

#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <hamsandwich>

#define MAX_TOP 15
#define KEY_LEN 48
#define NAME_LEN 32
#define TASK_HUD 7411

enum {
    CAT_PRO,
    CAT_CP,
    CAT_COUNT
};

new const CAT_NAME[CAT_COUNT][] = { "pro", "cp" };

new const START_TARGETS[][] = {
    "counter_start", "clockstartbutton", "firsttimerelay", "but_start",
    "counter_start_button", "multi_start", "timer_startbutton", "start_timer_emi", "gogogo"
};

new const STOP_TARGETS[][] = {
    "counter_off", "clockstopbutton", "clockstop", "but_stop",
    "counter_stop_button", "multi_stop", "stop_counter", "m_counter_end_emi"
};

new const RECORDS_DIR[] = "addons/amxmodx/data/records";
new const ZONES_DIR[] = "addons/amxmodx/data/zones";
new const BEAM_SPRITE[] = "sprites/laserbeam.spr";

enum {
    ZONE_START,
    ZONE_END,
    ZONE_COUNT
};

new const ZONE_NAME[ZONE_COUNT][] = { "start", "end" };

// How far past the outermost spawn point the automatic start zone reaches.
const Float:SPAWN_MARGIN = 96.0;
// A zone marked from two spots on one floor still has to be tall enough to
// catch a player crossing it in the air.
const Float:ZONE_MIN_HEIGHT = 128.0;

// --- Per-player run state ---------------------------------------------------

new bool:g_bRunning[33];
new Float:g_fStarted[33];
new g_iCheckpoints[33];
new g_iTeleports[33];

new bool:g_bHasStart[33];
new Float:g_fStartOrigin[33][3];
new Float:g_fStartAngles[33][3];

// The last two checkpoints: [0] is the newest.
new g_iSaved[33];
new Float:g_fCpOrigin[33][2][3];
new Float:g_fCpAngles[33][2][3];
new bool:g_bCpDucked[33][2];

// --- Top lists --------------------------------------------------------------

new g_iTopCount[CAT_COUNT];
new g_iTopTime[CAT_COUNT][MAX_TOP];
new g_iTopCheckpoints[CAT_COUNT][MAX_TOP];
new g_iTopTeleports[CAT_COUNT][MAX_TOP];
new g_iTopWhen[CAT_COUNT][MAX_TOP];
new g_szTopKey[CAT_COUNT][MAX_TOP][KEY_LEN];
new g_szTopName[CAT_COUNT][MAX_TOP][NAME_LEN];

new g_szMap[64];
new g_szRecordsFile[128];
new g_szZonesFile[128];
new bool:g_bHasTimer;
new bool:g_bSurf;
new g_szTag[8];

// --- Zones ------------------------------------------------------------------

new bool:g_bZone[ZONE_COUNT];
new bool:g_bZoneAuto;
new Float:g_fZoneMin[ZONE_COUNT][3];
new Float:g_fZoneMax[ZONE_COUNT][3];
new bool:g_bInStart[33];
new bool:g_bCorner[33][ZONE_COUNT];
new Float:g_fCorner[33][ZONE_COUNT][3];
new g_iBeam;

// --- Semiclip ---------------------------------------------------------------

new g_bSemiclip;
new bool:g_bSolid[33];
new bool:g_bRestore[33];
new g_iMaxPlayers;
new g_hudSync;

public plugin_init() {
    register_plugin("Movement", "1.0", "cs-server");

    bind_pcvar_num(register_cvar("mv_semiclip", "1"), g_bSemiclip);

    register_chat("/cp", "cmd_checkpoint");
    register_chat("/tp", "cmd_teleport");
    register_chat("/gc", "cmd_teleport");
    register_chat("/stuck", "cmd_stuck");
    register_chat("/start", "cmd_start");
    register_chat("/restart", "cmd_start");
    register_chat("/top", "cmd_top");

    register_clcmd("mv_zone", "cmd_zone", ADMIN_CFG, "<start|end|show|clear> - mark this map's timer zones");
    register_srvcmd("mv_zone_set", "srv_zone_set");
    register_srvcmd("mv_top", "srv_top");
    register_srvcmd("mv_record", "srv_record");

    RegisterHam(Ham_Use, "func_button", "on_button_use");
    RegisterHam(Ham_Spawn, "player", "on_spawn", 1);
    RegisterHam(Ham_Killed, "player", "on_killed", 1);
    RegisterHam(Ham_TakeDamage, "player", "on_take_damage");

    register_forward(FM_StartFrame, "on_frame");
    register_forward(FM_PlayerPreThink, "on_prethink");
    register_forward(FM_PlayerPostThink, "on_postthink");
    register_forward(FM_AddToFullPack, "on_fullpack", 1);

    g_iMaxPlayers = get_maxplayers();
    g_hudSync = CreateHudSyncObj();

    get_mapname(g_szMap, charsmax(g_szMap));
    strtolower(g_szMap);
    formatex(g_szRecordsFile, charsmax(g_szRecordsFile), "%s/%s.tsv", RECORDS_DIR, g_szMap);
    formatex(g_szZonesFile, charsmax(g_szZonesFile), "%s/%s.txt", ZONES_DIR, g_szMap);
    load_records();

    new szSkMode[16], szMapMode[16];
    get_localinfo("sk_mode", szSkMode, charsmax(szSkMode));
    get_localinfo("sk_mapmode", szMapMode, charsmax(szMapMode));
    if (equal(szSkMode, "auto") && (equal(szMapMode, "surf") || equal(szMapMode, "climb"))) {
        g_bSurf = bool:equal(szMapMode, "surf");
    } else {
        g_bSurf = bool:equal(g_szMap, "surf_", 5);
    }
    copy(g_szTag, charsmax(g_szTag), g_bSurf ? "SURF" : "CLIMB");

    g_bHasTimer = map_has_timer();
    load_zones();
    if (!g_bHasTimer && !g_bZone[ZONE_START] && g_bSurf) {
        g_bZoneAuto = spawn_zone();
    }
    log_amx("[MV] %s: %s, %d pro and %d cp times", g_szMap, timer_kind(),
        g_iTopCount[CAT_PRO], g_iTopCount[CAT_CP]);

    set_task(1.0, "show_timers", TASK_HUD, _, _, "b");
}

public plugin_precache() {
    g_iBeam = precache_model(BEAM_SPRITE);
}

timer_kind() {
    new szKind[48];
    if (g_bHasTimer) {
        copy(szKind, charsmax(szKind), "timer buttons found");
    } else if (g_bZone[ZONE_START] && g_bZone[ZONE_END]) {
        copy(szKind, charsmax(szKind), g_bZoneAuto ? "spawn start zone, end zone" : "start and end zones");
    } else if (g_bZone[ZONE_START]) {
        copy(szKind, charsmax(szKind), g_bZoneAuto ? "spawn start zone, no end zone" : "start zone, no end zone");
    } else {
        copy(szKind, charsmax(szKind), "no timer buttons");
    }
    return szKind;
}

bool:timed() {
    return bool:(g_bHasTimer || (g_bZone[ZONE_START] && g_bZone[ZONE_END]));
}

public plugin_end() {
    set_cvar_num("mp_forcerespawn", 0);
    set_cvar_num("mp_round_infinite", 0);
    set_cvar_num("mp_limitteams", 2);
    set_cvar_num("mp_falldamage", 1);
}

register_chat(const word[], const handler[]) {
    new szCmd[32];
    formatex(szCmd, charsmax(szCmd), "say %s", word);
    register_clcmd(szCmd, handler);
    formatex(szCmd, charsmax(szCmd), "say_team %s", word);
    register_clcmd(szCmd, handler);
}

bool:map_has_timer() {
    new ent = -1, szTarget[32];
    while ((ent = engfunc(EngFunc_FindEntityByString, ent, "classname", "func_button")) > 0) {
        pev(ent, pev_target, szTarget, charsmax(szTarget));
        if (in_list(szTarget, START_TARGETS, sizeof(START_TARGETS))) {
            return true;
        }
    }
    return false;
}

bool:in_list(const name[], const list[][], count) {
    for (new i = 0; i < count; i++) {
        if (equali(name, list[i])) {
            return true;
        }
    }
    return false;
}

// --- Players ----------------------------------------------------------------

public client_putinserver(id) {
    reset_player(id);
    if (!is_user_bot(id)) {
        set_task(8.0, "welcome", id);
    }
}

public client_disconnected(id) {
    remove_task(id);
    reset_player(id);
}

reset_player(id) {
    g_bRunning[id] = false;
    g_bHasStart[id] = false;
    g_iSaved[id] = 0;
    g_iCheckpoints[id] = 0;
    g_iTeleports[id] = 0;
    g_bSolid[id] = false;
    g_bRestore[id] = false;
    g_bInStart[id] = false;
    g_bCorner[id][ZONE_START] = false;
    g_bCorner[id][ZONE_END] = false;
}

public welcome(id) {
    if (!is_user_connected(id)) {
        return;
    }
    client_print(id, print_chat, "[%s] say /cp to save a checkpoint, /tp to return to it, /start to go back, /top for the best times.", g_szTag);
    if (!timed()) {
        client_print(id, print_chat, "[%s] This map has no timer yet, so runs are not timed here.", g_szTag);
    }
}

public on_spawn(id) {
    if (!is_user_alive(id) || !g_bRunning[id]) {
        return HAM_IGNORED;
    }
    // Died mid-run and respawned: carry on from the checkpoint.
    if (g_iSaved[id] > 0) {
        g_iTeleports[id]++;
        go_to_checkpoint(id, 0);
        client_print(id, print_chat, "[%s] Back on your checkpoint. This is a cp run now.", g_szTag);
    }
    return HAM_IGNORED;
}

public on_killed(id) {
    if (g_bRunning[id] && g_iSaved[id] == 0) {
        g_bRunning[id] = false;
        client_print(id, print_chat, "[%s] Run over. Head back to the start to go again.", g_szTag);
    }
    return HAM_IGNORED;
}

// No player hurts another. Falls and the map's own hazards still count.
public on_take_damage(victim, inflictor, attacker) {
    if (1 <= attacker <= g_iMaxPlayers && attacker != victim) {
        return HAM_SUPERCEDE;
    }
    return HAM_IGNORED;
}

// --- Timer ------------------------------------------------------------------

public on_button_use(ent, caller) {
    if (!(1 <= caller <= g_iMaxPlayers) || !is_user_alive(caller)) {
        return HAM_IGNORED;
    }
    new szTarget[32];
    pev(ent, pev_target, szTarget, charsmax(szTarget));
    if (in_list(szTarget, START_TARGETS, sizeof(START_TARGETS))) {
        start_run(caller);
    } else if (in_list(szTarget, STOP_TARGETS, sizeof(STOP_TARGETS))) {
        finish_run(caller);
    }
    return HAM_IGNORED;
}

// A button run restarts from the button; a zone run restarts from spawn,
// because the spot where a player left the start zone is in mid-air.
start_run(id, bool:fromButton = true) {
    g_bRunning[id] = true;
    g_fStarted[id] = get_gametime();
    g_iCheckpoints[id] = 0;
    g_iTeleports[id] = 0;
    g_iSaved[id] = 0;

    g_bHasStart[id] = fromButton;
    if (fromButton) {
        pev(id, pev_origin, g_fStartOrigin[id]);
        pev(id, pev_v_angle, g_fStartAngles[id]);
    }

    client_print(id, print_center, "Go!");
}

finish_run(id) {
    if (!g_bRunning[id]) {
        return;
    }
    g_bRunning[id] = false;

    new iCentis = floatround((get_gametime() - g_fStarted[id]) * 100.0, floatround_floor);
    new szName[NAME_LEN], szKey[KEY_LEN], szTime[16];
    get_user_name(id, szName, charsmax(szName));
    player_key(id, szKey, charsmax(szKey));
    format_time_centis(iCentis, szTime, charsmax(szTime));

    new iCat = g_iTeleports[id] > 0 ? CAT_CP : CAT_PRO;
    new iRank = record(iCat, szKey, szName, iCentis, g_iCheckpoints[id], g_iTeleports[id], get_systime());
    bump("mv_runs");

    if (iCat == CAT_PRO) {
        client_print(0, print_chat, "[%s] %s finished %s in %s (pro, no teleports).", g_szTag, szName, g_szMap, szTime);
    } else {
        client_print(0, print_chat, "[%s] %s finished %s in %s (%d checkpoints, %d teleports).",
            g_szTag, szName, g_szMap, szTime, g_iCheckpoints[id], g_iTeleports[id]);
    }
    if (iRank == 1) {
        client_print(0, print_chat, "[%s] New %s record on %s!", g_szTag, CAT_NAME[iCat], g_szMap);
    } else if (iRank > 0) {
        client_print(id, print_chat, "[%s] That is #%d on the %s list.", g_szTag, iRank, CAT_NAME[iCat]);
    }
}

public show_timers() {
    new szTime[16];
    for (new id = 1; id <= g_iMaxPlayers; id++) {
        if (!g_bRunning[id] || !is_user_alive(id)) {
            continue;
        }
        new iCentis = floatround((get_gametime() - g_fStarted[id]) * 100.0, floatround_floor);
        format_time_centis(iCentis - iCentis % 100, szTime, charsmax(szTime));
        // Whole seconds on the HUD; the finish message has the hundredths.
        szTime[strlen(szTime) - 3] = 0;
        set_hudmessage(255, 255, 255, -1.0, 0.92, 0, 0.0, 1.1, 0.0, 0.0, -1);
        ShowSyncHudMsg(id, g_hudSync, "%s   cp %d   tp %d", szTime, g_iCheckpoints[id], g_iTeleports[id]);
    }
}

format_time_centis(centis, out[], len) {
    new iMinutes = centis / 6000;
    new iSeconds = (centis / 100) % 60;
    formatex(out, len, "%02d:%02d.%02d", iMinutes, iSeconds, centis % 100);
}

// --- Checkpoints ------------------------------------------------------------

public cmd_checkpoint(id) {
    if (!is_user_alive(id)) {
        return PLUGIN_HANDLED;
    }
    if (!(pev(id, pev_flags) & FL_ONGROUND)) {
        client_print(id, print_center, "Stand on the ground to save a checkpoint");
        return PLUGIN_HANDLED;
    }
    // The newest becomes the one /stuck goes back to.
    for (new i = 0; i < 3; i++) {
        g_fCpOrigin[id][1][i] = g_fCpOrigin[id][0][i];
        g_fCpAngles[id][1][i] = g_fCpAngles[id][0][i];
    }
    g_bCpDucked[id][1] = g_bCpDucked[id][0];

    pev(id, pev_origin, g_fCpOrigin[id][0]);
    pev(id, pev_v_angle, g_fCpAngles[id][0]);
    g_bCpDucked[id][0] = bool:(pev(id, pev_flags) & FL_DUCKING);
    g_iSaved[id] = min(g_iSaved[id] + 1, 2);
    g_iCheckpoints[id]++;
    client_print(id, print_center, "Checkpoint #%d", g_iCheckpoints[id]);
    return PLUGIN_HANDLED;
}

public cmd_teleport(id) {
    teleport_cmd(id, 0);
    return PLUGIN_HANDLED;
}

public cmd_stuck(id) {
    teleport_cmd(id, 1);
    return PLUGIN_HANDLED;
}

teleport_cmd(id, which) {
    if (!is_user_alive(id)) {
        return;
    }
    if (g_iSaved[id] <= which) {
        client_print(id, print_center, which ? "No earlier checkpoint" : "No checkpoint yet: say /cp");
        return;
    }
    if (g_bRunning[id]) {
        g_iTeleports[id]++;
    }
    go_to_checkpoint(id, which);
}

go_to_checkpoint(id, which) {
    place(id, g_fCpOrigin[id][which], g_fCpAngles[id][which], g_bCpDucked[id][which]);
}

public cmd_start(id) {
    if (!is_user_connected(id)) {
        return PLUGIN_HANDLED;
    }
    g_bRunning[id] = false;
    g_iSaved[id] = 0;
    g_iCheckpoints[id] = 0;
    g_iTeleports[id] = 0;
    if (!is_user_alive(id)) {
        return PLUGIN_HANDLED;
    }
    if (g_bHasStart[id]) {
        place(id, g_fStartOrigin[id], g_fStartAngles[id], false);
    } else {
        ExecuteHamB(Ham_CS_RoundRespawn, id);
    }
    return PLUGIN_HANDLED;
}

place(id, const Float:origin[3], const Float:angles[3], bool:ducked) {
    set_pev(id, pev_velocity, Float:{ 0.0, 0.0, 0.0 });
    set_pev(id, pev_basevelocity, Float:{ 0.0, 0.0, 0.0 });
    if (ducked) {
        // A checkpoint saved crouching under a low ceiling: arrive crouched,
        // or the standing hull is stuck in it.
        set_pev(id, pev_flags, pev(id, pev_flags) | FL_DUCKING);
        engfunc(EngFunc_SetSize, id, Float:{ -16.0, -16.0, -18.0 }, Float:{ 16.0, 16.0, 32.0 });
    }
    engfunc(EngFunc_SetOrigin, id, origin);
    set_pev(id, pev_angles, angles);
    set_pev(id, pev_fixangle, 1);
}

// --- Top lists --------------------------------------------------------------

player_key(id, out[], len) {
    new szAuth[KEY_LEN];
    get_user_authid(id, szAuth, charsmax(szAuth));
    if (equal(szAuth, "STEAM_", 6) && contain(szAuth, "LAN") == -1 && contain(szAuth, "PENDING") == -1) {
        copy(out, len, szAuth);
    } else {
        new szName[NAME_LEN];
        get_user_name(id, szName, charsmax(szName));
        formatex(out, len, "name:%s", szName);
    }
    clean_field(out);
}

// A tab or a line break in a name would break the file's columns.
clean_field(text[]) {
    for (new i = 0; text[i]; i++) {
        if (text[i] < ' ') {
            text[i] = ' ';
        }
    }
}

// Enters a time. Returns the 1-based rank it took, or 0 when the player
// already has a time at least as good or the list is full of better ones.
record(cat, const key[], const name[], centis, checkpoints, teleports, when) {
    new iOld = -1;
    for (new i = 0; i < g_iTopCount[cat]; i++) {
        if (equal(g_szTopKey[cat][i], key)) {
            iOld = i;
            break;
        }
    }
    if (iOld >= 0) {
        if (g_iTopTime[cat][iOld] <= centis) {
            return 0;
        }
        for (new i = iOld; i < g_iTopCount[cat] - 1; i++) {
            copy_row(cat, i, i + 1);
        }
        g_iTopCount[cat]--;
    }

    new iPos = g_iTopCount[cat];
    while (iPos > 0 && g_iTopTime[cat][iPos - 1] > centis) {
        iPos--;
    }
    if (iPos >= MAX_TOP) {
        return 0;
    }
    if (g_iTopCount[cat] < MAX_TOP) {
        g_iTopCount[cat]++;
    }
    for (new i = g_iTopCount[cat] - 1; i > iPos; i--) {
        copy_row(cat, i, i - 1);
    }

    g_iTopTime[cat][iPos] = centis;
    g_iTopCheckpoints[cat][iPos] = checkpoints;
    g_iTopTeleports[cat][iPos] = teleports;
    g_iTopWhen[cat][iPos] = when;
    copy(g_szTopKey[cat][iPos], KEY_LEN - 1, key);
    copy(g_szTopName[cat][iPos], NAME_LEN - 1, name);
    clean_field(g_szTopName[cat][iPos]);

    save_records();
    bump("mv_bests");
    return iPos + 1;
}

copy_row(cat, to, from) {
    g_iTopTime[cat][to] = g_iTopTime[cat][from];
    g_iTopCheckpoints[cat][to] = g_iTopCheckpoints[cat][from];
    g_iTopTeleports[cat][to] = g_iTopTeleports[cat][from];
    g_iTopWhen[cat][to] = g_iTopWhen[cat][from];
    copy(g_szTopKey[cat][to], KEY_LEN - 1, g_szTopKey[cat][from]);
    copy(g_szTopName[cat][to], NAME_LEN - 1, g_szTopName[cat][from]);
}

load_records() {
    new f = fopen(g_szRecordsFile, "rt");
    if (!f) {
        return;
    }
    new szLine[256], szField[7][KEY_LEN];
    while (fgets(f, szLine, charsmax(szLine))) {
        trim(szLine);
        if (szLine[0] == 0 || szLine[0] == '#') {
            continue;
        }
        if (explode_string(szLine, "^t", szField, sizeof(szField), charsmax(szField[])) < 7) {
            continue;
        }
        new iCat = equal(szField[0], CAT_NAME[CAT_CP]) ? CAT_CP : CAT_PRO;
        new i = g_iTopCount[iCat];
        new iCentis = str_to_num(szField[1]);
        // The file is written in order; a row out of order (edited by hand)
        // or past the limit is dropped rather than trusted.
        if (i >= MAX_TOP || iCentis <= 0 || (i > 0 && g_iTopTime[iCat][i - 1] > iCentis)) {
            continue;
        }
        g_iTopTime[iCat][i] = iCentis;
        g_iTopCheckpoints[iCat][i] = str_to_num(szField[2]);
        g_iTopTeleports[iCat][i] = str_to_num(szField[3]);
        g_iTopWhen[iCat][i] = str_to_num(szField[4]);
        copy(g_szTopKey[iCat][i], KEY_LEN - 1, szField[5]);
        copy(g_szTopName[iCat][i], NAME_LEN - 1, szField[6]);
        g_iTopCount[iCat]++;
    }
    fclose(f);
}

save_records() {
    if (!dir_exists(RECORDS_DIR)) {
        mkdir(RECORDS_DIR);
    }
    new f = fopen(g_szRecordsFile, "wt");
    if (!f) {
        log_amx("[MV] cannot write %s", g_szRecordsFile);
        return;
    }
    for (new iCat = 0; iCat < CAT_COUNT; iCat++) {
        for (new i = 0; i < g_iTopCount[iCat]; i++) {
            fprintf(f, "%s^t%d^t%d^t%d^t%d^t%s^t%s^n", CAT_NAME[iCat], g_iTopTime[iCat][i],
                g_iTopCheckpoints[iCat][i], g_iTopTeleports[iCat][i], g_iTopWhen[iCat][i],
                g_szTopKey[iCat][i], g_szTopName[iCat][i]);
        }
    }
    fclose(f);
}

bump(const key[]) {
    new szCount[16];
    get_localinfo(key, szCount, charsmax(szCount));
    num_to_str(str_to_num(szCount) + 1, szCount, charsmax(szCount));
    set_localinfo(key, szCount);
}

public cmd_top(id) {
    static szBody[1536];
    new iLen = formatex(szBody, charsmax(szBody), "%s^n", g_szMap);
    new szTime[16];
    for (new iCat = 0; iCat < CAT_COUNT; iCat++) {
        iLen += formatex(szBody[iLen], charsmax(szBody) - iLen, "^n%s^n",
            iCat == CAT_PRO ? "Pro (no teleports)" : "With checkpoints");
        if (g_iTopCount[iCat] == 0) {
            iLen += formatex(szBody[iLen], charsmax(szBody) - iLen, "  no times yet^n");
        }
        for (new i = 0; i < g_iTopCount[iCat]; i++) {
            format_time_centis(g_iTopTime[iCat][i], szTime, charsmax(szTime));
            if (iCat == CAT_PRO) {
                iLen += formatex(szBody[iLen], charsmax(szBody) - iLen, "%2d. %s  %s^n",
                    i + 1, szTime, g_szTopName[iCat][i]);
            } else {
                iLen += formatex(szBody[iLen], charsmax(szBody) - iLen, "%2d. %s  %s  (%d tp)^n",
                    i + 1, szTime, g_szTopName[iCat][i], g_iTopTeleports[iCat][i]);
            }
        }
    }
    show_motd(id, szBody, "Best times");
    return PLUGIN_HANDLED;
}

public srv_top() {
    new szTime[16];
    for (new iCat = 0; iCat < CAT_COUNT; iCat++) {
        server_print("[MV] %s %s: %d", g_szMap, CAT_NAME[iCat], g_iTopCount[iCat]);
        for (new i = 0; i < g_iTopCount[iCat]; i++) {
            format_time_centis(g_iTopTime[iCat][i], szTime, charsmax(szTime));
            server_print("[MV] %s %d %s %s %s", CAT_NAME[iCat], i + 1, szTime, g_szTopKey[iCat][i], g_szTopName[iCat][i]);
        }
    }
    return PLUGIN_HANDLED;
}

public srv_record() {
    if (read_argc() != 6) {
        server_print("usage: mv_record ^"<player>^" ^"<name>^" <centiseconds> <checkpoints> <teleports>");
        return PLUGIN_HANDLED;
    }
    new szKey[KEY_LEN], szName[NAME_LEN], szNum[16];
    read_argv(1, szKey, charsmax(szKey));
    read_argv(2, szName, charsmax(szName));
    read_argv(3, szNum, charsmax(szNum));
    new iCentis = str_to_num(szNum);
    read_argv(4, szNum, charsmax(szNum));
    new iCheckpoints = str_to_num(szNum);
    read_argv(5, szNum, charsmax(szNum));
    new iTeleports = str_to_num(szNum);

    clean_field(szKey);
    if (szKey[0] == 0 || szName[0] == 0 || iCentis <= 0 || iCheckpoints < 0 || iTeleports < 0) {
        server_print("[MV] mv_record: a player, a name and a time above 0 are needed");
        return PLUGIN_HANDLED;
    }
    new iCat = iTeleports > 0 ? CAT_CP : CAT_PRO;
    new iRank = record(iCat, szKey, szName, iCentis, iCheckpoints, iTeleports, get_systime());
    if (iRank > 0) {
        server_print("[MV] recorded: %s #%d", CAT_NAME[iCat], iRank);
    } else {
        server_print("[MV] not recorded: no better than the time on the list");
    }
    return PLUGIN_HANDLED;
}

// --- Semiclip ---------------------------------------------------------------
// While one player's movement is computed, every other player is made
// non-solid, so nobody stands in anybody's way; the same is told to each
// client so its prediction agrees.

public on_frame() {
    for (new id = 1; id <= g_iMaxPlayers; id++) {
        g_bSolid[id] = bool:(g_bSemiclip && is_user_alive(id) && pev(id, pev_solid) == SOLID_SLIDEBOX);
    }
    return FMRES_IGNORED;
}

public on_prethink(id) {
    if (g_bZone[ZONE_START] && is_user_alive(id)) {
        check_zones(id);
    }
    if (!g_bSolid[id]) {
        return FMRES_IGNORED;
    }
    for (new i = 1; i <= g_iMaxPlayers; i++) {
        if (i != id && g_bSolid[i]) {
            set_pev(i, pev_solid, SOLID_NOT);
            g_bRestore[i] = true;
        }
    }
    return FMRES_IGNORED;
}

public on_postthink(id) {
    for (new i = 1; i <= g_iMaxPlayers; i++) {
        if (g_bRestore[i]) {
            set_pev(i, pev_solid, SOLID_SLIDEBOX);
            g_bRestore[i] = false;
        }
    }
    return FMRES_IGNORED;
}

public on_fullpack(es, e, ent, host, hostflags, player, pSet) {
    if (player && host != ent && g_bSolid[host] && g_bSolid[ent]) {
        set_es(es, ES_Solid, SOLID_NOT);
    }
    return FMRES_IGNORED;
}

// --- Zones ------------------------------------------------------------------

check_zones(id) {
    static Float:fOrigin[3];
    pev(id, pev_origin, fOrigin);
    if (in_zone(ZONE_START, fOrigin)) {
        // Back at the start: whatever run there was is off.
        g_bRunning[id] = false;
        g_bInStart[id] = true;
        return;
    }
    if (g_bInStart[id]) {
        g_bInStart[id] = false;
        if (g_bZone[ZONE_END]) {
            start_run(id, false);
        }
        return;
    }
    if (g_bRunning[id] && g_bZone[ZONE_END] && in_zone(ZONE_END, fOrigin)) {
        finish_run(id);
    }
}

bool:in_zone(zone, const Float:origin[3]) {
    for (new i = 0; i < 3; i++) {
        if (origin[i] < g_fZoneMin[zone][i] || origin[i] > g_fZoneMax[zone][i]) {
            return false;
        }
    }
    return true;
}

// Stores a zone from two opposite corners, in any order.
set_zone(zone, const Float:a[3], const Float:b[3]) {
    for (new i = 0; i < 3; i++) {
        g_fZoneMin[zone][i] = floatmin(a[i], b[i]);
        g_fZoneMax[zone][i] = floatmax(a[i], b[i]);
    }
    if (g_fZoneMax[zone][2] - g_fZoneMin[zone][2] < ZONE_MIN_HEIGHT) {
        g_fZoneMax[zone][2] = g_fZoneMin[zone][2] + ZONE_MIN_HEIGHT;
    }
    g_bZone[zone] = true;
    if (zone == ZONE_START) {
        g_bZoneAuto = false;
    }
}

// The box around every spawn point. False on a map without any.
bool:spawn_zone() {
    new const SPAWNS[][] = { "info_player_start", "info_player_deathmatch" };
    new Float:fMin[3], Float:fMax[3], Float:fOrigin[3], bool:bFound;
    for (new c = 0; c < sizeof(SPAWNS); c++) {
        new ent = -1;
        while ((ent = engfunc(EngFunc_FindEntityByString, ent, "classname", SPAWNS[c])) > 0) {
            pev(ent, pev_origin, fOrigin);
            for (new i = 0; i < 3; i++) {
                if (!bFound || fOrigin[i] < fMin[i]) {
                    fMin[i] = fOrigin[i];
                }
                if (!bFound || fOrigin[i] > fMax[i]) {
                    fMax[i] = fOrigin[i];
                }
            }
            bFound = true;
        }
    }
    if (!bFound) {
        return false;
    }
    for (new i = 0; i < 3; i++) {
        fMin[i] -= SPAWN_MARGIN;
        fMax[i] += SPAWN_MARGIN;
    }
    set_zone(ZONE_START, fMin, fMax);
    return true;
}

load_zones() {
    new f = fopen(g_szZonesFile, "rt");
    if (!f) {
        return;
    }
    new szLine[160], szField[7][24], Float:a[3], Float:b[3];
    while (fgets(f, szLine, charsmax(szLine))) {
        trim(szLine);
        if (parse(szLine, szField[0], charsmax(szField[]), szField[1], charsmax(szField[]),
                szField[2], charsmax(szField[]), szField[3], charsmax(szField[]),
                szField[4], charsmax(szField[]), szField[5], charsmax(szField[]),
                szField[6], charsmax(szField[])) < 7) {
            continue;
        }
        new iZone = zone_by_name(szField[0]);
        if (iZone < 0) {
            continue;
        }
        for (new i = 0; i < 3; i++) {
            a[i] = str_to_float(szField[1 + i]);
            b[i] = str_to_float(szField[4 + i]);
        }
        set_zone(iZone, a, b);
    }
    fclose(f);
}

save_zones() {
    if (!dir_exists(ZONES_DIR)) {
        mkdir(ZONES_DIR);
    }
    new f = fopen(g_szZonesFile, "wt");
    if (!f) {
        log_amx("[MV] cannot write %s", g_szZonesFile);
        return;
    }
    for (new z = 0; z < ZONE_COUNT; z++) {
        // The automatic start zone is worked out again on every map load.
        if (!g_bZone[z] || (z == ZONE_START && g_bZoneAuto)) {
            continue;
        }
        // Whole units: a box a player crosses needs no more, and the
        // float formatter here writes 64 as 63.9.
        fprintf(f, "%s %d %d %d %d %d %d^n", ZONE_NAME[z],
            floatround(g_fZoneMin[z][0]), floatround(g_fZoneMin[z][1]), floatround(g_fZoneMin[z][2]),
            floatround(g_fZoneMax[z][0]), floatround(g_fZoneMax[z][1]), floatround(g_fZoneMax[z][2]));
    }
    fclose(f);
}

zone_by_name(const name[]) {
    for (new z = 0; z < ZONE_COUNT; z++) {
        if (equali(name, ZONE_NAME[z])) {
            return z;
        }
    }
    return -1;
}

public cmd_zone(id, level, cid) {
    if (!cmd_access(id, level, cid, 2)) {
        return PLUGIN_HANDLED;
    }
    new szArg[16];
    read_argv(1, szArg, charsmax(szArg));

    if (equali(szArg, "show")) {
        show_zones(id);
        return PLUGIN_HANDLED;
    }
    if (equali(szArg, "clear")) {
        g_bZone[ZONE_START] = false;
        g_bZone[ZONE_END] = false;
        g_bZoneAuto = false;
        delete_file(g_szZonesFile);
        if (g_bSurf) {
            g_bZoneAuto = spawn_zone();
        }
        console_print(id, "[MV] zones cleared: %s", timer_kind());
        return PLUGIN_HANDLED;
    }
    new iZone = zone_by_name(szArg);
    if (iZone < 0 || !is_user_alive(id)) {
        console_print(id, "usage: mv_zone <start|end|show|clear> (alive, standing on a corner)");
        return PLUGIN_HANDLED;
    }

    new Float:fSpot[3];
    pev(id, pev_origin, fSpot);
    // The origin is 36 units above a standing player's feet.
    fSpot[2] -= 36.0;
    if (!g_bCorner[id][iZone]) {
        g_bCorner[id][iZone] = true;
        g_fCorner[id][iZone] = fSpot;
        console_print(id, "[MV] %s zone: first corner marked. Go to the opposite corner and run mv_zone %s again.",
            ZONE_NAME[iZone], ZONE_NAME[iZone]);
        return PLUGIN_HANDLED;
    }
    g_bCorner[id][iZone] = false;
    set_zone(iZone, g_fCorner[id][iZone], fSpot);
    save_zones();
    show_zones(id);
    new szAdmin[NAME_LEN];
    get_user_name(id, szAdmin, charsmax(szAdmin));
    log_amx("[MV] %s zone on %s set by %s: %s", ZONE_NAME[iZone], g_szMap, szAdmin, timer_kind());
    console_print(id, "[MV] %s zone saved: %s", ZONE_NAME[iZone], timer_kind());
    return PLUGIN_HANDLED;
}

public srv_zone_set() {
    new szArg[24];
    read_argv(1, szArg, charsmax(szArg));
    new iZone = zone_by_name(szArg);
    if (read_argc() != 8 || iZone < 0) {
        server_print("usage: mv_zone_set <start|end> <x1> <y1> <z1> <x2> <y2> <z2>");
        return PLUGIN_HANDLED;
    }
    new Float:a[3], Float:b[3];
    for (new i = 0; i < 3; i++) {
        read_argv(2 + i, szArg, charsmax(szArg));
        a[i] = str_to_float(szArg);
        read_argv(5 + i, szArg, charsmax(szArg));
        b[i] = str_to_float(szArg);
    }
    set_zone(iZone, a, b);
    save_zones();
    server_print("[MV] %s zone saved: %s", ZONE_NAME[iZone], timer_kind());
    return PLUGIN_HANDLED;
}

// The twelve edges of each box, as beams only this player sees.
show_zones(id) {
    static const EDGES[12][2] = {
        { 0, 1 }, { 0, 2 }, { 1, 3 }, { 2, 3 }, { 4, 5 }, { 4, 6 },
        { 5, 7 }, { 6, 7 }, { 0, 4 }, { 1, 5 }, { 2, 6 }, { 3, 7 }
    };
    new Float:fCorner[8][3];
    for (new z = 0; z < ZONE_COUNT; z++) {
        if (!g_bZone[z]) {
            continue;
        }
        for (new c = 0; c < 8; c++) {
            fCorner[c][0] = (c & 1) ? g_fZoneMax[z][0] : g_fZoneMin[z][0];
            fCorner[c][1] = (c & 2) ? g_fZoneMax[z][1] : g_fZoneMin[z][1];
            fCorner[c][2] = (c & 4) ? g_fZoneMax[z][2] : g_fZoneMin[z][2];
        }
        for (new e = 0; e < sizeof(EDGES); e++) {
            message_begin(MSG_ONE_UNRELIABLE, SVC_TEMPENTITY, _, id);
            write_byte(TE_BEAMPOINTS);
            engfunc(EngFunc_WriteCoord, fCorner[EDGES[e][0]][0]);
            engfunc(EngFunc_WriteCoord, fCorner[EDGES[e][0]][1]);
            engfunc(EngFunc_WriteCoord, fCorner[EDGES[e][0]][2]);
            engfunc(EngFunc_WriteCoord, fCorner[EDGES[e][1]][0]);
            engfunc(EngFunc_WriteCoord, fCorner[EDGES[e][1]][1]);
            engfunc(EngFunc_WriteCoord, fCorner[EDGES[e][1]][2]);
            write_short(g_iBeam);
            write_byte(0);
            write_byte(0);
            write_byte(80);
            write_byte(8);
            write_byte(0);
            write_byte(z == ZONE_START ? 0 : 255);
            write_byte(z == ZONE_START ? 255 : 0);
            write_byte(0);
            write_byte(200);
            write_byte(0);
            message_end();
        }
    }
}
