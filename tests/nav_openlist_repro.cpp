// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
//
// Deterministic repro of the ReGameDLL_CS 5.30.0.814 crash in
// CNavArea::UpdateOnOpenList (rehlds/ReGameDLL_CS#1202, cs-server#122).
//
// The open-list operations below are the ones in
// regamedll/game_shared/bot/nav_area.cpp (AddToOpenList, UpdateOnOpenList,
// RemoveFromOpenList, ClearSearchLists) and nav_area.h (IsOpen, PopOpenList,
// the NavAreaBuildPath branch that calls UpdateOnOpenList). m_masterMarker
// starts at 1, as in nav_area.cpp. Initialize() does not set the open-list
// fields. Bots and hostage AI both reach this through NavAreaBuildPath.
//
// Build with -DNAV_OPENLIST_FIX for the patch: the three fields are
// value-initialized, which is what scripts/regamedll-nav-openlist.patch does
// to CNavArea. Without it they keep whatever the allocation contained.
//
//   nav_openlist_repro <poison|zeroed> [searches]
//
// poison: each new area's leftover m_openMarker equals the generation the
// next search will install, and m_prevOpen is 0x1. The unfixed build
// segfaults in UpdateOnOpenList on the first search. The fixed build
// overwrites those bytes in the constructor.
// zeroed: leftover bytes are 0. m_openMarker 0 is not a live generation, so
// both builds finish the search. That is why the dedicated server only
// crashes sometimes: the leftover word has to equal the live generation.

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>

struct Area {
    unsigned m_marker;
    float m_totalCost;
    float m_costSoFar;
    Area *m_down;
    Area *m_side;
    static Area *m_openList;
    static unsigned m_masterMarker;

#if defined(NAV_OPENLIST_FIX)
    Area *m_nextOpen = nullptr;
    Area *m_prevOpen = nullptr;
    unsigned m_openMarker = 0;
#else
    Area *m_nextOpen;
    Area *m_prevOpen;
    unsigned m_openMarker;
#endif

    Area()
    {
        // Same omission as CNavArea::Initialize() in 5.30.0.814: the
        // open-list fields are not written. Default member initializers
        // (the fix) have already run, ahead of this body.
        m_marker = 0;
        m_totalCost = 0.f;
        m_costSoFar = 0.f;
        m_down = nullptr;
        m_side = nullptr;
    }

    static void MakeNewMarker()
    {
        if (++m_masterMarker == 0)
            m_masterMarker = 1;
    }

    void Mark() { m_marker = m_masterMarker; }
    bool IsMarked() const { return m_marker == m_masterMarker; }
    bool IsOpen() const { return m_openMarker == m_masterMarker; }
    bool IsClosed() const { return IsMarked() && !IsOpen(); }
    void AddToClosedList() { Mark(); }

    float GetTotalCost() const { return m_totalCost; }
    float GetCostSoFar() const { return m_costSoFar; }
    void SetCostSoFar(float value) { m_costSoFar = value; }
    void SetTotalCost(float value) { m_totalCost = value; }

    void AddToOpenList()
    {
        m_openMarker = m_masterMarker;
        if (!m_openList) {
            m_openList = this;
            m_prevOpen = nullptr;
            m_nextOpen = nullptr;
            return;
        }
        Area *area;
        Area *last = nullptr;
        for (area = m_openList; area; area = area->m_nextOpen) {
            if (GetTotalCost() < area->GetTotalCost())
                break;
            last = area;
        }
        if (area) {
            m_prevOpen = area->m_prevOpen;
            if (m_prevOpen)
                m_prevOpen->m_nextOpen = this;
            else
                m_openList = this;
            m_nextOpen = area;
            area->m_prevOpen = this;
        } else {
            last->m_nextOpen = this;
            m_prevOpen = last;
            m_nextOpen = nullptr;
        }
    }

    // No early return. 5.30.0.814 does not have one; a caller that reaches
    // here with a stale "open" flag must follow m_prevOpen, which is the crash.
    void UpdateOnOpenList()
    {
        while (m_prevOpen && GetTotalCost() < m_prevOpen->GetTotalCost()) {
            Area *other = m_prevOpen;
            Area *before = other->m_prevOpen;
            Area *after = m_nextOpen;
            m_nextOpen = other;
            m_prevOpen = before;
            other->m_prevOpen = this;
            other->m_nextOpen = after;
            if (before)
                before->m_nextOpen = this;
            else
                m_openList = this;
            if (after)
                after->m_prevOpen = other;
        }
    }

    void RemoveFromOpenList()
    {
        if (m_prevOpen)
            m_prevOpen->m_nextOpen = m_nextOpen;
        else
            m_openList = m_nextOpen;
        if (m_nextOpen)
            m_nextOpen->m_prevOpen = m_prevOpen;
        m_openMarker = 0;
    }

