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
-- Item contention index
-- ---------------------------------------------------------------------------
local itemIndex = {}

-- Which list the Loot tab resolves drops against. Only one is ever active.
local lootResolveMode = "wishlist"   -- "wishlist" | "reserve"

local function NormaliseItemName(raw)
	if not raw or raw == "" then return "" end
	local name = string.gsub(raw, "%s*%(.-%)%s*$", "")
	name = string.gsub(name, "%s+$", "")
	return string.lower(name)
end

local function BuildItemIndex(playerList, isReserve)
	itemIndex = {}
	for i = 1, table.getn(playerList) do
		local p = playerList[i]
		local maxCols = isReserve and 1 or 3
		for col = 1, maxCols do
			local raw
			if isReserve then
				raw = p.reserve
			else
				if col == 1 then raw = p.wish1
				elseif col == 2 then raw = p.wish2
				else raw = p.wish3
				end
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

local function GetItemColor(rawName, col)
	local key = NormaliseItemName(rawName)
	if key == "" then return 0.4, 0.4, 0.4 end

	local info = itemIndex[key]
	if not info then return 1, 1, 1 end

	if info.highest < col then
		return 1, 0.3, 0.3
	end

	local countHere = info.slots[col] or 0
	if countHere > 1 then
		return 1, 1, 0.3
	end

	return 0.3, 1, 0.3
end

-- Builds a short display string for owned ZG trinket pieces, e.g. "Gri'lek, Wushoolay".
local TRINKET_LABELS = {
	{ key = "grilek",    label = "Gri'lek" },
	{ key = "hazzarah",  label = "Hazza'rah" },
	{ key = "renataki",  label = "Renataki" },
	{ key = "wushoolay", label = "Wushoolay" },
}

local function FormatTrinkets(p)
	if not p.trinkets then
		return "-"
	end

	local owned = {}
	for i = 1, table.getn(TRINKET_LABELS) do
		local t = TRINKET_LABELS[i]
		if p.trinkets[t.key] then
			table.insert(owned, t.label)
		end
	end

	if table.getn(owned) == 0 then
		return "-"
	end

	return table.concat(owned, ", ")
end

-- Returns an ordered list of player entries for the active dataset and filter.
-- dataTable: CopeLoot_PlayerData or CopeLoot_ReserveData
local function GetFilteredPlayers(dataTable, filter, isReserve)
	if not dataTable then
		return {}
	end

	if filter == "raid" then
		local raidNames = {}
		local numRaid = GetNumRaidMembers() or 0
		for i = 1, numRaid do
			local name = UnitName("raid" .. i)
			if name then
				local _, englishClass = UnitClass("raid" .. i)
				raidNames[name] = englishClass or "Unknown"
			end
		end

		local haveEntry = {}
		local result = {}
		for i = 1, table.getn(dataTable) do
			local p = dataTable[i]
			if raidNames[p.name] then
				table.insert(result, p)
				haveEntry[p.name] = true
			end
		end

		-- Include raid members who have no wishlist/reserve entry yet
		for name, class in pairs(raidNames) do
			if not haveEntry[name] then
				if isReserve then
					table.insert(result, { name = name, class = class, boss = "", reserve = "", trinkets = {} })
				else
					table.insert(result, { name = name, class = class, wish1 = "", wish2 = "", wish3 = "" })
				end
			end
		end

		table.sort(result, function(a, b) return a.name < b.name end)
		return result
	end

	local sorted = {}
	for i = 1, table.getn(dataTable) do
		table.insert(sorted, dataTable[i])
	end
	table.sort(sorted, function(a, b) return a.name < b.name end)
	return sorted
end

-- ---------------------------------------------------------------------------
-- Loot detection state
-- ---------------------------------------------------------------------------
local detectedLoot = {}

local function GetRaidLeaderName()
	local numRaid = GetNumRaidMembers() or 0
	for i = 1, numRaid do
		local name, rank = GetRaidRosterInfo(i)
		if name and rank == 2 then
			return name
		end
	end
	return nil
end

local function GetRaidMemberSet()
	local set = {}
	local numRaid = GetNumRaidMembers() or 0
	for i = 1, numRaid do
		local name = UnitName("raid" .. i)
		if name then set[name] = true end
	end
	return set
end

