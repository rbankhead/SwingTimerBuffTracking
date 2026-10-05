-- SwingTimerBuffTracking: overlays tracked buffs onto a native Swing Timer
-- bar (see SWING_FRAME_NAMES) instead of adding a separate bar. Each icon
-- starts at the right edge when first tracked and slides left as it counts
-- down - opposite direction from the swing fill itself.

local ADDON_NAME = "SwingTimerBuffTracking"

SwingTimerBuffTracking = {}
local Addon = SwingTimerBuffTracking
Addon.name = ADDON_NAME

local DEFAULTS = {
	enabled = true,
	durationThreshold = 30,
	iconSize = 24,
	selfOnly = true,
	attachTo = "mainhand", -- "mainhand" | "offhand" | "ranged" - which native Swing Timer bar
	scaleMode = "appear", -- "appear" | "threshold"
	buffSourceMode = "duration", -- "duration" | "allowlist" | "both" - see CollectQualifyingBuffs
	blocklist = {}, -- array of buff names that never appear, regardless of any other setting
	allowlist = {}, -- array of buff names used by buffSourceMode "allowlist"/"both"
}
Addon.DEFAULTS = DEFAULTS

local function ApplyDefaults(db, defaults)
	for key, value in pairs(defaults) do
		if db[key] == nil then
			db[key] = value
		end
	end
end

local db -- SwingTimerBuffTrackingDB, set on ADDON_LOADED

local MAX_TRACKED = 8 -- sane ceiling on simultaneous tracked icons

local statusBar -- the chosen bar's StatusBar (see SWING_FRAME_NAMES), set once found
local slots = {} -- slots[i] = { icon = Texture, countdown = FontString }, pooled and reused
local trackedBuffs = {} -- trackedBuffs[i] = auraData, one slot per qualifying buff

-- For "appear" scale mode: how much time a buff had left at the moment it
-- FIRST started being tracked, frozen per application. Keyed by spellId;
-- {expirationTime, startRemaining}. A changed expirationTime means the buff
-- was refreshed/reapplied, so it gets a fresh snapshot (restarts at the
-- right edge), same as the native swing bar resetting on each new swing.
local startRemainingCache = {}

-- Textures can't take an OnUpdate script in this client; a plain frame drives
-- the per-frame reposition instead.
local driver = CreateFrame("Frame")

local function GetOrCreateSlot(i)
	local slot = slots[i]
	if slot then
		return slot
	end

	local icon = statusBar:CreateTexture(nil, "OVERLAY")
	icon:SetSize(db.iconSize, db.iconSize)

	local countdown = statusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	countdown:SetPoint("BOTTOM", icon, "TOP", 0, 1)

	slot = { icon = icon, countdown = countdown }
	slots[i] = slot
	return slot
end

local function HideSlot(i)
	local slot = slots[i]
	if slot then
		slot.icon:Hide()
		slot.countdown:Hide()
	end
end

local function StopAll()
	trackedBuffs = {}
	wipe(startRemainingCache)
	for i = 1, #slots do
		HideSlot(i)
	end
	driver:SetScript("OnUpdate", nil)
end

-- Scale modes, set via the Settings panel dropdown. Neither depends on a
-- buff's original total duration - only its remaining time, same as the
-- tracking threshold itself:
--   "appear"    - every icon starts at the right edge the moment it's first
--                 tracked, then crosses the bar over however much time it
--                 had left at that moment (frozen per application, via
--                 startRemainingCache). Speed varies per buff.
--   "threshold" - every icon shares one scale, db.durationThreshold, so all
--                 move at the same speed. A buff that just crossed the
--                 threshold starts at the right edge too, but a fresh short
--                 buff starts partway across instead (it has less than the
--                 full threshold remaining).
local function PositionAll()
	local now = GetTime()
	local anyVisible = false
	local scaleMode = db.scaleMode

	for i = 1, #trackedBuffs do
		local buff = trackedBuffs[i]
		local remaining = buff.expirationTime - now
		if remaining <= 0 then
			HideSlot(i)
		else
			local scaleDuration
			if scaleMode == "appear" then
				local cached = startRemainingCache[buff.spellId]
				scaleDuration = cached and cached.startRemaining
			else
				scaleDuration = db.durationThreshold
			end
			if not scaleDuration or scaleDuration <= 0 then
				scaleDuration = remaining -- defensive only; shouldn't happen given the qualifying filter
			end

			local fraction = remaining / scaleDuration -- 1 at application (right edge) -> 0 at expiry (left edge)
			local slot = slots[i]
			slot.icon:SetPoint("CENTER", statusBar, "LEFT", fraction * statusBar:GetWidth(), 0)
			slot.countdown:SetFormattedText("%.1f", remaining)
			anyVisible = true
		end
	end

	if not anyVisible then
		driver:SetScript("OnUpdate", nil)
	end
end

