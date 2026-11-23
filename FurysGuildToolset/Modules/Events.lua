-- Events: sign-ups from a sesh (Discord bot) event post, checked against who is in your group.
--
-- You copy the sesh post in Discord and paste it into the Events tab (Ctrl+V). The tab reads
-- the title, time, CP requirement and every sign-up section with its count and limit, such as
-- "Tank (1 / 2)", "DPS (1 / 8)", "Standby (0)" or "Attendees (4)" for a class with no limit.
-- Each sign-up is matched to an @account (by name, or the account you pick once) and shown as
-- in group, online, or offline.
--
-- Written from the ESO API and the ZOS UI source. What the game lets an addon do here:
--   Chat: an addon can't send chat. Whispers and guild ads go into the chat box with
--   StartChatInput and you press Enter.
--   Group invites: GroupInviteByName runs only when you click Invite.
--   Mail: opens filled in for you to send (GT.Actions.Warn).
--   Group Finder: the listing is filled in the same way the game's own Create window does it
--   (SetGroupFinderUserTypeGroupListing* on the draft, then RequestCreateGroupListing), only
--   after you check the text and press Create listing. Applicants are accepted in the game's
--   Group Finder window, by you.
--   Discord: the addon can't reach Discord. "Copy for Discord" shows the text to copy.
-- Off on a new install.

local GT = FuryGMT
local U = GT.Util
local A = GT.Actions

local Events = GT:RegisterModule("events", {})
GT.Events = Events

local MAX_PASTE = 12000
local MAX_CHAT = 350
local REFRESH_DELAY_MS = 500
local CHAT_EVENT_NAME = "FuryGMTEventsChat"
local DRAFT = GROUP_FINDER_GROUP_LISTING_USER_TYPE_GROUP_LISTING_DRAFT

local GUILD_CHANNELS = {
    CHAT_CHANNEL_GUILD_1, CHAT_CHANNEL_GUILD_2, CHAT_CHANNEL_GUILD_3,
    CHAT_CHANNEL_GUILD_4, CHAT_CHANNEL_GUILD_5,
}

local ROLE_OF_KIND = { tank = LFG_ROLE_TANK, heal = LFG_ROLE_HEAL, dps = LFG_ROLE_DPS }
local ROLE_NAME = { [LFG_ROLE_TANK] = "Tank", [LFG_ROLE_HEAL] = "Healer", [LFG_ROLE_DPS] = "DPS" }
local NEED_WORDS = { tank = { "tank", "tanks" }, heal = { "healer", "healers" }, dps = { "DPS", "DPS" } }

-- Short names people use for trials, so "vSS" in a post finds Sunspire in the Group Finder.
local TRIAL_ALIASES = {
    hrc = "helracitadel", aa = "aetherianarchive", so = "sanctumophidia", mol = "mawoflorkhaj",
    hof = "hallsoffabrication", as = "asylumsanctorium", cr = "cloudrest", ss = "sunspire",
    ka = "kynesaegis", rg = "rockgrove", dsr = "dreadsailreef", se = "sanitysedge",
    lc = "lucentcitadel", oc = "osseincage",
}

