// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
//
// Auto Bunny Hop — Automatically re-jumps when a player holds the jump key
// and touches the ground. Essential for low-gravity ScoutzKnivez gameplay.

#pragma semicolon 1

#include <amxmodx>
#include <fakemeta>

// Bound directly to the cvar value — avoids a pcvar lookup on every physics
// frame (~100 calls/sec per player, ~2000/sec at full 20-player capacity).
new g_bEnabled;

public plugin_init() {
    register_plugin("Auto Bhop", "1.0", "cs-server");
    register_forward(FM_PlayerPreThink, "fw_player_prethink");
    bind_pcvar_num(register_cvar("autobhop_enabled", "1"), g_bEnabled);
}

public fw_player_prethink(id) {
    if (!g_bEnabled)
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
