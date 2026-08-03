-- Mock vanilla 1.12 WoW API + Lua 5.0 shims, to smoke-test CopeLoot
table.getn = function(t) return #t end
math.mod   = function(a,b) return a % b end
tinsert    = table.insert
UISpecialFrames = {}
SlashCmdList = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(self,m) print("CHAT: "..tostring(m)) end }

local calls = {}

-- Methods that genuinely exist on vanilla 1.12 Frame/FontString/Texture widgets.
-- Anything outside this set errors, mirroring the real client. This is what lets
-- the harness catch bogus calls instead of silently stubbing them.
VALID_WIDGET_METHODS = {}
for _, m in ipairs({
  "SetWidth","SetHeight","SetPoint","SetAllPoints","ClearAllPoints","GetWidth","GetHeight",
  "Show","Hide","IsShown","IsVisible","SetParent","GetParent","GetName",
  "SetBackdrop","SetBackdropColor","SetBackdropBorderColor",
  "SetMovable","EnableMouse","EnableMouseWheel","RegisterForDrag","RegisterForClicks",
  "StartMoving","StopMovingOrSizing","SetFrameStrata","SetFrameLevel",
  "SetScript","GetScript","HasScript","RegisterEvent","UnregisterEvent",
  "CreateFontString","CreateTexture","SetText","GetText","SetTextColor",
  "SetJustifyH","SetJustifyV","SetFont","SetFontObject","SetTexture","SetTexCoord",
  "SetVertexColor","SetAlpha","SetChecked","GetChecked",
  "SetMinMaxValues","GetMinMaxValues","SetValue","GetValue","SetValueStep",
  "SetOrientation","SetThumbTexture","GetThumbTexture","SetText","GetText",
}) do VALID_WIDGET_METHODS[m] = true end

-- Methods that exist ONLY on ScrollFrame. Calling them on any other widget
-- must fail, exactly as it does in-game.
SCROLLFRAME_ONLY = { SetVerticalScroll = true, GetVerticalScroll = true,
                     SetHorizontalScroll = true, SetScrollChild = true }

local function widget(kind, name)
  local w = { __kind = kind, __name = name, __shown = false, __children = {} }
  local mt = {}
  mt.__index = function(t, k)
    if type(k) == "string" and string.sub(k,1,2) == "__" then return nil end
    if type(k) == "string" and SCROLLFRAME_ONLY[k] and t.__kind ~= "ScrollFrame" then
      error("attempt to call method '"..k.."' (a nil value)", 2)
    end
    if type(k) == "string" and SCROLLFRAME_ONLY[k] then
      local f = function() end; rawset(t,k,f); return f
    end
    if type(k) == "string" and not VALID_WIDGET_METHODS[k] then
      error("attempt to call method '"..k.."' (a nil value)", 2)
    end
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
  f.__parent = parent
  f.GetParent = function(self) return self.__parent end
  if template == "UIPanelScrollBarTemplate" then
    -- Vanilla's template attaches this XML handler; it assumes a ScrollFrame parent.
    -- Reproduces the real "SetVerticalScroll (a nil value)" failure.
    f.__scripts = f.__scripts or {}
    f.__scripts.OnValueChanged = function()
      local p = f:GetParent()
      p:SetVerticalScroll(f:GetValue())
    end
  end
  if name then _G[name] = f; frames[name] = f end
  return f
end
UIParent = widget("Frame", "UIParent")

-- Raid state, controllable by the test
_numRaid = 0
function GetNumRaidMembers() return _numRaid end
function GetRaidRosterInfo(i)
  if i == 1 then return "Lokiy", 2, 1, 60, "Priest", "PRIEST", "", true, false end
  if i == 2 then return "Gnomosek", 0, 1, 60, "Mage", "MAGE", "", true, false end
  return nil
end
function SendChatMessage(msg, channel) print("SEND["..channel.."]: "..msg) end
function UnitName(unit)
  if unit == "player" then return "Lokiy" end
  local i = string.match(unit or "", "^raid(%d+)$")
  if i then return ({"Lokiy","Someone"})[tonumber(i)] end
  return nil
end
function time() return 1234567 end

_G = _G or getfenv and getfenv(0) or _ENV