local function ResolveLoot(itemName, count)
	count = count or 1
	local key = NormaliseItemName(itemName)
	if key == "" then return {}, "No item" end

	local raidSet = GetRaidMemberSet()
	local claimants = {}

	if lootResolveMode == "reserve" then
		if CopeLoot_ReserveData then
			for i = 1, table.getn(CopeLoot_ReserveData) do
				local p = CopeLoot_ReserveData[i]
				if raidSet[p.name] then
					if NormaliseItemName(p.reserve) == key then
						table.insert(claimants, { name = p.name, col = 1 })
					end
				end
			end
		end

		if table.getn(claimants) == 0 then
			local qtyPrefix = count > 1 and ("(" .. count .. "x) ") or ""
			return {}, qtyPrefix .. "No reserve match in raid"
		end
	else
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
			local qtyPrefix = count > 1 and ("(" .. count .. "x) ") or ""
			return {}, qtyPrefix .. "No wishlist match in raid"
		end
	end

	table.sort(claimants, function(a, b) return a.col < b.col end)

	local bestCol = claimants[1].col
	local winners = {}
	for i = 1, table.getn(claimants) do
		if claimants[i].col == bestCol then
			table.insert(winners, claimants[i].name)
		end
	end

	local countStr = count > 1 and ("(" .. count .. "x Drop) ") or ""
	local verdict
	if lootResolveMode == "reserve" then
		if table.getn(winners) <= count then
			verdict = countStr .. table.concat(winners, ", ") .. " (reserved)"
		else
			verdict = countStr .. "TIE (" .. count .. " drop" .. (count > 1 and "s" or "") .. "): " .. table.concat(winners, ", ")
		end
	else
		if table.getn(winners) <= count then
			verdict = countStr .. table.concat(winners, ", ") .. " (priority #" .. bestCol .. ")"
		else
			verdict = countStr .. "TIE #" .. bestCol .. " (" .. count .. " drop" .. (count > 1 and "s" or "") .. "): " .. table.concat(winners, ", ")
		end
	end

	return claimants, verdict
end

-- Item quality colors we care about: Epic (purple) and Rare (blue)
-- Full 8-digit hex as it appears in chat links (alpha prefix "ff" + RRGGBB)
local LOOT_QUALITY_COLORS = {
	["ffa335ee"] = true, -- Epic
	["ff0070dd"] = true, -- Rare (Blue)
}

function CopeLoot:OnChatMsg(sender, message)
	local leader = GetRaidLeaderName()
	if not leader or sender ~= leader then return end

	-- Ignore our own broadcasts so linking an item back to raid chat doesn't
	-- get re-detected as a fresh drop.
	if string.find(message, "^%[CopeLoot%]") then return end

	local pos = 1
	local foundLinks = {}

	while true do
		local s, e, itemLink, colorHex = string.find(message,
			"(|c(%x%x%x%x%x%x%x%x)|Hitem:%d+:%d+:%d+:%d+|h%[.-%]|h|r)", pos)
		if not s then break end
		pos = e + 1

		if LOOT_QUALITY_COLORS[string.lower(colorHex)] then
			local _, _, itemName = string.find(itemLink, "%[(.-)%]")
			if itemName then
				local prefix = string.sub(message, math.max(1, s - 5), s - 1)
				local suffix = string.sub(message, e + 1, e + 5)
				
				local count = 1
				local _, _, pQty = string.find(prefix, "(%d+)%s*x%s*$")
				local _, _, sQty = string.find(suffix, "^%s*x%s*(%d+)")
				
				if pQty then count = tonumber(pQty) or 1
				elseif sQty then count = tonumber(sQty) or 1
				end

				table.insert(foundLinks, { itemLink = itemLink, itemName = itemName, count = count })
			end
		end
	end

	for i = 1, table.getn(foundLinks) do
		local item = foundLinks[i]
		local claimants, verdict = ResolveLoot(item.itemName, item.count)

		table.insert(detectedLoot, {
			itemLink  = item.itemLink,
			itemName  = item.itemName,
			count     = item.count,
			claimants = claimants,
			verdict   = verdict,
			mode      = lootResolveMode,
			broadcasted = false,
		})

		Print("Detected: " .. item.itemLink .. (item.count > 1 and (" x" .. item.count) or "") .. " -> " .. verdict)

		local db = EnsureDB()
		if db.autoBroadcast then
			CopeLoot:BroadcastLootEntry(table.getn(detectedLoot))
		end
	end

	if table.getn(foundLinks) > 0 and mainFrame and mainFrame:IsShown() then
		activeTab = "loot"
		scrollOffset = 0
		CopeLoot:RefreshUI()
	end
