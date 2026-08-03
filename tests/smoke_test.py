# Smoke test: runs CopeLoot against a mock vanilla 1.12 WoW API.
# Requires: pip install lupa    Run: python tests/smoke_test.py
import os
import lupa, io
L = lupa.LuaRuntime(unpack_returned_tuples=True)
g = L.globals()
g._G = g
import os
base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..") + "/"
L.execute(io.open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'wow_api_mock.lua'), encoding='utf-8').read())
for p in ['CopeLoot_Data.lua','CopeLoot.lua']:
    L.execute(io.open(base+p, encoding='utf-8').read())
print("== files loaded OK ==")

# Fire ADDON_LOADED then PLAYER_LOGIN like the client does
ev = g.CopeLootEventFrame
def fire(event, arg1=None):
    g.event = event; g.arg1 = arg1; g.this = ev
    ev.__scripts.OnEvent()

fire("ADDON_LOADED", "CopeLoot")
fire("PLAYER_LOGIN")
print("== events OK ==")

# Open the window (this builds the entire UI - where the SetPoint bug lived)
g.CopeLoot.Toggle(g.CopeLoot)
print("== window built + shown:", g.CopeLootMainFrame.IsShown(g.CopeLootMainFrame), "==")

# Click the tabs
g.CopeLootTabSettings.__scripts.OnClick()
print("== settings tab OK, autoSwap checkbox =", g.CopeLootAutoSwapCB.GetChecked(g.CopeLootAutoSwapCB), "==")
g.CopeLootTabWishlist.__scripts.OnClick()
print("== wishlist tab OK ==")

# Click both filters
g.CopeLootFilterRaid.__scripts.OnClick()
print("== raid filter OK ==")
g.CopeLootFilterAll.__scripts.OnClick()
print("== all filter OK ==")

# Simulate joining a raid -> auto-swap should flip the filter
g._numRaid = 2
fire("RAID_ROSTER_UPDATE")
print("== joined raid, auto-swap fired OK ==")
g._numRaid = 0
fire("RAID_ROSTER_UPDATE")
print("== left raid OK ==")

# Toggle the checkbox off, rejoin raid (should NOT swap)
g.CopeLootTabSettings.__scripts.OnClick()
cb = g.CopeLootAutoSwapCB
cb.SetChecked(cb, False)
g.this = cb; cb.__scripts.OnClick()
print("== autoSwap disabled, DB =", g.CopeLootDB.autoSwap, "==")

# Slash command
g.SlashCmdList["COPELOOT"]("")   # close
g.SlashCmdList["COPELOOT"]("")   # open
print("== slash command OK ==")
print("\nALL RUNTIME CHECKS PASSED")
