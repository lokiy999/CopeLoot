-- CopeLoot.lua
-- Wishlist-based loot addon for the guild <Cope>
-- Target client: World of Warcraft Classic 1.12.1 (Vanilla API)

CopeLoot = {}
local CopeLoot = CopeLoot

CopeLoot.name    = "CopeLoot"
CopeLoot.version = "0.1.0"

-- ---------------------------------------------------------------------------
-- Class colors (vanilla palette)
-- ---------------------------------------------------------------------------
local CLASS_COLORS = {
	["Druid"]   = { r = 1.00, g = 0.49, b = 0.04 },
	["Hunter"]  = { r = 0.67, g = 0.83, b = 0.45 },
	["Mage"]    = { r = 0.41, g = 0.80, b = 0.94 },
	["Paladin"] = { r = 0.96, g = 0.55, b = 0.73 },
	["Priest"]  = { r = 1.00, g = 1.00, b = 1.00 },
	["Rogue"]   = { r = 1.00, g = 0.96, b = 0.41 },
	["Shaman"]  = { r = 0.00, g = 0.44, b = 0.87 },
	["Warlock"] = { r = 0.58, g = 0.51, b = 0.79 },
	["Warrior"] = { r = 0.78, g = 0.61, b = 0.43 },
}

-- ---------------------------------------------------------------------------
-- Saved variables  (settings persisted across sessions)
-- ---------------------------------------------------------------------------
-- CopeLootDB = {
--   autoSwap      = true/false,
--   autoBroadcast = true/false,
-- }

local function EnsureDB()
	if not CopeLootDB then
		CopeLootDB = {}
	end
	if CopeLootDB.autoSwap == nil then
		CopeLootDB.autoSwap = true
	end
	if CopeLootDB.autoBroadcast == nil then
		CopeLootDB.autoBroadcast = false
	end
	return CopeLootDB
end

-- ---------------------------------------------------------------------------
-- Chat output helper
-- ---------------------------------------------------------------------------
local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[CopeLoot]|r " .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- Data helpers
-- ---------------------------------------------------------------------------
-- Reads CopeLoot_PlayerData (from CopeLoot_Data.lua) into a fast-lookup map.

local playerDataByName = {}

local function IndexPlayerData()
	playerDataByName = {}
	if CopeLoot_PlayerData then
		for i = 1, table.getn(CopeLoot_PlayerData) do
			local p = CopeLoot_PlayerData[i]
			playerDataByName[p.name] = p
		end
	end
end

-- ---------------------------------------------------------------------------
-- Item contention index  (rebuilt on each RefreshUI from the active dataset)
-- ---------------------------------------------------------------------------
-- itemIndex[normalised_name] = {
--   highest  = 1..3,          -- the highest-priority (lowest number) column
--   slots    = { [col] = count },   -- how many players have it in this column
-- }
local itemIndex = {}

local function NormaliseItemName(raw)
	-- Parenthetical notes like "(Questhero)" or "(Ronald)" denote ALT
	-- characters.  They are kept in the display text but stripped here so
	-- "Maladath (Ronald)" and "Maladath" contest the same slot.
	--
	-- Square brackets like "[Fists]" or "[1h Mace]" denote different stat
	-- rolls of the same base item and are KEPT so that e.g.
	-- "Ring of Master [Fists]" and "Ring of Master [1h Mace]" are treated
	-- as separate items.
	if not raw or raw == "" then return "" end
	local name = string.gsub(raw, "%s*%(.-%)%s*$", "")
	-- Strip trailing whitespace
	name = string.gsub(name, "%s+$", "")
	return string.lower(name)
end

local function BuildItemIndex(playerList)
	itemIndex = {}
	for i = 1, table.getn(playerList) do
		local p = playerList[i]
		for col = 1, 3 do
			local raw
			if col == 1 then raw = p.wish1
			elseif col == 2 then raw = p.wish2
			else raw = p.wish3
			end
			local key = NormaliseItemName(raw)
			if key ~= "" then
				if not itemIndex[key] then
					itemIndex[key] = { highest = col, slots = {} }
				end
				if not itemIndex[key].slots[col] then
					itemIndex[key].slots[col] = 0
				end
				itemIndex[key].slots[col] = itemIndex[key].slots[col] + 1
				if col < itemIndex[key].highest then
					itemIndex[key].highest = col
				end
			end
		end
	end
end

-- Returns r, g, b for an item text in a given column.
-- Rules:
--   Green  (0.3, 1, 0.3)  : item is untied in ANY column and this is the
--                            highest column it appears in.
--   Red    (1, 0.3, 0.3)  : item appears in a HIGHER-priority column for
--                            someone else (i.e. itemIndex.highest < col).
--   Yellow (1, 1, 0.3)    : item is tied (>1 player) in this column AND
--                            this is the highest column it appears in.
--   White  (1, 1, 1)      : fallback / empty.
local function GetItemColor(rawName, col)
	local key = NormaliseItemName(rawName)
	if key == "" then return 0.4, 0.4, 0.4 end  -- empty slot, dim

	local info = itemIndex[key]
	if not info then return 1, 1, 1 end  -- unknown, white

	-- Red: someone else has it in a higher column
	if info.highest < col then
		return 1, 0.3, 0.3
	end

	-- This IS the highest column for this item
	local countHere = info.slots[col] or 0
	if countHere > 1 then
		-- Yellow: tied in the highest column
		return 1, 1, 0.3
	end

	-- Green: untied in the highest column
	return 0.3, 1, 0.3