end

function CopeLoot:BroadcastLootEntry(index)
	local entry = detectedLoot[index]
	if not entry then return end

	local inRaid = (GetNumRaidMembers() or 0) > 0

	if entry.mode == "reserve" and table.getn(entry.claimants) == 0 then
		local rwMsg = "Roll for " .. entry.itemLink .. " MS /roll 100 || OS /roll 99"

		if inRaid then
			SendChatMessage(rwMsg, "RAID_WARNING")
		else
			Print(freeRollMsg)
			Print("RAID_WARNING: " .. rwMsg)
		end
	else
		if inRaid then
			SendChatMessage("[CopeLoot] " .. entry.itemLink, "RAID")
			local detailMsg = "-> " .. entry.verdict
			if table.getn(entry.claimants) > 0 then
				local parts = {}
				for i = 1, table.getn(entry.claimants) do
					local c = entry.claimants[i]
					if entry.mode == "reserve" then
						table.insert(parts, c.name)
					else
						table.insert(parts, c.name .. " (#" .. c.col .. ")")
					end
				end
				local label = (entry.mode == "reserve") and " - Reserved: " or " - Wishlisted: "
				detailMsg = detailMsg .. label .. table.concat(parts, ", ")
			end
			SendChatMessage(detailMsg, "RAID")
		else
			Print(entry.itemLink .. " -> " .. entry.verdict)
		end
	end

	-- Mark as broadcasted and update UI
	entry.broadcasted = true
	if mainFrame and mainFrame:IsShown() then
		CopeLoot:RefreshUI()
	end
end

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
local TAB_WIDTH      = 85
local VISIBLE_ROWS   = 13

local LEFT_MARGIN    = 20
local SCROLL_W       = 16
local SCROLL_INSET   = 28
local SCROLL_GUTTER  = 30

local CONTENT_W      = WINDOW_W - LEFT_MARGIN * 2 - SCROLL_GUTTER

local NAME_COL_W     = 110
local WISH_COL_W     = 135

-- Active state
local activeTab    = "wishlist"   -- "wishlist" | "reserves" | "loot" | "settings"
local activeFilter = "all"        -- "all" | "raid"
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

	mainFrame:RegisterForDrag("LeftButton")
	mainFrame:SetScript("OnDragStart", function() this:StartMoving() end)
	mainFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)

	tinsert(UISpecialFrames, "CopeLootMainFrame")

	local title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", mainFrame, "TOP", 0, -16)
	title:SetText("CopeLoot - Cope Guild Wishlists")

	local closeBtn = CreateFrame("Button", "CopeLootCloseButton", mainFrame, "UIPanelCloseButton")
	closeBtn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -5, -5)

	return mainFrame
end

-- ---------------------------------------------------------------------------
-- Tabs
-- ---------------------------------------------------------------------------
local tabWishlist, tabReserves, tabLoot, tabSettings

local function SetActiveTab(tab)
	activeTab = tab
	scrollOffset = 0
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

	-- Reserves tab
	tabReserves = CreateFrame("Button", "CopeLootTabReserves", mainFrame)
	tabReserves:SetWidth(TAB_WIDTH)
	tabReserves:SetHeight(TAB_HEIGHT)
	tabReserves:SetPoint("LEFT", tabWishlist, "RIGHT", 4, 0)
	tabReserves:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile     = true, tileSize = 8, edgeSize = 12,
		insets   = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	tabReserves:SetBackdropColor(0.3, 0.3, 0.3, 1)

	local trText = tabReserves:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	trText:SetPoint("CENTER", tabReserves, "CENTER", 0, 0)
	trText:SetText("Reserves")
	tabReserves.text = trText
	tabReserves:SetScript("OnClick", function() SetActiveTab("reserves") end)

	-- Loot tab
	tabLoot = CreateFrame("Button", "CopeLootTabLoot", mainFrame)
	tabLoot:SetWidth(TAB_WIDTH)
	tabLoot:SetHeight(TAB_HEIGHT)
	tabLoot:SetPoint("LEFT", tabReserves, "RIGHT", 4, 0)
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
-- Wishlist / Reserves filter bar
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
	faText:SetText("All Players")
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
-- Headers & Data Rows
-- ---------------------------------------------------------------------------
local headerFrame
local hW1, hW2, hW3
local rowFrames = {}

