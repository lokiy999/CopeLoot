-- Mock vanilla 1.12 WoW API + Lua 5.0 shims, to smoke-test CopeLoot
table.getn = function(t) return #t end
math.mod   = function(a,b) return a % b end
tinsert    = table.insert
UISpecialFrames = {}
SlashCmdList = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(self,m) print("CHAT: "..tostring(m)) end }

local calls = {}
local function widget(kind, name)
  local w = { __kind = kind, __name = name, __shown = false, __children = {} }
  local mt = {}
  mt.__index = function(t, k)
    if type(k) == "string" and string.sub(k,1,2) == "__" then return nil end
    -- Every unknown method is recorded and returns a no-op that logs
    local f = function(self, ...)
      calls[#calls+1] = (t.__name or "<unnamed>")..":"..k
      return nil
    end
    rawset(t, k, f)
    return f
  end
  setmetatable(w, mt)
  -- Explicit behaviours we care about
  w.SetPoint = function(self, point, rel, relPoint, x, y)
    -- Enforce the VANILLA 1.12 strictness that caused the reported bug
    if point == nil then error("SetPoint: missing point",2) end
    if rel == nil or relPoint == nil then
      error("Usage: "..(self.__name or "<unnamed>")..':SetPoint("point", region, "relativePoint", offsetX, offsetY)', 2)
    end
    return nil
  end
  w.Show      = function(self) self.__shown = true end
  w.Hide      = function(self) self.__shown = false end
  w.IsShown   = function(self) return self.__shown end
  w.GetValue  = function(self) return self.__value or 0 end
  w.SetValue  = function(self, v)
     self.__value = v
     if self.__scripts and self.__scripts.OnValueChanged then
       local prev = this; this = self; self.__scripts.OnValueChanged(); this = prev
     end
  end
  w.GetChecked = function(self) return self.__checked end
  w.SetChecked = function(self, v) self.__checked = v end
  w.SetScript = function(self, ev, fn) self.__scripts = self.__scripts or {}; self.__scripts[ev] = fn end
  w.GetScript = function(self, ev) return self.__scripts and self.__scripts[ev] end
  w.CreateFontString = function(self) return widget("FontString", nil) end
  w.CreateTexture    = function(self) return widget("Texture", nil) end
  return w
end

local frames = {}
function CreateFrame(kind, name, parent, template)
  local f = widget(kind, name)
  if name then _G[name] = f; frames[name] = f end
  return f
end
UIParent = widget("Frame", "UIParent")

-- Raid state, controllable by the test
_numRaid = 0
function GetNumRaidMembers() return _numRaid end
function UnitName(unit)
  if unit == "player" then return "Lokiy" end
  local i = string.match(unit or "", "^raid(%d+)$")
  if i then return ({"Lokiy","Someone"})[tonumber(i)] end
  return nil
end
function time() return 1234567 end

_G = _G or getfenv and getfenv(0) or _ENV