end

-- Returns an ordered list of player entries for the active filter.
-- filter: "all" | "raid"
local function GetFilteredPlayers(filter)
	if not CopeLoot_PlayerData then
		return {}
	end

	if filter == "raid" then
		local raidNames = {}
		local numRaid = GetNumRaidMembers() or 0
		for i = 1, numRaid do
			local name = UnitName("raid" .. i)
			if name then
				raidNames[name] = true
			end
		end

		local result = {}
		for i = 1, table.getn(CopeLoot_PlayerData) do
			if raidNames[CopeLoot_PlayerData[i].name] then
				table.insert(result, CopeLoot_PlayerData[i])
			end
		end
		return result
	end

	-- "all"
	return CopeLoot_PlayerData
end

-- ---------------------------------------------------------------------------
-- Loot detection state
-- ---------------------------------------------------------------------------
-- Each detected loot drop is stored in this list.  Entries are added when the
-- raid leader links an epic item in /say.
-- detectedLoot = {
--   { itemLink = "|cffa335ee...", itemName = "...", claimants = {
--       { name = "Lokiy", col = 1 },   -- col = priority column (1 = #1, etc.)
--     }, verdict = "Lokiy" | "TIE: A, B" | "No wishlist match" },
-- }
local detectedLoot = {}
local LOOT_ROW_HEIGHT = 56     -- each loot entry takes several lines

-- Returns the name of the current raid leader, or nil.
local function GetRaidLeaderName()
	local numRaid = GetNumRaidMembers() or 0
	for i = 1, numRaid do
		-- In 1.12.1, GetRaidRosterInfo(i) returns: name, rank, subgroup, level,
		-- class, fileName, zone, online, isDead.  rank 2 = leader.
		local name, rank = GetRaidRosterInfo(i)
		if name and rank == 2 then
			return name
		end
	end
	return nil
end

-- Build a set of names currently in the raid.
local function GetRaidMemberSet()
	local set = {}
	local numRaid = GetNumRaidMembers() or 0
	for i = 1, numRaid do
		local name = UnitName("raid" .. i)
		if name then set[name] = true end
	end
	return set
end

-- Resolve who should get a detected item.
-- Returns an ordered list of { name, col } sorted by priority column,
-- and a verdict string.
local function ResolveLoot(itemName)
	local key = NormaliseItemName(itemName)
	if key == "" then return {}, "No item" end

	local raidSet = GetRaidMemberSet()
	local claimants = {}

	if CopeLoot_PlayerData then
		for i = 1, table.getn(CopeLoot_PlayerData) do
			local p = CopeLoot_PlayerData[i]
			if raidSet[p.name] then
				for col = 1, 3 do
					local raw
					if col == 1 then raw = p.wish1
					elseif col == 2 then raw = p.wish2
					else raw = p.wish3
					end
					if NormaliseItemName(raw) == key then
						table.insert(claimants, { name = p.name, col = col })
					end
				end
			end
		end
	end

	if table.getn(claimants) == 0 then
		return {}, "No wishlist match in raid"
	end

	-- Sort by priority column (ascending = higher priority first)
	table.sort(claimants, function(a, b) return a.col < b.col end)

	local bestCol = claimants[1].col
	local winners = {}
	for i = 1, table.getn(claimants) do
		if claimants[i].col == bestCol then
			table.insert(winners, claimants[i].name)
		end
	end

	local verdict
	if table.getn(winners) == 1 then
		verdict = winners[1] .. " (priority #" .. bestCol .. ")"
	else
		verdict = "TIE #" .. bestCol .. ": " .. table.concat(winners, ", ")
	end

	return claimants, verdict
end

-- Process a chat message: if it contains an epic item link, record it.
function CopeLoot:OnChatMsg(sender, message)
	-- Only process from the raid leader
	local leader = GetRaidLeaderName()
	if not leader or sender ~= leader then return end

	-- Find all epic (purple, quality 4) item links in the message.
	-- Epic links use color code |cffa335ee in 1.12.1.
	local pos = 1
	while true do
		local s, e, itemLink = string.find(message,
			"(|cffa335ee|Hitem:%d+:%d+:%d+:%d+|h%[.-%]|h|r)", pos)
		if not s then break end
		pos = e + 1

		-- Extract item name from the link
		local _, _, itemName = string.find(itemLink, "%[(.-)%]")
		if itemName then
			local claimants, verdict = ResolveLoot(itemName)

			table.insert(detectedLoot, {
				itemLink  = itemLink,
				itemName  = itemName,
				claimants = claimants,
				verdict   = verdict,
			})

			Print("Detected: " .. itemLink .. " -> " .. verdict)

			-- Auto-broadcast if enabled
			local db = EnsureDB()
			if db.autoBroadcast then
				CopeLoot:BroadcastLootEntry(table.getn(detectedLoot))
			end

			-- Switch to loot tab if window is open
			if mainFrame and mainFrame:IsShown() then
				activeTab = "loot"
				scrollOffset = 0
				CopeLoot:RefreshUI()
			end
		end
	end
end

-- Broadcast a single loot entry to raid chat preserving clickable links.
function CopeLoot:BroadcastLootEntry(index)
	local entry = detectedLoot[index]
	if not entry then return end

	if (GetNumRaidMembers() or 0) > 0 then
		-- Send the clickable link line
		SendChatMessage("[CopeLoot] " .. entry.itemLink, "RAID")
		
		-- Send details on a separate line
		local detailMsg = "-> " .. entry.verdict
		if table.getn(entry.claimants) > 0 then
			local parts = {}
			for i = 1, table.getn(entry.claimants) do
				local c = entry.claimants[i]
				table.insert(parts, c.name .. " (#" .. c.col .. ")")
			end
			detailMsg = detailMsg .. " - Wishlisted: " .. table.concat(parts, ", ")
		end
		SendChatMessage(detailMsg, "RAID")
	else
		Print("[CopeLoot] " .. entry.itemLink .. " -> " .. entry.verdict)
	end
end

-- Broadcast all current loot entries.
function CopeLoot:BroadcastAllLoot()
	for i = 1, table.getn(detectedLoot) do
		CopeLoot:BroadcastLootEntry(i)
	end
end

-- ---------------------------------------------------------------------------
-- Constants / layout metrics
-- ---------------------------------------------------------------------------
local WINDOW_W       = 600
local WINDOW_H       = 400
local ROW_HEIGHT     = 20
local HEADER_HEIGHT  = 24
local TAB_HEIGHT     = 24
local TAB_WIDTH      = 100
local VISIBLE_ROWS   = 13

-- Scrollbar geometry. The content area is inset by SCROLL_GUTTER on the right
-- so rows/headers never run underneath the scrollbar.
local LEFT_MARGIN    = 20
local SCROLL_W       = 16
local SCROLL_INSET   = 28   -- distance from window right edge to scrollbar right edge
local SCROLL_GUTTER  = 30   -- reserved width: scrollbar + breathing room

-- Usable width for headers and rows (stops short of the scrollbar)
local CONTENT_W      = WINDOW_W - LEFT_MARGIN * 2 - SCROLL_GUTTER

-- Column widths must satisfy: NAME_COL_W + 3*WISH_COL_W + 12 <= CONTENT_W
local NAME_COL_W     = 110
local WISH_COL_W     = 135

-- Active state
local activeTab    = "wishlist"   -- "wishlist" | "loot" | "settings"
local activeFilter = "all"       -- "all" | "raid"
local scrollOffset = 0

-- ---------------------------------------------------------------------------
-- Main frame
-- ---------------------------------------------------------------------------
local mainFrame

local function CreateMainFrame()
	mainFrame = CreateFrame("Frame", "CopeLootMainFrame", UIParent)
	mainFrame:SetWidth(WINDOW_W)
	mainFrame:SetHeight(WINDOW_H)
	mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	mainFrame:SetMovable(true)
	mainFrame:EnableMouse(true)
	mainFrame:SetFrameStrata("DIALOG")
	mainFrame:SetBackdrop({
		bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile     = true,
		tileSize = 32,
		edgeSize = 32,
		insets   = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	mainFrame:SetBackdropColor(0, 0, 0, 0.85)
	mainFrame:Hide()

	-- Drag handling
	mainFrame:RegisterForDrag("LeftButton")
	mainFrame:SetScript("OnDragStart", function() this:StartMoving() end)
	mainFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)

	-- ESC closes the window
	tinsert(UISpecialFrames, "CopeLootMainFrame")

	-- Title
	local title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", mainFrame, "TOP", 0, -16)
	title:SetText("CopeLoot - Cope Guild Wishlists")

	-- Close button
	local closeBtn = CreateFrame("Button", "CopeLootCloseButton", mainFrame, "UIPanelCloseButton")
	closeBtn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -5, -5)

	return mainFrame
end

-- ---------------------------------------------------------------------------
-- Tabs
-- ---------------------------------------------------------------------------
local tabWishlist, tabLoot, tabSettings

local function SetActiveTab(tab)
	activeTab = tab
	CopeLoot:RefreshUI()
end

local function CreateTabs()
	-- Wishlist tab
	tabWishlist = CreateFrame("Button", "CopeLootTabWishlist", mainFrame)
	tabWishlist:SetWidth(TAB_WIDTH)
	tabWishlist:SetHeight(TAB_HEIGHT)
	tabWishlist:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 20, -40)
	tabWishlist:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile     = true, tileSize = 8, edgeSize = 12,
		insets   = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	tabWishlist:SetBackdropColor(0.2, 0.6, 0.2, 1)

	local twText = tabWishlist:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	twText:SetPoint("CENTER", tabWishlist, "CENTER", 0, 0)
	twText:SetText("Wishlist")
	tabWishlist.text = twText

	tabWishlist:SetScript("OnClick", function() SetActiveTab("wishlist") end)

	-- Loot tab
	tabLoot = CreateFrame("Button", "CopeLootTabLoot", mainFrame)
	tabLoot:SetWidth(TAB_WIDTH)
	tabLoot:SetHeight(TAB_HEIGHT)
	tabLoot:SetPoint("LEFT", tabWishlist, "RIGHT", 4, 0)
	tabLoot:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile     = true, tileSize = 8, edgeSize = 12,
		insets   = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	tabLoot:SetBackdropColor(0.3, 0.3, 0.3, 1)

	local tlText = tabLoot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	tlText:SetPoint("CENTER", tabLoot, "CENTER", 0, 0)
	tlText:SetText("Loot")
	tabLoot.text = tlText

	tabLoot:SetScript("OnClick", function() SetActiveTab("loot") end)

	-- Settings tab
	tabSettings = CreateFrame("Button", "CopeLootTabSettings", mainFrame)
	tabSettings:SetWidth(TAB_WIDTH)
	tabSettings:SetHeight(TAB_HEIGHT)
	tabSettings:SetPoint("LEFT", tabLoot, "RIGHT", 4, 0)
	tabSettings:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile     = true, tileSize = 8, edgeSize = 12,
		insets   = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	tabSettings:SetBackdropColor(0.3, 0.3, 0.3, 1)

	local tsText = tabSettings:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	tsText:SetPoint("CENTER", tabSettings, "CENTER", 0, 0)
	tsText:SetText("Settings")
	tabSettings.text = tsText

	tabSettings:SetScript("OnClick", function() SetActiveTab("settings") end)