-- This client can mark aura data "secret" (anti-automation); addon code is
-- locked out of reading auras while that's active. C_Secrets.ShouldAurasBeSecret
-- checks first instead of crashing on GetAuraSlots; we just keep showing the
-- last-known buffs, counting down on their own cached expirationTime.
local function AurasAreReadable()
	return not (C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret())
end

-- Case-insensitive exact-name check against a list (blocklist/allowlist).
local function NameInList(list, name)
	if not name then
		return false
	end
	local lower = name:lower()
	for _, entry in ipairs(list) do
		if entry:lower() == lower then
			return true
		end
	end
	return false
end

-- Collects buffs (self-applied only when db.selfOnly is set, otherwise any
-- source; never a blocklisted name - that check applies no matter which
-- mode below is active), sorted by remaining time descending. Which buffs
-- qualify depends on db.buffSourceMode:
--   "duration"  - remaining time <= db.durationThreshold (the default).
--   "allowlist" - name is on db.allowlist, regardless of remaining time.
--   "both"      - name is on db.allowlist AND remaining <= db.durationThreshold.
-- Filtering duration on remaining rather than the buff's original total
-- duration means a long buff (e.g. a 10-minute food buff) starts getting
-- tracked once it drops under the threshold, same as any genuinely short
-- buff. Returns ok, buffs; ok is false only when the read itself was
-- blocked (auras secret).
local function CollectQualifyingBuffs()
	local now = GetTime()
	local threshold = db.durationThreshold
	local selfOnly = db.selfOnly
	local mode = db.buffSourceMode
	local collected = {}

	-- Defense in depth: AurasAreReadable() is checked by the caller, but
	-- pcall guards any gap between that check and the actual read so a
	-- secrecy state change mid-scan degrades instead of throwing.
	local ok = pcall(AuraUtil.ForEachAura, "player", "HELPFUL", nil, function(auraData)
		if (not selfOnly or auraData.isFromPlayerOrPlayerPet) and auraData.expirationTime
			and auraData.expirationTime > 0 and not NameInList(db.blocklist, auraData.name) then
			local remaining = auraData.expirationTime - now
			if remaining > 0 then
				local qualifies
				if mode == "allowlist" then
					qualifies = NameInList(db.allowlist, auraData.name)
				elseif mode == "both" then
					qualifies = NameInList(db.allowlist, auraData.name) and remaining <= threshold
				else
					qualifies = remaining <= threshold
				end
				if qualifies then
					collected[#collected + 1] = auraData
				end
			end
		end
	end, true)

	if not ok then
		return false, nil
	end

	table.sort(collected, function(a, b)
		return (a.expirationTime - now) > (b.expirationTime - now)
	end)

	for i = #collected, MAX_TRACKED + 1, -1 do
		collected[i] = nil
	end

	return true, collected
end

local function RefreshBuff()
	if not statusBar or not db.enabled then
		return
	end

	if not AurasAreReadable() then
		return
	end

	local ok, buffs = CollectQualifyingBuffs()
	if not ok then
		return -- read was blocked; keep showing whatever we last knew
	end

	local previousCount = #trackedBuffs
	trackedBuffs = buffs

	-- Snapshot each buff's remaining time the first time it's seen at this
	-- expirationTime (a changed expirationTime means a refresh/reapply, so it
	-- gets a fresh snapshot too), for "appear" scale mode. Stale entries for
	-- buffs no longer tracked are pruned so this never grows unbounded.
	local stillPresent = {}
	for i = 1, #trackedBuffs do
		local buff = trackedBuffs[i]
		stillPresent[buff.spellId] = true
		local cached = startRemainingCache[buff.spellId]
		if not cached or cached.expirationTime ~= buff.expirationTime then
			startRemainingCache[buff.spellId] = {
				expirationTime = buff.expirationTime,
				startRemaining = buff.expirationTime - GetTime(),
			}
		end
	end
	for spellId in pairs(startRemainingCache) do
		if not stillPresent[spellId] then
			startRemainingCache[spellId] = nil
		end
	end

	for i = 1, #trackedBuffs do
		local slot = GetOrCreateSlot(i)
		slot.icon:SetTexture(trackedBuffs[i].icon)
		slot.icon:Show()
		slot.countdown:Show()
	end
	for i = #trackedBuffs + 1, previousCount do
		HideSlot(i)
	end

	if #trackedBuffs > 0 then
		driver:SetScript("OnUpdate", PositionAll)
		PositionAll()
	else
		driver:SetScript("OnUpdate", nil)
	end
end
Addon.RefreshBuff = RefreshBuff

function Addon:ApplyEnabled()
	if not db.enabled then
		StopAll()
	else
		RefreshBuff()
	end
end

-- C_Spell.DoesSpellExist's name-based lookup only resolves against the
-- client's LOCAL spell name cache (spells learned, seen cast, inspected,
-- etc.), not the full server-side spell list, so it can't reliably reject
-- anything - a real spell the client just hasn't encountered yet (e.g. one
-- you haven't learned) reads the same as a typo. It's used for a
-- non-blocking warning only.
local function WarnIfUnrecognizedSpell(name)
	if not (C_Spell and C_Spell.DoesSpellExist and C_Spell.DoesSpellExist(name)) then
		print("|cff33ccffSwingTimerBuffTracking|r: \"" .. name .. "\" isn't a spell your client currently recognizes - added anyway, but double-check the spelling.")
	end
