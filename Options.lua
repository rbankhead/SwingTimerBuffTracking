-- SwingTimerBuffTracking: settings panel. Hand-built with plain CreateFrame +
-- stock templates (not the Settings-system initializers) and registered via
-- Settings.RegisterCanvasLayoutCategory, since the native vertical-layout API
-- has no text-entry control for the blocklist/allowlist fields.

local Addon = SwingTimerBuffTracking

local Options = {}
Addon.Options = Options

local category
local panel

local function MakeCheck(parent, text, onClick)
	local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	local label = c.Text or c.text or c:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	label:ClearAllPoints()
	label:SetPoint("LEFT", c, "RIGHT", 2, 1)
	label:SetText(text)
	c:SetScript("OnClick", function(self)
		onClick(self:GetChecked() and true or false)
	end)
	return c
end

local function MakeSlider(parent, label, minValue, maxValue, step, onChange)
	local s = CreateFrame("Slider", nil, parent, "UISliderTemplateWithLabels")
	s:SetWidth(220)
	s:SetHeight(17)
	s:SetMinMaxValues(minValue, maxValue)
	s:SetValueStep(step)
	s:SetObeyStepOnDrag(true)
	s.Text:SetText(label)
	s.Low:SetText(tostring(minValue))
	s.High:SetText(tostring(maxValue))

	local valueText = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	valueText:SetPoint("LEFT", s, "RIGHT", 12, 0)
	s.valueText = valueText

	s:SetScript("OnValueChanged", function(self, value)
		value = math.floor(value + 0.5)
		valueText:SetText(tostring(value))
		onChange(value)
	end)

	return s
end

local function MakeButton(parent, text, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function MakeBox(parent, anchor, width)
	local b = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	b:SetSize(width or 220, 20)
	b:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 6, -8)
	b:SetAutoFocus(false)
	b:SetScript("OnEscapePressed", b.ClearFocus)
	return b
end

-- items is a list of { label, value, tooltip }. MenuUtil.CreateRadioMenu has
-- no per-item tooltip hook, so SetupMenu (what it calls internally) is used
-- directly here so each radio item can carry its own tooltip via
-- :SetTitleAndTextTooltip.
local function MakeRadioDropdown(parent, width, items, isSelected, setSelected)
	local dropdown = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
	dropdown:SetWidth(width)
	dropdown:SetupMenu(function(_, rootDescription)
		for _, item in ipairs(items) do
			local radio = rootDescription:CreateRadio(item.label, isSelected, setSelected, item.value)
			radio:SetTitleAndTextTooltip(item.label, item.tooltip)
		end
	end)
	return dropdown
end

local LIST_ROWS = 6 -- fixed visible rows; longer lists scroll instead of growing the panel
local LIST_ROW_HEIGHT = 18

