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
--   autoSwap = true/false,
-- }

local function EnsureDB()
	if not CopeLootDB then
		CopeLootDB = {}
	end
	if CopeLootDB.autoSwap == nil then
		CopeLootDB.autoSwap = true
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
-- Constants / layout metrics
-- ---------------------------------------------------------------------------
local WINDOW_W       = 600
local WINDOW_H       = 400
local ROW_HEIGHT     = 20
local HEADER_HEIGHT  = 24
local NAME_COL_W     = 130
local WISH_COL_W     = 150
local TAB_HEIGHT     = 24
local TAB_WIDTH      = 100
local VISIBLE_ROWS   = 14

-- Active state
local activeTab    = "wishlist"   -- "wishlist" | "settings"
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
	title:SetText("CopeLoot – Cope Guild Wishlists")

	-- Close button
	local closeBtn = CreateFrame("Button", nil, mainFrame, "UIPanelCloseButton")
	closeBtn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -5, -5)

	return mainFrame
end

-- ---------------------------------------------------------------------------
-- Tabs
-- ---------------------------------------------------------------------------
local tabWishlist, tabSettings

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
	twText:SetPoint("CENTER")
	twText:SetText("Wishlist")
	tabWishlist.text = twText

	tabWishlist:SetScript("OnClick", function() SetActiveTab("wishlist") end)

	-- Settings tab
	tabSettings = CreateFrame("Button", "CopeLootTabSettings", mainFrame)
	tabSettings:SetWidth(TAB_WIDTH)
	tabSettings:SetHeight(TAB_HEIGHT)
	tabSettings:SetPoint("LEFT", tabWishlist, "RIGHT", 4, 0)
	tabSettings:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile     = true, tileSize = 8, edgeSize = 12,
		insets   = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	tabSettings:SetBackdropColor(0.3, 0.3, 0.3, 1)

	local tsText = tabSettings:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	tsText:SetPoint("CENTER")
	tsText:SetText("Settings")
	tabSettings.text = tsText

	tabSettings:SetScript("OnClick", function() SetActiveTab("settings") end)
end

-- ---------------------------------------------------------------------------
-- Wishlist tab – filter bar
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
	faText:SetPoint("CENTER")
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
	frText:SetPoint("CENTER")
	frText:SetText("Current Raid")
	filterRaidBtn.text = frText

	filterRaidBtn:SetScript("OnClick", function() SetFilter("raid") end)
end

-- ---------------------------------------------------------------------------
-- Wishlist tab – column headers + data rows
-- ---------------------------------------------------------------------------
local headerFrame
local rowFrames = {}

local function CreateHeaderAndRows()
	-- Column header bar
	headerFrame = CreateFrame("Frame", nil, mainFrame)
	headerFrame:SetWidth(WINDOW_W - 40)
	headerFrame:SetHeight(HEADER_HEIGHT)
	headerFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 20, -96)

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
	sep:SetWidth(WINDOW_W - 44)
	sep:SetHeight(1)
	sep:SetPoint("BOTTOMLEFT", headerFrame, "BOTTOMLEFT", 0, 0)

	-- Pre-create row frames
	for i = 1, VISIBLE_ROWS do
		local row = CreateFrame("Frame", "CopeLootRow" .. i, mainFrame)
		row:SetWidth(WINDOW_W - 40)
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
	scrollBar = CreateFrame("Slider", "CopeLootScrollBar", mainFrame, "UIPanelScrollBarTemplate")
	scrollBar:SetWidth(16)
	scrollBar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -28, -122)
	scrollBar:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -28, 20)
	scrollBar:SetMinMaxValues(0, 1)
	scrollBar:SetValueStep(1)
	scrollBar:SetValue(0)

	scrollBar:SetScript("OnValueChanged", function()
		scrollOffset = math.floor(this:GetValue())
		CopeLoot:RefreshUI()
	end)

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

	-- Info text
	local info = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	info:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 0, -16)
	info:SetWidth(WINDOW_W - 60)
	info:SetJustifyH("LEFT")
	info:SetText(
		"When enabled, the Wishlist tab filter automatically switches to " ..
		"\"Current Raid\" when you join a raid group, and back to " ..
		"\"All Wishlist\" when you leave the raid."
	)
end

-- ---------------------------------------------------------------------------
-- Refresh / redraw
-- ---------------------------------------------------------------------------

function CopeLoot:RefreshUI()
	if not mainFrame or not mainFrame:IsShown() then return end

	local db = EnsureDB()

	-- Tab highlight
	if activeTab == "wishlist" then
		tabWishlist:SetBackdropColor(0.2, 0.6, 0.2, 1)
		tabSettings:SetBackdropColor(0.3, 0.3, 0.3, 1)
	else
		tabWishlist:SetBackdropColor(0.3, 0.3, 0.3, 1)
		tabSettings:SetBackdropColor(0.2, 0.6, 0.2, 1)
	end

	-- Show/hide panes
	local showWishlist = (activeTab == "wishlist")
	if showWishlist then
		filterAllBtn:Show()
		filterRaidBtn:Show()
		headerFrame:Show()
		scrollBar:Show()
		settingsFrame:Hide()
		for i = 1, VISIBLE_ROWS do
			rowFrames[i]:Show()
		end
	else
		filterAllBtn:Hide()
		filterRaidBtn:Hide()
		headerFrame:Hide()
		scrollBar:Hide()
		for i = 1, VISIBLE_ROWS do
			rowFrames[i]:Hide()
		end
		settingsFrame:Show()
		settingsFrame.autoSwapCB:SetChecked(db.autoSwap)
		return
	end

	-- Filter button highlight
	if activeFilter == "all" then
		filterAllBtn:SetBackdropColor(0.2, 0.5, 0.8, 1)
		filterRaidBtn:SetBackdropColor(0.3, 0.3, 0.3, 1)
	else
		filterAllBtn:SetBackdropColor(0.3, 0.3, 0.3, 1)
		filterRaidBtn:SetBackdropColor(0.2, 0.5, 0.8, 1)
	end

	-- Get data
	local players = GetFilteredPlayers(activeFilter)
	local total = table.getn(players)

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

			row.w1FS:SetTextColor(1, 1, 1)
			row.w2FS:SetTextColor(1, 1, 1)
			row.w3FS:SetTextColor(0.7, 0.7, 0.7)
			if p.wish3 == "" then
				row.w3FS:SetTextColor(0.4, 0.4, 0.4)
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

eventFrame:SetScript("OnEvent", function()
	if event == "ADDON_LOADED" and arg1 == "CopeLoot" then
		EnsureDB()
		IndexPlayerData()
	elseif event == "PLAYER_LOGIN" then
		Print(CopeLoot.version .. " loaded. Type /copeloot to open.")
	elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
		CheckAutoSwap()
	end
end)