Events.defaults = {
    enabled = false,          -- off on a new install (Albert's rule)
    event = nil,              -- the last pasted sign-up post, parsed (see Events.Parse)
    map = {},                 -- [name key] = "@account": the account you picked for a Discord name
    adGuilds = {},            -- [guildId] = true: Advertise puts the ad in that guild's chat box
    whisperText = "Hi {name}, {event} is forming up now. Are you still coming? I can send you an invite.",
    mailSubject = "{event} is starting",
    mailText = "Hi {name},\n\nYou signed up for {event} ({time}) and we're forming up now. If you can still make it, log in and whisper {me} for an invite.\n\nThanks!",
    adText = "LFM {need} for {event}{cp}. Whisper {me} for an invite!",
}

Events.columns = {
    { title = "Signed up as", width = 130, tip = "The sign-up section in the sesh post (Tank, Healer, DPS, Standby, Attendees...)." },
    { title = "Discord name", width = 220, tip = "The name in the sesh post." },
    { title = "Account", width = 200, tip = "Their ESO @account. Matched by name, or the one you picked with right-click > Set account." },
    { title = "Status", width = 300, tip = "In group, online (in one of your guilds or on your friends list), or offline and for how long." },
    { title = "Group role", width = 100, tip = "The role they picked in the group (from the group window)." },
    { title = "CP", width = 70, tip = "Their champion points, while they are in your group. Red when under the post's CP requirement." },
}

-- Text helpers ---------------------------------------------------------------------

local function Trim(text)
    return zo_strtrim(tostring(text or ""))
end

-- One Unicode code point as plain a-z / 0-9, or nil. Covers ASCII, the "fancy" math letters
-- Discord names often use (𝖩𝖮𝖤 is U+1D5A9...) and full-width letters.
local function AsciiFor(cp)
    if (cp >= 48 and cp <= 57) or (cp >= 97 and cp <= 122) then return string.char(cp) end
    if cp >= 65 and cp <= 90 then return string.char(cp + 32) end
    if cp >= 0x1D400 and cp <= 0x1D6A3 then return string.char(97 + ((cp - 0x1D400) % 52) % 26) end
    if cp >= 0x1D7CE and cp <= 0x1D7FF then return string.char(48 + (cp - 0x1D7CE) % 10) end
    if cp >= 0xFF21 and cp <= 0xFF3A then return string.char(97 + cp - 0xFF21) end
    if cp >= 0xFF41 and cp <= 0xFF5A then return string.char(97 + cp - 0xFF41) end
    if cp >= 0xFF10 and cp <= 0xFF19 then return string.char(48 + cp - 0xFF10) end
    return nil
end

-- "Marth Wolf" -> "marthwolf", "@Bmguyen18458" -> "bmguyen18458", "𝖩𝖮𝖤𝖲𝖲𝖠𝖭" -> "joessan".
-- Used to compare Discord names with account names.
local function Norm(text)
    local s = tostring(text or "")
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:byte(i)
        local cp, len
        if c < 0x80 then
            cp, len = c, 1
        elseif c >= 0xF0 then
            cp = (c % 8) * 262144 + ((s:byte(i + 1) or 128) % 64) * 4096 + ((s:byte(i + 2) or 128) % 64) * 64 + ((s:byte(i + 3) or 128) % 64)
            len = 4
        elseif c >= 0xE0 then
            cp = (c % 16) * 4096 + ((s:byte(i + 1) or 128) % 64) * 64 + ((s:byte(i + 2) or 128) % 64)
            len = 3
        elseif c >= 0xC0 then
            cp = (c % 32) * 64 + ((s:byte(i + 1) or 128) % 64)
            len = 2
        else
            cp, len = 0, 1
        end
        local ch = AsciiFor(cp)
        if ch then out[#out + 1] = ch end
        i = i + len
    end
    return table.concat(out)
end
Events.Norm = Norm

-- Drops characters the game font can't show (emoji and other 4-byte characters).
local function Printable(text)
    return (tostring(text or ""):gsub("[\240-\244][\128-\191][\128-\191][\128-\191]", ""))
end

-- A line with leading symbols (emoji, bullets) removed, for spotting headers like "Tank (1 / 2)".
local function Bare(line)
    line = Printable(line):gsub("%[%+%]", "")
    line = line:gsub("^[^%w@%(]+", "")
    return Trim(line)
end

local function Fill(template, values)
    return (tostring(template or ""):gsub("{(%w+)}", function(key)
        local value = values[key]
        if value == nil then return "{" .. key .. "}" end
        return tostring(value)
    end))
end

-- Parsing a sesh post ----------------------------------------------------------------

local LABELS = { time = true, duration = true, ["repeat"] = true, ["repeats"] = true, ["when"] = true }

local function KindOf(name)
    local low = zo_strlower(name)
    if low:find("tank") then return "tank" end
    if low:find("heal") then return "heal" end
    if low:find("dps") or low:find("damage") or low:find("^dd") then return "dps" end
    if low:find("standby") or low:find("bench") or low:find("reserve") or low:find("tentative") or low:find("maybe")
        or low:find("late") or low:find("backup") or low:find("sub") then return "standby" end
    if low:find("absent") or low:find("declin") or low:find("can'?t") or low:find("cannot") or low:find("not ")
        or low == "no" then return "out" end
    return "any"
end

-- "Tank (1 / 2)" -> "Tank", 1, 2. "Attendees (4)" -> "Attendees", 4, nil. Otherwise nil.
local function Header(line)
    local bare = Bare(line)
    local name, count, max = bare:match("^(.-)%s*%(%s*(%d+)%s*/%s*(%d+)%s*%)$")
    if not name then
        name, count = bare:match("^(.-)%s*%(%s*(%d+)%s*%)$")
    end
    if not name or name == "" or #name > 40 or not name:find("%a") then return nil end
    return name, tonumber(count), max and tonumber(max) or nil
end

-- "Furyous (Albert)" -> { raw =, base = "Furyous", nick = "Albert", key = "furyous" }
local function Person(raw)
    raw = Trim(raw)
    raw = raw:gsub("^%d+[%.%)]%s+", "")
    raw = raw:gsub("^[%-%*]%s+", "")
    raw = Trim((raw:gsub("^\226\128\162%s*", "")))
    local base, nick = raw:match("^(.-)%s*%((.-)%)$")
    base = Trim(base or raw)
    local key = Norm(base)
    if key == "" then key = zo_strlower(base) end
    return { raw = raw, base = base, nick = nick and Trim(nick) or nil, key = key }
end

-- Reads a pasted sesh post. Returns the event table, or nil and a reason.
function Events.Parse(text)
    local lines = {}
    for line in (tostring(text or ""):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = Trim(line) end

    local ev = { sections = {}, desc = {}, requirements = {}, pastedAt = GetTimeStamp() }
    local first
    for i, line in ipairs(lines) do
        if Bare(line) ~= "" then first = i; break end
    end
    if not first then return nil, "The text is empty." end
    ev.title = Bare(lines[first])

    -- Time, Duration and Repeat are a label line followed by the value.
    local infoStart
    for i = first + 1, #lines do
        local label = zo_strlower(Bare(lines[i]))
        if LABELS[label] then
            infoStart = infoStart or i
            local value
            for j = i + 1, #lines do
                if lines[j] ~= "" then value = lines[j]; break end
            end
            if value then
                value = Trim(Printable(value):gsub("%[%+%]", ""):gsub("%s*%(in [^%)]*%)", ""))
                if label == "time" or label == "when" then ev.time = value
                elseif label == "duration" then ev.duration = value
                else ev.repeatText = value end
            end
        end
    end

    -- Sign-up sections: a header with a count, then one name per line ("-" = nobody).
    local section
    local valueLine = {}
    for i = 1, #lines do
        if LABELS[zo_strlower(Bare(lines[i]))] then
            for j = i + 1, #lines do
                if lines[j] ~= "" then valueLine[j] = true; break end
            end
        end
    end
    for i = (infoStart or first + 1), #lines do
        local line = lines[i]
        local name, count, max = Header(line)
        if name and not valueLine[i] then
            section = { name = name, kind = KindOf(name), count = count, max = max, people = {} }
            ev.sections[#ev.sections + 1] = section
        elseif section and line ~= "" and line ~= "-" and not LABELS[zo_strlower(Bare(line))] and not valueLine[i] then
            for part in (line .. ","):gmatch("([^,]+),") do
                local person = Person(part)
                if person.base ~= "" and person.base ~= "-" then section.people[#section.people + 1] = person end
            end
        end
    end
    if #ev.sections == 0 then
        return nil, "No sign-up sections found. Copy the whole sesh post, down to the last name under the last role."
    end

    -- Description: everything between the title and the Time line (or the first section).
    local descEnd = (infoStart or #lines + 1) - 1
    for i = first + 1, descEnd do ev.desc[#ev.desc + 1] = Printable(lines[i]) end

    -- CP: "160 CP", "CP 160", "CP: 1800+".
    local whole = table.concat(ev.desc, "\n")
    local cp = whole:match("(%d+)%s*[Cc][Pp]%f[%A]") or whole:match("%f[%a][Cc][Pp]%s*:?%s*(%d+)")
    ev.minCP = cp and tonumber(cp) or 0

    -- Requirements: the short lines under a line that says "required" or "requirements".
    local inList = false
    for _, line in ipairs(ev.desc) do
        local low = zo_strlower(line)
        if low:find("requir") then
            inList = true
        elseif inList then
            local bare = Bare(line)
            if bare == "" or #bare > 40 then
                if #ev.requirements > 0 then inList = false end
            elseif not bare:find("%d+%s*[Cc][Pp]") then
                ev.requirements[#ev.requirements + 1] = bare
            end
        end
    end
    return ev
end

-- Settings and lifecycle ---------------------------------------------------------------

function Events:Initialize(sv)
    self.sv = sv
    self:RegisterTab()
    SCENE_MANAGER:RegisterTopLevel(FuryGMTEventsInput, false)
    FuryGMTEventsInputTextBox:SetMaxInputChars(MAX_PASTE)
    FuryGMTEventsInputTextBox:SetMultiLine(true)
    FuryGMTEventsInputTextBox:SetNewLineEnabled(true)
    EVENT_MANAGER:RegisterForEvent("FuryGMTEventsListing", EVENT_GROUP_FINDER_CREATE_GROUP_LISTING_RESULT,
        function(_, result) self:OnListingResult(result) end)
    self:RegisterWatch()
end

-- Group and online changes refresh the tab while it's showing. Only while the feature is on.
local WATCH_EVENTS = {
    EVENT_GROUP_MEMBER_JOINED, EVENT_GROUP_MEMBER_LEFT, EVENT_GROUP_MEMBER_ROLE_CHANGED, EVENT_GROUP_UPDATE,
    EVENT_GROUP_MEMBER_CONNECTED_STATUS, EVENT_GUILD_MEMBER_PLAYER_STATUS_CHANGED, EVENT_FRIEND_PLAYER_STATUS_CHANGED,
}

function Events:RegisterWatch()
    for i, event in ipairs(WATCH_EVENTS) do
        local name = "FuryGMTEventsWatch" .. i
        EVENT_MANAGER:UnregisterForEvent(name, event)
        if self.sv.enabled then
            EVENT_MANAGER:RegisterForEvent(name, event, function() self:QueueRefresh() end)
        end
    end
end

function Events:QueueRefresh()
    if self.refreshQueued then return end
    self.refreshQueued = true
    zo_callLater(function()
        self.refreshQueued = false
        if GT.Report.currentTab == "events" then GT.Report:RefreshIfShown() end
    end, REFRESH_DELAY_MS)
end

function Events:SetEnabled(on)
    self.sv.enabled = on
    self:RegisterWatch()
    GT.Report:RefreshIfShown()
end

-- Who is who -----------------------------------------------------------------------------

-- Everyone in your guilds and on your friends list, by Norm(account): { name, status, secs }.
-- Online beats offline when someone is in several guilds.
function Events:BuildIndex()
    local index = {}
    local function Add(name, status, secs, note)
        local key = Norm(name)
        local known = index[key]
        if not known then
            index[key] = { name = name, status = status, secs = secs or 0, notes = note and { note } or {} }
        else
            if known.status == PLAYER_STATUS_OFFLINE and status ~= PLAYER_STATUS_OFFLINE then
                known.status = status
                known.secs = 0
            elseif status == PLAYER_STATUS_OFFLINE and known.status == PLAYER_STATUS_OFFLINE then
                known.secs = math.min(known.secs, secs or known.secs)
            end
            if note then known.notes[#known.notes + 1] = note end
        end
    end
    for _, guildId in ipairs(U.GetGuildIds()) do
        for i = 1, GetNumGuildMembers(guildId) do
            local name, note, _, status, secs = GetGuildMemberInfo(guildId, i)
            Add(name, status, secs, note ~= "" and note or nil)
        end
    end
    for i = 1, GetNumFriends() do
        local name, _, status, secs = GetFriendInfo(i)
        Add(name, status, secs)
    end
    return index
end

-- Who is in your group, by Norm(account): { name, role, cp, online }. You count even when solo.
function Events:BuildGroup()
    local group, count = {}, 0
    local size = GetGroupSize()
    for i = 1, size do
        local tag = GetGroupUnitTagByIndex(i)
        if tag then
            local name = GetUnitDisplayName(tag)
            group[Norm(name)] = { name = name, role = GetGroupMemberSelectedRole(tag), cp = GetUnitChampionPoints(tag), online = IsUnitOnline(tag) }
            count = count + 1
        end
    end
    local me = GetDisplayName()
    if not group[Norm(me)] then
        group[Norm(me)] = { name = me, role = GetSelectedLFGRole(), cp = GetUnitChampionPoints("player"), online = true }
        count = count + 1
    end
    return group, count
end

-- The @account for a sign-up: the one you picked, the one typed in the post, or a match by name.
-- Returns account, how ("picked", "post", "name") or nil.
function Events:AccountFor(person, index, group)
    local picked = self.sv.map[person.key]
    if picked then return picked, "picked" end
    if person.base:sub(1, 1) == "@" then return person.base, "post" end
    local nickKey = person.nick and Norm(person.nick) or nil
    for _, key in ipairs({ person.key, nickKey }) do
        if key and key ~= "" then
            local hit = group[key] or index[key]
            if hit then return hit.name, "name" end
        end
    end
    return nil
end

-- Up to four accounts that look like this Discord name, for the right-click menu.
function Events:Suggestions(person, index)
    local found, seen = {}, {}
    local keys = { person.key }
    if person.nick then keys[#keys + 1] = Norm(person.nick) end
    local function Try(name)
        if #found < 4 and not seen[name] then
            seen[name] = true
            found[#found + 1] = name
        end
    end
    for _, key in ipairs(keys) do
        if #key >= 4 then
            for accountKey, entry in pairs(index) do
                if accountKey:find(key, 1, true) or (#accountKey >= 4 and key:find(accountKey, 1, true)) then Try(entry.name) end
            end
            for _, entry in pairs(index) do
                for _, note in ipairs(entry.notes) do
                    if Norm(note):find(key, 1, true) then Try(entry.name) end
                end
            end
        end
    end
    table.sort(found)
    return found
end

function Events:SetAccount(person, account)
    self.cache = nil
    account = U.NormalizeName(account)
    if account == "@" then
        self.sv.map[person.key] = nil
    else
        self.sv.map[person.key] = account
        U.Print("%s is now matched to %s.", person.base, account)
    end
    GT.Report:RefreshIfShown()
end

-- The state of the event right now ------------------------------------------------------

local function StatusText(info, entry)
    if info.inGroup then
        local text = "|c9FD49FIn group|r"
        if entry.role and info.groupRole ~= LFG_ROLE_INVALID and info.groupRole ~= entry.role then
            text = string.format("|cFF9933In group as %s|r", ROLE_NAME[info.groupRole] or "?")
        end
        if not info.online then text = text .. " |cAAAAAA(disconnected)|r" end
        return text
    end
    if not info.account then return "|cAAAAAANo account matched. Right-click to set it.|r" end
    if not info.status then return "|cAAAAAANot in your guilds or friends|r" end
    if info.status == PLAYER_STATUS_OFFLINE then
        return "|cAAAAAAOffline " .. U.FormatDuration(info.secs) .. "|r"
    end
    if info.status == PLAYER_STATUS_AWAY then return "|cFFFF66Online (away), not in group|r" end
    if info.status == PLAYER_STATUS_DO_NOT_DISTURB then return "|cFFFF66Online (busy), not in group|r" end
    return "|cFFFF66Online, not in group|r"
end

-- Everything the tab and the buttons need: one entry per sign-up, the walk-ins, counts and
-- open slots. Built fresh each time (group and online status change all the time).
function Events:State()
    local ev = self.sv.event
    if not ev then return nil end
    -- The tab title, summary and rows all ask in the same refresh: build it once per frame.
    local frame = GetFrameTimeMilliseconds()
    if self.cache and self.cacheFrame == frame and self.cache.ev == ev then return self.cache end
    local state = self:BuildState(ev)
    self.cache, self.cacheFrame = state, frame
    return state
end

function Events:BuildState(ev)
    local index = self:BuildIndex()
    local group, groupCount = self:BuildGroup()
    local state = { ev = ev, entries = {}, walkIns = {}, missing = {}, open = {}, here = {}, groupCount = groupCount, index = index }
    local matched = {}
    local roleCount = {}
    for _, member in pairs(group) do roleCount[member.role] = (roleCount[member.role] or 0) + 1 end

    for _, section in ipairs(ev.sections) do
        state.here[section] = 0
        for _, person in ipairs(section.people) do
            local account, how = self:AccountFor(person, index, group)
            local key = account and Norm(account) or nil
            local member = key and group[key] or nil
            local known = key and index[key] or nil
            local info = {
                person = person, section = section, account = account, how = how,
                inGroup = member ~= nil, groupRole = member and member.role or nil, cp = member and member.cp or nil,
                online = member and member.online or nil,
                status = known and known.status or nil, secs = known and known.secs or 0,
            }
            info.statusText = StatusText(info, { role = ROLE_OF_KIND[section.kind] })
            if key then matched[key] = true end
            if member then state.here[section] = state.here[section] + 1 end
            state.entries[#state.entries + 1] = info
            if not member and section.kind ~= "standby" and section.kind ~= "out" then state.missing[#state.missing + 1] = info end
        end
    end

    for key, member in pairs(group) do
        if not matched[key] then
            state.walkIns[#state.walkIns + 1] = { account = member.name, inGroup = true, groupRole = member.role, cp = member.cp, online = member.online }
        end
    end
    table.sort(state.walkIns, function(a, b) return a.account < b.account end)

    -- Open slots: a role's limit minus the people in your group playing that role. A section
    -- with no role (Attendees) and a limit: its limit minus everyone in the group.
    local anyMax = 0
    for _, section in ipairs(ev.sections) do
        if section.max then
            local role = ROLE_OF_KIND[section.kind]
            if role then
                state.open[section.kind] = (state.open[section.kind] or 0) + section.max
            elseif section.kind == "any" then
                anyMax = anyMax + section.max
            end
        end
    end
    for kind, max in pairs(state.open) do state.open[kind] = math.max(0, max - (roleCount[ROLE_OF_KIND[kind]] or 0)) end
    if anyMax > 0 then state.open.any = math.max(0, anyMax - groupCount) end
    state.roleCount = roleCount
    return state
end

-- "1 tank, 2 healers, 7 DPS", or "" when no section has a limit.
function Events:NeedText(state)
    local parts = {}
    for _, kind in ipairs({ "tank", "heal", "dps" }) do
        local n = state.open[kind]
        if n and n > 0 then parts[#parts + 1] = string.format("%d %s", n, NEED_WORDS[kind][n == 1 and 1 or 2]) end
    end
    if state.open.any and state.open.any > 0 then parts[#parts + 1] = string.format("%d more", state.open.any) end
    return table.concat(parts, ", ")
end

function Events:Values(state, name)
    local ev = state.ev
    local need = self:NeedText(state)
    return {
        event = ev.title, time = ev.time or "now", me = GetDisplayName(), name = name or "",
        need = need ~= "" and need or "more people",
        cp = (ev.minCP or 0) > 0 and string.format(" (CP %d+)", ev.minCP) or "",
    }
end

-- The tab ------------------------------------------------------------------------------------

function Events:RegisterTab()
    GT.Report:RegisterTab({
        id = "events",
        title = function() return self:TabTitle() end,
        tip = "Sign-ups from a sesh event post in Discord, checked against who is in your group: who is missing, open slots, invites, guild ads and a Group Finder listing.",
        GetOffText = function() return GT:FeatureOffText(self.sv.enabled, "Events") end,
        GetSummary = function() return self:TabSummary() end,
        GetRows = function() return self:TabRows() end,
        columns = Events.columns,
        footer = function() return self:TabFooter() end,
        GetExportLines = function() return self:TabExportLines() end,
    })
end

function Events:TabTitle()
    if not self.sv.enabled or not self.sv.event then return "Events" end
    local state = self:State()
    return #state.missing > 0 and string.format("Events (%d)", #state.missing) or "Events"
end

function Events:TabSummary()
    if not self.sv.enabled then return "" end
    local state = self:State()
    if not state then
        return "Copy a sesh sign-up post in Discord (select it from the title down to the last name), click Paste sign-ups and press Ctrl+V."
    end
    local ev = state.ev
    local parts = {}
    for _, section in ipairs(ev.sections) do
        if section.kind ~= "out" then
            local here = section.kind ~= "standby" and string.format(", %d here", state.here[section]) or ""
            parts[#parts + 1] = string.format("%s %d%s%s", section.name, #section.people,
                section.max and ("/" .. section.max) or "", here)
        end
    end
    local line = string.format("|cFFFFFF%s|r%s.  %s.", ev.title, ev.time and (", " .. ev.time) or "", table.concat(parts, "; "))
    local need = self:NeedText(state)
    if need ~= "" then line = line .. "  Open: " .. need .. "." end
    if (ev.minCP or 0) > 0 then line = line .. string.format("  CP %d+.", ev.minCP) end
    return line
end

local function CpText(info, minCP)
    if not info.cp then return "" end
    if minCP and minCP > 0 and info.cp < minCP then return "|cFF6666" .. info.cp .. "|r" end
    return tostring(info.cp)
end

function Events:TabRows()
    if not self.sv.enabled then return {} end
    local state = self:State()
    if not state then return {} end
    local rows = {}
    local minCP = state.ev.minCP
    for _, info in ipairs(state.entries) do
        local person = info.person
        local accountText = info.account or "|cAAAAAA?|r"
        local tip
        if info.how == "name" then
            tip = string.format("%s was matched to %s by name. Right-click > Set account if that's the wrong person.", person.raw, info.account)
        elseif info.how == "picked" then
            tip = string.format("You matched %s to %s.", person.raw, info.account)
        end
        if (minCP or 0) > 0 and info.cp and info.cp < minCP then
            tip = (tip and (tip .. "\n") or "") .. string.format("Under the CP requirement (%d).", minCP)
        end
        local row = {
            cells = { info.section.name, person.raw, accountText, info.statusText, info.groupRole and (ROLE_NAME[info.groupRole] or "-") or "", CpText(info, minCP) },
            tooltip = tip,
        }
        rows[#rows + 1] = GT.Report.AddMenu(row, self:MenuItems(info, state))
    end
    for _, info in ipairs(state.walkIns) do
        local row = {
            cells = { "|cAAAAAANot signed up|r", "", info.account, "|c9FD49FIn group|r", ROLE_NAME[info.groupRole] or "-", CpText(info, minCP) },
            tooltip = "In your group but not in the sesh post, or not matched to a sign-up yet.",
        }
        rows[#rows + 1] = GT.Report.AddMenu(row, GT.Report.ContactItems(info.account))
    end
    return rows
end

function Events:MenuItems(info, state)
    local items = {}
    local account = info.account
    local values = self:Values(state, info.person.base)
    if account and account ~= GetDisplayName() then
        items[#items + 1] = { label = "Whisper " .. account, fn = function() A.Warn(account, "", Fill(self.sv.whisperText, values), "whisper") end }
        if not info.inGroup then
            items[#items + 1] = { label = "Invite " .. account .. " to the group", fn = function() self:Invite(account) end }
        end
        items[#items + 1] = { label = "Mail " .. account, fn = function() A.Warn(account, Fill(self.sv.mailSubject, values), Fill(self.sv.mailText, values), "mail") end }
    end
    if info.how ~= "picked" and info.how ~= "post" then
        for _, name in ipairs(self:Suggestions(info.person, state.index)) do
            if name ~= account then
                items[#items + 1] = { label = "Set account: " .. name, fn = function() self:SetAccount(info.person, name) end }
            end
        end
    end
    items[#items + 1] = { label = "Set account (type it)...", fn = function() self:AskAccount(info.person, account) end }
    if info.how == "picked" then
        items[#items + 1] = { label = "Forget the account for " .. info.person.base, fn = function() self:SetAccount(info.person, "") end }
    end
    return items
end

function Events:TabFooter()
    if not self.sv.enabled then return {} end
    return {
        { label = "Paste sign-ups", tip = "Opens a box to paste a sesh event post into (Ctrl+V). Replaces the event shown now.", fn = function() self:AskPaste() end },
        { label = "Invite online", tip = "Sends a group invite to every sign-up who is online and not in your group (not Standby). One click, one invite each.", fn = function() self:InviteOnline() end },
        { label = "Advertise in guilds", tip = "Puts an ad for the open slots in the chat box of each guild ticked in the Events settings, one guild after another. You press Enter for each.", fn = function() self:Advertise() end },
        { label = "Group Finder", tip = "Shows a Group Finder listing for the open slots (title, description, CP and roles from the post) to check. Nothing is listed until you press Create listing.", fn = function() self:AskListing() end },
        { label = "Copy for Discord", tip = "Shows a message with the missing names and open slots to copy into Discord.", fn = function() self:CopyForDiscord() end },
    }
end

function Events:TabExportLines()
    local lines = { "Signed up as\tDiscord name\tAccount\tStatus\tGroup role\tCP" }
    local state = self.sv.enabled and self:State()
    if not state then return lines end
    local function Plain(text) return (tostring(text or ""):gsub("|c%x%x%x%x%x%x", ""):gsub("|r", "")) end
    for _, info in ipairs(state.entries) do
        lines[#lines + 1] = table.concat({ info.section.name, info.person.raw, info.account or "", Plain(info.statusText),
            info.groupRole and (ROLE_NAME[info.groupRole] or "") or "", info.cp and tostring(info.cp) or "" }, "\t")
    end
    for _, info in ipairs(state.walkIns) do
        lines[#lines + 1] = table.concat({ "Not signed up", "", info.account, "In group", ROLE_NAME[info.groupRole] or "", info.cp and tostring(info.cp) or "" }, "\t")
    end
    return lines
end

-- The text window --------------------------------------------------------------------------
-- One window for pasting the post, typing an account and checking the Group Finder listing.

function Events:OpenInput(def)
    self.input = def
    FuryGMTEventsInputTitle:SetText(def.title)
    FuryGMTEventsInputHint:SetText(def.hint or "")
    FuryGMTEventsInputOK:SetText(def.okLabel or "OK")
    FuryGMTEventsInputTextBox:SetText(def.text or "")
    if FuryGMTEventsInput:IsHidden() then SCENE_MANAGER:ShowTopLevel(FuryGMTEventsInput) end
    FuryGMTEventsInputTextBox:TakeFocus()
end

function Events:CloseInput()
    FuryGMTEventsInputTextBox:LoseFocus()
    SCENE_MANAGER:HideTopLevel(FuryGMTEventsInput)
end

function Events:SubmitInput()
    local def = self.input
    local text = FuryGMTEventsInputTextBox:GetText() or ""
    self:CloseInput()
    if def then def.onOk(text) end
end

function Events:InputTip()
    return self.input and self.input.okTip or ""
end

function Events:AskPaste()
    self:OpenInput({
        title = "Paste sign-ups",
        hint = "In Discord, select the sesh event post from its title down to the last name under the last role, press Ctrl+C, then click in the box below and press Ctrl+V.",
        okLabel = "Read sign-ups",
        okTip = "Reads the post and shows each sign-up in the Events tab. Replaces the event shown now.",
        onOk = function(text) self:ReadPaste(text) end,
    })
end

function Events:ReadPaste(text)
    local ev, reason = Events.Parse(text)
    if not ev then
        U.Print("Couldn't read that post: %s", reason)
        return
    end
    self.sv.event = ev
    self.cache = nil
    local people = 0
    for _, section in ipairs(ev.sections) do people = people + #section.people end
    U.Print("Read %s: %d %s in %d %s%s.", ev.title, people, people == 1 and "sign-up" or "sign-ups", #ev.sections,
        #ev.sections == 1 and "section" or "sections", (ev.minCP or 0) > 0 and string.format(", CP %d+", ev.minCP) or "")
    GT.Report:Show("events")
end

function Events:AskAccount(person, current)
    self:OpenInput({
        title = "Account for " .. person.base,
        hint = string.format("Type the ESO @account of %s. It's remembered for every event. Leave it empty to forget it.", person.raw),
        okLabel = "Save account",
        okTip = "Remembers this account for this Discord name.",
        text = current or "@",
        onOk = function(text) self:SetAccount(person, Trim((text:gsub("[\r\n].*", "")))) end,
    })
end

-- Actions ---------------------------------------------------------------------------------

local function CanInvite()
    if IsUnitSoloOrGroupLeader("player") then return true end
    U.Print("Only the group leader can invite.")
    return false
end

function Events:Invite(account)
    if not CanInvite() then return end
    GroupInviteByName(account)
    U.Print("Group invite sent to %s.", account)
end

function Events:InviteOnline()
    local state = self:State()
    if not state then U.Print("Paste a sesh sign-up post first."); return end
    if not CanInvite() then return end
    local sent = {}
    for _, info in ipairs(state.missing) do
        if info.account and info.status and info.status ~= PLAYER_STATUS_OFFLINE and info.account ~= GetDisplayName() then
            GroupInviteByName(info.account)
            sent[#sent + 1] = info.account
        end
    end
    if #sent == 0 then
        U.Print("Nobody who signed up is online and out of the group.")
    else
        U.Print("Group invites sent to %s.", table.concat(sent, ", "))
    end
end

-- Guild ads: one guild at a time. The next guild's ad goes in the chat box after you send
-- the one before it.
function Events:Advertise()
    local state = self:State()
    if not state then U.Print("Paste a sesh sign-up post first."); return end
    if CHAT_SYSTEM:IsTextEntryOpen() then
        U.Print("You're typing in chat. Send or close that first, then try again.")
        return
    end
    local posts = {}
    local text = Fill(self.sv.adText, self:Values(state))
    if #text > MAX_CHAT then text = text:sub(1, MAX_CHAT) end
    for i = 1, GetNumGuilds() do
        local guildId = GetGuildId(i)
        if self.sv.adGuilds[guildId] then posts[#posts + 1] = { channel = GUILD_CHANNELS[i], guildId = guildId, text = text } end
    end
    if #posts == 0 then
        U.Print("Tick the guilds to advertise in under Events settings (Guilds to advertise in).")
        return
    end
    self.adQueue = { posts = posts, total = #posts }
    EVENT_MANAGER:UnregisterForEvent(CHAT_EVENT_NAME, EVENT_CHAT_MESSAGE_CHANNEL)
    if #posts > 1 then
        local me = GetDisplayName()
        EVENT_MANAGER:RegisterForEvent(CHAT_EVENT_NAME, EVENT_CHAT_MESSAGE_CHANNEL, function(_, channelType, _, _, _, fromDisplayName)
            local queue = self.adQueue
            if queue and queue.current and channelType == queue.current.channel and fromDisplayName == me then
                zo_callLater(function() if self.adQueue == queue and not CHAT_SYSTEM:IsTextEntryOpen() then self:NextAd() end end, 300)
            end
        end)
    end
    self:NextAd()
end

function Events:NextAd()
    local queue = self.adQueue
    local post = table.remove(queue.posts, 1)
    if not post then
        self.adQueue = nil
        EVENT_MANAGER:UnregisterForEvent(CHAT_EVENT_NAME, EVENT_CHAT_MESSAGE_CHANNEL)
        return
    end
    queue.current = post
    if #queue.posts == 0 then
        self.adQueue = nil
        EVENT_MANAGER:UnregisterForEvent(CHAT_EVENT_NAME, EVENT_CHAT_MESSAGE_CHANNEL)
    end
    StartChatInput(post.text, post.channel)
    U.Print("Ad for %s is in the chat box (%d of %d). Press Enter to post it%s.", U.GuildName(post.guildId),
        queue.total - #queue.posts, queue.total, #queue.posts > 0 and "; the next guild's follows" or "")
end

function Events:CopyForDiscord()
    local state = self:State()
    if not state then U.Print("Paste a sesh sign-up post first."); return end
    local ev = state.ev
    local lines = { string.format("**%s** is forming up now%s.", ev.title, ev.time and (" (" .. ev.time .. ")") or "") }
    if #state.missing > 0 then
        local names = {}
        for _, info in ipairs(state.missing) do names[#names + 1] = string.format("%s (%s)", info.person.base, info.section.name) end
        lines[#lines + 1] = "Still missing: " .. table.concat(names, ", ") .. ". Are you coming?"
    else
        lines[#lines + 1] = "Everyone who signed up is here."
    end
    local need = self:NeedText(state)
    if need ~= "" then
        lines[#lines + 1] = string.format("Open slots: **%s**%s. Whisper %s in game for an invite.", need,
            (ev.minCP or 0) > 0 and string.format(", CP %d+", ev.minCP) or "", GetDisplayName())
    end
    local Report = GT.Report
    Report.exportParts = { table.concat(lines, "\n") }
    Report.exportIndex = 1
    if FuryGMTExport:IsHidden() then SCENE_MANAGER:ShowTopLevel(FuryGMTExport) end
    Report:ShowExportPart(0)
    U.Print("The Discord message is in the copy window. Click Select all, press Ctrl+C, and paste it into Discord.")
end

-- Group Finder ---------------------------------------------------------------------------

-- Picks the trial in the Group Finder that the post names (full name, or vSS / nSS style
-- short names), and normal or veteran. Sets the draft's category and options. Returns
-- "Sunspire (Normal)" or nil when no trial is named.
function Events:PickTrial(ev)
    local text = zo_strlower(ev.title .. "\n" .. table.concat(ev.desc, "\n"))
    local flat = Norm(text)
    local veteran = (text:find("veteran") or text:find("%f[%a]vet%f[%A]")) and true or false
    local aliases = {}
    for word in text:gmatch("%a+") do
        local prefix, rest = word:sub(1, 1), word:sub(2)
        if (prefix == "v" or prefix == "n") and TRIAL_ALIASES[rest] then
            aliases[#aliases + 1] = TRIAL_ALIASES[rest]
            if prefix == "v" then veteran = true end
        elseif #word >= 3 and TRIAL_ALIASES[word] then
            aliases[#aliases + 1] = TRIAL_ALIASES[word]
        end
    end
    if text:find("normal") then veteran = false end

    SetGroupFinderUserTypeGroupListingCategory(DRAFT, GROUP_FINDER_CATEGORY_TRIAL)
    UpdateGroupFinderUserTypeGroupListingOptions(DRAFT)
    -- Trials list the difficulty as the first choice (Normal, Veteran) and the trial second.
    local numDifficulties = GetGroupFinderUserTypeGroupListingNumPrimaryOptions(DRAFT)
    local difficulty = (veteran and numDifficulties >= 2) and 2 or 1
    for i = 1, numDifficulties do
        local name = zo_strlower(GetGroupFinderUserTypeGroupListingPrimaryOptionByIndex(DRAFT, i) or "")
        if (veteran and name:find("veteran")) or (not veteran and name:find("normal")) then difficulty = i end
    end
    SetGroupFinderUserTypeGroupListingPrimaryOption(DRAFT, difficulty)
    UpdateGroupFinderUserTypeGroupListingOptions(DRAFT)

    local options = {}
    for i = 1, GetGroupFinderUserTypeGroupListingNumSecondaryOptions(DRAFT) do
        local name = GetGroupFinderUserTypeGroupListingSecondaryOptionByIndex(DRAFT, i) or ""
        options[i] = { name = name, key = Norm((name:gsub("%b()", ""))) }
    end
    local pick
    for i, option in ipairs(options) do
        if not pick and #option.key >= 4 and flat:find(option.key, 1, true) then pick = i end
    end
    for _, alias in ipairs(aliases) do
        for i, option in ipairs(options) do
            if not pick and option.key:find(alias, 1, true) then pick = i end
        end
    end
    if not pick then return nil end
    SetGroupFinderUserTypeGroupListingSecondaryOption(DRAFT, pick)
    UpdateGroupFinderUserTypeGroupListingOptions(DRAFT)
    local primary = GetGroupFinderUserTypeGroupListingPrimaryOptionByIndex(DRAFT, difficulty)
    return string.format("%s (%s)", options[pick].name, primary ~= "" and primary or (veteran and "Veteran" or "Normal"))
end

-- Desired players per role for the listing: the post's limit for that role, never fewer than
-- the group already has, and never more than the listing's size.
function Events:ListingRoles(ev)
    local numRoles = GetGroupFinderUserTypeGroupListingNumRoles(DRAFT)
    local desired, total, any = {}, 0, false
    for _, section in ipairs(ev.sections) do
        local role = ROLE_OF_KIND[section.kind]
        if role and section.max then
            desired[role] = (desired[role] or 0) + section.max
            any = true
        end
    end
    if not any then return nil, numRoles end
    for _, role in ipairs({ LFG_ROLE_TANK, LFG_ROLE_HEAL, LFG_ROLE_DPS }) do
        desired[role] = math.max(desired[role] or 0, GetGroupFinderUserTypeGroupListingAttainedRoleCount(DRAFT, role))
        total = total + desired[role]
    end
    for _, role in ipairs({ LFG_ROLE_DPS, LFG_ROLE_HEAL, LFG_ROLE_TANK }) do
        local floor = GetGroupFinderUserTypeGroupListingAttainedRoleCount(DRAFT, role)
        while total > numRoles and desired[role] > floor do
            desired[role] = desired[role] - 1
            total = total - 1
        end
    end
    return desired, numRoles
end

function Events:ListingDescription(state)
    local ev = state.ev
    local parts = {}
    local need = self:NeedText(state)
    if need ~= "" then parts[#parts + 1] = "Need " .. need .. "." end
    if ev.time then parts[#parts + 1] = ev.time .. "." end
    if (ev.minCP or 0) > 0 then parts[#parts + 1] = string.format("CP %d+.", ev.minCP) end
    if #ev.requirements > 0 then parts[#parts + 1] = "Required: " .. table.concat(ev.requirements, ", ") .. "." end
    parts[#parts + 1] = "Whisper " .. GetDisplayName() .. " with questions."
    return table.concat(parts, " ")
end

function Events:AskListing()
    local state = self:State()
    if not state then U.Print("Paste a sesh sign-up post first."); return end
    if HasGroupListingForUserType(GROUP_FINDER_GROUP_LISTING_USER_TYPE_CREATED_GROUP_LISTING) then
        U.Print("You already have a Group Finder listing. Change or remove it in the game's Group Finder window.")
        return
    end
    if not IsUnitSoloOrGroupLeader("player") then
        U.Print("Only the group leader can create a Group Finder listing.")
        return
    end
    local ev = state.ev
    local trial = self:PickTrial(ev)
    if not trial then SetGroupFinderUserTypeGroupListingCategory(DRAFT, GROUP_FINDER_CATEGORY_CUSTOM) end
    local description = self:ListingDescription(state)
    local maxDesc = GROUP_FINDER_GROUP_LISTING_DESCRIPTION_MAX_LENGTH
    if #description > maxDesc then description = description:sub(1, maxDesc) end
    local need = self:NeedText(state)
    self:OpenInput({
        title = "Group Finder listing",
        hint = string.format("First line: the listing's title (letters, up to %d characters). The rest: its description (up to %d characters). %s%s%s Edit it, then press Create listing.",
            GROUP_FINDER_GROUP_LISTING_TITLE_MAX_LENGTH, maxDesc,
            trial and ("Activity: " .. trial .. ". ") or "Activity: Custom (no trial named in the post). ",
            (ev.minCP or 0) > 0 and string.format("Requires CP %d. ", ev.minCP) or "",
            need ~= "" and ("Roles wanted: " .. need .. ".") or ""),
        okLabel = "Create listing",
        okTip = "Creates the Group Finder listing. Accept applicants in the game's Group Finder window.",
        text = Printable(ev.title):sub(1, GROUP_FINDER_GROUP_LISTING_TITLE_MAX_LENGTH) .. "\n" .. description,
        onOk = function(text) self:CreateListing(text) end,
    })
end

function Events:CreateListing(text)
    local state = self:State()
    if not state then return end
    local ev = state.ev
    local title, description = text:match("^([^\n]*)\n?(.*)$")
    title = Trim(title)
    description = Trim(description):sub(1, GROUP_FINDER_GROUP_LISTING_DESCRIPTION_MAX_LENGTH)
    if select("#", IsValidGroupFinderListingTitle(title)) > 0 or #title > GROUP_FINDER_GROUP_LISTING_TITLE_MAX_LENGTH then
        U.Print("The Group Finder won't take \"%s\" as a title. Use letters and spaces only, end with a letter, and keep it short.", title)
        return
    end
    local trial = self:PickTrial(ev)
    if not trial then
        SetGroupFinderUserTypeGroupListingCategory(DRAFT, GROUP_FINDER_CATEGORY_CUSTOM)
        UpdateGroupFinderUserTypeGroupListingOptions(DRAFT)
        -- Custom listings pick a size: the smallest that fits everyone the post asks for.
        local wanted = 0
        for _, section in ipairs(ev.sections) do
            if section.kind ~= "standby" and section.kind ~= "out" then wanted = wanted + (section.max or #section.people) end
        end
        wanted = math.max(wanted, state.groupCount + 1)
        for size = GetGroupFinderUserTypeGroupSizeIterationBegin(DRAFT), GetGroupFinderUserTypeGroupSizeIterationEnd(DRAFT) do
            SetGroupFinderUserTypeGroupListingGroupSize(DRAFT, size)
            if GetGroupFinderUserTypeGroupListingNumRoles(DRAFT) >= wanted then break end
        end
    end
    SetGroupFinderUserTypeGroupListingTitle(DRAFT, title)
    SetGroupFinderUserTypeGroupListingDescription(DRAFT, description)
    local minCP = ev.minCP or 0
    SetGroupFinderUserTypeGroupListingRequiresChampion(DRAFT, minCP > 0)
    if minCP > 0 then SetGroupFinderUserTypeGroupListingChampionPoints(DRAFT, minCP) end
    local desired, numRoles = self:ListingRoles(ev)
    SetGroupFinderUserTypeGroupListingEnforceRoles(DRAFT, desired ~= nil)
    if desired then
        local total = 0
        for _, role in ipairs({ LFG_ROLE_TANK, LFG_ROLE_HEAL, LFG_ROLE_DPS }) do
            SetGroupFinderUserTypeGroupListingRoleCount(DRAFT, role, desired[role])
            total = total + desired[role]
        end
        SetGroupFinderUserTypeGroupListingRoleCount(DRAFT, LFG_ROLE_INVALID, math.max(0, numRoles - total))
    end
    self.listingPending = true
    RequestCreateGroupListing()
    U.Print("Asking the game to create the Group Finder listing \"%s\"...", title)
end

function Events:OnListingResult(result)
    if not self.listingPending then return end
    self.listingPending = false
    if result == GROUP_FINDER_ACTION_RESULT_SUCCESS then
        U.Print("Your Group Finder listing is up. Accept applicants in the game's Group Finder window.")
    else
        U.Print("The Group Finder listing wasn't created: %s", GetString("SI_GROUPFINDERACTIONRESULT", result))
    end
end

-- Settings ----------------------------------------------------------------------------------

function Events:BuildSettings(options)
    self.panel = GT.Settings:AddPage("Events", "Events", self:SettingsControls(), true)
    GT.Settings:AddPointer(options, "Events", "Sign-ups from sesh event posts, missing people, guild ads and Group Finder listings are on their own page: \"Fury's Guild Management - Events\" in the Add-Ons list.",
        function() self:OpenSettings() end)
end

function Events:OpenSettings()
    LibAddonMenu2:OpenToPanel(self.panel)
end

function Events:SettingsControls()
    local sv = self.sv
    local controls = {
        { type = "description", text = "Copy a sesh event post in Discord and paste it into the Events tab (/gt events > Paste sign-ups). The tab shows each sign-up next to who is in your group, and lets you whisper, invite or mail the missing people, advertise the open slots in your guilds, and create a Group Finder listing. Nothing is sent without a click or Enter from you." },
        { type = "checkbox", name = "Turn on Events", tooltip = "Shows the Events tab and keeps it up to date while people join your group or log in.",
          getFunc = function() return sv.enabled end, setFunc = function(v) self:SetEnabled(v) end, default = false },
        { type = "description", title = "Texts", text = "You can use {name} (their Discord name), {event} (the event title), {time}, {need} (open slots, like \"1 tank, 2 DPS\"), {cp} (\" (CP 160+)\" when the post has a CP requirement) and {me} (your @account)." },
        { type = "editbox", name = "Whisper", tooltip = "Goes in the chat box when you right-click a sign-up > Whisper. You press Enter.",
          getFunc = function() return sv.whisperText end, setFunc = function(v) sv.whisperText = v end, default = Events.defaults.whisperText },
        { type = "editbox", name = "Mail subject", tooltip = "For right-click > Mail. The mail opens filled in; you press Send.",
          getFunc = function() return sv.mailSubject end, setFunc = function(v) sv.mailSubject = v end, default = Events.defaults.mailSubject },
        { type = "editbox", name = "Mail text", isMultiline = true, tooltip = "For right-click > Mail.",
          getFunc = function() return sv.mailText end, setFunc = function(v) sv.mailText = v end, default = Events.defaults.mailText },
        { type = "editbox", name = "Guild ad", tooltip = "Advertise in guilds puts this in each ticked guild's chat box, one after another. Up to 350 characters.",
          getFunc = function() return sv.adText end, setFunc = function(v) sv.adText = v end, default = Events.defaults.adText },
        { type = "header", name = "Guilds to advertise in" },
    }
    for _, guildId in ipairs(U.GetGuildIds()) do
        local gid = guildId
        controls[#controls + 1] = { type = "checkbox", name = U.GuildName(gid), tooltip = "Advertise in guilds puts the ad in this guild's chat box.",
            getFunc = function() return sv.adGuilds[gid] == true end, setFunc = function(v) sv.adGuilds[gid] = v or nil end, default = false }
    end
    controls[#controls + 1] = { type = "header", name = "Discord names" }
    controls[#controls + 1] = { type = "button", name = "Forget all matched accounts", width = "half", isDangerous = true,
        tooltip = "Forgets every account you picked for a Discord name with right-click > Set account. Matches by name still work.",
        warning = "Forgets every Discord name to account match you set.",
        func = function() sv.map = {}; self.cache = nil; GT.Report:RefreshIfShown(); U.Print("Forgot every matched account.") end }
    return controls
end