    static void ClearSearchLists()
    {
        MakeNewMarker();
        m_openList = nullptr;
    }

    static bool IsOpenListEmpty() { return m_openList == nullptr; }

    static Area *PopOpenList()
    {
        if (!m_openList)
            return nullptr;
        Area *area = m_openList;
        area->RemoveFromOpenList();
        return area;
    }
};

Area *Area::m_openList = nullptr;
unsigned Area::m_masterMarker = 1;

static unsigned next_generation()
{
    unsigned next = Area::m_masterMarker + 1;
    if (next == 0)
        next = 1;
    return next;
}

// Leftover heap, written before the constructor. poison makes the leftover
// generation equal the one ClearSearchLists is about to install, and points
// m_prevOpen at an unmapped address. zeroed is the lucky allocation.
static Area *create(bool poison)
{
    void *mem = std::malloc(sizeof(Area));
    if (!mem)
        std::abort();
    std::memset(mem, 0, sizeof(Area));
    if (poison) {
        auto *bytes = static_cast<unsigned char *>(mem);
        unsigned marker = next_generation();
        auto *bad = reinterpret_cast<Area *>(static_cast<std::uintptr_t>(1));
        std::memcpy(bytes + offsetof(Area, m_openMarker), &marker, sizeof(marker));
        std::memcpy(bytes + offsetof(Area, m_prevOpen), &bad, sizeof(bad));
        std::memcpy(bytes + offsetof(Area, m_nextOpen), &bad, sizeof(bad));
    }
    return new (mem) Area();
}

static void destroy(Area *area)
{
    area->~Area();
    std::free(area);
}

// NavAreaBuildPath's open-list branch, on a start with a cheap path to the
// goal and a dearer side branch. Returning at the goal leaves the side
// branch on the open list, which is what a real mesh does, and what
// DestroyNavigationMap then frees without unlinking.
static bool search(Area *start, Area *goal)
{
    Area::ClearSearchLists();
    start->SetCostSoFar(0.f);
    start->SetTotalCost(0.f);
    start->AddToOpenList();

    while (!Area::IsOpenListEmpty()) {
        Area *area = Area::PopOpenList();
        if (area == goal)
            return true;

        Area *neighbors[2] = {area->m_down, area->m_side};
        for (Area *next : neighbors) {
            if (!next)
                continue;
            float step = (next == area->m_down) ? 1.f : 100.f;
            float so_far = area->GetCostSoFar() + step;
            if ((next->IsOpen() || next->IsClosed()) && next->GetCostSoFar() <= so_far)
                continue;
            next->SetCostSoFar(so_far);
            next->SetTotalCost(so_far);
            if (next->IsClosed()) {
                // closed means marked and not open; clearing the mark is a no-op
                // in the real RemoveFromClosedList.
            }
            if (next->IsOpen())
                next->UpdateOnOpenList();
            else
                next->AddToOpenList();
        }
        area->AddToClosedList();
    }
    return false;
}

int main(int argc, char **argv)
{
    bool poison = true;
    int searches = 1;
    if (argc >= 2 && std::strcmp(argv[1], "zeroed") == 0)
        poison = false;
    else if (argc < 2 || std::strcmp(argv[1], "poison") != 0) {
        std::fprintf(stderr, "usage: %s <poison|zeroed> [searches]\n", argv[0]);
        return 2;
    }
    if (argc >= 3)
        searches = std::atoi(argv[2]);
    if (searches < 1)
        return 2;

    int left_on_list = 0;
    for (int n = 0; n < searches; n++) {
        // Map change. The previous search's open list is not cleared here.
        // DestroyNavigationMap doesn't either; the next search's
        // ClearSearchLists drops the head without reading it.
        Area *start = create(poison);
        Area *goal = create(poison);
        Area *side = create(poison);
        start->m_down = goal;
        start->m_side = side;
        // Initialize() zeroes the costs. A leftover generation that also
        // looks cheaper than this step would be skipped, and never bubble.
        // The crash is the other leftover: a matching generation whose
        // stored cost does not win, so UpdateOnOpenList runs.
        goal->m_costSoFar = 1.0e30f;
        goal->m_totalCost = 1.0e30f;
        side->m_costSoFar = 1.0e30f;
        side->m_totalCost = 1.0e30f;

        if (!search(start, goal)) {
            std::fprintf(stderr, "search failed\n");
            return 1;
        }
        if (Area::m_openList)
            left_on_list++;

        destroy(side);
        destroy(goal);
        destroy(start);
    }

    std::printf("nav-openlist: fix=%d mode=%s searches=%d left_on_list=%d crashes=0\n",
#if defined(NAV_OPENLIST_FIX)
                1,
#else
                0,
#endif
                poison ? "poison" : "zeroed", searches, left_on_list);
    return 0;
}