end

-- ---------------------------------------------------------------------------
-- Wishlist tab - filter bar
-- ---------------------------------------------------------------------------
local filterAllBtn, filterRaidBtn

local function SetFilter(f)
	activeFilter = f
	scrollOffset = 0
	CopeLoot:RefreshUI()
end

local function CreateFilterBar()
	filterAllBtn = CreateFrame("Button", "CopeLootFilterAll", mainFrame)
	filterAllBtn:SetWidth(90)
	filterAllBtn:SetHeight(20)
	filterAllBtn:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 20, -70)
	filterAllBtn:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile     = true, tileSize = 8, edgeSize = 12,
		insets   = { left = 2, right = 2, top = 2, bottom = 2 },
	})

	local faText = filterAllBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	faText:SetPoint("CENTER", filterAllBtn, "CENTER", 0, 0)
	faText:SetText("All Wishlist")
	filterAllBtn.text = faText

	filterAllBtn:SetScript("OnClick", function() SetFilter("all") end)

	filterRaidBtn = CreateFrame("Button", "CopeLootFilterRaid", mainFrame)
	filterRaidBtn:SetWidth(90)
	filterRaidBtn:SetHeight(20)
	filterRaidBtn:SetPoint("LEFT", filterAllBtn, "RIGHT", 4, 0)
	filterRaidBtn:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile     = true, tileSize = 8, edgeSize = 12,
		insets   = { left = 2, right = 2, top = 2, bottom = 2 },
	})

	local frText = filterRaidBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frText:SetPoint("CENTER", filterRaidBtn, "CENTER", 0, 0)
	frText:SetText("Current Raid")
	filterRaidBtn.text = frText

	filterRaidBtn:SetScript("OnClick", function() SetFilter("raid") end)