local function CreateHeaderAndRows()
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

	hW1 = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	hW1:SetPoint("LEFT", headerFrame, "LEFT", NAME_COL_W + 4, 0)
	hW1:SetWidth(WISH_COL_W)
	hW1:SetJustifyH("LEFT")
	hW1:SetText("#1")
	hW1:SetTextColor(1, 0.82, 0)

	hW2 = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	hW2:SetPoint("LEFT", headerFrame, "LEFT", NAME_COL_W + WISH_COL_W + 8, 0)
	hW2:SetWidth(WISH_COL_W)
	hW2:SetJustifyH("LEFT")
	hW2:SetText("#2")
	hW2:SetTextColor(1, 0.82, 0)

	hW3 = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	hW3:SetPoint("LEFT", headerFrame, "LEFT", NAME_COL_W + WISH_COL_W * 2 + 12, 0)
	hW3:SetWidth(WISH_COL_W)
	hW3:SetJustifyH("LEFT")
	hW3:SetText("#3")
	hW3:SetTextColor(1, 0.82, 0)

	local sep = headerFrame:CreateTexture(nil, "ARTWORK")
	sep:SetTexture(1, 0.82, 0, 0.5)
	sep:SetWidth(CONTENT_W)
	sep:SetHeight(1)
	sep:SetPoint("BOTTOMLEFT", headerFrame, "BOTTOMLEFT", 0, 0)

	for i = 1, VISIBLE_ROWS do
		local row = CreateFrame("Frame", "CopeLootRow" .. i, mainFrame)
		row:SetWidth(CONTENT_W)
		row:SetHeight(ROW_HEIGHT)
		row:SetPoint("TOPLEFT", headerFrame, "BOTTOMLEFT", 0, -(i - 1) * ROW_HEIGHT - 2)

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
	scrollBar = CreateFrame("Slider", "CopeLootScrollBar", mainFrame)
	scrollBar:SetWidth(SCROLL_W)
	scrollBar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -SCROLL_INSET, -122)
	scrollBar:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -SCROLL_INSET, 20)
	scrollBar:SetOrientation("VERTICAL")

	scrollBar:SetBackdrop({
		bgFile   = "Interface\\Buttons\\UI-SliderBar-Background",
		edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
		tile     = true, tileSize = 8, edgeSize = 8,
		insets   = { left = 3, right = 3, top = 6, bottom = 6 },
	})

	local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
	thumb:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
	thumb:SetWidth(SCROLL_W)
	thumb:SetHeight(SCROLL_W)
	scrollBar:SetThumbTexture(thumb)

	scrollBar:SetScript("OnValueChanged", function()
		scrollOffset = math.floor(this:GetValue())
		CopeLoot:RefreshUI()
	end)

	scrollBar:SetMinMaxValues(0, 0)
	scrollBar:SetValueStep(1)
	scrollBar:SetValue(0)

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

	local cb = CreateFrame("CheckButton", "CopeLootAutoSwapCB", settingsFrame, "UICheckButtonTemplate")
	cb:SetWidth(24)
	cb:SetHeight(24)
	cb:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 4, -10)
	cb:SetChecked(true)

	local cbLabel = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	cbLabel:SetPoint("LEFT", cb, "RIGHT", 4, 0)
	cbLabel:SetText("Swap to Current Raid list automatically when in a raid")

	cb:SetScript("OnClick", function()
		local db = EnsureDB()
		db.autoSwap = this:GetChecked() and true or false
	end)

	settingsFrame.autoSwapCB = cb

	local info = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	info:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 0, -8)
	info:SetWidth(WINDOW_W - 60)
	info:SetJustifyH("LEFT")
	info:SetText(
		"When enabled, the Wishlist/Reserves tab filter automatically switches to " ..
		"\"Current Raid\" when you join a raid group, and back to " ..
		"\"All Players\" when you leave the raid."
	)

	local cb2 = CreateFrame("CheckButton", "CopeLootAutoBroadcastCB", settingsFrame, "UICheckButtonTemplate")
	cb2:SetWidth(24)
	cb2:SetHeight(24)
	cb2:SetPoint("TOPLEFT", info, "BOTTOMLEFT", 0, -16)
	cb2:SetChecked(false)

	local cb2Label = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	cb2Label:SetPoint("LEFT", cb2, "RIGHT", 4, 0)
	cb2Label:SetText("Automatically broadcast loot info to raid chat")

	cb2:SetScript("OnClick", function()
		local db = EnsureDB()
		db.autoBroadcast = this:GetChecked() and true or false
	end)

	settingsFrame.autoBroadcastCB = cb2

	local info2 = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	info2:SetPoint("TOPLEFT", cb2, "BOTTOMLEFT", 0, -8)
	info2:SetWidth(WINDOW_W - 60)
	info2:SetJustifyH("LEFT")
	info2:SetText(
		"When enabled, CopeLoot automatically sends the wishlist verdict " ..
		"to raid chat whenever the raid leader links an epic or rare (blue) item in /say."
	)