end

-- Adds name to list (case-insensitive de-duped). Returns true if it's in the
-- list afterward (added or already present), false only for an empty name.
local function AddToList(list, name)
	name = strtrim(name or "")
	if name == "" then
		return false
	end
	WarnIfUnrecognizedSpell(name)
	if NameInList(list, name) then
		return true
	end
	table.insert(list, name)
	return true
end

-- Returns true if an entry was actually removed.
local function RemoveFromList(list, name)
	name = strtrim(name or ""):lower()
	if name == "" then
		return false
	end
	for i, existing in ipairs(list) do
		if existing:lower() == name then
			table.remove(list, i)
			return true
		end
	end
	return false
end

-- Builds the Add*/Remove* pair for a db list key (blocklist/allowlist),
-- sharing AddToList/RemoveFromList and the RefreshBuff-on-change behavior.
local function MakeListMutators(listKey)
	local function add(_, name)
		local added = AddToList(db[listKey], name)
		if added then
			RefreshBuff()
		end
		return added
	end

	local function remove(_, name)
		if RemoveFromList(db[listKey], name) then
			RefreshBuff()
		end
	end

	return add, remove
end

Addon.AddBlock, Addon.RemoveBlock = MakeListMutators("blocklist")
Addon.AddAllow, Addon.RemoveAllow = MakeListMutators("allowlist")

function Addon:ApplyIconSize()
	for i = 1, #slots do
		if slots[i] then
			slots[i].icon:SetSize(db.iconSize, db.iconSize)
		end
	end
	if #trackedBuffs > 0 then
		PositionAll()
	end
end

-- The three native Blizzard bars this can attach to (Blizzard_SwingTimer.xml).
local SWING_FRAME_NAMES = {
	mainhand = "SwingTimerMainHandFrame",
	offhand = "SwingTimerOffHandFrame",
	ranged = "SwingTimerRangedFrame",
}

local function AttachToSwingTimer()
	local frameName = SWING_FRAME_NAMES[db.attachTo] or SWING_FRAME_NAMES.mainhand
	local swingFrame = _G[frameName]
	if not swingFrame or not swingFrame.StatusBar then
		return false
	end

	statusBar = swingFrame.StatusBar
	return true
end

-- Called when the "Attach to bar" setting changes: re-finds the chosen
-- bar's StatusBar and reparents every existing icon/countdown onto it
-- (Texture/FontString both support SetParent after creation), rather than
-- discarding and recreating the pooled slots.
function Addon:ApplyAttachTo()
	if not AttachToSwingTimer() then
		print("|cff33ccffSwingTimerBuffTracking|r: that Swing Timer bar isn't available right now; keeping the previous attachment.")
		return
	end

	for i = 1, #slots do
		local slot = slots[i]
		if slot then
			slot.icon:SetParent(statusBar)
			slot.countdown:SetParent(statusBar)
		end
	end

	RefreshBuff()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterUnitEvent("UNIT_AURA", "player")
frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			SwingTimerBuffTrackingDB = SwingTimerBuffTrackingDB or {}
			ApplyDefaults(SwingTimerBuffTrackingDB, DEFAULTS)
			db = SwingTimerBuffTrackingDB
			Addon.db = db
			if Addon.Options then
				Addon.Options:Init()
			end
		end
	elseif event == "PLAYER_LOGIN" then
		-- This addon only has something to attach to once the native Swing
		-- Timer bar itself is enabled - confirmed real CVar name
		-- "showSwingTimer" (the same one Interface Options -> Advanced
		-- Options' own "Enable Swing Timer" checkbox is wired to, and that
		-- EditMode's own shouldEnableCVarName for the Swing Timer system
		-- uses). Off by default on a fresh character (confirmed in-game),
		-- which left this addon with no bar to find at all. Forced on here
		-- rather than just failing with a print, since this addon is useless
		-- without it.
		if not GetCVarBool("showSwingTimer") then
			SetCVar("showSwingTimer", "1")
		end

		if not AttachToSwingTimer() then
			print("|cff33ccffSwingTimerBuffTracking|r: the selected native Swing Timer bar wasn't found; the native Swing Timer UI may have changed.")
			return
		end
		RefreshBuff()
	elseif event == "UNIT_AURA" then
		RefreshBuff()
	end
end)

SLASH_SWINGTIMERBUFFTRACKING1 = "/swingbufftracking"
SlashCmdList["SWINGTIMERBUFFTRACKING"] = function()
	if Addon.Options then
		Addon.Options:Open()
	end
end