end

-- ---------------------------------------------------------------------------
-- Wishlist tab - column headers + data rows
-- ---------------------------------------------------------------------------
local headerFrame
local rowFrames = {}

local function CreateHeaderAndRows()
	-- Column header bar
	headerFrame = CreateFrame("Frame", "CopeLootHeaderFrame", mainFrame)
	headerFrame:SetWidth(CONTENT_W)
	headerFrame:SetHeight(HEADER_HEIGHT)
	headerFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", LEFT_MARGIN, -96)

	local hPlayer = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	hPlayer:SetPoint("LEFT", headerFrame, "LEFT", 4, 0)
	hPlayer:SetWidth(NAME_COL_W)
	hPlayer:SetJustifyH("LEFT")
	hPlayer:SetText("Player")
	hPlayer:SetTextColor(1, 0.82, 0)

	local hW1 = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	hW1:SetPoint("LEFT", headerFrame, "LEFT", NAME_COL_W + 4, 0)
	hW1:SetWidth(WISH_COL_W)
	hW1:SetJustifyH("LEFT")
	hW1:SetText("#1")
	hW1:SetTextColor(1, 0.82, 0)

	local hW2 = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	hW2:SetPoint("LEFT", headerFrame, "LEFT", NAME_COL_W + WISH_COL_W + 8, 0)
	hW2:SetWidth(WISH_COL_W)
	hW2:SetJustifyH("LEFT")
	hW2:SetText("#2")
	hW2:SetTextColor(1, 0.82, 0)

	local hW3 = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	hW3:SetPoint("LEFT", headerFrame, "LEFT", NAME_COL_W + WISH_COL_W * 2 + 12, 0)
	hW3:SetWidth(WISH_COL_W)
	hW3:SetJustifyH("LEFT")
	hW3:SetText("#3")
	hW3:SetTextColor(1, 0.82, 0)

	-- Separator line
	local sep = headerFrame:CreateTexture(nil, "ARTWORK")
	sep:SetTexture(1, 0.82, 0, 0.5)
	sep:SetWidth(CONTENT_W)
	sep:SetHeight(1)
	sep:SetPoint("BOTTOMLEFT", headerFrame, "BOTTOMLEFT", 0, 0)

	-- Pre-create row frames
	for i = 1, VISIBLE_ROWS do
		local row = CreateFrame("Frame", "CopeLootRow" .. i, mainFrame)
		row:SetWidth(CONTENT_W)
		row:SetHeight(ROW_HEIGHT)
		row:SetPoint("TOPLEFT", headerFrame, "BOTTOMLEFT", 0, -(i - 1) * ROW_HEIGHT - 2)

		-- Alternate row bg
		local bg = row:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints(row)
		if math.mod(i, 2) == 0 then
			bg:SetTexture(1, 1, 1, 0.05)
		else
			bg:SetTexture(0, 0, 0, 0)
		end

		local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		nameFS:SetPoint("LEFT", row, "LEFT", 4, 0)
		nameFS:SetWidth(NAME_COL_W)
		nameFS:SetJustifyH("LEFT")

		local w1FS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		w1FS:SetPoint("LEFT", row, "LEFT", NAME_COL_W + 4, 0)
		w1FS:SetWidth(WISH_COL_W)
		w1FS:SetJustifyH("LEFT")

		local w2FS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		w2FS:SetPoint("LEFT", row, "LEFT", NAME_COL_W + WISH_COL_W + 8, 0)
		w2FS:SetWidth(WISH_COL_W)
		w2FS:SetJustifyH("LEFT")

		local w3FS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		w3FS:SetPoint("LEFT", row, "LEFT", NAME_COL_W + WISH_COL_W * 2 + 12, 0)
		w3FS:SetWidth(WISH_COL_W)
		w3FS:SetJustifyH("LEFT")

		row.nameFS = nameFS
		row.w1FS   = w1FS
		row.w2FS   = w2FS
		row.w3FS   = w3FS

		rowFrames[i] = row
	end
