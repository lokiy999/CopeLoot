-- CopeLoot.lua
-- Wishlist-based loot addon for the guild <Cope>
-- Target client: World of Warcraft Classic 1.12.1 (Vanilla API)

CopeLoot = {}
local CopeLoot = CopeLoot

CopeLoot.name = "CopeLoot"
CopeLoot.version = "0.1.0"

-- ---------------------------------------------------------------------------
-- Saved variables
-- ---------------------------------------------------------------------------
-- CopeLootDB layout:
-- CopeLootDB = {
--   wishlists = {
--     ["PlayerName"] = {
--       [1] = { link = "|cffa335ee|Hitem:...|h[Item Name]|h|r", name = "Item Name", added = time() },
--       ...
--     },
--   },
-- }

local function EnsureDB()
	if not CopeLootDB then
		CopeLootDB = {}
	end
	if not CopeLootDB.wishlists then
		CopeLootDB.wishlists = {}
	end
	return CopeLootDB
end

local function GetPlayerName()
	return UnitName("player")
end

local function GetMyWishlist()
	local db = EnsureDB()
	local playerName = GetPlayerName()
	if not db.wishlists[playerName] then
		db.wishlists[playerName] = {}
	end
	return db.wishlists[playerName]
end

-- ---------------------------------------------------------------------------
-- Chat output helper
-- ---------------------------------------------------------------------------

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[CopeLoot]|r " .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- Item link parsing
-- ---------------------------------------------------------------------------

local function GetItemNameFromLink(link)
	if not link then
		return nil
	end
	local _, _, name = string.find(link, "%[(.-)%]")
	return name
end

-- ---------------------------------------------------------------------------
-- Wishlist operations
-- ---------------------------------------------------------------------------

function CopeLoot:AddItem(link)
	if not link or link == "" then
		Print("Usage: /copeloot add <item link> (shift-click an item into chat)")
		return
	end

	local name = GetItemNameFromLink(link)
	if not name then
		Print("That doesn't look like a valid item link.")
		return
	end

	local wishlist = GetMyWishlist()

	for i = 1, table.getn(wishlist) do
		if wishlist[i].link == link then
			Print(name .. " is already on your wishlist.")
			return
		end
	end

	table.insert(wishlist, {
		link = link,
		name = name,
		added = time(),
	})

	Print("Added " .. link .. " to your wishlist.")
end

function CopeLoot:RemoveItem(index)
	local wishlist = GetMyWishlist()
	index = tonumber(index)

	if not index or index < 1 or index > table.getn(wishlist) then
		Print("Usage: /copeloot remove <index> (see /copeloot list for indices)")
		return
	end

	local removed = table.remove(wishlist, index)
	if removed then
		Print("Removed " .. removed.link .. " from your wishlist.")
	end
end

function CopeLoot:ClearWishlist()
	local db = EnsureDB()
	db.wishlists[GetPlayerName()] = {}
	Print("Your wishlist has been cleared.")
end

function CopeLoot:ListWishlist(targetName)
	local db = EnsureDB()
	local playerName = targetName or GetPlayerName()
	local wishlist = db.wishlists[playerName]

	if not wishlist or table.getn(wishlist) == 0 then
		Print(playerName .. "'s wishlist is empty.")
		return
	end

	Print(playerName .. "'s wishlist:")
	for i = 1, table.getn(wishlist) do
		DEFAULT_CHAT_FRAME:AddMessage(i .. ". " .. wishlist[i].link)
	end
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

SLASH_COPELOOT1 = "/copeloot"
SLASH_COPELOOT2 = "/cl"

SlashCmdList["COPELOOT"] = function(msg)
	msg = msg or ""

	local _, _, cmd, rest = string.find(msg, "^(%S*)%s*(.-)$")
	cmd = string.lower(cmd or "")

	if cmd == "add" then
		CopeLoot:AddItem(rest)
	elseif cmd == "remove" or cmd == "rm" then
		CopeLoot:RemoveItem(rest)
	elseif cmd == "clear" then
		CopeLoot:ClearWishlist()
	elseif cmd == "list" then
		if rest and rest ~= "" then
			CopeLoot:ListWishlist(rest)
		else
			CopeLoot:ListWishlist()
		end
	else
		Print(CopeLoot.name .. " v" .. CopeLoot.version .. " commands:")
		DEFAULT_CHAT_FRAME:AddMessage("/copeloot add <item link> - add an item to your wishlist")
		DEFAULT_CHAT_FRAME:AddMessage("/copeloot remove <index> - remove an item from your wishlist")
		DEFAULT_CHAT_FRAME:AddMessage("/copeloot list [player] - list your wishlist, or another player's")
		DEFAULT_CHAT_FRAME:AddMessage("/copeloot clear - clear your wishlist")
	end
end

-- ---------------------------------------------------------------------------
-- Event handling
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame", "CopeLootFrame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function()
	if event == "ADDON_LOADED" and arg1 == "CopeLoot" then
		EnsureDB()
	elseif event == "PLAYER_LOGIN" then
		Print(CopeLoot.version .. " loaded. Type /copeloot for commands.")
	end
end)
