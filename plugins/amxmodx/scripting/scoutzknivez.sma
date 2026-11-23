// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
//
// Spawn loadout and game modes.
//
//   scoutz   scout + knife (default)
//   knife    knife only; buying and weapon pickups blocked ("Nipper Friday").
//            On grenade-fight maps (he_*, e.g. he_dodgeball2) HE grenades
//            placed by the map can be picked up; everything else stays blocked.
//   vanilla  stock Counter-Strike: the plugin leaves spawns and buying alone
//            and only applies the mode's settings.
//   match    5v5 competitive rules; match.amxx (in the mode's plugin list)
//            runs the warmup, knife round, sides and pauses.
//
// The mode lives in `localinfo sk_mode`, which survives map changes. On each
// map the plugin execs server.cfg, modes/<mode>.cfg and, if present,
// modes/<mode>_<prefix>.cfg (prefix = map name up to the first `_`, e.g.
// modes/knife_he.cfg). The engine does not re-run server.cfg on changelevel
// here, so without the first exec mode settings would leak across switches.
//
// A mode can have its own plugin list, addons/amxmodx/configs/modes/<mode>.ini.
// AMX Mod X reads the list named by `localinfo amxx_plugins` on every map
// load, so a switch points it at that file (or clears it: plugins.ini)
// before the changelevel. entrypoint.sh does the same for MODE at startup.
//
// `localinfo sk_bots 0` (set by BOTS=0) keeps bots off: server.cfg sets
// bot_quota, and re-running it would otherwise bring them back on every map.
//
// sk_switchmode <scoutz|knife|vanilla|match> <mapcyclefile> [map]
//   Server command (console/FIFO only). Announces the switch and changes level
//   at the next round end, never mid-round. Without a map, the first map of
//   the mapcycle that exists on disk is used. A no-op if already in that mode
//   and mapcycle.

#pragma semicolon 1

#include <amxmodx>
#include <cstrike>
#include <fun>
#include <hamsandwich>

#define MODE_LEN 16
#define TASK_SWITCH_DEADLINE 7301

// Switch anyway if no round has ended this long after the announcement
// (e.g. an empty server with bots off).
const Float:SWITCH_DEADLINE = 180.0;

new g_szMode[MODE_LEN];
new bool:g_bKnifeOnly;
new bool:g_bLoadout;
new g_szMapPrefix[32];
new bool:g_bGrenadeMap;

new g_szPendingMode[MODE_LEN];
new g_szPendingCycle[64];
new g_szPendingMap[64];
new bool:g_bSwitchPending;

public plugin_init() {
    register_plugin("ScoutzKnivez", "1.4", "cs-server");

    load_mode();

    RegisterHam(Ham_Spawn, "player", "on_spawn", 1);
    RegisterHam(Ham_Touch, "armoury_entity", "on_armoury_touch");
    RegisterHam(Ham_Touch, "weaponbox", "on_weaponbox_touch");

    register_logevent("on_round_end", 2, "1=Round_End");

    new pcvarQuota = get_cvar_pointer("bot_quota");
    if (pcvarQuota && bots_off()) {
        hook_cvar_change(pcvarQuota, "on_bot_quota");
    }
    register_srvcmd("sk_switchmode", "cmd_switchmode");
}

public plugin_cfg() {
    // Queue after the engine's startup execs so the mode's settings win.
    set_task(0.5, "exec_mode_cfg");
}

// Bots off: server.cfg sets bot_quota on every map (the engine runs it at
// map start, exec_mode_cfg again half a second later), and the game adds a
// bot on the very next frame. Until exec_mode_cfg put the 0 back, a bot
// joined on every start and was kicked again; a map change shortly after
// has crashed in that bot's navigation code (CNavArea::UpdateOnOpenList).
// Holding the cvar at 0 as it changes leaves no frame for a bot to join.
public on_bot_quota(pcvar, const szOld[], const szNew[]) {
    if (str_to_num(szNew) != 0) {
        set_pcvar_num(pcvar, 0);
    }
}

bool:bots_off() {
    new szBots[4];
    get_localinfo("sk_bots", szBots, charsmax(szBots));
    return bool:equal(szBots, "0");
}

