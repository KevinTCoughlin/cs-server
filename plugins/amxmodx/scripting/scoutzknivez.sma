// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin

#include <amxmodx>
#include <cstrike>
#include <fun>
#include <hamsandwich>

public plugin_init() {
    register_plugin("ScoutzKnivez", "1.0", "cs-server")
    RegisterHam(Ham_Spawn, "player", "on_spawn", 1)
}

public on_spawn(id) {
    if (!is_user_alive(id))
        return

    strip_user_weapons(id)
    give_item(id, "weapon_knife")
    give_item(id, "weapon_scout")
    cs_set_user_bpammo(id, CSW_SCOUT, 90)
}
