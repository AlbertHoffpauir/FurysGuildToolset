-- Recruiting: zone ads with a cooldown per zone, a zone tour that moves on when you post,
-- whisper leads, "Invite to" on player names in chat, join notices, and welcomes.
--
-- Written from the ESO API and the ZOS UI source. What the game lets an addon do here:
--   Chat: an addon can't send chat. Ads and welcomes are put into the chat box with
--   StartChatInput and you press Enter.
--   Travel: JumpToGuildMember, JumpToFriend and RequestJumpToHouse are normal API calls.
--   The tour only travels after you post the ad yourself (or press the Next zone key), so
--   every jump comes from a keypress of yours. There is no unattended loop.
--   Invites: GuildInvite only runs when you click Invite. Whispers never invite anyone
--   on their own.
--   Mail: the welcome mail opens filled in for you to send, unless you turn on
--   "Send automatically" (sent through GT.Actions.SendMailNow, like the demotion mail).
-- Every part starts off on a new install.

local GT = FuryGMT
local U = GT.Util
local A = GT.Actions

local Recruit = GT:RegisterModule("recruit", {})

local GUILD_MAX_MEMBERS = 500
local MAX_CHAT = 350
local LINK_TYPE = "furygmt"
local LEAD_KEEP_SECONDS = 24 * 3600
local INVITE_KEEP_SECONDS = 7 * 86400
local MAIL_KEEP_SECONDS = 3 * 86400
local TRAVEL_TIMEOUT_MS = 25000

local GUILD_CHANNELS = {
    CHAT_CHANNEL_GUILD_1, CHAT_CHANNEL_GUILD_2, CHAT_CHANNEL_GUILD_3,
    CHAT_CHANNEL_GUILD_4, CHAT_CHANNEL_GUILD_5,
}

ZO_CreateStringId("SI_BINDING_NAME_FURYGMT_RECRUIT_AD", "Recruit: put the zone ad in chat")
ZO_CreateStringId("SI_BINDING_NAME_FURYGMT_RECRUIT_TOUR", "Recruit: start/stop the zone tour")
ZO_CreateStringId("SI_BINDING_NAME_FURYGMT_RECRUIT_NEXT", "Recruit: travel to the next ready zone")