end

-- ---------------------------------------------------------------------------
-- Loot tab content
-- ---------------------------------------------------------------------------
local lootFrame
local lootModeBtn
local lootRowFrames = {}
local LOOT_VISIBLE = 4
local LOOT_ROW_SPACING = 68

StaticPopupDialogs["COPELOOT_CONFIRM_DELETE"] = {
	text = "Are you sure you want to delete this loot entry?",
	button1 = "Yes",
	button2 = "No",
	OnAccept = function()
		if StaticPopupDialogs["COPELOOT_CONFIRM_DELETE"].targetIndex then
			table.remove(detectedLoot, StaticPopupDialogs["COPELOOT_CONFIRM_DELETE"].targetIndex)
			CopeLoot:RefreshUI()
		end
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

StaticPopupDialogs["COPELOOT_CONFIRM_BROADCAST"] = {
	text = "Are you sure you want to broadcast this loot entry to raid chat?",
	button1 = "Yes",
	button2 = "No",
	OnAccept = function()
		if StaticPopupDialogs["COPELOOT_CONFIRM_BROADCAST"].targetIndex then
			CopeLoot:BroadcastLootEntry(StaticPopupDialogs["COPELOOT_CONFIRM_BROADCAST"].targetIndex)
		end
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

StaticPopupDialogs["COPELOOT_CONFIRM_BROADCAST_ALL"] = {
	text = "Are you sure you want to broadcast ALL detected loot entries to raid chat?",
	button1 = "Yes",
	button2 = "No",
	OnAccept = function()
		CopeLoot:BroadcastAllLoot()
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

StaticPopupDialogs["COPELOOT_CONFIRM_CLEAR_ALL"] = {
	text = "Are you sure you want to clear ALL detected loot entries?",
	button1 = "Yes",
	button2 = "No",
	OnAccept = function()
		detectedLoot = {}
		scrollOffset = 0
		CopeLoot:RefreshUI()
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

local function CreateLootFrame()
	lootFrame = CreateFrame("Frame", "CopeLootLootFrame", mainFrame)
	lootFrame:SetWidth(CONTENT_W)
	lootFrame:SetHeight(WINDOW_H - 100)
	lootFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", LEFT_MARGIN, -70)
	lootFrame:Hide()

	local hdr = lootFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	hdr:SetPoint("TOPLEFT", lootFrame, "TOPLEFT", 4, -4)
	hdr:SetText("Detected Loot (Epic/Blue, from Raid Chat)")
	hdr:SetTextColor(1, 0.82, 0)

	local modeBtn = CreateFrame("Button", "CopeLootModeBtn", lootFrame, "UIPanelButtonTemplate")
	modeBtn:SetWidth(150)
	modeBtn:SetHeight(20)
	modeBtn:SetPoint("TOPRIGHT", lootFrame, "TOPRIGHT", -SCROLL_GUTTER, -2)
	modeBtn:SetScript("OnClick", function()
		if lootResolveMode == "wishlist" then
			lootResolveMode = "reserve"
		else
			lootResolveMode = "wishlist"
		end

		-- Re-evaluate all previously detected items under the new mode
		for i = 1, table.getn(detectedLoot) do
			local entry = detectedLoot[i]
			local claimants, verdict = ResolveLoot(entry.itemName, entry.count)
			entry.claimants = claimants
			entry.verdict   = verdict
			entry.mode      = lootResolveMode
		end

		CopeLoot:RefreshUI()
	end)
	lootModeBtn = modeBtn

	for i = 1, LOOT_VISIBLE do
		local row = CreateFrame("Frame", "CopeLootLootRow" .. i, lootFrame)
		row:SetWidth(CONTENT_W - SCROLL_GUTTER)
		row:SetHeight(60)
		row:SetPoint("TOPLEFT", lootFrame, "TOPLEFT", 4, -24 - (i - 1) * LOOT_ROW_SPACING)

		local bg = row:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints(row)
		if math.mod(i, 2) == 0 then
			bg:SetTexture(1, 1, 1, 0.05)
		else
			bg:SetTexture(0.5, 0.5, 0.5, 0.08)
		end

		local delBtn = CreateFrame("Button", "CopeLootDelBtn" .. i, row, "UIPanelButtonTemplate")
		delBtn:SetWidth(50)
		delBtn:SetHeight(20)
		delBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -4)
		delBtn:SetText("Delete")

		local bcBtn = CreateFrame("Button", "CopeLootBcBtn" .. i, row, "UIPanelButtonTemplate")
		bcBtn:SetWidth(65)
		bcBtn:SetHeight(20)
		bcBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
		bcBtn:SetText("Broadcast")

		local bcStatusFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		bcStatusFS:SetPoint("TOPRIGHT", bcBtn, "BOTTOMRIGHT", 0, -4)
		bcStatusFS:SetJustifyH("RIGHT")

		local itemFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		itemFS:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -2)
		itemFS:SetWidth(CONTENT_W - SCROLL_GUTTER - 130)
		itemFS:SetJustifyH("LEFT")

		local claimFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		claimFS:SetPoint("TOPLEFT", itemFS, "BOTTOMLEFT", 0, -2)
		claimFS:SetWidth(CONTENT_W - SCROLL_GUTTER - 130)
		claimFS:SetJustifyH("LEFT")

		local verdictFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		verdictFS:SetPoint("TOPLEFT", claimFS, "BOTTOMLEFT", 0, -2)
		verdictFS:SetWidth(CONTENT_W - SCROLL_GUTTER - 130)
		verdictFS:SetJustifyH("LEFT")

		row.itemFS    = itemFS
		row.claimFS   = claimFS
		row.verdictFS = verdictFS
		row.bcBtn     = bcBtn
		row.delBtn    = delBtn
		row.bcStatusFS = bcStatusFS

		lootRowFrames[i] = row
	end

	lootScrollBar = CreateFrame("Slider", "CopeLootLootScrollBar", lootFrame)
	lootScrollBar:SetWidth(SCROLL_W)
	lootScrollBar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -SCROLL_INSET, -96)
	lootScrollBar:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -SCROLL_INSET, 50)
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

	local broadcastBtn = CreateFrame("Button", "CopeLootBroadcastBtn", lootFrame, "UIPanelButtonTemplate")
	broadcastBtn:SetWidth(120)
	broadcastBtn:SetHeight(22)
	broadcastBtn:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 20, 15)
	broadcastBtn:SetText("Broadcast All")
	broadcastBtn:SetScript("OnClick", function()
		if table.getn(detectedLoot) > 0 then
			StaticPopup_Show("COPELOOT_CONFIRM_BROADCAST_ALL")
		end
	end)

	local clearBtn = CreateFrame("Button", "CopeLootClearLootBtn", lootFrame, "UIPanelButtonTemplate")
	clearBtn:SetWidth(80)
	clearBtn:SetHeight(22)
	clearBtn:SetPoint("LEFT", broadcastBtn, "RIGHT", 8, 0)
	clearBtn:SetText("Clear All")
	clearBtn:SetScript("OnClick", function()
		if table.getn(detectedLoot) > 0 then
			StaticPopup_Show("COPELOOT_CONFIRM_CLEAR_ALL")
		end
	end)
