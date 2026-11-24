local addonName, ns = ...
local sync = ns.Sync
local events = CreateFrame("Frame")
local db
local deathSerial = 0
local lastSeen = {}
local pending = {}
local tracked = {}
local icon = "Interface\\Icons\\Ability_DualWield"

local function readable(value, kind)
    if issecretvalue and issecretvalue(value) then return nil end
    if type(value) == kind then return value end
end

local function inWorld()
    local inside, instanceType = IsInInstance()
    return not inside and instanceType == "none"
end

local window, scroll, content, empty
local selected
local selectedOffset
local deathTab = 1
local deathRows, attackerRows = {}, {}
local demo
local refresh, refreshActivity, refreshAssassins
local assassinPanel
local deathsByID = {}
local knownLevels = {}

local function plain(text)
    return text:gsub("|", "||")
end

local function playerName()
    local name, surname = UnitName("player")
    name = readable(name, "string") or "Personnage inconnu"
    surname = readable(surname, "string")
    return surname and surname ~= "" and name .. " " .. surname or name
end

local function zoneName()
    local zone = GetRealZoneText()
    if not zone or zone == "" then zone = GetZoneText() end
    if not zone or zone == "" then return "Zone inconnue" end
    local subzone = GetSubZoneText()
    if subzone and subzone ~= "" and subzone ~= zone then return zone .. " / " .. subzone end
    return zone
end

local function level(value)
    local number = tonumber(value)
    if number and number >= 1 and number <= 100 and number % 1 == 0 then return number end
end

local function rebuildPending()
    pending = {}
    tracked = {}
    for _, death in ipairs(db.deaths) do
        for index, attacker in ipairs(death.context ~= "bg" and death.attackers or {}) do
            tracked[attacker.guid] = attacker
            if db.alwaysRevenge or not attacker.avenged then
                local previous = pending[attacker.guid]
                if not previous or death.time >= previous.death.time then
                    pending[attacker.guid] = { attacker = attacker, death = death, fatal = index == 1 }
                end
            end
        end
    end
end

local function newer(event, other)
    return not other or event.time > other.time or (event.time == other.time and event.id > other.id)
end

local function updateStatus(death, attacker)
    local manual = db.manual[death.id]
    local state = manual and manual[attacker.guid]
    local kill = db.kills[attacker.guid]
    if kill and kill.time >= death.time and newer(kill, state) then state = kill end
    attacker.status = state
    attacker.avenged = state and state.checked or (not state and attacker.initialAvenged == true)
end

local function setPrivateStatus(death, attacker, checked)
    db.manualSerial = (db.manualSerial or 0) + 1
    local states = db.manual[death.id] or {}
    states[attacker.guid] = {
        id = ("local:%012d"):format(db.manualSerial),
        time = GetServerTime(),
        checked = checked,
    }
    db.manual[death.id] = states
    updateStatus(death, attacker)
end

