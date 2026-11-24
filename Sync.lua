local _, ns = ...
local prefix = "RevengeJournal1"
local Sync = {}
ns.Sync = Sync
local recentWhispers = {}

local function identity(name)
    if not name then return end
    name = name:match("^%s*(.-)%s*$")
    if name == "" or #name > 100 or name:find("[%c|]") then return end
    local character, realm = name:match("^(.+)%-(.+)$")
    return ((character or name) .. "-" .. (realm or GetNormalizedRealmName()):gsub("%s", "")):lower(), name
end

local function hideOfflineNotice(_, _, message)
    if type(message) ~= "string" or (issecretvalue and issecretvalue(message)) then return false end
    for _, template in ipairs({ ERR_CHAT_PLAYER_NOT_FOUND_S or "", ERR_CHAT_PLAYER_NOT_FOUND or "" }) do
        local first, last = template:find("%s", 1, true)
        if not first then first, last = template:find("%1$s", 1, true) end
        if first then
            local before, after = template:sub(1, first - 1), template:sub(last + 1)
            if message:sub(1, #before) == before and (#after == 0 or message:sub(-#after) == after) then
                local name = message:sub(#before + 1, #message - #after)
                local key = identity(name)
                local untilTime = key and recentWhispers[key]
                if untilTime and untilTime >= GetTime() then return true end
            end
        end
    end
    return false
end

local function encode(fields)
    local encoded = {}
    for index, field in ipairs(fields) do
        encoded[index] = tostring(field):gsub("[^%w ._%-]", function(byte)
            return ("%02X"):format(byte:byte()):gsub("^", "%%")
        end)
    end
    return table.concat(encoded, "|")
end

local function decode(payload)
    local fields = {}
    for field in (payload .. "|"):gmatch("([^|]*)|") do
        fields[#fields + 1] = field:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
    end
    return fields
end

local function encodeShared(fields)
    if fields[1] == "M" then return "X" end
    if fields[1] == "D" then
        local shared = {}
        for index, field in ipairs(fields) do
            shared[index] = index >= 10 and (index - 10) % 4 == 0 and "0" or field
        end
        return encode(shared)
    end
    return encode(fields)
end

local function send(payload, name)
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then return end
    local key = identity(name)
    if key then
        local now = GetTime()
        for target, expiry in pairs(recentWhispers) do
            if expiry < now then recentWhispers[target] = nil end
        end
        recentWhispers[key] = now + 3
    end
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, prefix, payload, "WHISPER", name)
    local success = Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success
    return ok and (result == nil or result == true or result == success)
end

function Sync:Start(db, apply, notice, sent, sighting)
    self.db, self.apply, self.notice, self.sent = db, apply, notice, sent
    self.sighting = sighting
    db.contacts = db.contacts or {}
    db.outgoing = db.outgoing or {}
    if not db.sharedManualRemoved then
        for index, payload in ipairs(db.outgoing) do
            if payload:match("^[MD]|") then
                db.outgoing[index] = encodeShared(decode(payload))
            end
        end
        db.sharedManualRemoved = true
    end
    db.received = db.received or {}
    if not db.lastSyncReceived then
        db.lastSyncReceived = {}
        for _, entry in ipairs(db.activity or {}) do
            if entry.kind == "S" then
                local key = identity(entry.sender)
                if key then db.lastSyncReceived[key] = math.max(db.lastSyncReceived[key] or 0, entry.time) end
            end
        end
    end
    self.waiting = {}
    self.transfers, self.incoming = {}, {}
    self.sightings, self.sightingParts, self.sightingSerial = {}, {}, 0
    self.frame = CreateFrame("Frame")
    self.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix and C_ChatInfo.SendAddonMessage then
        local result = C_ChatInfo.RegisterAddonMessagePrefix(prefix)
        local codes = Enum and Enum.RegisterAddonMessagePrefixResult
        self.enabled = result == true or (codes and result ~= nil
            and (result == codes.Success or result == codes.DuplicatePrefix))
        if not self.enabled and C_ChatInfo.IsAddonMessagePrefixRegistered then
            self.enabled = C_ChatInfo.IsAddonMessagePrefixRegistered(prefix)
        end
        if self.enabled then
            self.frame:RegisterEvent("CHAT_MSG_ADDON")
            local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
            if addFilter then addFilter("CHAT_MSG_SYSTEM", hideOfflineNotice) end
        end
    end
    self.frame:SetScript("OnEvent", function(_, event, ...)
        if event == "PLAYER_ENTERING_WORLD" then
            self:Stream()
            C_Timer.After(5, function() self:Announce() end)
        else
            self:Receive(...)
        end
    end)
    C_Timer.NewTicker(600, function() self:Announce() end)
    C_Timer.NewTicker(0.5, function() self:SendNext() end)
    C_Timer.NewTicker(0.25, function() self:SendSighting() end)
end

function Sync:Stream()
    if not self.db.stream then
        local guid = UnitGUID("player")
        if not guid or (issecretvalue and issecretvalue(guid)) then return end
        self.db.stream = guid .. "-" .. GetServerTime() .. "-" .. math.random(100000, 999999)
    end
    return self.db.stream
end

function Sync:Contact(name, add)
    local key, display = identity(name)
    if not key or key == identity(UnitName("player")) then return false end
    if add then
        self.db.contacts[key] = display
        self:Announce()
    else
        self.db.contacts[key] = nil
        self.transfers[key], self.incoming[key] = nil, nil
        self.sightingParts[key] = nil
        self.waiting[key] = nil
        if self.lastSent == key then self.lastSent = nil end
    end
    return true
end

function Sync:BroadcastSighting(fields)
    if not self.enabled or not next(self.db.contacts) then return end
    local payload = encode(fields)
    if #payload > 1600 then return end
    self.sightingSerial = self.sightingSerial + 1
    local total = math.ceil(#payload / 200)
    local expiry = GetTime() + 25
    for key, name in pairs(self.db.contacts) do
        self.sightings[#self.sightings + 1] = {
            key = key, name = name, id = self.sightingSerial, payload = payload,
            part = 1, total = total, expiry = expiry,
        }
    end
end

function Sync:SendSighting()
    if not self.enabled then return end
    local job = self.sightings[1]
    if not job then return end
    if not self.db.contacts[job.key] or job.expiry < GetTime() then
        table.remove(self.sightings, 1)
        return
    end
    local packet = ("V|%d|%d|%d|%s"):format(job.id, job.part, job.total,
        job.payload:sub((job.part - 1) * 200 + 1, job.part * 200))
    if not send(packet, job.name) then
        table.remove(self.sightings, 1)
        return
    end
    job.part = job.part + 1
    if job.part > job.total then table.remove(self.sightings, 1) end
end

function Sync:ReceiveSighting(key, sender, id, part, total, chunk)
    part, total = tonumber(part), tonumber(total)
    if part < 1 or part > total or total > 8 or #id > 12 then return end
    if part == 1 then
        self.sightingParts[key] = { id = id, total = total, parts = {}, expiry = GetTime() + 30 }
    end
    local record = self.sightingParts[key]
    if not record or record.id ~= id or record.total ~= total
        or record.expiry < GetTime() or part ~= #record.parts + 1 then return end
    record.parts[part] = chunk
    if part == total then
        self.sightingParts[key] = nil
        self.sighting(decode(table.concat(record.parts)), sender, key)
    end
end

function Sync:ContactKey(name)
    return identity(name)
end

function Sync:ContactStatus(key)
    return self.waiting[key] ~= nil, self.db.lastSyncReceived[key]
end

function Sync:WaitForContact(key, waiting)
    local existing = self.waiting[key]
    if waiting and not existing then
        local token = {}
        self.waiting[key] = token
        C_Timer.After(18, function()
            if self.waiting[key] == token then self:WaitForContact(key, false) end
        end)
    elseif not waiting and existing then
        self.waiting[key] = nil
    else
        return
    end
    if self.statusChanged then self.statusChanged(key) end
end

function Sync:Announce()
    if not self.enabled or not next(self.db.contacts) then return end
    local stream = self:Stream()
    if not stream then return end
    for key, name in pairs(self.db.contacts) do
        if send("H|" .. stream, name) then self:WaitForContact(key, true) end
    end
end

function Sync:Publish(fields)
    local stream = self:Stream()
    if not stream then return end
    local seq = #self.db.outgoing + 1
    local payload = encodeShared(fields)
    if #payload > 12000 then return end
    local id = ("%s:%012d"):format(stream, seq)
    if not self.apply(fields, id) then return end
    self.db.outgoing[seq] = payload
    if not self.announceScheduled then
        self.announceScheduled = true
        C_Timer.After(2, function()
            self.announceScheduled = nil
            self:Announce()
        end)
    end
    return id
end

function Sync:SendNext()
    if not self.enabled then return end
    local key = next(self.transfers, self.lastSent)
    if not key then key = next(self.transfers) end
    self.lastSent = key
    if not key then return end
    local job = self.transfers[key]
    local payload = self.db.outgoing[job.seq]
    if not payload then
        self.lastSent = nil
        self.transfers[key] = nil
        self.sent(job.name, job.seq - job.start)
        return
    end
    local total = math.ceil(#payload / 200)
    local packet = ("E|%d|%d|%d|%s"):format(job.seq, job.part, total,
        payload:sub((job.part - 1) * 200 + 1, job.part * 200))
    if send(packet, job.name) then
        job.failures = nil
        job.part = job.part + 1
        if job.part > total then job.seq, job.part = job.seq + 1, 1 end
    else
        job.failures = (job.failures or 0) + 1
        if job.failures >= 8 then
            self.lastSent = nil
            self.transfers[key] = nil
        end
    end
end

function Sync:Receive(messagePrefix, message, channel, sender)
    if issecretvalue and (issecretvalue(messagePrefix) or issecretvalue(message)
        or issecretvalue(channel) or issecretvalue(sender)) then return end
    if messagePrefix ~= prefix or channel ~= "WHISPER" or type(message) ~= "string"
        or type(sender) ~= "string" or #message > 255 then return end
    local key = identity(sender)
    if not key or not self.db.contacts[key] then return end
    local sightingID, sightingPart, sightingTotal, sightingChunk = message:match("^V|(%d+)|(%d+)|(%d+)|(.+)$")
    if sightingID then
        self:ReceiveSighting(key, sender, sightingID, sightingPart, sightingTotal, sightingChunk)
        return
    end
    local op, stream = message:match("^([HR])|(Player%-%w[%w%-]+)$")
    if stream and #stream < 95 then
        local incoming = self.incoming[key]
        if not incoming or incoming.stream ~= stream then
            incoming = { stream = stream }
            self.incoming[key] = incoming
        end
        local ownStream = self:Stream()
        if op == "H" and ownStream then send("R|" .. ownStream, sender) end
        if send("Q|" .. stream .. "|" .. (self.db.received[stream] or 0), sender) then
            self:WaitForContact(key, true)
        end
        return
    end
    local requested, cursor = message:match("^Q|(Player%-%w[%w%-]+)|(%d+)$")
    if requested and requested == self.db.stream then
        cursor = tonumber(cursor)
        if cursor >= #self.db.outgoing then
            send("A|" .. requested, sender)
        elseif not self.transfers[key] then
            self.transfers[key] = { seq = cursor + 1, start = cursor + 1, part = 1, name = sender }
        end
        return
    end
    local seq, part, total, chunk = message:match("^E|(%d+)|(%d+)|(%d+)|(.+)$")
    local incoming = self.incoming[key]
    if incoming and message == "A|" .. incoming.stream then
        self:WaitForContact(key, false)
        return
    end
    if not seq or not incoming then return end
    seq, part, total = tonumber(seq), tonumber(part), tonumber(total)
    if seq ~= (self.db.received[incoming.stream] or 0) + 1 or total > 60 or part > total then return end
    if part == 1 then incoming.parts, incoming.total = {}, total end
    local parts = incoming.parts
    if not parts or part ~= #parts + 1 or total ~= incoming.total then return end
    parts[part] = chunk
    if part == total then
        local accepted = self.apply(decode(table.concat(parts)), ("%s:%012d"):format(incoming.stream, seq), sender)
        self.db.received[incoming.stream] = seq
        incoming.parts = nil
        if accepted then
            self.db.lastSyncReceived[key] = GetServerTime()
            if self.waiting[key] then
                self:WaitForContact(key, false)
            elseif self.statusChanged then
                self.statusChanged(key)
            end
            self.notice(sender)
        end
    end
end