load_mode() {
    get_localinfo("sk_mode", g_szMode, charsmax(g_szMode));
    if (!is_valid_mode(g_szMode)) {
        copy(g_szMode, charsmax(g_szMode), "scoutz");
    }
    g_bKnifeOnly = bool:equal(g_szMode, "knife");
    g_bLoadout = bool:(g_bKnifeOnly || equal(g_szMode, "scoutz"));

    new szMap[64];
    get_mapname(szMap, charsmax(szMap));
    new iSep = contain(szMap, "_");
    if (iSep > 0) {
        copy(g_szMapPrefix, min(iSep, charsmax(g_szMapPrefix)), szMap);
    }
    g_bGrenadeMap = g_bKnifeOnly && bool:equal(g_szMapPrefix, "he");
}

bool:is_valid_mode(const mode[]) {
    return bool:(equal(mode, "scoutz") || equal(mode, "knife") || equal(mode, "vanilla") || equal(mode, "match"));
}

public exec_mode_cfg() {
    new szCfg[64];
    formatex(szCfg, charsmax(szCfg), "modes/%s.cfg", g_szMode);
    // Base settings first, then the mode's overrides (same command buffer,
    // so they run in this order).
    server_cmd("exec server.cfg");
    if (file_exists(szCfg)) {
        server_cmd("exec %s", szCfg);
    }
    if (g_szMapPrefix[0]) {
        formatex(szCfg, charsmax(szCfg), "modes/%s_%s.cfg", g_szMode, g_szMapPrefix);
        if (file_exists(szCfg)) {
            server_cmd("exec %s", szCfg);
        }
    }
    if (bots_off()) {
        server_cmd("bot_quota 0");
    }
    log_amx("[SK] mode: %s%s", g_szMode, g_bGrenadeMap ? " (grenade pickups on)" : "");
}

public on_spawn(id) {
    if (!g_bLoadout || !is_user_alive(id))
        return HAM_IGNORED;

    strip_user_weapons(id);
    give_item(id, "weapon_knife");

    if (!g_bKnifeOnly) {
        give_item(id, "weapon_scout");
        cs_set_user_bpammo(id, CSW_SCOUT, 90);
    }

    return HAM_IGNORED;
}

// Knife mode: no picking up map-placed or dropped weapons, except HE
// grenades on grenade-fight maps.
public on_armoury_touch(ent, id) {
    if (!g_bKnifeOnly || !is_user_alive(id))
        return HAM_IGNORED;
    if (g_bGrenadeMap && cs_get_armoury_type(ent) == CSW_HEGRENADE)
        return HAM_IGNORED;
    return HAM_SUPERCEDE;
}

public on_weaponbox_touch(ent, id) {
    if (!g_bKnifeOnly || !is_user_alive(id))
        return HAM_IGNORED;
    if (g_bGrenadeMap) {
        new weapon = cs_get_weaponbox_item(ent);
        if (weapon > 0 && cs_get_weapon_id(weapon) == CSW_HEGRENADE)
            return HAM_IGNORED;
    }
    return HAM_SUPERCEDE;
}

// Knife mode: no buying, whatever mp_buytime says (buy-zone exploits exist
// on some knife maps).
public CS_OnBuyAttempt(id, item) {
    if (g_bKnifeOnly) {
        client_print(id, print_center, "Knives only");
        return PLUGIN_HANDLED;
    }
    return PLUGIN_CONTINUE;
}