local function logActivity(entry)
    db.activity[#db.activity + 1] = entry
    if refreshActivity then refreshActivity() end
end

local function validText(value, max)
    return type(value) == "string" and #value > 0 and #value <= max and not value:find("%c")
end

local function validGUID(value)
    return validText(value, 80) and value:match("^Player%-%d+%-%x+$")
end

local function applyEvent(fields, id, sender)
    local kind = fields[1]
    local stamp = tonumber(fields[2])
    if not stamp or stamp % 1 ~= 0 or stamp < 1 or stamp > GetServerTime() + 300 then return false end
    local entry = { kind = kind, time = stamp, id = id, sender = sender }
    if kind == "D" then
        if deathsByID[id] or not validText(fields[3], 120) or not validText(fields[6], 240)
            or #fields < 10 or (#fields - 6) % 4 ~= 0 or #fields > 206 then return false end
        local death = { id = id, time = stamp, character = fields[3], characterClass = fields[4],
            level = level(fields[5]), zone = fields[6], context = "world", sender = sender, attackers = {} }
        for index = 7, #fields, 4 do
            if not validGUID(fields[index]) or not validText(fields[index + 1], 120) then return false end
            local attacker = { guid = fields[index], name = fields[index + 1],
                class = fields[index + 2] ~= "" and fields[index + 2] or nil,
                initialAvenged = not sender and fields[index + 3] == "1" }
            updateStatus(death, attacker)
            death.attackers[#death.attackers + 1] = attacker
        end
        deathsByID[id] = death
        db.deaths[#db.deaths + 1] = death
        table.sort(db.deaths, function(a, b)
            return a.time < b.time or (a.time == b.time and (a.id or "") < (b.id or ""))
        end)
        entry.character, entry.zone, entry.level = death.character, death.zone, death.level
    elseif kind == "L" then
        local death = deathsByID[fields[3]]
        if not death or #fields < 5 or #fields > 103 or (#fields - 3) % 2 ~= 0
            or death.id:match("^(.-):") ~= id:match("^(.-):") then return false end
        local levels = {}
        for index = 4, #fields, 2 do
            local attackerLevel = level(fields[index + 1])
            if not validGUID(fields[index]) or not attackerLevel then return false end
            levels[fields[index]] = attackerLevel
        end
        for _, attacker in ipairs(death.attackers) do
            if levels[attacker.guid] then attacker.level = levels[attacker.guid] end
        end
        if window and window:IsShown() then refresh() end
        return true
    elseif kind == "K" then
        if not validGUID(fields[3]) or not validText(fields[4], 120) or not validText(fields[5], 120)
            or not validText(fields[8], 240) or #fields ~= 8 then return false end
        entry.targetGUID, entry.target, entry.character = fields[3], fields[4], fields[5]
        entry.level, entry.targetLevel, entry.zone = level(fields[6]), level(fields[7]), fields[8]
        entry.checked = true
        if newer(entry, db.kills[fields[3]]) then db.kills[fields[3]] = entry end
        for _, death in ipairs(db.deaths) do
            if death.id then
                for _, attacker in ipairs(death.attackers) do
                    if attacker.guid == fields[3] then updateStatus(death, attacker) end
                end
            end
        end
    else
        return false
    end
    logActivity(entry)
    rebuildPending()
    if window and window:IsShown() then refresh() end
    return true
end

local function publishDeath(death)
    local fields = { "D", tostring(death.time), death.character, death.characterClass or "",
        tostring(death.level or ""), death.zone }
    for _, attacker in ipairs(death.attackers) do
        fields[#fields + 1] = attacker.guid
        fields[#fields + 1] = attacker.name
        fields[#fields + 1] = attacker.class or ""
        fields[#fields + 1] = attacker.avenged and "1" or "0"
    end
    local id = sync:Publish(fields)
    if not id then return end
    local levels = { "L", tostring(death.time), id }
    for _, attacker in ipairs(death.attackers) do
        if attacker.level then
            levels[#levels + 1] = attacker.guid
            levels[#levels + 1] = tostring(attacker.level)
        end
    end
    if #levels > 3 then sync:Publish(levels) end
    return id
end

local function makePanel(name, titleText, parent, width, height)
    local panel = CreateFrame("Frame", name, parent, "BasicFrameTemplateWithInset")
    panel:SetSize(width, height)
    panel:SetPoint("CENTER")
    panel:EnableMouse(true)
    local title = panel.TitleText or panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if not panel.TitleText then title:SetPoint("TOP", 0, -5) end
    title:SetText(titleText)
    panel:Hide()
    return panel
end

local function makeScroll(panel, width)
    local frame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    frame:SetPoint("TOPLEFT", 15, -64)
    frame:SetPoint("BOTTOMRIGHT", -31, 15)
    local child = CreateFrame("Frame", nil, frame)
    child:SetSize(width, 1)
    frame:SetScrollChild(child)
    return frame, child
end

local function classForGUID(guid)
    local lookup = GetPlayerInfoByGUID or (C_PlayerInfo and C_PlayerInfo.GetPlayerInfoByGUID)
    if not guid or not lookup then return end
    local ok, _, class = pcall(lookup, guid)
    if ok then return readable(class, "string") end
end

local function setClassIcon(texture, class)
    local atlas = class and ("classicon-" .. class:lower())
    if atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        texture:SetAtlas(atlas)
        return
    end
    local coords = CLASS_ICON_TCOORDS and class and CLASS_ICON_TCOORDS[class]
    if coords then
        texture:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        texture:SetTexCoord(unpack(coords))
    else
        texture:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        texture:SetTexCoord(0, 1, 0, 1)
    end
end

local alert, alertPreview, alertTimer
local recentReports = {}

local function rememberSighting(guid, time, sighting)
    if not tracked[guid] then return end
    local previous = db.lastSightings[guid]
    if previous and previous.time > time then return end
    db.lastSightings[guid] = { zone = sighting.zone, level = sighting.level, observer = sighting.observer, time = time }
    if assassinPanel and assassinPanel:IsVisible() then refreshAssassins() end
end

local function makeAlert()
    local box = CreateFrame("Frame", "RevengeSightingAlert", UIParent, "BackdropTemplate")
    box:SetSize(465, 118)
    box:SetFrameStrata("TOOLTIP")
    box:SetClampedToScreen(true)
    box:SetMovable(true)
    box:RegisterForDrag("LeftButton")
    box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    box:SetBackdropColor(0.055, 0.047, 0.045, 0.97)
    box:SetBackdropBorderColor(0.66, 0.43, 0.26, 1)
    box.icon = box:CreateTexture(nil, "ARTWORK")
    box.icon:SetSize(34, 34)
    box.icon:SetPoint("TOPLEFT", 13, -14)
    box.title = box:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    box.title:SetPoint("TOPLEFT", 57, -13)
    box.title:SetWidth(365)
    box.title:SetJustifyH("LEFT")
    box.title:SetWordWrap(false)
    box.title:SetTextColor(1, 0.81, 0.51)
    box.location = box:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    box.location:SetPoint("TOPLEFT", box.title, "BOTTOMLEFT", 0, -5)
    box.location:SetWidth(389)
    box.location:SetJustifyH("LEFT")
    box.detail = box:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    box.detail:SetPoint("TOPLEFT", box.location, "BOTTOMLEFT", 0, -9)
    box.detail:SetWidth(389)
    box.detail:SetJustifyH("LEFT")
    box.detail:SetTextColor(0.75, 0.73, 0.70)
    box.help = box:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    box.help:SetPoint("TOPLEFT", box.detail, "BOTTOMLEFT", 0, -10)
    box.help:SetText("Démo · Fais glisser l’alerte, puis ferme-la pour terminer.")
    box.help:SetTextColor(1, 0.81, 0.51)
    box.close = CreateFrame("Button", nil, box, "UIPanelCloseButton")
    box.close:SetPoint("TOPRIGHT", -2, -2)
    box.close:SetScript("OnClick", function()
        if box.dragging then box:GetScript("OnDragStop")(box) end
        alertPreview = false
        box:Hide()
    end)
    box:SetScript("OnDragStart", function(self)
        if not alertPreview then return end
        self.dragging = true
        self:StartMoving()
    end)
    box:SetScript("OnDragStop", function(self)
        if not self.dragging then return end
        self.dragging = false
        self:StopMovingOrSizing()
        local x, y = self:GetCenter()
        if x and y then
            db.alertX, db.alertY = x / UIParent:GetWidth(), y / UIParent:GetHeight()
            self:ClearAllPoints()
            self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
        end
    end)
    if db.alertX and db.alertY then
        box:SetPoint("CENTER", UIParent, "BOTTOMLEFT", db.alertX * UIParent:GetWidth(), db.alertY * UIParent:GetHeight())
    else
        box:SetPoint("CENTER", UIParent, "CENTER", 0, 155)
    end
    box:Hide()
    return box
end

local function showSighting(sighting, preview)
    local title = ("%s · niv. %s"):format(sighting.name, sighting.level or "?")
    local current = ("%s · Vu par %s"):format(sighting.zone, sighting.observer)
    local relation = sighting.fatal and "a tué " or "a participé à la mort de "
    local detail = ("Revenge · %s %s%s (niv. %s) · %s"):format(
        sighting.name, relation, sighting.character, sighting.deathLevel or "?", sighting.deathZone)
    if not preview then
        DEFAULT_CHAT_FRAME:AddMessage(plain("Revenge · " .. title .. " · " .. current .. " · " .. detail), 1, 0.68, 0.45)
        PlaySound(SOUNDKIT.RAID_WARNING)
        if alertPreview then return end
    end
    alert = alert or makeAlert()
    if alertTimer then alertTimer:Cancel(); alertTimer = nil end
    alertPreview = preview
    setClassIcon(alert.icon, sighting.class)
    alert.title:SetText(plain(title))
    alert.location:SetText(plain(current))
    alert.detail:SetText(plain(detail))
    alert.close:SetShown(preview)
    alert.help:SetShown(preview)
    alert:EnableMouse(preview)
    alert:SetHeight(math.max(88, 37 + alert.title:GetStringHeight() + alert.location:GetStringHeight()
        + alert.detail:GetStringHeight() + (preview and 23 or 0)))
    alert:Show()
    if not preview then
        alertTimer = C_Timer.NewTimer(9, function()
            alertTimer = nil
            alert:Hide()
        end)
    end
end

local function toggleAlertPreview()
    if alertPreview then
        alert.close:Click()
        return
    end
    showSighting({ name = "Lamegrise", class = "ROGUE", level = 46, zone = "Tanaris / Gadgetzan",
        observer = "Aubeflamme", fatal = true, character = "Briselune", deathLevel = 41,
        deathZone = "Tanaris" }, true)
end

local function receiveSighting(fields, _, key)
    local time = tonumber(fields[1])
    if #fields ~= 11 or not time or math.abs(GetServerTime() - time) > 35
        or not validGUID(fields[2]) or not validText(fields[3], 120) or not validText(fields[6], 240)
        or not validText(fields[7], 120) or not validText(fields[8], 120) or not validText(fields[10], 240) then return end
    local now = GetTime()
    for report, when in pairs(recentReports) do
        if now - when >= 10 then recentReports[report] = nil end
    end
    local report = key .. ":" .. fields[2]
    if recentReports[report] then return end
    recentReports[report] = now
    local sighting = { name = fields[3], class = fields[4]:match("^[A-Z]+$"), level = level(fields[5]),
        zone = fields[6], observer = fields[7],
        character = fields[8], deathLevel = level(fields[9]), deathZone = fields[10], fatal = fields[11] == "1" }
    rememberSighting(fields[2], time, sighting)
    showSighting(sighting, false)
end

local function refreshAttackers(death, offset)
    local attackers = death and death.attackers or {}
    for index, attacker in ipairs(attackers) do
        local row = attackerRows[index]
        if not row then
            row = CreateFrame("Frame", nil, content)
            row:SetSize(426, 25)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(17, 17)
            row.icon:SetPoint("LEFT")
            row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
            row.label:SetWidth(390)
            row.label:SetJustifyH("LEFT")
            attackerRows[index] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 22, -offset - (index - 1) * 27)
        attacker.class = attacker.class or classForGUID(attacker.guid)
        setClassIcon(row.icon, attacker.class)
        local status = attacker.status
        local by = status and status.kind == "K" and (" · vengé par " .. status.character) or ""
        local role = index == 1 and "coup fatal" or "participation"
        row.label:SetText(plain(("%s · niv. %s · %s%s"):format(attacker.name, attacker.level or "?", role, by)))
        if attacker.avenged then
            row.label:SetTextColor(0.3, 1, 0.45)
        else
            row.label:SetTextColor(1, 0.3, 0.3)
        end
        row:Show()
    end
    for index = #attackers + 1, #attackerRows do
        attackerRows[index]:Hide()
    end
    return #attackers * 27
end

refresh = function()
    if assassinPanel and assassinPanel:IsVisible() then refreshAssassins() end
    local deaths = {}
    local function matchesTab(death)
        return deathTab == 3 or (death.sender ~= nil) == (deathTab == 2)
    end
    if db.showDemo then
        for _, death in ipairs(demo.deaths) do
            if matchesTab(death) then deaths[#deaths + 1] = death end
        end
    end
    for index = #db.deaths, 1, -1 do
        local death = db.deaths[index]
        if death.context ~= "bg" and matchesTab(death) then deaths[#deaths + 1] = death end
    end
    local count = #deaths
    local offset, expanded = 0, false
    selectedOffset = nil
    local emptyMessages = {
        "Aucune mort personnelle enregistrée.",
        "Aucune mort partagée par tes contacts.",
        "Aucune mort enregistrée.",
    }
    empty:SetText(emptyMessages[deathTab])
    empty:SetShown(count == 0)
    for index, death in ipairs(deaths) do
        local row = deathRows[index]
        if not row then
            row = CreateFrame("Button", nil, content)
            row:SetHeight(45)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(17, 17)
            row.icon:SetPoint("TOPLEFT", 8, -4)
            row.title = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            row.title:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
            row.marker = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            row.marker:SetPoint("RIGHT", -10, 0)
            row.info = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            row.info:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -5)
            row:SetScript("OnClick", function(self)
                if selected == self.death then
                    selected = nil
                else
                    selected = self.death
                end
                refresh()
            end)
            deathRows[index] = row
        end
        row.death = death
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -offset)
        row:SetPoint("TOPRIGHT", 0, -offset)
        row.marker:SetText(death == selected and "−" or "+")
        setClassIcon(row.icon, death.characterClass)
        local marker = death.isDemo and "[Démo] " or ""
        row.title:SetText(("%s%s · niveau %s"):format(marker, plain(death.character), death.level or "?"))
        local source = death.sender and (" · " .. death.sender) or ""
        row.info:SetText(("%s · %s"):format(date("%d/%m/%Y à %H:%M", death.time), plain(death.zone .. source)))
        row:Show()
        if death == selected then selectedOffset = offset end
        offset = offset + 47
        if death == selected then
            offset = offset + refreshAttackers(death, offset) + 5
            expanded = true
        end
    end
    for index = count + 1, #deathRows do
        deathRows[index]:Hide()
    end
    if not expanded then refreshAttackers() end
    content:SetHeight(math.max(1, offset))
    scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(), scroll:GetVerticalScrollRange()))
end

local function openDeath(death)
    selected = death
    deathTab = death.sender and 2 or 1
    PanelTemplates_SetTab(window, deathTab)
    refresh()
    scroll:SetVerticalScroll(math.min(selectedOffset or 0, scroll:GetVerticalScrollRange()))
end

local function actionButton(parent, text, width, callback)
    local control = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    control:SetSize(width, 23)
    control:SetText(text)
    control:SetScript("OnClick", callback)
    return control
end

local function makeAssassinPanel(parent)
    local width = 350
    local panel = makePanel("RevengeAssassins", "Assassins", parent, width, parent:GetHeight())
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", parent, "TOPRIGHT", 0, 0)
    local listScroll, list = makeScroll(panel, width - 46)
    local noEntries = list:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    noEntries:SetPoint("TOPLEFT", 7, -7)
    noEntries:SetText("Aucun adversaire pour ce filtre.")
    local rows, filters = {}, {}
    local scope, expanded = 3, nil

    for index, title in ipairs({ "Moi", "Contacts", "Tous" }) do
        local filter = actionButton(panel, title, 87, function()
            scope, expanded = index, nil
            for buttonIndex, button in ipairs(filters) do button:SetEnabled(buttonIndex ~= scope) end
            refreshAssassins()
            listScroll:SetVerticalScroll(0)
        end)
        filter:SetPoint("TOPLEFT", 16 + (index - 1) * 92, -33)
        filter:SetEnabled(index ~= scope)
        filters[index] = filter
    end

    refreshAssassins = function()
        local byKey, groups = {}, {}
        local function collect(deaths)
            for _, death in ipairs(deaths) do
                if death.context ~= "bg" and (scope == 3 or (death.sender ~= nil) == (scope == 2)) then
                    for index, attacker in ipairs(death.attackers) do
                        local key = attacker.guid or ("demo:" .. attacker.name)
                        local group = byKey[key]
                        if not group then
                            group = { key = key, name = attacker.name, class = attacker.class, demo = death.isDemo,
                                fatal = 0, own = 0, shared = 0, assists = 0, waiting = 0, deaths = {} }
                            byKey[key] = group
                            groups[#groups + 1] = group
                        end
                        group.class = group.class or attacker.class
                        group.deaths[#group.deaths + 1] = { death = death, attacker = attacker, fatal = index == 1 }
                        if index == 1 then
                            group.fatal = group.fatal + 1
                            if death.sender then group.shared = group.shared + 1 else group.own = group.own + 1 end
                        else
                            group.assists = group.assists + 1
                        end
                        if not attacker.avenged then group.waiting = group.waiting + 1 end
                    end
                end
            end
        end
        collect(db.deaths)
        if db.showDemo then collect(demo.deaths) end
        table.sort(groups, function(a, b)
            if a.fatal ~= b.fatal then return a.fatal > b.fatal end
            if a.name ~= b.name then return a.name < b.name end
            return a.key < b.key
        end)
        noEntries:SetShown(#groups == 0)

        local used, offset = 0, 0
        local function addRow(title, subtitle, observation, group, death)
            used = used + 1
            local row = rows[used]
            if not row then
                row = CreateFrame("Button", nil, list)
                row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                row.icon = row:CreateTexture(nil, "ARTWORK")
                row.icon:SetSize(18, 18)
                row.icon:SetPoint("TOPLEFT", 30, -6)
                row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
                row.check:SetSize(22, 22)
                row.check:SetPoint("TOPLEFT", 4, -4)
                row.check.mixed = row.check:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                row.check.mixed:SetPoint("CENTER")
                row.check.mixed:SetText("−")
                row.check:SetScript("OnClick", function(self)
                    local current = row.group
                    if not current then return end
                    local checked = self:GetChecked() and true or false
                    for _, occurrence in ipairs(current.deaths) do
                        if occurrence.death.id and not occurrence.death.isDemo then
                            setPrivateStatus(occurrence.death, occurrence.attacker, checked)
                        else
                            occurrence.attacker.avenged = checked
                        end
                    end
                    if not current.demo then
                        if not db.alwaysRevenge then lastSeen[current.key] = nil end
                        rebuildPending()
                    end
                    refresh()
                end)
                row.title = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
                row.subtitle = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
                row.subtitle:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -4)
                row.observation = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
                row.observation:SetPoint("TOPLEFT", row.subtitle, "BOTTOMLEFT", 0, -4)
                row.observation:SetTextColor(0.70, 0.76, 0.82)
                row.marker = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                row.marker:SetPoint("RIGHT", -9, 0)
                for _, label in ipairs({ row.title, row.subtitle, row.observation }) do
                    label:SetJustifyH("LEFT")
                end
                row:SetScript("OnClick", function(self)
                    if self.death then
                        openDeath(self.death)
                    else
                        if expanded == self.group.key then expanded = nil else expanded = self.group.key end
                        refreshAssassins()
                    end
                end)
                rows[used] = row
            end
            row.death, row.group = death, group
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", death and 17 or 0, -offset)
            row:SetPoint("TOPRIGHT", 0, -offset)
            row.icon:SetShown(group ~= nil)
            row.check:SetShown(group ~= nil)
            if group then
                setClassIcon(row.icon, group.class)
                row.check:SetChecked(group.waiting == 0)
                row.check.mixed:SetShown(group.waiting > 0 and group.waiting < #group.deaths)
            end
            local textLeft = group and 55 or 33
            row.title:ClearAllPoints()
            row.title:SetPoint("TOPLEFT", textLeft, -7)
            for _, label in ipairs({ row.title, row.subtitle, row.observation }) do
                label:SetWidth(list:GetWidth() - textLeft - (death and 44 or 27))
            end
            row.title:SetText(plain(title))
            row.subtitle:SetText(plain(subtitle))
            row.observation:SetText(observation and plain(observation) or "")
            local height = 18 + row.title:GetStringHeight() + row.subtitle:GetStringHeight()
            if observation then height = height + 4 + row.observation:GetStringHeight() end
            row:SetHeight(height)
            row.marker:SetText(death and "›" or (expanded == group.key and "−" or "+"))
            row:Show()
            offset = offset + height + 3
        end

        for _, group in ipairs(groups) do
            local name = (group.demo and "[Démo] " or "") .. group.name
            local counts = ("%d coups fatals · %d participations · %d en attente"):format(
                group.fatal, group.assists, group.waiting)
            if scope == 3 then
                counts = ("%d coups fatals (%d moi, %d contacts) · %d participations · %d en attente"):format(
                    group.fatal, group.own, group.shared, group.assists, group.waiting)
            end
            local sighting = group.demo and demo.sightings[group.name] or db.lastSightings[group.key]
            local observation = sighting and ("Vu à %s · niv. %s · par %s"):format(
                sighting.zone, sighting.level or "?", sighting.observer) or nil
            addRow(name, counts, observation, group, nil)
            if expanded == group.key then
                table.sort(group.deaths, function(a, b) return a.death.time > b.death.time end)
                for _, occurrence in ipairs(group.deaths) do
                    local death, attacker = occurrence.death, occurrence.attacker
                    local detail = ("%s · %s · %s"):format(date("%d/%m à %H:%M", death.time), death.zone,
                        attacker.avenged and "Vengé" or "À venger")
                    local title = ("%s · %s · niv. %s"):format(death.character,
                        occurrence.fatal and "Coup fatal" or "Participation", attacker.level or "?")
                    addRow(title, detail, nil, nil, death)
                end
            end
        end
        for index = used + 1, #rows do rows[index]:Hide() end
        list:SetHeight(math.max(26, offset))
        listScroll:SetVerticalScroll(math.min(listScroll:GetVerticalScroll(), listScroll:GetVerticalScrollRange()))
    end
    return panel
end

local function relatedDeath(entry, example)
    local records = example and demo.deaths or db.deaths
    local match
    for _, death in ipairs(records) do
        if death.context ~= "bg" and death.time <= entry.time and (not match or death.time > match.time) then
            for _, attacker in ipairs(death.attackers) do
                if (entry.targetGUID and entry.targetGUID == attacker.guid)
                    or (not entry.targetGUID and attacker.name == entry.target) then
                    match = death
                    break
                end
            end
        end
    end
    return match
end

local function visitContactCandidates(add)
    if C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetFriendInfoByIndex then
        for index = 1, readable(C_FriendList.GetNumFriends(), "number") or 0 do
            local friend = readable(C_FriendList.GetFriendInfoByIndex(index), "table")
            if friend then
                local localized = readable(friend.className, "string")
                local token
                if localized then
                    for class, name in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do
                        if name == localized or (LOCALIZED_CLASS_NAMES_FEMALE or {})[class] == localized then
                            token = class
                            break
                        end
                    end
                end
                add(friend.name, token)
            end
        end
    end
    if IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo then
        for index = 1, readable(GetNumGuildMembers(), "number") or 0 do
            local name, _, _, _, _, _, _, _, _, _, class = GetGuildRosterInfo(index)
            add(name, class)
        end
    end
    local function addUnit(unit)
        local _, class = UnitClass(unit)
        add(GetUnitName(unit, true), class)
    end
    if IsInRaid() then
        for index = 1, GetNumGroupMembers() do addUnit("raid" .. index) end
    else
        for index = 1, GetNumSubgroupMembers() do addUnit("party" .. index) end
    end
    addUnit("target")
end

local function addContactSuggestions(parent, input)
    local dropdown = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    dropdown:SetPoint("TOPLEFT", input, "BOTTOMLEFT", -5, -3)
    dropdown:SetWidth(230)
    dropdown:SetFrameLevel(parent:GetFrameLevel() + 20)
    dropdown:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    dropdown:SetBackdropColor(0.07, 0.07, 0.09, 0.98)
    dropdown:EnableMouse(true)
    dropdown:Hide()
    local rows = {}
    local function choose(name)
        input:SetText(name)
        input:SetCursorPosition(#name)
        dropdown:Hide()
    end
    for index = 1, 6 do
        local row = CreateFrame("Button", nil, dropdown)
        row:SetPoint("TOPLEFT", 4, -4 - (index - 1) * 22)
        row:SetPoint("TOPRIGHT", -4, -4 - (index - 1) * 22)
        row:SetHeight(22)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.label:SetPoint("LEFT", 6, 0)
        row.label:SetPoint("RIGHT", -6, 0)
        row.label:SetJustifyH("LEFT")
        row.label:SetWordWrap(false)
        row:SetScript("OnClick", function(self) choose(self.name) end)
        rows[index] = row
    end

    local function update()
        local query = input:GetText():match("^%s*(.-)%s*$"):lower()
        if query == "" or not input:HasFocus() then dropdown:Hide(); return end
        local matches, seen = {}, {}
        local ownName = readable(GetUnitName("player", true), "string")
        local function add(value)
            local name = readable(value, "string")
            if not name or name == ownName or #name > 100 then return end
            local key = name:lower()
            if seen[key] or key:sub(1, #query) ~= query then return end
            seen[key] = true
            matches[#matches + 1] = name
        end
        for _, name in pairs(db.contacts) do add(name) end
        visitContactCandidates(add)
        table.sort(matches, function(a, b) return a:lower() < b:lower() end)
        for index, row in ipairs(rows) do
            row.name = matches[index]
            row:SetShown(row.name ~= nil)
            if row.name then row.label:SetText(plain(row.name)) end
        end
        dropdown:SetHeight(8 + math.min(#rows, #matches) * 22)
        dropdown:SetShown(#matches > 0)
    end

    input:HookScript("OnTextChanged", function(_, userInput)
        if userInput then update() else dropdown:Hide() end
    end)
    input:HookScript("OnEditFocusGained", update)
    input:SetScript("OnTabPressed", function()
        if dropdown:IsShown() and rows[1].name then choose(rows[1].name) end
    end)
    input:SetScript("OnEscapePressed", function(self)
        dropdown:Hide()
        self:ClearFocus()
    end)
    parent:HookScript("OnHide", function()
        dropdown:Hide()
        input:ClearFocus()
    end)
end

local function makeManagementPanels(parent)
    local contacts = makePanel("RevengeContacts", "Contacts autorisés", parent, 480, 330)
    local activity = makePanel("RevengeActivity", "Historique des échanges et des vengeances", parent, 635, 345)
    for _, panel in ipairs({ contacts, activity }) do
        panel:SetFrameStrata("FULLSCREEN_DIALOG")
        table.insert(UISpecialFrames, panel:GetName())
    end
    parent:HookScript("OnHide", function() contacts:Hide(); activity:Hide() end)
    local input = CreateFrame("EditBox", nil, contacts, "InputBoxTemplate")
    input:SetAutoFocus(false)
    input:SetMaxLetters(100)
    input:SetSize(183, 23)
    input:SetPoint("TOPLEFT", 19, -33)
    addContactSuggestions(contacts, input)
    local contactScroll, contactList = makeScroll(contacts, 434)
    local hint = contactList:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 3, -3)
    hint:SetWidth(425)
    hint:SetJustifyH("LEFT")
    local contactRows = {}
    local function updateSyncStatus(row)
        local waiting, last = sync:ContactStatus(row.contact.key)
        if waiting then
            row.syncStatus:SetText("En attente")
            row.syncStatus:SetTextColor(1, 0.76, 0.38)
        elseif last then
            row.syncStatus:SetText("Dernier échange à " .. date("%H h %M", last))
            row.syncStatus:SetTextColor(0.54, 0.85, 0.64)
        else
            row.syncStatus:SetText("Aucun échange reçu")
            row.syncStatus:SetTextColor(0.72, 0.72, 0.72)
        end
    end
    sync.statusChanged = function(key)
        if not contacts:IsVisible() then return end
        for _, row in ipairs(contactRows) do
            if row:IsShown() and row.contact.key == key then updateSyncStatus(row); return end
        end
    end
    local function refreshContacts()
        db.contactClasses = db.contactClasses or {}
        visitContactCandidates(function(value, token)
            local name, class = readable(value, "string"), readable(token, "string")
            local key = name and sync:ContactKey(name)
            if key and class and db.contacts[key] then db.contactClasses[key] = class end
        end)
        local names = {}
        for key, name in pairs(db.contacts) do names[#names + 1] = { key = key, name = name } end
        table.sort(names, function(a, b) return a.key < b.key end)
        local status = sync.enabled and "" or "\nCanal addon indisponible sur ce client.\n"
        hint:SetText("Saisis le nom du personnage (Nom-Royaume si nécessaire).\n"
            .. "Seuls les contacts qui t’ajoutent aussi peuvent échanger.\n" .. status .. "\n"
            .. (#names == 0 and "Aucun contact autorisé." or ""))
        local start = hint:GetStringHeight() + 8
        for index, contact in ipairs(names) do
            local row = contactRows[index]
            if not row then
                row = CreateFrame("Frame", nil, contactList)
                row:SetSize(430, 26)
                row.icon = row:CreateTexture(nil, "ARTWORK")
                row.icon:SetSize(17, 17)
                row.icon:SetPoint("LEFT", 4, 0)
                row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
                row.label:SetJustifyH("LEFT")
                row.label:SetWordWrap(false)
                row.syncStatus = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
                row.syncStatus:SetPoint("RIGHT", -5, 0)
                local remove = actionButton(row, "Supprimer", 85, function()
                    if sync:Contact(row.contact.name, false) then
                        db.contactClasses[row.contact.key] = nil
                        refreshContacts()
                    end
                end)
                remove:SetPoint("LEFT", row.label, "RIGHT", 10, 0)
                contactRows[index] = row
            end
            row.contact = contact
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -start - (index - 1) * 28)
            row.label:SetText(plain(contact.name))
            row.label:SetWidth(math.min(148, math.max(1, row.label:GetStringWidth())))
            setClassIcon(row.icon, db.contactClasses[contact.key])
            updateSyncStatus(row)
            row:Show()
        end
        for index = #names + 1, #contactRows do contactRows[index]:Hide() end
        contactList:SetHeight(math.max(1, start + #names * 28))
        contactScroll:SetVerticalScroll(math.min(contactScroll:GetVerticalScroll(), contactScroll:GetVerticalScrollRange()))
    end
    local function addContact()
        if sync:Contact(input:GetText(), true) then
            input:SetText("")
            input:ClearFocus()
            refreshContacts()
        else
            DEFAULT_CHAT_FRAME:AddMessage("Revenge : saisis le nom d’un autre personnage.")
        end
    end
    actionButton(contacts, "Ajouter", 75, addContact):SetPoint("LEFT", input, "RIGHT", 9, 0)
    actionButton(contacts, "Synchroniser", 108, function() sync:Announce() end):SetPoint("LEFT", input, "RIGHT", 89, 0)
    local activityScroll, activityList = makeScroll(activity, activity:GetWidth() - 46)
    activityScroll:SetPoint("TOPLEFT", 15, -90)
    local activityEmpty = activityList:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    activityEmpty:SetPoint("TOPLEFT", 4, -6)
    activityEmpty:SetText("Aucune activité pour ces filtres.")
    local activityRows, filters = {}, { D = true, K = true, S = true }
    local page, pageSize = 1, 20
    local function resetActivityScroll()
        refreshActivity()
        activityScroll:SetVerticalScroll(0)
    end
    local pageLabel = activity:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    pageLabel:SetPoint("TOP", 0, -39)
    local newerPage = actionButton(activity, "Plus récent", 95, function()
        page = page - 1
        resetActivityScroll()
    end)
    newerPage:SetPoint("TOPLEFT", 15, -32)
    local olderPage = actionButton(activity, "Plus ancien", 95, function()
        page = page + 1
        resetActivityScroll()
    end)
    olderPage:SetPoint("TOPRIGHT", -15, -32)
    local categories = { { "D", "Morts" }, { "K", "Vengeances" }, { "S", "Synchronisations" } }
    for index, category in ipairs(categories) do
        local kind, title = category[1], category[2]
        local box = CreateFrame("CheckButton", nil, activity, "UICheckButtonTemplate")
        box:SetSize(22, 22)
        box:SetPoint("TOPLEFT", 18 + (index - 1) * 127, -60)
        box:SetChecked(filters[kind])
        local label = box:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", box, "RIGHT", 3, 0)
        label:SetText(title)
        box:SetScript("OnClick", function(self)
            filters[kind] = self:GetChecked()
            page = 1
            resetActivityScroll()
        end)
    end
    refreshActivity = function()
        if not activity:IsVisible() then return end
        local entries = {}
        for _, entry in ipairs(db.activity) do
            if filters[entry.kind] then entries[#entries + 1] = { entry = entry } end
        end
        if db.showDemo then
            for _, entry in ipairs(demo.activity) do
                if filters[entry.kind] then entries[#entries + 1] = { entry = entry, example = true } end
            end
        end
        local count = #entries
        local pages = math.max(1, math.ceil(count / pageSize))
        page = math.max(1, math.min(page, pages))
        pageLabel:SetText(("%d / %d"):format(page, pages))
        newerPage:SetEnabled(page > 1)
        olderPage:SetEnabled(page < pages)
        activityEmpty:SetShown(count == 0)
        local first = count - (page - 1) * pageSize
        local visible, offset = 0, 0
        for index = first, math.max(1, first - pageSize + 1), -1 do
            local item = entries[index]
            local entry = item.entry
            local summary, color
            if entry.kind == "K" then
                color = "|cff81e99a"
                summary = ("%s (niv. %s) a vengé %s (niv. %s) · %s"):format(
                    entry.character, entry.level or "?", entry.target, entry.targetLevel or "?", entry.zone)
            elseif entry.kind == "D" then
                color = "|cffff9390"
                summary = ("Mort de %s (niv. %s) · %s"):format(entry.character, entry.level or "?", entry.zone)
            else
                color = "|cff91caff"
                summary = "Synchronisation · " .. tostring(entry.count) .. " mises à jour reçues"
            end
            local via = entry.sender and (" |cffd2bea0· " .. plain(entry.sender) .. "|r") or ""
            local marker = item.example and "|cffd7ad68[Démo]|r " or ""
            visible = visible + 1
            local row = activityRows[visible]
            if not row then
                row = CreateFrame("Button", nil, activityList)
                row:SetWidth(activityList:GetWidth())
                row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                row.label:SetPoint("TOPLEFT", 5, -4)
                row.label:SetWidth(activityList:GetWidth() - 36)
                row.label:SetJustifyH("LEFT")
                row.arrow = row:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
                row.arrow:SetPoint("RIGHT", -7, 0)
                row.arrow:SetText("›")
                row:SetScript("OnClick", function(self)
                    if not self.death then return end
                    activity:Hide()
                    openDeath(self.death)
                end)
                activityRows[visible] = row
            end
            row.death = entry.kind == "K" and relatedDeath(entry, item.example) or nil
            row:EnableMouse(row.death ~= nil)
            row.arrow:SetShown(row.death ~= nil)
            row.label:SetText(marker .. "|cffb3b3b3" .. date("%d/%m/%Y à %H:%M", entry.time)
                .. " · |r" .. color .. plain(summary) .. "|r" .. via)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -offset)
            local height = math.max(24, row.label:GetStringHeight() + 10)
            row:SetHeight(height)
            row:Show()
            offset = offset + height + 4
        end
        for index = visible + 1, #activityRows do activityRows[index]:Hide() end
        activityList:SetHeight(math.max(25, offset))
        activityScroll:SetVerticalScroll(math.min(activityScroll:GetVerticalScroll(), activityScroll:GetVerticalScrollRange()))
    end
    contacts:SetScript("OnShow", function()
        if IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
        refreshContacts()
    end)
    local rosterEvents = CreateFrame("Frame", nil, contacts)
    rosterEvents:RegisterEvent("FRIENDLIST_UPDATE")
    rosterEvents:RegisterEvent("GUILD_ROSTER_UPDATE")
    rosterEvents:RegisterEvent("GROUP_ROSTER_UPDATE")
    rosterEvents:RegisterEvent("PLAYER_TARGET_CHANGED")
    rosterEvents:SetScript("OnEvent", function()
        if contacts:IsVisible() then refreshContacts() end
    end)
    activity:SetScript("OnShow", function()
        page = 1
        resetActivityScroll()
    end)
    actionButton(parent, "Activité", 88, function() contacts:Hide(); activity:SetShown(not activity:IsShown()) end)
        :SetPoint("TOPRIGHT", -16, -33)
    actionButton(parent, "Contacts", 88, function() activity:Hide(); contacts:SetShown(not contacts:IsShown()) end)
        :SetPoint("TOPRIGHT", -112, -33)
    actionButton(parent, "Alertes", 75, toggleAlertPreview):SetPoint("TOPRIGHT", -208, -33)
end

local function fitAssassinPanel()
    if not assassinPanel or not assassinPanel:IsVisible() then return end
    local right, screenRight = assassinPanel:GetRight(), UIParent:GetRight()
    if not right or not screenRight or right <= screenRight then return end
    local x, y = window:GetCenter()
    local left, bottom = UIParent:GetLeft(), UIParent:GetBottom()
    if not x or not y or not left or not bottom then return end
    local shiftedX = math.max(window:GetWidth() / 2, x - left - (right - screenRight))
    window:ClearAllPoints()
    window:SetPoint("CENTER", UIParent, "BOTTOMLEFT", shiftedX, y - bottom)
end

local function toggleWindow()
    if not window then
        window = makePanel("RevengeWindow", "Revenge — Morts en PvP sauvage", UIParent, 520, 385)
        window:SetFrameStrata("DIALOG")
        window:SetMovable(true)
        window:SetClampedToScreen(true)
        window:RegisterForDrag("LeftButton")
        window:SetScript("OnDragStart", window.StartMoving)
        window:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            fitAssassinPanel()
        end)
        table.insert(UISpecialFrames, "RevengeWindow")
        local always = CreateFrame("CheckButton", nil, window, "UICheckButtonTemplate")
        always:SetPoint("TOPLEFT", 17, -32)
        always:SetSize(24, 24)
        local label = always:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", always, "RIGHT", 6, 0)
        label:SetText("Toujours me venger")
        always:SetChecked(db.alwaysRevenge == true)
        always:SetScript("OnClick", function(self)
            db.alwaysRevenge = self:GetChecked() and true or false
            rebuildPending()
            lastSeen = {}
        end)
        local divider = window:CreateTexture(nil, "ARTWORK")
        divider:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -61)
        divider:SetPoint("TOPRIGHT", window, "TOPRIGHT", -16, -61)
        divider:SetHeight(1)
        divider:SetColorTexture(0.77, 0.66, 0.46, 0.42)
        scroll, content = makeScroll(window, 474)
        scroll:SetPoint("TOPLEFT", 15, -70)
        local tabs = { "Mes morts", "Morts des contacts", "Toutes les morts" }
        local previous
        for index, title in ipairs(tabs) do
            local tab = CreateFrame("Button", "RevengeWindowTab" .. index, window, "PanelTabButtonTemplate")
            tab:SetID(index)
            tab:SetText(title)
            PanelTemplates_TabResize(tab, 12)
            if previous then
                tab:SetPoint("LEFT", previous, "RIGHT", 0, 0)
            else
                tab:SetPoint("TOPLEFT", window, "BOTTOMLEFT", 16, 0)
            end
            tab:SetScript("OnClick", function(self)
                local id = self:GetID()
                deathTab = id
                selected = nil
                PanelTemplates_SetTab(window, id)
                refresh()
                scroll:SetVerticalScroll(0)
            end)
            previous = tab
        end
        PanelTemplates_SetNumTabs(window, #tabs)
        PanelTemplates_SetTab(window, 1)
        empty = window:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        empty:SetPoint("TOPLEFT", 22, -76)
        assassinPanel = makeAssassinPanel(window)
        local assassinsToggle = actionButton(window, "Assassins ›", 99, function()
            assassinPanel:SetShown(not assassinPanel:IsShown())
        end)
        assassinsToggle:SetPoint("TOPRIGHT", window, "BOTTOMRIGHT", -7, -2)
        assassinPanel:HookScript("OnShow", function()
            assassinsToggle:SetText("Assassins ‹")
            fitAssassinPanel()
            refreshAssassins()
        end)
        assassinPanel:HookScript("OnHide", function()
            assassinsToggle:SetText("Assassins ›")
        end)
        window:SetScript("OnShow", refresh)
        window:HookScript("OnHide", function() assassinPanel:Hide() end)
        makeManagementPanels(window)
    end
    window:SetShown(not window:IsShown())
end

local button = CreateFrame("Button", "RevengeMinimapButton", MinimapCluster or Minimap)
button:SetSize(31, 31)
button:SetFrameStrata("HIGH")
button:SetFrameLevel(20)
local background = button:CreateTexture(nil, "BACKGROUND")
background:SetSize(24, 24)
background:SetPoint("CENTER")
background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
local art = button:CreateTexture(nil, "ARTWORK")
art:SetSize(21, 21)
art:SetPoint("CENTER")
art:SetTexture(icon)
art:SetTexCoord(0.08, 0.92, 0.08, 0.92)
local rim = button:CreateTexture(nil, "OVERLAY")
rim:SetSize(53, 53)
rim:SetPoint("TOPLEFT")
rim:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
button:RegisterForDrag("LeftButton")
button:Hide()

local function positionButton()
    local angle = db.angle
    local x = math.cos(angle) * (Minimap:GetWidth() / 2 + 3)
    local y = math.sin(angle) * (Minimap:GetHeight() / 2 + 3)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

button:SetScript("OnDragStart", function(self)
    GameTooltip:Hide()
    self:SetScript("OnUpdate", function()
        local x, y = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        local centerX, centerY = Minimap:GetCenter()
        if centerX and centerY then
            db.angle = math.atan2(y / scale - centerY, x / scale - centerX)
            positionButton()
        end
    end)
end)
button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
button:SetScript("OnClick", toggleWindow)
button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Revenge")
    GameTooltip:AddLine("Cliquer pour ouvrir l'historique. Glisser pour déplacer.", 1, 1, 1, true)
    GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)
Minimap:HookScript("OnSizeChanged", function() if db then positionButton() end end)

local function inspect(unit)
    if not inWorld() or UnitIsDeadOrGhost("player") then return end
    local guid = readable(UnitGUID(unit), "string")
    local observed
    if guid and tracked[guid] then
        observed = level(readable(UnitLevel(unit), "number"))
        if observed then knownLevels[guid] = { value = observed, seen = GetTime() } end
    end
    local encounter = guid and pending[guid]
    if not encounter then return end
    local now = GetTime()
    local previous = lastSeen[guid]
    lastSeen[guid] = now
    if previous and now - previous < 10 then return end
    local attacker, death = encounter.attacker, encounter.death
    local _, classToken = UnitClass(unit)
    attacker.class = readable(classToken, "string") or attacker.class
    local sighting = { name = readable(GetUnitName(unit, true), "string") or attacker.name,
        class = attacker.class, level = observed, zone = zoneName(),
        observer = playerName(), character = death.character, deathLevel = death.level,
        deathZone = death.zone, fatal = encounter.fatal }
    local nowServer = GetServerTime()
    rememberSighting(guid, nowServer, sighting)
    showSighting(sighting, false)
    sync:BroadcastSighting({ tostring(nowServer), guid, sighting.name, sighting.class or "",
        tostring(sighting.level or ""), sighting.zone, sighting.observer, sighting.character,
        tostring(sighting.deathLevel or ""), sighting.deathZone, sighting.fatal and "1" or "0" })
end

local function scan()
    if not next(tracked) or not inWorld() or UnitIsDeadOrGhost("player") then return end
    inspect("target")
    inspect("mouseover")
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        if plate.namePlateUnitToken then inspect(plate.namePlateUnitToken) end
    end
end

local function readAttackers(deathTime)
    if not C_DeathRecap or not C_DeathRecap.GetRecapEvents then return end
    local ok, recap = pcall(C_DeathRecap.GetRecapEvents)
    if not ok then return end
    recap = readable(recap, "table")
    if not recap then return end
    local attackers, seen = {}, {}
    local killer
    for _, entry in ipairs(recap) do
        entry = readable(entry, "table")
        if entry then
            local stamp = readable(entry.timestamp, "number")
            if stamp and stamp >= deathTime - 30 and stamp <= deathTime + 5 then
                local guid = readable(entry.sourceGUID, "string")
                local flags = readable(entry.sourceFlags, "number")
                local name = readable(entry.sourceName, "string")
                if guid and guid:match("^Player%-") and flags and bit.band(flags, 0x40) ~= 0 and name and name ~= "" then
                    if not seen[guid] then
                        local attacker = { guid = guid, name = name, class = classForGUID(guid), avenged = false }
                        attackers[#attackers + 1] = attacker
                        seen[guid] = #attackers
                    end
                    local overkill = readable(entry.overkill, "number")
                    if overkill and overkill >= 0 and math.abs(stamp - deathTime) <= 5 then
                        killer = killer or guid
                    end
                end
            end
        end
    end
    if killer then
        local index = seen[killer]
        attackers[1], attackers[index] = attackers[index], attackers[1]
        return attackers
    end
end

local function recordKill(attackerGUID, victimGUID)
    if not inWorld() then return end
    local attacker = readable(attackerGUID, "string")
    local player = readable(UnitGUID("player"), "string")
    local victim = readable(victimGUID, "string")
    if not attacker or attacker ~= player or not victim then return end
    local target = tracked[victim]
    if not target then return end
    local targetLevel
    for _, unit in ipairs({ "target", "mouseover", "focus" }) do
        if readable(UnitGUID(unit), "string") == victim then
            targetLevel = level(readable(UnitLevel(unit), "number"))
            if targetLevel then break end
        end
    end
    local cached = knownLevels[victim]
    if not targetLevel and cached and GetTime() - cached.seen <= 30 then targetLevel = cached.value end
    sync:Publish({ "K", tostring(GetServerTime()), victim, target.name, playerName(),
        tostring(readable(UnitLevel("player"), "number") or ""), tostring(targetLevel or ""), zoneName() })
end

local function recordDeath()
    deathSerial = deathSerial + 1
    if not inWorld() then return end
    local serial = deathSerial
    local _, characterClass = UnitClass("player")
    local death = {
        context = "world",
        time = GetServerTime(),
        character = playerName(),
        characterClass = readable(characterClass, "string"),
        level = readable(UnitLevel("player"), "number"),
        zone = zoneName(),
    }
    local visible = {}
    local function snapshotUnit(unit)
        local guid = readable(UnitGUID(unit), "string")
        if not guid or not guid:match("^Player%-") or visible[guid] then return end
        local observed = level(readable(UnitLevel(unit), "number"))
        local _, class = UnitClass(unit)
        if observed or readable(class, "string") then
            visible[guid] = { level = observed, class = readable(class, "string") }
        end
    end
    for _, unit in ipairs({ "target", "mouseover", "focus" }) do snapshotUnit(unit) end
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        if plate.namePlateUnitToken then snapshotUnit(plate.namePlateUnitToken) end
    end
    local delays = { 0.3, 0.7, 1 }
    local attempt = 1
    local function read()
        if serial ~= deathSerial then return end
        local attackers = readAttackers(death.time)
        if attackers then
            for _, attacker in ipairs(attackers) do
                local observation = visible[attacker.guid]
                if observation then
                    attacker.class = observation.class or attacker.class
                    attacker.level = observation.level
                end
                local previous = knownLevels[attacker.guid]
                if not attacker.level and previous and GetTime() - previous.seen <= 15 then
                    attacker.level = previous.value
                end
            end
            death.attackers = attackers
            publishDeath(death)
        elseif attempt < #delays then
            attempt = attempt + 1
            C_Timer.After(delays[attempt], read)
        end
    end
    C_Timer.After(delays[attempt], read)
end

local function importLegacyDeaths()
    if not sync:Stream() then return end
    local legacy = {}
    for index = #db.deaths, 1, -1 do
        local death = db.deaths[index]
        if not death.id and death.context ~= "bg" then
            legacy[#legacy + 1] = death
            table.remove(db.deaths, index)
        end
    end
    for index = #legacy, 1, -1 do
        local death = legacy[index]
        if not publishDeath(death) then db.deaths[#db.deaths + 1] = death end
    end
    rebuildPending()
end

local incomingActivity = {}
local function noteSync(sender)
    local report = incomingActivity[sender]
    if report then
        report.count = report.count + 1
        return
    end
    report = { kind = "S", time = GetServerTime(), sender = sender, count = 1 }
    incomingActivity[sender] = report
    C_Timer.After(4, function()
        incomingActivity[sender] = nil
        logActivity(report)
    end)
end

events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg, other)
    if event == "ADDON_LOADED" and arg == addonName then
        RevengeJournalDB = RevengeJournalDB or { deaths = {}, angle = RevengeDB and RevengeDB.angle or 3.85 }
        db = RevengeJournalDB
        db.activity = db.activity or {}
        db.manual = db.manual or {}
        db.kills = db.kills or {}
        db.lastSightings = db.lastSightings or {}
        for _, states in pairs(db.manual) do
            for guid, state in pairs(states) do
                if state.sender then states[guid] = nil end
            end
        end
        for _, death in ipairs(db.deaths) do
            if death.id then
                deathsByID[death.id] = death
                for _, attacker in ipairs(death.attackers) do
                    if death.sender then attacker.initialAvenged = false end
                    updateStatus(death, attacker)
                end
            end
        end
        sync:Start(db, applyEvent, noteSync, function(contact, count)
            logActivity({ kind = "T", time = GetServerTime(), sender = contact, count = count })
        end, receiveSighting)
        if db.showDemo == nil then db.showDemo = true end
        local now = GetServerTime()
        local _, class = UnitClass("player")
        local function example(character, characterClass, characterLevel, ago, zone, sender, attackers)
            return { isDemo = true, character = character, characterClass = characterClass, level = characterLevel,
                time = now - ago, zone = zone, sender = sender, attackers = attackers }
        end
        demo = {
            deaths = {
                example(playerName(), readable(class, "string"), level(readable(UnitLevel("player"), "number")),
                    1200, "Vallée de Strangleronce", nil, {
                        { name = "Roncebrume", class = "DRUID", level = 46, avenged = false },
                        { name = "Lamegrise", class = "ROGUE", level = 44, avenged = true },
                    }),
                example("Écuclair", "WARRIOR", 32, 3600, "Hautes-terres d’Arathi", nil, {
                    { name = "Roncebrume", class = "DRUID", level = 45, avenged = false },
                }),
                example("Plumedor", "HUNTER", 24, 86400, "Les Paluns", nil, {
                    { name = "Éclatnoir", class = "WARLOCK", level = 27, avenged = false },
                }),
                example("Briselune", "DRUID", 35, 1800, "Désolace", "Briselune", {
                    { name = "Roncebrume", class = "DRUID", level = 46, avenged = false },
                    { name = "Forgevent", class = "SHAMAN", level = 38, avenged = false },
                }),
                example("Veillebraise", "PALADIN", 41, 7200, "Tanaris", "Aubeflamme", {
                    { name = "Tirépine", class = "HUNTER", level = 43, avenged = true },
                }),
            },
            activity = {
                { kind = "D", time = now - 3600, character = "Écuclair", level = 32, zone = "Hautes-terres d’Arathi" },
                { kind = "D", time = now - 1800, character = "Briselune", level = 35, zone = "Désolace", sender = "Briselune" },
                { kind = "K", time = now - 900, character = "Briselune", level = 35, target = "Lamegrise",
                    targetLevel = 34, zone = "Vallée de Strangleronce", sender = "Briselune" },
                { kind = "S", time = now - 840, sender = "Briselune", count = 3 },
            },
            sightings = { Roncebrume = { zone = "Tanaris", level = 46, observer = "Aubeflamme" } },
        }
        rebuildPending()
        positionButton()
        button:Show()
        SLASH_REVENGE1 = "/revenge"
        SlashCmdList.REVENGE = function(message)
            if message:match("^%s*icone%s*$") then
                db.angle = 3.85
                positionButton()
                button:Show()
            elseif message:match("^%s*alerte%s*$") then
                toggleAlertPreview()
            elseif message:match("^%s*demo%s*$") then
                db.showDemo = not db.showDemo
                if selected and selected.isDemo and not db.showDemo then selected = nil end
                if window and window:IsShown() then refresh() end
                if refreshActivity then refreshActivity() end
                DEFAULT_CHAT_FRAME:AddMessage(db.showDemo and "Revenge : démo affichée." or "Revenge : démo masquée.")
            else
                toggleWindow()
            end
        end
        self:UnregisterEvent("ADDON_LOADED")
        self:RegisterEvent("PLAYER_DEAD")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("PARTY_KILL")
        self:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        self:RegisterEvent("PLAYER_TARGET_CHANGED")
        self:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
        C_Timer.NewTicker(2, scan)
    elseif event == "PLAYER_ENTERING_WORLD" then
        importLegacyDeaths()
    elseif event == "PLAYER_DEAD" then
        recordDeath()
    elseif event == "PARTY_KILL" then
        recordKill(arg, other)
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        inspect(arg)
    elseif event == "PLAYER_TARGET_CHANGED" then
        inspect("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        inspect("mouseover")
    end
end)