Recruit.defaults = {
    -- Every part starts off on a new install (Albert's rule).
    enabled = false,          -- zone ads, cooldowns and the zone tour
    guildId = 0,              -- guild you recruit for; 0 = your first guild
    ads = {},                 -- [guildId] = zone ad text ({guild} = guild name)
    cooldownMinutes = 15,     -- wait this long before posting in the same zone again
    useFriends = true,        -- travel through friends as well as guildmates
    useHouses = true,         -- travel to a house you own when nobody is in the zone
    playerMenu = false,       -- "Invite to (guild)" when you right-click a name in chat
    leads = false,            -- whispers with a keyword become leads
    keywords = "inv, invite, join, guild",
    joinNotice = false,       -- chat line when someone joins
    nearlyFull = 10,          -- warn when this many slots or fewer are open (0 = never)
    traderWarning = true,     -- the join line also says when the guild has no trader
    welcomeChat = false,      -- put a welcome in the guild chat box when someone joins
    welcomeWho = "mine",      -- "mine" = people you invited or accepted, "all" = everyone
    welcomeText = "Welcome to {guild}, {new}! Glad to have you here. Check the guild MOTD for our rules and say hi any time.",
    welcomeCooldownMinutes = 5,
    welcomeMail = false,      -- welcome mail to new members who were offline when they joined
    welcomeMailAuto = false,  -- send it without opening the mail window
    mailSubject = "Welcome to {guild}!",
    mailBody = "Hi {new},\n\nWelcome to {guild}! We're glad you joined.\n\nCheck the guild MOTD for our rules and links, say hi in guild chat when you're on, and ask an officer if you need anything.\n\nSee you in game!",
    posted = {},              -- [zoneId] = GetTimeStamp() of your last ad there
    skipZones = {},           -- [zoneId] = true: the tour never goes there
    leadList = {},            -- ["@name"] = { at =, text = }
    invited = {},             -- ["guildId:@name"] = when you invited them
    mailWaiting = {},         -- ["guildId:@name"] = { guildId =, name =, at = }
}

-- Settings -------------------------------------------------------------------

function Recruit:Initialize(sv)
    self.sv = sv
    self.lastWelcome = {}
    self:Prune()
    self:RegisterTab()
    EVENT_MANAGER:RegisterForEvent("FuryGMTRecruit", EVENT_CHAT_MESSAGE_CHANNEL, function(_, channel, _, text, _, fromDisplayName)
        self:OnChat(channel, text, fromDisplayName)
    end)
    EVENT_MANAGER:RegisterForEvent("FuryGMTRecruit", EVENT_GUILD_MEMBER_ADDED, function(_, guildId, displayName)
        self:OnMemberAdded(guildId, displayName)
    end)
    LINK_HANDLER:RegisterCallback(LINK_HANDLER.LINK_MOUSE_UP_EVENT, self.OnLink, self)
    LINK_HANDLER:RegisterCallback(LINK_HANDLER.LINK_CLICKED_EVENT, self.OnLink, self)
    ZO_PostHook(CHAT_SYSTEM, "ShowPlayerContextMenu", function(_, playerName, rawName)
        self:AddPlayerMenu(playerName, rawName)
    end)
end

function Recruit:OnPlayerActivated()
    self:BuildZoneList()
    -- Every load screen (the tour waits for the one after a jump).
    EVENT_MANAGER:RegisterForEvent("FuryGMTRecruitArrive", EVENT_PLAYER_ACTIVATED, function() self:OnArrived() end)
end

-- Roster history tells us who invited or accepted whom; only needed for welcomes.
function Recruit:GetHistoryCategories()
    if not (self.sv.welcomeChat or self.sv.welcomeMail) then return {} end
    return { GUILD_HISTORY_EVENT_CATEGORY_ROSTER }
end

function Recruit:AnyOn()
    local sv = self.sv
    return sv.enabled or sv.leads or sv.playerMenu or sv.joinNotice or sv.welcomeChat or sv.welcomeMail
end

function Recruit:Prune()
    local now = GetTimeStamp()
    for name, lead in pairs(self.sv.leadList) do
        if now - lead.at > LEAD_KEEP_SECONDS then self.sv.leadList[name] = nil end
    end
    for key, at in pairs(self.sv.invited) do
        if now - at > INVITE_KEEP_SECONDS then self.sv.invited[key] = nil end
    end
    for key, job in pairs(self.sv.mailWaiting) do
        if now - job.at > MAIL_KEEP_SECONDS then self.sv.mailWaiting[key] = nil end
    end
end

-- The guild you recruit for: the one picked in settings, or your first guild.
function Recruit:GuildId()
    local wanted = self.sv.guildId
    if wanted ~= 0 and U.IsPlayerInGuild(wanted) then return wanted end
    return GetGuildId(1)
end

local function GuildChannel(guildId)
    for i = 1, GetNumGuilds() do
        if GetGuildId(i) == guildId then return GUILD_CHANNELS[i] end
    end
end

local function Fill(text, guildId, name)
    text = (text or ""):gsub("{guild}", function() return U.GuildName(guildId) end)
    return (text:gsub("{new}", function() return name or "" end))
end

local function Link(label, action, ...)
    local data = table.concat({ LINK_TYPE, action, ... }, ":")
    return string.format("|c66CCFF|H1:%s|h[%s]|h|r", data, label)
end

-- Guild slots ----------------------------------------------------------------

-- Open slots, counting invites that haven't been answered yet (they hold a slot too).
function Recruit:OpenSlots(guildId)
    local numMembers, _, _, numInvitees = GetGuildInfo(guildId)
    return GUILD_MAX_MEMBERS - numMembers - numInvitees, numMembers
end

function Recruit:HasTrader(guildId)
    local kiosk = GetGuildOwnedKioskInfo(guildId)
    return kiosk ~= nil and kiosk ~= ""
end

-- Zones ----------------------------------------------------------------------

-- Every overland zone on the world map's zone list that you can travel to.
function Recruit:BuildZoneList()
    local zones, seen = {}, {}
    for i = 1, GetNumMaps() do
        local _, mapType, mapContentType, zoneIndex = GetMapInfoByIndex(i)
        if mapType == MAPTYPE_ZONE and mapContentType == MAP_CONTENT_NONE and zoneIndex and zoneIndex > 0 then
            local zoneId = GetZoneId(zoneIndex)
            if zoneId ~= 0 and GetParentZoneId(zoneId) == zoneId and not seen[zoneId] and CanJumpToPlayerInZone(zoneId) then
                seen[zoneId] = true
                zones[#zones + 1] = { id = zoneId, name = zo_strformat("<<C:1>>", GetZoneNameById(zoneId)) }
            end
        end
    end
    self.zones = zones
end

function Recruit:CurrentZoneId()
    return GetParentZoneId(GetZoneId(GetUnitZoneIndex("player")))
end

function Recruit:ZoneName(zoneId)
    return zo_strformat("<<C:1>>", GetZoneNameById(zoneId))
end

-- Seconds left on a zone's cooldown, 0 when it's ready.
function Recruit:CooldownLeft(zoneId)
    local at = self.sv.posted[zoneId]
    if not at then return 0 end
    return math.max(0, self.sv.cooldownMinutes * 60 - (GetTimeStamp() - at))
end

-- Houses you own, by the zone they're in: [zoneId] = { houseId =, name = }.
function Recruit:OwnedHouses()
    local houses = {}
    for i = 1, GetTotalCollectiblesByCategoryType(COLLECTIBLE_CATEGORY_TYPE_HOUSE) do
        local collectibleId = GetCollectibleIdFromType(COLLECTIBLE_CATEGORY_TYPE_HOUSE, i)
        if IsCollectibleUnlocked(collectibleId) then
            local houseId = GetCollectibleReferenceId(collectibleId)
            local zoneId = GetParentZoneId(GetHouseFoundInZoneId(houseId))
            if not houses[zoneId] then
                houses[zoneId] = { houseId = houseId, name = zo_strformat("<<1>>", GetCollectibleName(collectibleId)) }
            end
        end
    end
    return houses
end

-- Someone to travel to in a zone: a guildmate, then a friend, then a house you own.
-- Returns { kind =, name =, houseId = } or nil.
function Recruit:FindWayInto(zoneId, houses)
    local me = GetDisplayName()
    for _, guildId in ipairs(U.GetGuildIds()) do
        for i = 1, GetNumGuildMembers(guildId) do
            local name, _, _, status = GetGuildMemberInfo(guildId, i)
            if status ~= PLAYER_STATUS_OFFLINE and name ~= me then
                local _, _, _, _, _, _, _, memberZoneId = GetGuildMemberCharacterInfo(guildId, i)
                if GetParentZoneId(memberZoneId) == zoneId then return { kind = "guild", name = name } end
            end
        end
    end
    if self.sv.useFriends then
        for i = 1, GetNumFriends() do
            local name, _, status = GetFriendInfo(i)
            if status ~= PLAYER_STATUS_OFFLINE then
                local _, _, _, _, _, _, _, friendZoneId = GetFriendCharacterInfo(i)
                if GetParentZoneId(friendZoneId) == zoneId then return { kind = "friend", name = name } end
            end
        end
    end
    if self.sv.useHouses and houses[zoneId] then
        return { kind = "house", name = houses[zoneId].name, houseId = houses[zoneId].houseId }
    end
    return nil
end

-- The next zone in list order after the one you're in that's ready, not skipped, and has a
-- way in. Returns zone, way.
function Recruit:NextReadyZone()
    if not self.zones then self:BuildZoneList() end
    local here = self:CurrentZoneId()
    local start = 0
    for i, zone in ipairs(self.zones) do
        if zone.id == here then start = i end
    end
    local houses = self.sv.useHouses and self:OwnedHouses() or {}
    local count = #self.zones
    for step = 1, count do
        local zone = self.zones[(start + step - 1) % count + 1]
        if zone.id ~= here and not self.sv.skipZones[zone.id] and self:CooldownLeft(zone.id) == 0 then
            local way = self:FindWayInto(zone.id, houses)
            if way then return zone, way end
        end
    end
    return nil
end

-- Zone ad --------------------------------------------------------------------

function Recruit:AdText()
    local guildId = self:GuildId()
    return Fill(zo_strtrim(self.sv.ads[guildId] or ""), guildId)
end

-- Puts the ad in the zone chat box. Asks first if you posted in this zone too recently.
function Recruit:PasteAd(skipCheck)
    if not self.sv.enabled then
        U.Print("Zone ads are turned off. Turn on Recruiting in /gtsettings.")
        return
    end
    local ad = self:AdText()
    if ad == "" then
        U.Print("You haven't written a zone ad for %s yet. Write one in /gtsettings under Recruiting.", U.GuildName(self:GuildId()))
        return
    end
    local zoneId = self:CurrentZoneId()
    local left = self:CooldownLeft(zoneId)
    if left > 0 and not skipCheck then
        A.Confirm("Zone ad", zo_strformat("You posted your ad in <<1>> <<2>>. Its cooldown has <<3>> left.\n\nPut the ad in chat anyway?",
            self:ZoneName(zoneId), U.FormatAgo(self.sv.posted[zoneId]), U.FormatDuration(left)), function() self:PasteAd(true) end)
        return
    end
    if #ad > MAX_CHAT then
        U.Print("Your ad is %d characters. ESO cuts chat at %d.", #ad, MAX_CHAT)
    end
    StartChatInput(ad, CHAT_CHANNEL_ZONE)
end

-- Your own zone message that matches the ad starts that zone's cooldown, and moves the tour on.
function Recruit:OnChat(channel, text, fromDisplayName)
    local me = GetDisplayName()
    if channel == CHAT_CHANNEL_ZONE and fromDisplayName == me then
        if not self.sv.enabled then return end
        local ad = self:AdText()
        if ad == "" or zo_strtrim(text or "") ~= ad then return end
        self.sv.posted[self:CurrentZoneId()] = GetTimeStamp()
        GT.Report:RefreshIfShown()
        if self.touring then self:TravelNext() end
    elseif channel == CHAT_CHANNEL_WHISPER and fromDisplayName ~= me and self.sv.leads then
        self:CheckLead(fromDisplayName, text or "")
    end
end

-- Zone tour ------------------------------------------------------------------
-- Start: you get the ad in this zone's chat box (or travel on if this zone is on cooldown).
-- Each time you press Enter on the ad, you travel to the next ready zone, and on arrival the
-- ad is in the chat box again. Nothing happens until you press Enter.

function Recruit:ToggleTour()
    if self.touring then self:StopTour() else self:StartTour() end
end

function Recruit:StartTour()
    if not self.sv.enabled then
        U.Print("Zone ads are turned off. Turn on Recruiting in /gtsettings.")
        return
    end
    if self:AdText() == "" then
        U.Print("You haven't written a zone ad for %s yet. Write one in /gtsettings under Recruiting.", U.GuildName(self:GuildId()))
        return
    end
    self.touring = true
    U.Print("Zone tour started. Press Enter to post the ad; you'll travel to the next ready zone after each post. Use the tour key or /gt tour to stop.")
    local here = self:CurrentZoneId()
    if self:CooldownLeft(here) == 0 and not self.sv.skipZones[here] then
        self:PasteAd(true)
    else
        self:TravelNext()
    end
    GT.Report:RefreshIfShown()
end

function Recruit:StopTour(reason)
    if not self.touring then return end
    self.touring = false
    self.travelTo = nil
    U.Print(reason or "Zone tour stopped.")
    GT.Report:RefreshIfShown()
end

-- One jump. Called by your ad post during a tour, the Next zone key, or a row's menu.
function Recruit:TravelNext()
    local zone, way = self:NextReadyZone()
    if not zone then
        local soonest
        for _, z in ipairs(self.zones) do
            if not self.sv.skipZones[z.id] then
                local left = self:CooldownLeft(z.id)
                if left > 0 and (not soonest or left < soonest) then soonest = left end
            end
        end
        local msg = "No other zone is ready with a guildmate, friend or house of yours in it."
        if soonest then msg = msg .. " The next cooldown ends in " .. U.FormatDuration(soonest) .. "." end
        if self.touring then self:StopTour("Zone tour finished. " .. msg) else U.Print(msg) end
        return
    end
    self:TravelTo(zone, way)
end

function Recruit:TravelTo(zone, way)
    local from = self:CurrentZoneId()
    if way.kind == "house" then
        U.Print("Traveling to %s in %s...", way.name, zone.name)
        RequestJumpToHouse(way.houseId, true)   -- true: arrive outside the house, in the zone
    elseif way.kind == "friend" then
        U.Print("Traveling to %s in %s...", way.name, zone.name)
        JumpToFriend(way.name)
    else
        U.Print("Traveling to %s in %s...", way.name, zone.name)
        JumpToGuildMember(way.name)
    end
    local token = {}
    self.travelTo = { zoneId = zone.id, token = token }
    zo_callLater(function()
        if self.travelTo and self.travelTo.token == token and self:CurrentZoneId() == from then
            self.travelTo = nil
            local why = string.format("Travel to %s didn't happen (cancelled, in combat, or they moved).", zone.name)
            if self.touring then self:StopTour(why .. " Zone tour stopped.") else U.Print(why) end
        end
    end, TRAVEL_TIMEOUT_MS)
end

function Recruit:OnArrived()
    if not self.travelTo then return end
    self.travelTo = nil
    if self.touring then
        -- Give the chat window a moment after the load screen.
        zo_callLater(function() if self.touring then self:PasteAd() end end, 1500)
    end
    GT.Report:RefreshIfShown()
end

function Recruit:TravelToZone(zoneId)
    local houses = self.sv.useHouses and self:OwnedHouses() or {}
    local way = self:FindWayInto(zoneId, houses)
    if not way then
        U.Print("Nobody you can travel to is in %s right now.", self:ZoneName(zoneId))
        return
    end
    self:TravelTo({ id = zoneId, name = self:ZoneName(zoneId) }, way)
end

-- Invites and leads ----------------------------------------------------------

function Recruit:Invite(guildId, name)
    if not U.HasPermission(guildId, GUILD_PERMISSION_INVITE) then
        U.Print("Your rank in %s can't invite.", U.GuildName(guildId))
        return
    end
    if U.IsMember(guildId, name) then
        U.Print("%s is already in %s.", name, U.GuildName(guildId))
        return
    end
    GuildInvite(guildId, name)
    self.sv.invited[guildId .. ":" .. name] = GetTimeStamp()
    self.sv.leadList[name] = nil
    U.Print("Invited %s to %s.", name, U.GuildName(guildId))
    GT.Report:RefreshIfShown()
end

local function MatchesKeyword(text, keyword)
    if keyword:find("%w") then
        local escaped = keyword:gsub("(%W)", "%%%1")
        return text:find("%f[%w]" .. escaped .. "%f[%W]") ~= nil
    end
    return zo_strtrim(text) == keyword   -- a keyword like "+" counts only on its own
end

function Recruit:CheckLead(name, text)
    local lower = zo_strlower(text)
    local hit
    for keyword in pairs(U.ParseList(self.sv.keywords)) do
        if MatchesKeyword(lower, keyword) then hit = keyword break end
    end
    if not hit then return end
    local guildId = self:GuildId()
    if U.IsMember(guildId, name) then return end
    self.sv.leadList[name] = { at = GetTimeStamp(), text = text }
    U.Print("Lead: %s whispered \"%s\". %s", name, text, Link("Invite to " .. U.GuildName(guildId), "invite", guildId, name))
    GT.Report:RefreshIfShown()
end

-- "Invite to (guild)" on player names in chat, for each guild where you can invite.
function Recruit:AddPlayerMenu(playerName, rawName)
    if not self.sv.playerMenu then return end
    local name = (rawName and rawName:sub(1, 1) == "@") and rawName or playerName
    if not name or name == "" or name == GetDisplayName() then return end
    local added = false
    for _, guildId in ipairs(U.GetGuildIds()) do
        if U.HasPermission(guildId, GUILD_PERMISSION_INVITE) and not U.IsMember(guildId, name) then
            local gid = guildId
            AddMenuItem("Invite to " .. U.GuildName(gid), function() self:Invite(gid, name) end)
            added = true
        end
    end
    if added then ShowMenu() end
end

-- Joins and welcomes ---------------------------------------------------------

function Recruit:OnMemberAdded(guildId, name)
    if not self.sv.joinNotice or name == GetDisplayName() then return end
    if not U.HasPermission(guildId, GUILD_PERMISSION_INVITE) then return end
    local open, numMembers = self:OpenSlots(guildId)
    local line = string.format("%s joined %s. %d/%d members, %d open.", name, U.GuildName(guildId), numMembers, GUILD_MAX_MEMBERS, open)
    if self.sv.nearlyFull > 0 and open <= self.sv.nearlyFull then
        line = line .. (open <= 0 and " |cFF6666The guild is full.|r" or " |cFF6666Nearly full.|r")
    end
    if self.sv.traderWarning and not self:HasTrader(guildId) then
        line = line .. " |cFFCC66No trader hired this week.|r"
    end
    U.Print(line)
end

-- Roster history: who invited and who accepted whom. Live joins get a welcome.
function Recruit:OnHistoryEvent(guildId, category, info, isLive)
    local t, me = info.eventType, GetDisplayName()
    if t == GUILD_HISTORY_ROSTER_EVENT_INVITE then
        if info.actingDisplayName == me and GetTimeStamp() - info.timestampS < INVITE_KEEP_SECONDS then
            self.sv.invited[guildId .. ":" .. info.targetDisplayName] = info.timestampS
        end
    elseif isLive and t == GUILD_HISTORY_ROSTER_EVENT_APPLICATION_ACCEPTED then
        self:Welcome(guildId, info.targetDisplayName, info.actingDisplayName == me)
    elseif isLive and t == GUILD_HISTORY_ROSTER_EVENT_JOIN then
        local key = guildId .. ":" .. info.actingDisplayName
        local mine = self.sv.invited[key] ~= nil
        self.sv.invited[key] = nil
        self:Welcome(guildId, info.actingDisplayName, mine)
    end
end

function Recruit:Welcome(guildId, name, mine)
    if name == GetDisplayName() then return end
    if self.sv.welcomeWho == "mine" and not mine then return end
    local index = GetGuildMemberIndexFromDisplayName(guildId, name)
    if not index then return end
    local _, _, _, status = GetGuildMemberInfo(guildId, index)
    if status ~= PLAYER_STATUS_OFFLINE then
        if self.sv.welcomeChat then self:WelcomeInChat(guildId, name) end
    elseif self.sv.welcomeMail then
        self:WelcomeMail(guildId, name)
    end
end

-- Puts the welcome in the guild's chat box, if you aren't typing and the cooldown is over.
-- Otherwise you get a chat line with a link that does it when you're ready.
function Recruit:WelcomeInChat(guildId, name, fromLink)
    local channel = GuildChannel(guildId)
    if not channel then return end
    local text = Fill(self.sv.welcomeText, guildId, name)
    local recent = self.lastWelcome[guildId] and (GetTimeStamp() - self.lastWelcome[guildId] < self.sv.welcomeCooldownMinutes * 60)
    if fromLink or (not recent and not CHAT_SYSTEM:IsTextEntryOpen()) then
        self.lastWelcome[guildId] = GetTimeStamp()
        StartChatInput(text, channel)
        if not fromLink then U.Print("%s joined %s. The welcome is in the guild chat box; press Enter to post it.", name, U.GuildName(guildId)) end
    else
        U.Print("%s joined %s. %s", name, U.GuildName(guildId), Link("Say welcome", "welcome", guildId, name))
    end
end

function Recruit:MailText(guildId, name)
    return Fill(self.sv.mailSubject, guildId, name), Fill(self.sv.mailBody, guildId, name)
end

function Recruit:WelcomeMail(guildId, name)
    if self.sv.welcomeMailAuto then
        local subject, body = self:MailText(guildId, name)
        A.SendMailNow(name, subject, body, function(ok, why)
            if ok then
                U.Print("Welcome mail sent to %s (%s).", name, U.GuildName(guildId))
            else
                U.Print("Welcome mail to %s failed: %s. %s", name, why or "unknown", Link("Write it", "mail", guildId, name))
                self.sv.mailWaiting[guildId .. ":" .. name] = { guildId = guildId, name = name, at = GetTimeStamp() }
                GT.Report:RefreshIfShown()
            end
        end)
        return
    end
    self.sv.mailWaiting[guildId .. ":" .. name] = { guildId = guildId, name = name, at = GetTimeStamp() }
    U.Print("%s joined %s while offline. %s", name, U.GuildName(guildId), Link("Write welcome mail", "mail", guildId, name))
    GT.Report:RefreshIfShown()
end

function Recruit:OpenWelcomeMail(guildId, name)
    local subject, body = self:MailText(guildId, name)
    self.sv.mailWaiting[guildId .. ":" .. name] = nil
    A.Warn(name, subject, body, "mail")
    GT.Report:RefreshIfShown()
end

-- Chat links: [Invite to ...], [Say welcome], [Write welcome mail].
function Recruit:OnLink(link, button, text, color, linkType, action, guildId, name)
    if linkType ~= LINK_TYPE then return end
    if button ~= MOUSE_BUTTON_INDEX_LEFT then return true end
    -- The game can report one click as both a mouse-up and a click; act once.
    local now = GetGameTimeMilliseconds()
    if self.lastLink == link and now - (self.lastLinkAt or 0) < 500 then return true end
    self.lastLink, self.lastLinkAt = link, now
    guildId = tonumber(guildId)
    if action == "invite" then
        self:Invite(guildId, name)
    elseif action == "welcome" then
        self:WelcomeInChat(guildId, name, true)
    elseif action == "mail" then
        self:OpenWelcomeMail(guildId, name)
    end
    return true
end

-- Recruit tab ----------------------------------------------------------------

function Recruit:TabTitle()
    local n = U.Count(self.sv.leadList) + U.Count(self.sv.mailWaiting)
    return n > 0 and string.format("Recruit (%d)", n) or "Recruit"
end

function Recruit:TabOffText()
    if self:AnyOn() then return nil end
    return "Recruiting is turned off. Turn it on in /gtsettings under Recruiting."
end

function Recruit:TabSummary()
    local guildId = self:GuildId()
    if not guildId or guildId == 0 then return "You aren't in a guild." end
    local open, numMembers = self:OpenSlots(guildId)
    local parts = { string.format("Recruiting for %s: %d/%d members, %d open", U.GuildName(guildId), numMembers, GUILD_MAX_MEMBERS, open) }
    parts[#parts + 1] = string.format("%d pending %s", GetGuildFinderNumGuildApplications(guildId),
        GetGuildFinderNumGuildApplications(guildId) == 1 and "application" or "applications")
    if not self:HasTrader(guildId) then parts[#parts + 1] = "|cFFCC66no trader this week|r" end
    local line = table.concat(parts, ", ") .. "."
    if self.sv.enabled then
        local ready, total = 0, 0
        for _, zone in ipairs(self.zones or {}) do
            if not self.sv.skipZones[zone.id] then
                total = total + 1
                if self:CooldownLeft(zone.id) == 0 then ready = ready + 1 end
            end
        end
        line = line .. string.format("  Zones ready: %d of %d.%s", ready, total, self.touring and "  |c9FD49FTour on.|r" or "")
    end
    return line
end

function Recruit:TabRows()
    local rows = {}
    local guildId = self:GuildId()
    local leads = {}
    for name, lead in pairs(self.sv.leadList) do leads[#leads + 1] = { name = name, lead = lead } end
    table.sort(leads, function(a, b) return a.lead.at > b.lead.at end)
    for _, entry in ipairs(leads) do
        local name = entry.name
        local row = { text = string.format("|c66CCFFLead|r  %s  whispered \"%s\"  %s", name, entry.lead.text, U.FormatAgo(entry.lead.at)),
            tooltip = "Someone whispered one of your keywords." }
        local items = {
            { label = "Invite to " .. U.GuildName(guildId), fn = function() self:Invite(guildId, name) end },
        }
        for _, item in ipairs(GT.Report.ContactItems(name)) do items[#items + 1] = item end
        items[#items + 1] = { label = "Dismiss", fn = function() self.sv.leadList[name] = nil; GT.Report:RefreshIfShown() end }
        rows[#rows + 1] = GT.Report.AddMenu(row, items)
    end
    for key, job in pairs(self.sv.mailWaiting) do
        local row = { text = string.format("|cD4AF37Welcome mail|r  %s joined %s %s", job.name, U.GuildName(job.guildId), U.FormatAgo(job.at)),
            tooltip = "They joined while offline. Write them a welcome mail." }
        rows[#rows + 1] = GT.Report.AddMenu(row, {
            { label = "Write welcome mail", fn = function() self:OpenWelcomeMail(job.guildId, job.name) end },
            { label = "Dismiss", fn = function() self.sv.mailWaiting[key] = nil; GT.Report:RefreshIfShown() end },
        })
    end
    if self.sv.enabled then
        local here = self:CurrentZoneId()
        for _, zone in ipairs(self.zones or {}) do
            local zoneId = zone.id
            local status
            if self.sv.skipZones[zoneId] then
                status = "|c888888skipped|r"
            elseif self:CooldownLeft(zoneId) > 0 then
                status = string.format("posted %s, ready in %s", U.FormatAgo(self.sv.posted[zoneId]), U.FormatDuration(self:CooldownLeft(zoneId)))
            else
                status = "|c9FD49Fready|r" .. (self.sv.posted[zoneId] and (" (posted " .. U.FormatAgo(self.sv.posted[zoneId]) .. ")") or "")
            end
            local row = { text = string.format("Zone  %s%s  %s", zone.name, zoneId == here and " |c66CCFF(you are here)|r" or "", status) }
            local items = {}
            if zoneId == here then
                items[#items + 1] = { label = "Put the ad in chat", fn = function() self:PasteAd() end }
            else
                items[#items + 1] = { label = "Travel here", fn = function() self:TravelToZone(zoneId) end }
            end
            if self.sv.posted[zoneId] then
                items[#items + 1] = { label = "Clear cooldown", fn = function() self.sv.posted[zoneId] = nil; GT.Report:RefreshIfShown() end }
            end
            if self.sv.skipZones[zoneId] then
                items[#items + 1] = { label = "Include in the tour", fn = function() self.sv.skipZones[zoneId] = nil; GT.Report:RefreshIfShown() end }
            else
                items[#items + 1] = { label = "Skip in the tour", fn = function() self.sv.skipZones[zoneId] = true; GT.Report:RefreshIfShown() end }
            end
            rows[#rows + 1] = GT.Report.AddMenu(row, items)
        end
    end
    return rows
end

function Recruit:TabFooter()
    if not self.sv.enabled then
        return { { label = "Clear leads", tip = "Removes every lead from the list.", fn = function() self:ClearLeads() end } }
    end
    return {
        { label = self.touring and "Stop tour" or "Start tour",
          tip = "Zone tour: the ad goes in the chat box, and each time you press Enter to post it you travel to the next ready zone. Click again to stop.",
          fn = function() self:ToggleTour() end },
        { label = "Put ad in chat", tip = "Puts your zone ad in the chat box. You press Enter to post it. Asks first if this zone is still on cooldown.",
          fn = function() self:PasteAd() end },
        { label = "Next zone", tip = "Travels once to the next ready zone through a guildmate, friend or house of yours.",
          fn = function() self:TravelNext() end },
        { label = "Clear leads", tip = "Removes every lead from the list.", fn = function() self:ClearLeads() end },
    }
end

function Recruit:ClearLeads()
    self.sv.leadList = {}
    GT.Report:RefreshIfShown()
end

function Recruit:TabExportLines()
    local lines = { "Type\tName\tDetail" }
    for name, lead in pairs(self.sv.leadList) do lines[#lines + 1] = table.concat({ "Lead", name, lead.text }, "\t") end
    for _, job in pairs(self.sv.mailWaiting) do lines[#lines + 1] = table.concat({ "Welcome mail", job.name, U.GuildName(job.guildId) }, "\t") end
    if self.sv.enabled then
        for _, zone in ipairs(self.zones or {}) do
            local at = self.sv.posted[zone.id]
            lines[#lines + 1] = table.concat({ "Zone", zone.name, at and U.FormatDate(at) or "never posted" }, "\t")
        end
    end
    return lines
end

function Recruit:RegisterTab()
    GT.Report:RegisterTab({
        id = "recruit",
        tip = "Recruiting: zone ad cooldowns, the zone tour, whisper leads and welcome mails waiting to be written.",
        title = function() return self:TabTitle() end,
        GetOffText = function() return self:TabOffText() end,
        GetSummary = function() return self:TabSummary() end,
        GetRows = function() return self:TabRows() end,
        footer = function() return self:TabFooter() end,
        GetExportLines = function() return self:TabExportLines() end,
    })
end

-- Settings panel -------------------------------------------------------------

function Recruit:BuildSettings(options)
    local sv, d = self.sv, self.defaults
    local names, ids = { "Your first guild" }, { 0 }
    for _, guildId in ipairs(U.GetGuildIds()) do
        names[#names + 1] = U.GuildName(guildId)
        ids[#ids + 1] = guildId
    end
    local refresh = function() GT.Report:RefreshIfShown() end
    local controls = {
        { type = "description", text = "Everything here starts off. Chat is never sent for you: ads and welcomes go into the chat box and you press Enter. Nobody is invited until you click Invite." },
        { type = "header", name = "Zone ads and zone tour" },
        { type = "checkbox", name = "Turn on zone ads and the zone tour",
          tooltip = "Adds zone cooldowns and the zone tour to the Recruit tab (/gt recruit), plus keybinds to put the ad in chat, start or stop the tour, and travel to the next ready zone.",
          getFunc = function() return sv.enabled end, setFunc = function(v) sv.enabled = v; if not v then self:StopTour() end; refresh() end, default = d.enabled },
        { type = "dropdown", name = "Recruit for", choices = names, choicesValues = ids,
          tooltip = "The guild your zone ad, whisper leads and the Recruit tab are for.",
          getFunc = function() return sv.guildId end, setFunc = function(v) sv.guildId = v; refresh() end, default = d.guildId },
        { type = "editbox", name = "Zone ad", isMultiline = true, isExtraWide = true,
          tooltip = "The ad for the guild picked above. {guild} becomes the guild's name. ESO cuts chat at 350 characters.",
          getFunc = function() return sv.ads[self:GuildId()] or "" end, setFunc = function(v) sv.ads[self:GuildId()] = v end, default = "" },
        { type = "slider", name = "Zone cooldown (minutes)", min = 5, max = 120, step = 5,
          tooltip = "After you post the ad in a zone, wait this long before posting there again. The tour skips zones on cooldown.",
          getFunc = function() return sv.cooldownMinutes end, setFunc = function(v) sv.cooldownMinutes = v; refresh() end, default = d.cooldownMinutes },
        { type = "checkbox", name = "Travel through friends too", tooltip = "Besides guildmates, the tour can travel to friends in a zone.",
          getFunc = function() return sv.useFriends end, setFunc = function(v) sv.useFriends = v end, default = d.useFriends },
        { type = "checkbox", name = "Travel to my houses when nobody is there", tooltip = "If no guildmate or friend is in a zone, the tour travels to a house you own there (you arrive outside).",
          getFunc = function() return sv.useHouses end, setFunc = function(v) sv.useHouses = v end, default = d.useHouses },
        { type = "header", name = "Invites" },
        { type = "checkbox", name = "Invite from player names in chat",
          tooltip = "Right-click a player's name in chat for \"Invite to (guild)\", for each guild where your rank can invite.",
          getFunc = function() return sv.playerMenu end, setFunc = function(v) sv.playerMenu = v end, default = d.playerMenu },
        { type = "checkbox", name = "Whisper leads",
          tooltip = "When someone whispers one of the keywords below, you get a chat line with an Invite link and a row on the Recruit tab. Nobody is invited until you click.",
          getFunc = function() return sv.leads end, setFunc = function(v) sv.leads = v; refresh() end, default = d.leads },
        { type = "editbox", name = "Lead keywords",
          tooltip = "Separated by commas. Whole words only, upper or lower case. A keyword like + counts only when it's the whole whisper.",
          getFunc = function() return sv.keywords end, setFunc = function(v) sv.keywords = v end, default = d.keywords },
        { type = "header", name = "New members" },
        { type = "checkbox", name = "Join notices",
          tooltip = "A chat line when someone joins a guild where you can invite, with the member count and open slots.",
          getFunc = function() return sv.joinNotice end, setFunc = function(v) sv.joinNotice = v end, default = d.joinNotice },
        { type = "slider", name = "Warn when open slots are at or below", min = 0, max = 50, step = 1,
          tooltip = "The join notice says the guild is nearly full. 0 = never.",
          getFunc = function() return sv.nearlyFull end, setFunc = function(v) sv.nearlyFull = v end, default = d.nearlyFull },
        { type = "checkbox", name = "Say when the guild has no trader", tooltip = "The join notice also says when the guild hasn't hired a trader this week.",
          getFunc = function() return sv.traderWarning end, setFunc = function(v) sv.traderWarning = v end, default = d.traderWarning },
        { type = "dropdown", name = "Welcome", choices = { "People I invited or accepted", "Everyone who joins" }, choicesValues = { "mine", "all" },
          tooltip = "Who gets the welcome message and welcome mail below. With several officers online, \"People I invited or accepted\" keeps you from welcoming the same person twice.",
          getFunc = function() return sv.welcomeWho end, setFunc = function(v) sv.welcomeWho = v end, default = d.welcomeWho },
        { type = "checkbox", name = "Welcome message in guild chat", requiresReload = true,
          tooltip = "When a new member joins while online, the welcome goes into that guild's chat box and you press Enter to post it. If you're typing, or the cooldown hasn't ended, you get a [Say welcome] link instead.",
          getFunc = function() return sv.welcomeChat end, setFunc = function(v) sv.welcomeChat = v end, default = d.welcomeChat },
        { type = "editbox", name = "Welcome message", isMultiline = true, isExtraWide = true,
          tooltip = "{new} = the new member's @name, {guild} = the guild's name.",
          getFunc = function() return sv.welcomeText end, setFunc = function(v) sv.welcomeText = v end, default = d.welcomeText },
        { type = "slider", name = "Welcome cooldown (minutes)", min = 0, max = 60, step = 1,
          tooltip = "After a welcome, the next one in the same guild waits this long and comes as a link instead, so a burst of joins doesn't flood guild chat.",
          getFunc = function() return sv.welcomeCooldownMinutes end, setFunc = function(v) sv.welcomeCooldownMinutes = v end, default = d.welcomeCooldownMinutes },
        { type = "checkbox", name = "Welcome mail", requiresReload = true,
          tooltip = "When a new member joins while offline, you get a [Write welcome mail] link and a row on the Recruit tab. The mail opens filled in for you to send.",
          getFunc = function() return sv.welcomeMail end, setFunc = function(v) sv.welcomeMail = v; refresh() end, default = d.welcomeMail },
        { type = "checkbox", name = "Send the welcome mail automatically",
          tooltip = "Sends the welcome mail in the background instead of opening it (normal postage). Waits while you're in combat or busy. If sending fails, you get the link instead.",
          getFunc = function() return sv.welcomeMailAuto end, setFunc = function(v) sv.welcomeMailAuto = v end, default = d.welcomeMailAuto,
          disabled = function() return not sv.welcomeMail end },
        { type = "editbox", name = "Welcome mail subject", tooltip = "{new} = their @name, {guild} = the guild's name.",
          getFunc = function() return sv.mailSubject end, setFunc = function(v) sv.mailSubject = v end, default = d.mailSubject },
        { type = "editbox", name = "Welcome mail text", isMultiline = true, isExtraWide = true, tooltip = "{new} = their @name, {guild} = the guild's name.",
          getFunc = function() return sv.mailBody end, setFunc = function(v) sv.mailBody = v end, default = d.mailBody },
    }
    options[#options + 1] = { type = "submenu", name = "Recruiting", controls = controls }
end

-- Keybinds
function Recruit.KeyAd() Recruit:PasteAd() end
function Recruit.KeyTour() Recruit:ToggleTour() end
function Recruit.KeyNext() if Recruit.sv.enabled then Recruit:TravelNext() else U.Print("Zone ads are turned off. Turn on Recruiting in /gtsettings.") end end
GT.Recruit = Recruit
