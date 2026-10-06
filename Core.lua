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
	learnedDurations = {}, -- [spellId] = seconds, auto-learned - see the combat-log tracking section below
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

-- Confirmed in-game: "SwingTimerBuffTracking has been blocked from an action
-- only available to the Blizzard UI" - WoW's older combat-lockdown system
-- (separate from the secret-value restrictions elsewhere). First suspected
-- this was only about CREATING new regions on statusBar (a child of the
-- native Swing Timer frame, which inherits BottomManagedFrameTemplate, the
-- same secure-adjacent bottom-HUD management the action bars use) -
-- pre-creating every slot up front fixed that specific case, but the error
-- still happened. Confirmed in-game a second time: it's broader than
-- creation - REPOSITIONING an existing region that's already a child of
-- that frame tree (PositionAll's own SetPoint calls, which run every frame
-- while anything is tracked) is restricted too, during combat.
--
-- The real fix is to stop being a child of that frame tree at all. This
-- overlay is an ordinary frame parented to UIParent - no secure/managed
-- lineage of its own - sized and positioned to exactly cover statusBar via
-- SetAllPoints once (safe: that's this addon's own frame taking statusBar
-- as a position REFERENCE, not modifying statusBar's own children, the
-- opposite direction from what's restricted). Every icon/countdown is a
-- child of this overlay instead of statusBar directly, so nothing this
-- addon ever does again - creating, resizing, or repositioning - touches
-- the native frame's own hierarchy at all, in or out of combat.
local overlayFrame = CreateFrame("Frame", nil, UIParent)

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

	local icon = overlayFrame:CreateTexture(nil, "OVERLAY")
	icon:SetSize(db.iconSize, db.iconSize)

	local countdown = overlayFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
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

-- Belt-and-suspenders from chasing this bug's first (incomplete) diagnosis -
-- harmless to keep now that overlayFrame makes it unnecessary for the
-- combat-lockdown issue specifically, but there's no reason for slot
-- creation to wait until the first buff shows up either way.
local function PreCreateSlots()
	for i = 1, MAX_TRACKED do
		GetOrCreateSlot(i)
		HideSlot(i)
	end
end

-- Confirmed in-game: the real trigger for "blocked from an action only
-- available to the Blizzard UI" was neither of the two things this addon
-- tried fixing before (slot creation, then slot repositioning) - it was a
-- wrong assumption underneath both of them. PLAYER_LOGIN was assumed to
-- "not itself happen mid-combat", true for a real login but not for a
-- /reload - confirmed directly: the player reloaded WHILE already in
-- combat, so PLAYER_LOGIN's own setup work (AttachToSwingTimer syncing
-- overlayFrame, PreCreateSlots, RefreshBuff) ran mid-combat for the first
-- time, tripping combat lockdown on something in that path. The fix isn't
-- another frame-handling change - it's not running any of this setup while
-- InCombatLockdown() is true at all (confirmed real, standard API), and
-- waiting for the real PLAYER_REGEN_ENABLED event (confirmed real, fires
-- when combat actually ends) to run it instead. Also used for ApplyAttachTo
-- below, since changing the "Attach to bar" setting does the same
-- overlayFrame sync and could in principle be changed mid-combat too.
local function RunWhenSafe(fn)
	if InCombatLockdown() then
		local waiter = CreateFrame("Frame")
		waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
		waiter:SetScript("OnEvent", function(self)
			self:UnregisterEvent("PLAYER_REGEN_ENABLED")
			fn()
		end)
	else
		fn()
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
			slot.icon:SetPoint("CENTER", overlayFrame, "LEFT", fraction * overlayFrame:GetWidth(), 0)
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