end

function CopeLoot:AssignLootToPerson(itemName, recipientName)
	local targetKey = NormaliseItemName(itemName)
	if targetKey == "" then return end

	-- Find the first open item in detectedLoot that has no assigned recipient yet
	for i = 1, table.getn(detectedLoot) do
		local entry = detectedLoot[i]
		if NormaliseItemName(entry.itemName) == targetKey and not entry.recipient then
			entry.recipient = recipientName
			Print("Assigned " .. entry.itemLink .. " -> " .. recipientName)

			if mainFrame and mainFrame:IsShown() then
				CopeLoot:RefreshUI()
			end
			return
		end
	end
end

function CopeLoot:OnSystemMsg(msg)
	if not msg then return end

	-- Vanilla WoW System Patterns for receiving items:
	-- Pattern 1: "Player receives item: [Item Name]."
	local _, _, player, itemLink = string.find(msg, "^(%S+) receives item: (|c%x+|Hitem:%d+:%d+:%d+:%d+|h%[.-%]|h|r)")
	
	-- Pattern 2: "You receive item: [Item Name]."
	if not player and not itemLink then
		_, _, itemLink = string.find(msg, "^You receive item: (|c%x+|Hitem:%d+:%d+:%d+:%d+|h%[.-%]|h|r)")
		if itemLink then
			player = UnitName("player")
		end
	end

	if player and itemLink then
		local _, _, rawItemName = string.find(itemLink, "%[(.-)%]")
		if rawItemName then
			CopeLoot:AssignLootToPerson(rawItemName, player)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Refresh / redraw
