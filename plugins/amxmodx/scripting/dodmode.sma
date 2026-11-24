// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
//
// Re-applies the Day of Defeat mode file after each map starts.
//
// The command line execs pub.cfg or match.cfg before the map is up. Day of
// Defeat then resets the hostname and mp_timelimit, so a console `exec` is
// what makes them stick. plugin_cfg runs once the map is in, which is late
// enough. The file also sets dod_cfg, so a later `exec match.cfg` or
// `exec match-ot.cfg` is what the next map applies.

#pragma semicolon 1

#include <amxmodx>

public plugin_init() {
    register_plugin("DoD Mode", "1.0", "cs-server");
    register_cvar("dod_cfg", "pub.cfg");

    new mode[8];
    get_localinfo("dod_mode", mode, charsmax(mode));
    if (equal(mode, "match")) {
        set_cvar_string("dod_cfg", "match.cfg");
    } else if (equal(mode, "pub")) {
        set_cvar_string("dod_cfg", "pub.cfg");
    }
}

public plugin_cfg() {
    new cfg[32];
    get_cvar_string("dod_cfg", cfg, charsmax(cfg));
    if (!equal(cfg, "pub.cfg") && !equal(cfg, "match.cfg") && !equal(cfg, "match-ot.cfg")) {
        return;
    }
    server_cmd("exec %s", cfg);
    server_exec();
}