-- Confirmed in-game: ShouldAurasBeSecret() is true while the player is in
-- combat on this client, which blocks the scan above entirely - so a buff
-- applied DURING combat (a Warrior's self-cast Bloodrage, reported not
-- showing) is invisible until combat ends, even though one applied BEFORE
-- combat (a Paladin's seal) keeps counting down fine, since no new read is
-- needed for a buff already being tracked from its cached expirationTime.
-- There's no way to read around that restriction - it's deliberate, the
-- same anti-automation system that blocks the Damage Meter's own live
-- secret-number comparisons in SymmetricalChatAndDamageMeter.
--
-- Combat log events aren't blocked by it though - that's the same reason
-- the native Damage Meter itself keeps working mid-fight, since it's driven
-- by combat log data rather than aura reads. There's no API to look up a
-- spell's base duration directly (confirmed: nothing like GetSpellDuration
-- exists), and a hardcoded per-spell list is explicitly not wanted - so
-- instead this LEARNS each ability's duration automatically, the first time
-- it's ever seen, from nothing but two plain GetTime() timestamps:
-- SPELL_AURA_APPLIED/SPELL_AURA_REFRESH (confirmed real subevents, used
-- throughout this client's own CombatLogProcessor) mark when a buff starts,
-- SPELL_AURA_REMOVED marks when it ends - the elapsed time between them is
-- the real duration, cached per spellId in db.learnedDurations and reused
-- on every later cast of the same ability. Nothing here ever touches a live
-- aura value, secret or not, so none of it is at risk of the taint/secrecy
-- issues elsewhere in this addon - it's pure event timestamps, computed
-- entirely in this addon's own Lua.
--
-- The very first time a given ability is ever seen there's no learned
-- duration yet - it still displays immediately even so, using
-- db.durationThreshold as a provisional guess (see the combat log handler
-- below), so every cast works, not just the second one onward. That
-- provisional display self-corrects to the real learned duration as soon
-- as it's actually observed expiring, automatically, same as everything
-- else in this file (still filtered through the normal selfOnly/blocklist/
-- buffSourceMode/durationThreshold settings above - there's no separate
-- list or setting for this at all).
--
-- C_CombatLog.GetCurrentEventInfo() is the modern real name - confirmed via
-- this client's own Deprecated_CombatLog.lua, where the old global
-- CombatLogGetCurrentEventInfo is defined as nothing but an alias to it.
-- Its SPELL_AURA_* extra args (spellId, spellName, spellSchool, auraType)
-- are confirmed in this client's own Blizzard_CombatLogProcessor.lua.
local combatLogBuffs = {} -- [spellId] = { spellId=, name=, icon=, expirationTime=, isFromPlayerOrPlayerPet=true, isCombatLogSourced=true }
local pendingAuraStart = {} -- [spellId] = GetTime() when APPLIED/REFRESH was last seen, cleared on REMOVED

local function PruneCombatLogBuffs()
	local now = GetTime()
	for spellId, entry in pairs(combatLogBuffs) do
		if entry.expirationTime <= now then
			combatLogBuffs[spellId] = nil
		end
	end
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

-- Same qualification rule CollectQualifyingBuffs applies inline to a live
-- aura's remaining time, factored out so the combat-log path below can
-- apply the identical rule to a just-learned duration (the two are
-- equivalent the moment a buff is freshly applied - remaining == full
-- duration). Blocklist always applies regardless of mode, matching the
-- aura-scan path.
local function DoesNameQualify(name, durationSeconds)
	if NameInList(db.blocklist, name) then
		return false
	end
	local mode = db.buffSourceMode
	if mode == "allowlist" then
		return NameInList(db.allowlist, name)
	elseif mode == "both" then
		return NameInList(db.allowlist, name) and durationSeconds <= db.durationThreshold
	else
		return durationSeconds <= db.durationThreshold
	end
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

	PruneCombatLogBuffs()

	-- Aura-sourced half of the list: a fresh scan when readable, or (when
	-- not - the auras-secret-in-combat case) whatever aura-sourced entries
	-- were already being tracked, carried forward rather than wiped, since
	-- their cached expirationTime is still good for display even though a
	-- new read isn't possible right now. Combat-log-sourced entries are
	-- never carried forward this way - combatLogBuffs below is already the
	-- authoritative, continuously-updated source for those.
	local buffs
	local freshAuraScan = false
	if AurasAreReadable() then
		local ok, auraBuffs = CollectQualifyingBuffs()
		if ok then
			buffs = auraBuffs
			freshAuraScan = true
		end
	end
	if not freshAuraScan then
		buffs = {}
		for _, buff in ipairs(trackedBuffs) do
			if not buff.isCombatLogSourced then
				buffs[#buffs + 1] = buff
			end
		end
	end

	-- Combat-log-sourced half: always re-added fresh regardless of aura
	-- readability, since these never depended on an aura read at all.
	local now = GetTime()
	for _, entry in pairs(combatLogBuffs) do
		if not NameInList(db.blocklist, entry.name) then
			buffs[#buffs + 1] = entry
		end
	end

	table.sort(buffs, function(a, b)
		return (a.expirationTime - now) > (b.expirationTime - now)
	end)
	for i = #buffs, MAX_TRACKED + 1, -1 do
		buffs[i] = nil
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

	-- Syncs overlayFrame to statusBar's current screen rect - this addon's
	-- own frame reading statusBar's position as a reference, not touching
	-- statusBar's own anchors/children, so it's safe regardless of combat
	-- state (see overlayFrame's own comment above for why that direction
	-- matters here). Strata/level pushed above statusBar's own so the icons
	-- render on top of the bar instead of potentially behind it, now that
	-- they're siblings in UIParent's tree rather than direct children.
	overlayFrame:ClearAllPoints()
	overlayFrame:SetAllPoints(statusBar)
	overlayFrame:SetFrameStrata(statusBar:GetFrameStrata())
	overlayFrame:SetFrameLevel(statusBar:GetFrameLevel() + 10)

	return true
end

-- Called when the "Attach to bar" setting changes: re-finds the chosen
-- bar's StatusBar and re-syncs overlayFrame to it. The icons/countdowns
-- themselves stay put - they're children of overlayFrame, not statusBar
-- directly, so there's nothing per-slot to reparent anymore.
function Addon:ApplyAttachTo()
	RunWhenSafe(function()
		if not AttachToSwingTimer() then
			print("|cff33ccffSwingTimerBuffTracking|r: that Swing Timer bar isn't available right now; keeping the previous attachment.")
			return
		end

		RefreshBuff()
	end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterUnitEvent("UNIT_AURA", "player")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		if not db then
			return
		end
		local _, subevent, _, sourceGUID, _, _, _, destGUID, _, _, _, spellId, spellName, _, auraType = C_CombatLog.GetCurrentEventInfo()
		if destGUID ~= UnitGUID("player") then
			return
		end
		if subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_AURA_REFRESH" then
			if auraType ~= "BUFF" or not spellId or not spellName then
				return
			end
			if db.selfOnly and sourceGUID ~= UnitGUID("player") then
				return
			end

			pendingAuraStart[spellId] = GetTime()

			-- The very first time an ability is ever seen there's no
			-- learned duration yet - confirmed real complaint: silently
			-- skipping that first cast and only tracking from the second
			-- one onward isn't acceptable. db.durationThreshold stands in
			-- as a provisional guess so it displays immediately every time,
			-- not just after the first; DoesNameQualify trivially passes
			-- its own duration<=threshold check against that guess, so this
			-- only changes WHEN a never-before-seen ability starts
			-- displaying, not the qualification rules. The provisional
			-- display self-corrects the moment the real duration is
			-- learned below (on SPELL_AURA_REMOVED) and used for every
			-- cast after - a buff that turns out to run longer than the
			-- threshold just stops qualifying from the second cast on, the
			-- same as it always would have.
			local duration = db.learnedDurations[spellId] or db.durationThreshold
			if DoesNameQualify(spellName, duration) then
				combatLogBuffs[spellId] = {
					spellId = spellId,
					name = spellName,
					icon = C_Spell.GetSpellTexture(spellId),
					expirationTime = GetTime() + duration,
					isFromPlayerOrPlayerPet = true,
					isCombatLogSourced = true,
				}
				RefreshBuff()
			end
		elseif subevent == "SPELL_AURA_REMOVED" then
			if auraType ~= "BUFF" or not spellId then
				return
			end
			local startedAt = pendingAuraStart[spellId]
			if startedAt then
				pendingAuraStart[spellId] = nil
				local observed = GetTime() - startedAt
				if observed > 0 then
					db.learnedDurations[spellId] = observed
				end
			end
			if combatLogBuffs[spellId] then
				combatLogBuffs[spellId] = nil
				RefreshBuff()
			end
		end
		return
	end

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

		RunWhenSafe(function()
			if not AttachToSwingTimer() then
				print("|cff33ccffSwingTimerBuffTracking|r: the selected native Swing Timer bar wasn't found; the native Swing Timer UI may have changed.")
				return
			end
			PreCreateSlots()
			RefreshBuff()
		end)
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