end

-- ---------------------------------------------------------------------------
-- Scroll bar
-- ---------------------------------------------------------------------------
local scrollBar

local function CreateScrollBar()
	-- NOTE: Do NOT use "UIPanelScrollBarTemplate" here. In 1.12.1 that template
	-- ships an XML OnValueChanged handler that calls
	--     this:GetParent():SetVerticalScroll(value)
	-- which only exists on a ScrollFrame. Our parent is a plain Frame, so it
	-- errors with "attempt to call method 'SetVerticalScroll' (a nil value)".
	-- We build a bare Slider and supply our own artwork/handler instead.
	scrollBar = CreateFrame("Slider", "CopeLootScrollBar", mainFrame)
	scrollBar:SetWidth(SCROLL_W)
	scrollBar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -SCROLL_INSET, -122)
	scrollBar:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -SCROLL_INSET, 20)
	scrollBar:SetOrientation("VERTICAL")

	-- Track background
	scrollBar:SetBackdrop({
		bgFile   = "Interface\\Buttons\\UI-SliderBar-Background",
		edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
		tile     = true, tileSize = 8, edgeSize = 8,
		insets   = { left = 3, right = 3, top = 6, bottom = 6 },
	})

	-- Thumb
	local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
	thumb:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
	thumb:SetWidth(SCROLL_W)
	thumb:SetHeight(SCROLL_W)
	scrollBar:SetThumbTexture(thumb)

	-- IMPORTANT: register the handler BEFORE the first SetValue, otherwise the
	-- initial SetValue fires whatever handler is currently attached.
	scrollBar:SetScript("OnValueChanged", function()
		scrollOffset = math.floor(this:GetValue())
		CopeLoot:RefreshUI()
	end)

	scrollBar:SetMinMaxValues(0, 0)
	scrollBar:SetValueStep(1)
	scrollBar:SetValue(0)

	-- Mouse-wheel on main frame
	mainFrame:EnableMouseWheel(true)
	mainFrame:SetScript("OnMouseWheel", function()
		local newVal = scrollOffset - arg1
		if newVal < 0 then newVal = 0 end
		scrollBar:SetValue(newVal)
	end)
end

-- ---------------------------------------------------------------------------
-- Settings tab content
-- ---------------------------------------------------------------------------
local settingsFrame

