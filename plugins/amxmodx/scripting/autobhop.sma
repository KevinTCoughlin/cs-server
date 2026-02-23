// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
//
// Auto Bunny Hop — Automatically re-jumps when a player holds the jump key
// and touches the ground. Essential for low-gravity ScoutzKnivez gameplay.

#include <amxmodx>
#include <fakemeta>

new g_pcvarEnabled;

public plugin_init() {
    register_plugin("Auto Bhop", "1.0", "cs-server");
    register_forward(FM_PlayerPreThink, "fw_player_prethink");
    g_pcvarEnabled = register_cvar("autobhop_enabled", "1");
}

public fw_player_prethink(id) {
    if (!get_pcvar_num(g_pcvarEnabled))
        return FMRES_IGNORED;

    if (!is_user_alive(id))
        return FMRES_IGNORED;

    // Check if player is holding +jump
    new buttons = pev(id, pev_button);
    if (!(buttons & IN_JUMP))
        return FMRES_IGNORED;

    // Check if player is on the ground
    new flags = pev(id, pev_flags);
    if (!(flags & FL_ONGROUND))
        return FMRES_IGNORED;

    // Remove jump bit briefly so the engine registers a fresh press
    set_pev(id, pev_button, buttons & ~IN_JUMP);

    return FMRES_IGNORED;
}