-- A label, an Add box+button, and a fixed LIST_ROWS-tall window of entries
-- (each with its own "x" remove button) that scrolls via a manual slider, so
-- a long list can't push the panel taller than the Settings window.
local function MakeListEditor(parent, topAnchor, xOffset, titleText, addFn, removeFn, getList)
	local label = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	label:SetPoint("TOPLEFT", topAnchor, "BOTTOMLEFT", xOffset, -20)
	label:SetWidth(260)
	label:SetJustifyH("LEFT")
	label:SetText(titleText)

	local box = MakeBox(parent, label, 170)

	local rows = {}
	for i = 1, LIST_ROWS do
		local text = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		text:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -6 - (i - 1) * LIST_ROW_HEIGHT)
		text:SetWidth(195)
		text:SetJustifyH("LEFT")

		local removeBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
		removeBtn:SetSize(20, 18)
		removeBtn:SetPoint("LEFT", text, "RIGHT", 6, 0)
		removeBtn:SetText("x")

		rows[i] = { text = text, removeBtn = removeBtn }
	end

	local scrollBar = CreateFrame("Slider", nil, parent)
	scrollBar:SetOrientation("VERTICAL")
	scrollBar:SetWidth(14)
	scrollBar:SetPoint("TOPLEFT", rows[1].removeBtn, "TOPRIGHT", 10, 0)
	scrollBar:SetPoint("BOTTOMLEFT", rows[LIST_ROWS].removeBtn, "BOTTOMRIGHT", 10, 0)
	local track = scrollBar:CreateTexture(nil, "BACKGROUND")
	track:SetAllPoints()
	if track.SetColorTexture then
		track:SetColorTexture(0, 0, 0, 0.35)
	end
	local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
	thumb:SetTexture([[Interface\Buttons\UI-ScrollBar-Knob]])
	thumb:SetSize(18, 24)
	scrollBar:SetThumbTexture(thumb)
	scrollBar:SetMinMaxValues(0, 0)
	scrollBar:SetValueStep(1)
	scrollBar:SetObeyStepOnDrag(true)
	scrollBar:SetValue(0)
	scrollBar:Hide() -- shown only once a list actually overflows LIST_ROWS

	local editor = {}
	local offset = 0

	local function RenderRows()
		local names = getList()
		for i = 1, LIST_ROWS do
			local name = names[offset + i]
			local row = rows[i]
			if name then
				row.text:SetText(name)
				row.removeBtn:SetScript("OnClick", function()
					removeFn(name)
					editor:Refresh()
				end)
				row.text:Show()
				row.removeBtn:Show()
			else
				row.text:Hide()
				row.removeBtn:Hide()
			end
		end
	end
	scrollBar:SetScript("OnValueChanged", function(_, value)
		offset = math.floor(value + 0.5)
		RenderRows()
	end)

	function editor:Refresh()
		local names = getList()
		local maxOffset = math.max(0, #names - LIST_ROWS)
		if offset > maxOffset then
			offset = maxOffset
		end
		scrollBar:SetMinMaxValues(0, maxOffset)
		scrollBar:SetShown(maxOffset > 0)
		scrollBar:SetValue(offset)
		RenderRows() -- SetValue above only fires OnValueChanged when it actually changes
	end

	local function DoAdd()
		addFn(box:GetText())
		box:SetText("")
		box:ClearFocus()
		editor:Refresh()
	end
	box:SetScript("OnEnterPressed", DoAdd)

	local addBtn = MakeButton(parent, "Add", 70, DoAdd)
	addBtn:SetPoint("LEFT", box, "RIGHT", 6, 1)

	return editor
end

function Options:Init()
	if category then
		return
	end
	local db = Addon.db

	panel = CreateFrame("Frame")
	panel.name = Addon.name

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText(Addon.name)

	local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	desc:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
	desc:SetJustifyH("LEFT")
	desc:SetText("Tracks buffs whose remaining time drops under the threshold below, as icons sliding across a native Swing Timer bar (choose which one under Attach to bar).")

	local RIGHT_COL_X = 300 -- right column x-offset, reused for dropdowns and the allowlist below

	-- Left column: checkboxes and sliders.
	local enable = MakeCheck(panel, "Enabled", function(value)
		db.enabled = value
		Addon:ApplyEnabled()
	end)
	enable:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", -2, -14)

	local selfOnly = MakeCheck(panel, "Show only buffs cast by self", function(value)
		db.selfOnly = value
		Addon:RefreshBuff()
	end)
	selfOnly:SetPoint("TOPLEFT", enable, "BOTTOMLEFT", 0, -6)

	local thresholdSlider = MakeSlider(panel, "Max tracked duration (sec)", 5, 180, 1, function(value)
		db.durationThreshold = value
		Addon:RefreshBuff()
	end)
	thresholdSlider:SetPoint("TOPLEFT", selfOnly, "BOTTOMLEFT", 2, -26)

	local iconSizeSlider = MakeSlider(panel, "Icon size", 12, 48, 2, function(value)
		db.iconSize = value
		Addon:ApplyIconSize()
	end)
	iconSizeSlider:SetPoint("TOPLEFT", thresholdSlider, "BOTTOMLEFT", 0, -46)

	-- Right column: all three dropdowns, using the space that otherwise sat empty.
	local attachLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	attachLabel:SetPoint("TOPLEFT", enable, "TOPLEFT", RIGHT_COL_X, 4)
	attachLabel:SetText("Attach to bar")

	local attachToItems = {
		{ label = "Main Hand", value = "mainhand", tooltip = "Attach to the native main-hand Swing Timer bar." },
		{ label = "Off Hand", value = "offhand", tooltip = "Attach to the native off-hand Swing Timer bar." },
		{ label = "Ranged", value = "ranged", tooltip = "Attach to the native ranged Swing Timer bar - useful for Hunters." },
	}
	local attachDropdown = MakeRadioDropdown(panel, 260, attachToItems,
		function(value) return value == db.attachTo end,
		function(value)
			db.attachTo = value
			Addon:ApplyAttachTo()
		end)
	attachDropdown:SetPoint("TOPLEFT", attachLabel, "BOTTOMLEFT", 2, -8)

	local scaleLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	scaleLabel:SetPoint("TOPLEFT", attachDropdown, "BOTTOMLEFT", -2, -20)
	scaleLabel:SetText("Bar scale")

	local scaleModeItems = {
		{ label = "Per-Buff Scale", value = "appear",
			tooltip = "Every icon starts at the right edge the moment it's first tracked, then crosses the bar at a speed based on how much time it had left at that moment. A fresh 30s buff crosses faster than a long buff that just dropped to its last 3 minutes." },
		{ label = "Fixed Scale (Max Tracked Duration)", value = "threshold",
			tooltip = "All icons share one scale: the Max tracked duration setting above. A fresh short buff starts partway across; a long buff that just crossed the threshold starts at the right edge." },
	}
	local scaleDropdown = MakeRadioDropdown(panel, 260, scaleModeItems,
		function(value) return value == db.scaleMode end,
		function(value) db.scaleMode = value end)
	scaleDropdown:SetPoint("TOPLEFT", scaleLabel, "BOTTOMLEFT", 2, -8)

	local sourceLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	sourceLabel:SetPoint("TOPLEFT", scaleDropdown, "BOTTOMLEFT", -2, -20)
	sourceLabel:SetText("Buff source")

	local buffSourceItems = {
		{ label = "Buffs Under Max Duration", value = "duration",
			tooltip = "Any buff whose remaining time is under Max tracked duration qualifies. The default - no list to maintain." },
		{ label = "Allowlist Only", value = "allowlist",
			tooltip = "Only buffs on the Allowlist below are shown, regardless of their remaining time." },
		{ label = "Allowlist + Max Duration", value = "both",
			tooltip = "Only buffs that are both on the Allowlist below AND under Max tracked duration are shown." },
	}
	local sourceDropdown = MakeRadioDropdown(panel, 260, buffSourceItems,
		function(value) return value == db.buffSourceMode end,
		function(value) db.buffSourceMode = value end)
	sourceDropdown:SetPoint("TOPLEFT", sourceLabel, "BOTTOMLEFT", 2, -8)

	-- Blocklist/allowlist row, anchored below the right column (the taller of
	-- the two at 3 dropdowns vs. 2 checkboxes + 2 sliders).
	local blockEditor = MakeListEditor(panel, sourceDropdown, -RIGHT_COL_X - 2,
		"Blocklist (always excluded)",
		function(name) Addon:AddBlock(name) end,
		function(name) Addon:RemoveBlock(name) end,
		function() return Addon.db.blocklist end)

	local allowEditor = MakeListEditor(panel, sourceDropdown, 0,
		"Allowlist (used by Buff source above)",
		function(name) Addon:AddAllow(name) end,
		function(name) Addon:RemoveAllow(name) end,
		function() return Addon.db.allowlist end)

	function panel:Refresh()
		enable:SetChecked(db.enabled)
		selfOnly:SetChecked(db.selfOnly)
		thresholdSlider:SetValue(db.durationThreshold)
		iconSizeSlider:SetValue(db.iconSize)
		blockEditor:Refresh()
		allowEditor:Refresh()
	end
	panel:SetScript("OnShow", panel.Refresh)

	category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
	Settings.RegisterAddOnCategory(category)
end

function Options:Open()
	if not category then
		return
	end
	-- OpenToCategory's argument has shifted between client builds; try the
	-- category object first and its numeric id as a fallback.
	if not pcall(Settings.OpenToCategory, category) then
		pcall(Settings.OpenToCategory, category.GetID and category:GetID() or nil)
	end
end