local function CreateSettingsFrame()
	settingsFrame = CreateFrame("Frame", "CopeLootSettingsFrame", mainFrame)
	settingsFrame:SetWidth(WINDOW_W - 40)
	settingsFrame:SetHeight(WINDOW_H - 100)
	settingsFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 20, -70)
	settingsFrame:Hide()

	-- Auto-swap checkbox
	local cb = CreateFrame("CheckButton", "CopeLootAutoSwapCB", settingsFrame, "UICheckButtonTemplate")
	cb:SetWidth(24)
	cb:SetHeight(24)
	cb:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 4, -10)
	cb:SetChecked(true) -- will be refreshed from DB

	local cbLabel = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	cbLabel:SetPoint("LEFT", cb, "RIGHT", 4, 0)
	cbLabel:SetText("Swap to Current Raid list automatically when in a raid")

	cb:SetScript("OnClick", function()
		local db = EnsureDB()
		if this:GetChecked() then
			db.autoSwap = true
		else
			db.autoSwap = false
		end
	end)

	settingsFrame.autoSwapCB = cb

	-- Info text for auto-swap
	local info = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	info:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 0, -8)
	info:SetWidth(WINDOW_W - 60)
	info:SetJustifyH("LEFT")
	info:SetText(
		"When enabled, the Wishlist tab filter automatically switches to " ..
		"\"Current Raid\" when you join a raid group, and back to " ..
		"\"All Wishlist\" when you leave the raid."
	)

	-- Auto-broadcast checkbox
	local cb2 = CreateFrame("CheckButton", "CopeLootAutoBroadcastCB", settingsFrame, "UICheckButtonTemplate")
	cb2:SetWidth(24)
	cb2:SetHeight(24)
	cb2:SetPoint("TOPLEFT", info, "BOTTOMLEFT", 0, -16)
	cb2:SetChecked(false) -- refreshed from DB

	local cb2Label = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	cb2Label:SetPoint("LEFT", cb2, "RIGHT", 4, 0)
	cb2Label:SetText("Automatically broadcast loot info to raid chat")

	cb2:SetScript("OnClick", function()
		local db = EnsureDB()
		if this:GetChecked() then
			db.autoBroadcast = true
		else
			db.autoBroadcast = false
		end
	end)

	settingsFrame.autoBroadcastCB = cb2

	-- Info text for auto-broadcast
	local info2 = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	info2:SetPoint("TOPLEFT", cb2, "BOTTOMLEFT", 0, -8)
	info2:SetWidth(WINDOW_W - 60)
	info2:SetJustifyH("LEFT")
	info2:SetText(
		"When enabled, CopeLoot automatically sends the wishlist verdict " ..
		"to raid chat whenever the raid leader links an epic item in /say."
	)
end

-- ---------------------------------------------------------------------------
-- Loot tab content
-- ---------------------------------------------------------------------------
local lootFrame
local lootRowFrames = {}
local LOOT_VISIBLE = 5  -- max loot entries visible at once
local lootScrollBar

local function CreateLootFrame()
	lootFrame = CreateFrame("Frame", "CopeLootLootFrame", mainFrame)
	lootFrame:SetWidth(CONTENT_W)
	lootFrame:SetHeight(WINDOW_H - 100)
	lootFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", LEFT_MARGIN, -70)
	lootFrame:Hide()

	-- Loot header
	local hdr = lootFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	hdr:SetPoint("TOPLEFT", lootFrame, "TOPLEFT", 4, -4)
	hdr:SetText("Detected Epic Loot (from Raid Leader /say)")
	hdr:SetTextColor(1, 0.82, 0)

	-- Pre-create loot entry rows
	for i = 1, LOOT_VISIBLE do
		local row = CreateFrame("Frame", "CopeLootLootRow" .. i, lootFrame)
		row:SetWidth(CONTENT_W - 10)
		row:SetHeight(LOOT_ROW_HEIGHT)
		row:SetPoint("TOPLEFT", lootFrame, "TOPLEFT", 4, -24 - (i - 1) * (LOOT_ROW_HEIGHT + 4))

		-- Alternating background
		local bg = row:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints(row)
		if math.mod(i, 2) == 0 then
			bg:SetTexture(1, 1, 1, 0.05)
		else
			bg:SetTexture(0.5, 0.5, 0.5, 0.08)
		end

		-- Item name line
		local itemFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		itemFS:SetPoint("TOPLEFT", row, "TOPLEFT", 2, -2)
		itemFS:SetWidth(CONTENT_W - 14)
		itemFS:SetJustifyH("LEFT")

		-- Claimants line
		local claimFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		claimFS:SetPoint("TOPLEFT", itemFS, "BOTTOMLEFT", 0, -2)
		claimFS:SetWidth(CONTENT_W - 14)
		claimFS:SetJustifyH("LEFT")

		-- Verdict line
		local verdictFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		verdictFS:SetPoint("TOPLEFT", claimFS, "BOTTOMLEFT", 0, -2)
		verdictFS:SetWidth(CONTENT_W - 14)
		verdictFS:SetJustifyH("LEFT")

		row.itemFS    = itemFS
		row.claimFS   = claimFS
		row.verdictFS = verdictFS

		lootRowFrames[i] = row
	end

	-- Loot scrollbar
	lootScrollBar = CreateFrame("Slider", "CopeLootLootScrollBar", lootFrame)
	lootScrollBar:SetWidth(SCROLL_W)
	lootScrollBar:SetPoint("TOPRIGHT", lootFrame, "TOPRIGHT", 0, -24)
	lootScrollBar:SetPoint("BOTTOMRIGHT", lootFrame, "BOTTOMRIGHT", 0, 30)
	lootScrollBar:SetOrientation("VERTICAL")
	lootScrollBar:SetBackdrop({
		bgFile   = "Interface\\Buttons\\UI-SliderBar-Background",
		edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
		tile     = true, tileSize = 8, edgeSize = 8,
		insets   = { left = 3, right = 3, top = 6, bottom = 6 },
	})
	local lThumb = lootScrollBar:CreateTexture(nil, "OVERLAY")
	lThumb:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
	lThumb:SetWidth(SCROLL_W)
	lThumb:SetHeight(SCROLL_W)
	lootScrollBar:SetThumbTexture(lThumb)
	lootScrollBar:SetScript("OnValueChanged", function()
		scrollOffset = math.floor(this:GetValue())
		CopeLoot:RefreshUI()
	end)
	lootScrollBar:SetMinMaxValues(0, 0)
	lootScrollBar:SetValueStep(1)
	lootScrollBar:SetValue(0)

	-- Broadcast All button
	local broadcastBtn = CreateFrame("Button", "CopeLootBroadcastBtn", lootFrame, "UIPanelButtonTemplate")
	broadcastBtn:SetWidth(120)
	broadcastBtn:SetHeight(22)
	broadcastBtn:SetPoint("BOTTOMLEFT", lootFrame, "BOTTOMLEFT", 4, 4)
	broadcastBtn:SetText("Broadcast All")
	broadcastBtn:SetScript("OnClick", function()
		CopeLoot:BroadcastAllLoot()
	end)

	-- Clear button
	local clearBtn = CreateFrame("Button", "CopeLootClearLootBtn", lootFrame, "UIPanelButtonTemplate")
	clearBtn:SetWidth(80)
	clearBtn:SetHeight(22)
	clearBtn:SetPoint("LEFT", broadcastBtn, "RIGHT", 8, 0)
	clearBtn:SetText("Clear")
	clearBtn:SetScript("OnClick", function()
		detectedLoot = {}
		scrollOffset = 0
		CopeLoot:RefreshUI()
	end)