-- ---------------------------------------------------------------------------
function CopeLoot:RefreshUI()
	if not mainFrame or not mainFrame:IsShown() then return end

	local db = EnsureDB()

	local function HighlightTab(tab, isActive)
		if isActive then
			tab:SetBackdropColor(0.2, 0.6, 0.2, 1)
		else
			tab:SetBackdropColor(0.3, 0.3, 0.3, 1)
		end
	end
	HighlightTab(tabWishlist, activeTab == "wishlist")
	HighlightTab(tabReserves, activeTab == "reserves")
	HighlightTab(tabLoot,     activeTab == "loot")
	HighlightTab(tabSettings, activeTab == "settings")

	-- Hide all panes
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

		if lootResolveMode == "reserve" then
			lootModeBtn:SetText("Mode: Reserve")
		else
			lootModeBtn:SetText("Mode: Wishlist")
		end

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

				local qtyText = (entry.count and entry.count > 1) and (" (" .. entry.count .. "x)") or ""
				row.itemFS:SetText((entry.itemLink or entry.itemName) .. qtyText)
				row.itemFS:SetTextColor(0.63, 0.21, 0.93)

				if table.getn(entry.claimants) > 0 then
					local parts = {}
					for j = 1, table.getn(entry.claimants) do
						local c = entry.claimants[j]
						if entry.mode == "reserve" then
							table.insert(parts, c.name)
						else
							table.insert(parts, c.name .. " (#" .. c.col .. ")")
						end
					end
					if entry.mode == "reserve" then
						row.claimFS:SetText("Reserved (in raid): " .. table.concat(parts, ", "))
					else
						row.claimFS:SetText("Wishlisted (in raid): " .. table.concat(parts, ", "))
					end
					row.claimFS:SetTextColor(0.8, 0.8, 0.8)
				else
					if entry.mode == "reserve" then
						row.claimFS:SetText("No raid members have this reserved")
					else
						row.claimFS:SetText("No raid members have this wishlisted")
					end
					row.claimFS:SetTextColor(0.5, 0.5, 0.5)
				end

				local verdict = entry.verdict
				if entry.recipient then
					row.verdictFS:SetText("-> Assigned To: |cff00ff00" .. entry.recipient .. "|r")
					row.verdictFS:SetTextColor(0.3, 1, 0.3)
				elseif string.find(verdict, "^TIE") then
					row.verdictFS:SetText("-> " .. verdict)
					row.verdictFS:SetTextColor(1, 1, 0.3)
				elseif string.find(verdict, "No wishlist") or string.find(verdict, "No reserve") then
					row.verdictFS:SetText("-> " .. verdict)
					row.verdictFS:SetTextColor(0.5, 0.5, 0.5)
				else
					row.verdictFS:SetText("-> Award to: " .. verdict)
					row.verdictFS:SetTextColor(0.3, 1, 0.3)
				end

				row.bcBtn:SetScript("OnClick", function()
					StaticPopupDialogs["COPELOOT_CONFIRM_BROADCAST"].targetIndex = dataIdx
					StaticPopup_Show("COPELOOT_CONFIRM_BROADCAST")
				end)

				row.delBtn:SetScript("OnClick", function()
					StaticPopupDialogs["COPELOOT_CONFIRM_DELETE"].targetIndex = dataIdx
					StaticPopup_Show("COPELOOT_CONFIRM_DELETE")
				end)

				if entry.broadcasted then
					row.bcStatusFS:SetText("Broadcasted")
					row.bcStatusFS:SetTextColor(0.3, 1, 0.3) -- Green
				else
					row.bcStatusFS:SetText("Not Broadcasted")
					row.bcStatusFS:SetTextColor(0.6, 0.6, 0.6) -- Gray
				end

				row:Show()
			else
				row:Hide()
			end
		end
		return
	end

	-- --- Wishlist or Reserves Tab ---
	filterAllBtn:Show()
	filterRaidBtn:Show()
	headerFrame:Show()
	scrollBar:Show()
	for i = 1, VISIBLE_ROWS do
		rowFrames[i]:Show()
	end

	if activeFilter == "all" then
		filterAllBtn:SetBackdropColor(0.2, 0.5, 0.8, 1)
		filterRaidBtn:SetBackdropColor(0.3, 0.3, 0.3, 1)
	else
		filterAllBtn:SetBackdropColor(0.3, 0.3, 0.3, 1)
		filterRaidBtn:SetBackdropColor(0.2, 0.5, 0.8, 1)
	end

	local isReserve = (activeTab == "reserves")
	local rawTable = isReserve and CopeLoot_ReserveData or CopeLoot_PlayerData

	-- Adjust header labels according to active tab
	if isReserve then
		hW1:SetText("Reserve Item")
		hW2:SetText("Boss")
		hW3:SetText("Trinket Pieces")
	else
		hW1:SetText("#1")
		hW2:SetText("#2")
		hW3:SetText("#3")
	end

	local players = GetFilteredPlayers(rawTable, activeFilter, isReserve)
	local total = table.getn(players)
	BuildItemIndex(players, isReserve)

	local maxScroll = total - VISIBLE_ROWS
	if maxScroll < 0 then maxScroll = 0 end
	scrollBar:SetMinMaxValues(0, maxScroll)
	if scrollOffset > maxScroll then
		scrollOffset = maxScroll
	end

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

			if isReserve then
				row.w1FS:SetText(p.reserve ~= "" and p.reserve or "-")
				row.w2FS:SetText(p.boss ~= "" and p.boss or "-")
				row.w3FS:SetText(FormatTrinkets(p))

				row.w1FS:SetTextColor(1, 1, 1)
				row.w2FS:SetTextColor(1, 1, 1)
				row.w3FS:SetTextColor(1, 1, 1)
			else
				row.w1FS:SetText(p.wish1 ~= "" and p.wish1 or "-")
				row.w2FS:SetText(p.wish2 ~= "" and p.wish2 or "-")
				row.w3FS:SetText(p.wish3 ~= "" and p.wish3 or "-")

				local r1, g1, b1 = GetItemColor(p.wish1, 1)
				row.w1FS:SetTextColor(r1, g1, b1)

				local r2, g2, b2 = GetItemColor(p.wish2, 2)
				row.w2FS:SetTextColor(r2, g2, b2)

				local r3, g3, b3 = GetItemColor(p.wish3, 3)
				row.w3FS:SetTextColor(r3, g3, b3)
			end
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
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")

eventFrame:SetScript("OnEvent", function()
	if event == "ADDON_LOADED" and arg1 == "CopeLoot" then
		EnsureDB()
		IndexPlayerData()
	elseif event == "PLAYER_LOGIN" then
		Print(CopeLoot.version .. " loaded. Type /copeloot to open.")
	elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
		CheckAutoSwap()
	elseif event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER" then
		CopeLoot:OnChatMsg(arg2, arg1)
	elseif event == "CHAT_MSG_SYSTEM" then
		CopeLoot:OnSystemMsg(arg1)
	end
end)