public cmd_switchmode() {
    if (read_argc() < 3) {
        server_print("usage: sk_switchmode <scoutz|knife|vanilla|match> <mapcyclefile> [map]");
        return PLUGIN_HANDLED;
    }

    new szMode[MODE_LEN], szCycle[64], szMap[64];
    read_argv(1, szMode, charsmax(szMode));
    read_argv(2, szCycle, charsmax(szCycle));
    read_argv(3, szMap, charsmax(szMap));

    if (!is_valid_mode(szMode)) {
        server_print("[SK] unknown mode '%s' (scoutz|knife|vanilla|match)", szMode);
        return PLUGIN_HANDLED;
    }
    if (!is_safe_name(szCycle) || !file_exists(szCycle)) {
        server_print("[SK] mapcycle '%s' not found", szCycle);
        return PLUGIN_HANDLED;
    }

    new szCurrentCycle[64];
    get_cvar_string("mapcyclefile", szCurrentCycle, charsmax(szCurrentCycle));
    if (equal(szMode, g_szMode) && equali(szCycle, szCurrentCycle)) {
        server_print("[SK] already in mode %s (%s)", szMode, szCycle);
        return PLUGIN_HANDLED;
    }

    if (szMap[0] == 0 && !first_map_in_cycle(szCycle, szMap, charsmax(szMap))) {
        server_print("[SK] no playable map in %s", szCycle);
        return PLUGIN_HANDLED;
    }
    if (!map_exists(szMap)) {
        server_print("[SK] map '%s' not found", szMap);
        return PLUGIN_HANDLED;
    }

    copy(g_szPendingMode, charsmax(g_szPendingMode), szMode);
    copy(g_szPendingCycle, charsmax(g_szPendingCycle), szCycle);
    copy(g_szPendingMap, charsmax(g_szPendingMap), szMap);
    g_bSwitchPending = true;

    remove_task(TASK_SWITCH_DEADLINE);
    set_task(SWITCH_DEADLINE, "do_switch", TASK_SWITCH_DEADLINE);

    if (equal(szMode, "knife")) {
        client_print(0, print_chat, "[SERVER] Nipper Friday! Knives only on %s from the end of this round. Maps by NIPPER.", szMap);
    } else if (equal(szMode, "match")) {
        client_print(0, print_chat, "[SERVER] Match mode on %s from the end of this round: warmup, then say .ready", szMap);
    } else if (equal(szMode, "vanilla")) {
        client_print(0, print_chat, "[SERVER] Classic Counter-Strike on %s from the end of this round.", szMap);
    } else {
        client_print(0, print_chat, "[SERVER] Back to ScoutzKnivez on %s at the end of this round.", szMap);
    }
    log_amx("[SK] switch to %s (%s, %s) queued for round end", szMode, szCycle, szMap);
    return PLUGIN_HANDLED;
}

public on_round_end() {
    if (g_bSwitchPending) {
        // Let the round-end sounds and scoreboard play out briefly.
        remove_task(TASK_SWITCH_DEADLINE);
        set_task(3.0, "do_switch", TASK_SWITCH_DEADLINE);
    }
}

public do_switch() {
    if (!g_bSwitchPending)
        return;
    g_bSwitchPending = false;

    set_localinfo("sk_mode", g_szPendingMode);
    new szPlugins[96];
    formatex(szPlugins, charsmax(szPlugins), "addons/amxmodx/configs/modes/%s.ini", g_szPendingMode);
    set_localinfo("amxx_plugins", file_exists(szPlugins) ? szPlugins : "");
    set_cvar_string("mapcyclefile", g_szPendingCycle);
    log_amx("[SK] switching to %s (%s, %s)", g_szPendingMode, g_szPendingCycle, g_szPendingMap);
    server_cmd("changelevel %s", g_szPendingMap);
}

bool:is_safe_name(const name[]) {
    if (name[0] == 0 || name[0] == '.')
        return false;
    for (new i = 0; name[i]; i++) {
        new c = name[i];
        if (!(('a' <= c <= 'z') || ('A' <= c <= 'Z') || ('0' <= c <= '9') || c == '_' || c == '-' || c == '.'))
            return false;
    }
    return true;
}

bool:map_exists(const map[]) {
    if (!is_safe_name(map))
        return false;
    new szBsp[96];
    formatex(szBsp, charsmax(szBsp), "maps/%s.bsp", map);
    return bool:file_exists(szBsp);
}

bool:first_map_in_cycle(const cycle[], out[], len) {
    new f = fopen(cycle, "r");
    if (!f)
        return false;

    new szLine[64];
    new bool:found;
    while (!found && fgets(f, szLine, charsmax(szLine))) {
        trim(szLine);
        if (szLine[0] == 0 || szLine[0] == ';' || szLine[0] == '/')
            continue;
        if (map_exists(szLine)) {
            copy(out, len, szLine);
            found = true;
        }
    }
    fclose(f);
    return found;
}