end

-- ---------------------------------------------------------------------------
-- Refresh / redraw
-- ---------------------------------------------------------------------------

function CopeLoot:RefreshUI()
	if not mainFrame or not mainFrame:IsShown() then return end

	local db = EnsureDB()

	-- Tab highlight (active = green, inactive = grey)
	local function HighlightTab(tab, isActive)
		if isActive then
			tab:SetBackdropColor(0.2, 0.6, 0.2, 1)
		else
			tab:SetBackdropColor(0.3, 0.3, 0.3, 1)
		end
	end
	HighlightTab(tabWishlist, activeTab == "wishlist")
	HighlightTab(tabLoot,     activeTab == "loot")
	HighlightTab(tabSettings, activeTab == "settings")

	-- Hide all panes first
	filterAllBtn:Hide()
	filterRaidBtn:Hide()
	headerFrame:Hide()
	scrollBar:Hide()
	settingsFrame:Hide()
	lootFrame:Hide()
	for i = 1, VISIBLE_ROWS do
		rowFrames[i]:Hide()
	end

	-- --- Settings tab ---
	if activeTab == "settings" then
		settingsFrame:Show()
		settingsFrame.autoSwapCB:SetChecked(db.autoSwap)
		settingsFrame.autoBroadcastCB:SetChecked(db.autoBroadcast)
		return
	end

	-- --- Loot tab ---
	if activeTab == "loot" then
		lootFrame:Show()
		local total = table.getn(detectedLoot)
		local maxScroll = total - LOOT_VISIBLE
		if maxScroll < 0 then maxScroll = 0 end
		lootScrollBar:SetMinMaxValues(0, maxScroll)
		if scrollOffset > maxScroll then scrollOffset = maxScroll end

		for i = 1, LOOT_VISIBLE do
			local dataIdx = i + scrollOffset
			local row = lootRowFrames[i]
			if dataIdx <= total then
				local entry = detectedLoot[dataIdx]
				row.itemFS:SetText(entry.itemLink or entry.itemName)
				row.itemFS:SetTextColor(0.63, 0.21, 0.93) -- epic purple

				-- Build claimants string
				if table.getn(entry.claimants) > 0 then
					local parts = {}
					for j = 1, table.getn(entry.claimants) do
						local c = entry.claimants[j]
						table.insert(parts, c.name .. " (#" .. c.col .. ")")
					end
					row.claimFS:SetText("Wishlisted (in raid): " .. table.concat(parts, ", "))
					row.claimFS:SetTextColor(0.8, 0.8, 0.8)
				else
					row.claimFS:SetText("No raid members have this wishlisted")
					row.claimFS:SetTextColor(0.5, 0.5, 0.5)
				end

				-- Verdict with color
				local verdict = entry.verdict
				if string.find(verdict, "^TIE") then
					row.verdictFS:SetText("-> " .. verdict)
					row.verdictFS:SetTextColor(1, 1, 0.3) -- yellow for tie
				elseif string.find(verdict, "No wishlist") then
					row.verdictFS:SetText("-> " .. verdict)
					row.verdictFS:SetTextColor(0.5, 0.5, 0.5) -- grey
				else
					row.verdictFS:SetText("-> Award to: " .. verdict)
					row.verdictFS:SetTextColor(0.3, 1, 0.3) -- green for clear winner
				end
				row:Show()
			else
				row.itemFS:SetText("")
				row.claimFS:SetText("")
				row.verdictFS:SetText("")
				row:Show()
			end
		end
		return
	end

	-- --- Wishlist tab ---
	filterAllBtn:Show()
	filterRaidBtn:Show()
	headerFrame:Show()
	scrollBar:Show()
	for i = 1, VISIBLE_ROWS do
		rowFrames[i]:Show()
	end

	-- Filter button highlight
	if activeFilter == "all" then
		filterAllBtn:SetBackdropColor(0.2, 0.5, 0.8, 1)
		filterRaidBtn:SetBackdropColor(0.3, 0.3, 0.3, 1)
	else
		filterAllBtn:SetBackdropColor(0.3, 0.3, 0.3, 1)
		filterRaidBtn:SetBackdropColor(0.2, 0.5, 0.8, 1)
	end

	-- Get data and rebuild the contention index for the visible set
	local players = GetFilteredPlayers(activeFilter)
	local total = table.getn(players)
	BuildItemIndex(players)

	-- Update scroll range
	local maxScroll = total - VISIBLE_ROWS
	if maxScroll < 0 then maxScroll = 0 end
	scrollBar:SetMinMaxValues(0, maxScroll)
	if scrollOffset > maxScroll then
		scrollOffset = maxScroll
	end

	-- Populate rows
	for i = 1, VISIBLE_ROWS do
		local dataIdx = i + scrollOffset
		local row = rowFrames[i]
		if dataIdx <= total then
			local p = players[dataIdx]
			local cc = CLASS_COLORS[p.class]
			if cc then
				row.nameFS:SetTextColor(cc.r, cc.g, cc.b)
			else
				row.nameFS:SetTextColor(1, 1, 1)
			end
			row.nameFS:SetText(p.name)

			row.w1FS:SetText(p.wish1 ~= "" and p.wish1 or "-")
			row.w2FS:SetText(p.wish2 ~= "" and p.wish2 or "-")
			row.w3FS:SetText(p.wish3 ~= "" and p.wish3 or "-")

			-- Apply contention-based coloring
			local r1, g1, b1 = GetItemColor(p.wish1, 1)
			row.w1FS:SetTextColor(r1, g1, b1)

			local r2, g2, b2 = GetItemColor(p.wish2, 2)
			row.w2FS:SetTextColor(r2, g2, b2)

			local r3, g3, b3 = GetItemColor(p.wish3, 3)
			row.w3FS:SetTextColor(r3, g3, b3)
		else
			row.nameFS:SetText("")
			row.w1FS:SetText("")
			row.w2FS:SetText("")
			row.w3FS:SetText("")
		end
	end
end

-- ---------------------------------------------------------------------------
-- Toggle window
-- ---------------------------------------------------------------------------
function CopeLoot:Toggle()
	if not mainFrame then
		CreateMainFrame()
		CreateTabs()
		CreateFilterBar()
		CreateHeaderAndRows()
		CreateScrollBar()
		CreateSettingsFrame()
		CreateLootFrame()
		IndexPlayerData()
	end

	if mainFrame:IsShown() then
		mainFrame:Hide()
	else
		mainFrame:Show()
		CopeLoot:RefreshUI()
	end
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
SLASH_COPELOOT1 = "/copeloot"
SLASH_COPELOOT2 = "/cl"

SlashCmdList["COPELOOT"] = function(msg)
	msg = msg or ""
	local _, _, cmd = string.find(msg, "^(%S+)")
	cmd = string.lower(cmd or "")

	if cmd == "" or cmd == "show" or cmd == "toggle" then
		CopeLoot:Toggle()
	elseif cmd == "help" then
		Print(CopeLoot.name .. " v" .. CopeLoot.version)
		DEFAULT_CHAT_FRAME:AddMessage("/copeloot (or /cl) - toggle the CopeLoot window")
	else
		-- Default: open the window
		CopeLoot:Toggle()
	end
end

-- ---------------------------------------------------------------------------
-- Auto-swap filter when joining / leaving a raid
-- ---------------------------------------------------------------------------
local function CheckAutoSwap()
	local db = EnsureDB()
	if not db.autoSwap then return end

	local inRaid = (GetNumRaidMembers() or 0) > 0
	if inRaid and activeFilter ~= "raid" then
		activeFilter = "raid"
		scrollOffset = 0
		CopeLoot:RefreshUI()
	elseif not inRaid and activeFilter ~= "all" then
		activeFilter = "all"
		scrollOffset = 0
		CopeLoot:RefreshUI()
	end
end

-- ---------------------------------------------------------------------------
-- Event handling
-- ---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame", "CopeLootEventFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("CHAT_MSG_RAID")
eventFrame:RegisterEvent("CHAT_MSG_RAID_LEADER")

eventFrame:SetScript("OnEvent", function()
	if event == "ADDON_LOADED" and arg1 == "CopeLoot" then
		EnsureDB()
		IndexPlayerData()
	elseif event == "PLAYER_LOGIN" then
		Print(CopeLoot.version .. " loaded. Type /copeloot to open.")
	elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
		CheckAutoSwap()
	elseif event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER" then
		-- arg1 = message, arg2 = sender name
		CopeLoot:OnChatMsg(arg2, arg1)
	end
end)
