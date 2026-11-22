-- Raffle: sells raffle tickets for gold deposited into a guild bank and/or mailed to you, then
-- draws the winners. The guild is optional, so groups that aren't guilds (housing, fashion)
-- can run a mail-only raffle.
--
-- Tickets: the amount alone decides (Albert, 1.6.1). Every gold deposit into the raffle guild's
-- bank, and every mail with gold attached (optionally only with a word in the subject), between
-- the start and the end of the sale buys amount / ticket price tickets, rounded down. The
-- remainder of each payment is dropped, not carried over, and plain donations buy tickets too.
-- Tickets per person stop at the optional cap. Unused gold is shown as "Not used".
-- Tickets can also be added or removed by hand (right-click a row, or /gt raffle add).
--
-- Bank deposits come from LibHistoire through the raffle's own reader, so the first time the
-- raffle is turned on it reads the whole look-back period, and every deposit is kept for
-- 45 days. A raffle can start in the past and still count every deposit since its start.
-- Mail: the game only lists your mail while the mailbox is open, so every time you open it,
-- each mail with gold attached is recorded once (by mail id) with the time it arrived. The
-- draw waits until you have opened the mailbox after the sale ended.
--
-- The draw numbers the tickets 1..N (buyers in order of their first deposit), then picks a
-- random ticket for each prize. With one win per person, tickets of earlier winners are
-- skipped. Results are put in the guild chat box for you to press Enter; nothing is sent
-- automatically.

local GT = FuryGMT
local U = GT.Util

local Raffle = GT:RegisterModule("raffle", {})
GT.Raffle = Raffle

Raffle.historyReader = "raffle"   -- own LibHistoire reader and saved position (see Core/History.lua)

local KEEP_DAYS = 45
local DRAW_DELAY_S = 60           -- wait this long after the sale ends for late history events
local MAX_CHAT = 350
local UPDATE_NAME = "FuryGMTRaffle"

-- Which prize a draw result is for: its own slot, or the draw number for results from before 1.7.0.
local function Slot(res) return res.slot or res.n end

Raffle.defaults = {
    enabled = false,        -- every feature starts off on a new install (Albert, 1.3.0)
    buyNotice = false,      -- chat line when someone buys tickets
    deposits = {},          -- { g =, id =, ts =, who =, amt =, src = "mail" or nil, subj = } bank deposits and gold mails, kept KEEP_DAYS
    raffle = {
        guildId = 0,        -- 0 = no guild (mail-only raffle)
        useBank = true,     -- guild bank gold deposits buy tickets
        useMail = false,    -- gold mailed to you buys tickets
        mailSubject = "",   -- a mail counts only if its subject contains this (blank = any gold mail)
        mailCheckedAt = 0,  -- last time the mailbox was read
        prize = "",
        price = 1000,
        winners = 1,
        maxTickets = 0,     -- 0 = no limit
        oneWin = true,
        startText = "",     -- "YYYY-MM-DD HH:MM" local time; blank = when you click Start sales now
        hours = 72,
        startedAt = nil,    -- set by Start sales now
        endedAt = nil,      -- set by End sales now
        adjust = {},        -- [name] = tickets added (+) or removed (-) by hand
        excluded = {},      -- [name] = true: left out of the draw
        changes = {},       -- { ts =, who =, text = } every change made by hand
        draw = nil,         -- { ts =, total =, results = { { n =, ticket =, who =, from =, to =, tickets =, void = } } }
    },
    past = {},              -- finished raffles (last 20)
}

function Raffle.SeenKey(d)
    if d.src == "mail" then return "mail:" .. d.id end
    return d.g .. ":" .. tostring(d.id)
end

function Raffle:Initialize(sv)
    self.sv = sv
    self.seen = {}
    for _, d in ipairs(sv.deposits) do self.seen[Raffle.SeenKey(d)] = true end
    self:Prune()
    self:RegisterTab()
    if sv.raffle.mailCheckedAt == nil then sv.raffle.mailCheckedAt = 0 end
    -- 1.6.1: the amount alone decides, so mails no longer need "raffle" in the subject (1.6.0's default).
    if (sv.settingsVersion or 1) < 2 then
        if sv.raffle.mailSubject == "raffle" then sv.raffle.mailSubject = "" end
        sv.settingsVersion = 2
    end
    if sv.enabled then
        EVENT_MANAGER:RegisterForUpdate(UPDATE_NAME, 1000, function() self:Tick() end)
        EVENT_MANAGER:RegisterForEvent(UPDATE_NAME, EVENT_MAIL_INBOX_UPDATE, function() self:ScanMail() end)
        EVENT_MANAGER:RegisterForEvent(UPDATE_NAME, EVENT_MAIL_OPEN_MAILBOX, function() self:ScanMail() end)
        EVENT_MANAGER:RegisterForEvent(UPDATE_NAME, EVENT_MAIL_READABLE, function(_, mailId) self:OnMailReadable(mailId) end)
        -- 1.6.2: also record a mail right before its gold is taken, so taking the gold always counts.
        ZO_PreHook("TakeMailAttachedMoney", function(mailId) self:BeforeTakeGold(mailId) end)
        ZO_PreHook("TakeMailAttachments", function(mailId) self:BeforeTakeGold(mailId) end)
    end
end

function Raffle:Prune()
    local cutoff = GetTimeStamp() - KEEP_DAYS * 86400
    local start = self:StartTime()
    if start and start < cutoff then cutoff = start end
    local kept = {}
    for _, d in ipairs(self.sv.deposits) do
        if d.ts >= cutoff then kept[#kept + 1] = d else self.seen[Raffle.SeenKey(d)] = nil end
    end
    self.sv.deposits = kept
end

-- History -------------------------------------------------------------------------

function Raffle:GetHistoryCategories()
    if not self.sv.enabled then return {} end
    return { GUILD_HISTORY_EVENT_CATEGORY_BANKED_CURRENCY }
end

function Raffle:OnHistoryEvent(guildId, category, info, isLive)
    if info.currencyType ~= CURT_MONEY or info.eventType ~= GUILD_HISTORY_BANKED_CURRENCY_EVENT_DEPOSITED then return end
    local key = guildId .. ":" .. tostring(info.eventId)
    if self.seen[key] then return end
    self.seen[key] = true
    local d = { g = guildId, id = info.eventId, ts = info.timestampS, who = info.displayName, amt = info.amount }
    table.insert(self.sv.deposits, d)
    self.tally = nil
    if isLive and self.sv.buyNotice and self:Counts(d) then
        local buyer = self:GetTally().byName[d.who]
        if buyer then
            U.Print("Raffle: %s deposited %s and now has %d %s.", d.who, U.FormatGold(d.amt), buyer.tickets,
                buyer.tickets == 1 and "ticket" or "tickets")
        end
    end
    if isLive then GT.Report:RefreshIfShown() end
end

function Raffle:OnHistoryCaughtUp()
    self.tally = nil
    GT.Report:RefreshIfShown()
end

function Raffle:IsCaughtUp()
    local guildId = self.sv.raffle.guildId
    if not self.sv.raffle.useBank or guildId == 0 then return true end
    return GT.History:IsCaughtUp(GUILD_HISTORY_EVENT_CATEGORY_BANKED_CURRENCY, guildId, self.historyReader)
end

-- Mail ----------------------------------------------------------------------------

-- Records every mail in the inbox that has gold attached (not system mail, not returned, not
-- cash on delivery). Runs each time the mailbox opens or its list changes.
-- Records one mail with gold attached, once (by mail id). money/cod come from the caller,
-- because the inbox list and the opened mail report them through different functions.
function Raffle:RecordMail(mailId, money, cod)
    local key = "mail:" .. Id64ToString(mailId)
    if self.seen[key] or (money or 0) <= 0 or (cod or 0) > 0 then return false end
    local sender, _, subject, _, _, fromSystem, fromCustomerService, returned, _, _, _, _, secsSinceReceived = GetMailItemInfo(mailId)
    if fromSystem or fromCustomerService or returned or not sender or sender == "" then return false end
    self.seen[key] = true
    local d = { g = 0, id = Id64ToString(mailId), src = "mail", ts = GetTimeStamp() - (secsSinceReceived or 0), who = U.NormalizeName(sender), amt = money, subj = subject }
    table.insert(self.sv.deposits, d)
    self.tally = nil
    if self:Counts(d) then
        local buyer = self:GetTally().byName[d.who]
        U.Print("Raffle: counted %s mailed by %s. They now have %d %s.", U.FormatGold(d.amt), d.who, buyer.tickets, buyer.tickets == 1 and "ticket" or "tickets")
    end
    GT.Report:RefreshIfShown()
    return true
end

-- The inbox list, each time the mailbox opens or changes.
function Raffle:ScanMail()
    local mailId = GetNextMailId(nil)
    while mailId do
        local _, _, _, _, _, _, _, _, _, attachedMoney, codAmount = GetMailItemInfo(mailId)
        self:RecordMail(mailId, attachedMoney, codAmount)
        mailId = GetNextMailId(mailId)
    end
    self.sv.raffle.mailCheckedAt = GetTimeStamp()
    if GT.Report.currentTab == "raffle" then GT.Report:RefreshIfShown() end
end

-- An opened mail: its attachment info is certain to be loaded now.
function Raffle:OnMailReadable(mailId)
    local _, money, cod = GetMailAttachmentInfo(mailId)
    self:RecordMail(mailId, money, cod)
    self.sv.raffle.mailCheckedAt = GetTimeStamp()
end

-- Last chance: right before the gold is taken out of a mail (Take, Take all, or another addon).
function Raffle:BeforeTakeGold(mailId)
    if not mailId then return end
    local _, money, cod = GetMailAttachmentInfo(mailId)
    self:RecordMail(mailId, money, cod)
end

-- Times ---------------------------------------------------------------------------

-- "2026-11-23 20:00" (or "2026-11-23 8:00 pm") in your local time -> timestamp, or nil.
function Raffle.ParseTime(text)
    text = zo_strtrim(text or "")
    local y, mo, d, h, mi = text:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)%s+(%d%d?):(%d%d)")
    if not y then return nil end
    h = tonumber(h)
    local ampm = zo_strlower(text):match("([ap])%.?m%.?%s*$")
    if ampm == "p" and h < 12 then h = h + 12 elseif ampm == "a" and h == 12 then h = 0 end
    return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = h, min = tonumber(mi), sec = 0 })
end

function Raffle:StartTime()
    local r = self.sv.raffle
    return Raffle.ParseTime(r.startText) or r.startedAt
end

function Raffle:EndTime()
    local r = self.sv.raffle
    if r.endedAt then return r.endedAt end
    local start = self:StartTime()
    return start and (start + r.hours * 3600) or nil
end

-- "setup", "scheduled", "selling", "closed" or "drawn"
function Raffle:Status()
    local r = self.sv.raffle
    if r.draw then return "drawn" end
    local start, finish = self:StartTime(), self:EndTime()
    if not start then return "setup" end
    local now = GetTimeStamp()
    if now < start then return "scheduled" end
    if now < finish then return "selling" end
    return "closed"
end

local function NiceDate(ts)
    return os.date("%a %b %d, %I:%M %p", ts):gsub(" 0(%d)", " %1")
end

local function NiceLeft(seconds)
    seconds = math.max(0, seconds)
    local d, h, m = math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600), math.floor(seconds % 3600 / 60)
    if d > 0 then return string.format("%dd %dh", d, h) end
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", m)
end

-- "1d 02:03:04", "2:03:04" or "3:04".
local function Clock(seconds)
    seconds = math.max(0, math.floor(seconds))
    local d, h, m, sec = math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600), math.floor(seconds % 3600 / 60), seconds % 60
    if d > 0 then return string.format("%dd %02d:%02d:%02d", d, h, m, sec) end
    if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
    return string.format("%d:%02d", m, sec)
end

-- The countdown for the tab button and the top line, or nil when nothing is counting down.
function Raffle:Countdown()
    local status = self:Status()
    local now = GetTimeStamp()
    if status == "selling" then return "ends in " .. Clock(self:EndTime() - now) end
    if status == "scheduled" then return "starts in " .. Clock(self:StartTime() - now) end
end

function Raffle:TabTitle()
    local status = self:Status()
    if status == "selling" then
        local left = self:EndTime() - GetTimeStamp()
        return "Raffle " .. (left >= 86400 and NiceLeft(left) or Clock(left))
    end
    if status == "closed" then return "Raffle: draw!" end
    return "Raffle"
end

-- Every second while the feature is on: tells you when sales start and end, and keeps the
-- countdown on the Raffle tab button and the top line ticking without rebuilding the list.
function Raffle:Tick()
    local status = self:Status()
    if self.lastStatus and self.lastStatus ~= status then
        if status == "selling" then
            U.Print("Raffle ticket sales have started.")
        elseif status == "closed" then
            U.Alert("Raffle ticket sales have ended. Open /gt raffle and click Draw winners.")
        end
        self.tally = nil
        self.lastStatus = status
        GT.Report:RefreshIfShown()
        return
    end
    self.lastStatus = status
    local Report = GT.Report
    if not Report.control or Report.control:IsHidden() then return end
    if status ~= "selling" and status ~= "scheduled" then return end
    for i, tab in ipairs(Report.tabs) do
        if tab.id == "raffle" then Report.tabButtons[i]:SetText(self:TabTitle()) end
    end
    if Report.currentTab == "raffle" then
        local summary = self:TabSummary()
        if #self:GetTally().list > 0 then summary = summary .. "  " .. Report.MENU_HINT end
        Report.summary:SetText(summary)
    end
end

-- Tickets -------------------------------------------------------------------------

function Raffle:SubjectOk(subject)
    local word = zo_strlower(zo_strtrim(self.sv.raffle.mailSubject or ""))
    if word == "" then return true end
    return zo_strlower(subject or ""):find(word, 1, true) ~= nil
end

function Raffle:Counts(d)
    local r = self.sv.raffle
    local start, finish = self:StartTime(), self:EndTime()
    if not start or d.ts < start or d.ts >= finish or not d.who or d.who == "" then return false end
    if d.src == "mail" then return r.useMail and self:SubjectOk(d.subj) end
    return r.useBank and r.guildId ~= 0 and d.g == r.guildId
end

-- At least one way to buy tickets is set up.
function Raffle:HasSource()
    local r = self.sv.raffle
    return r.useMail or (r.useBank and r.guildId ~= 0)
end

-- Buyers in ticket-number order (first deposit first), with ticket ranges.
-- Result: { list = { buyer, ... }, byName = { [name] = buyer }, total =, gold = }
-- buyer = { who, gold, paid, deposits, first, last, bought, adjust, tickets, refund, from, to, excluded }
function Raffle:GetTally()
    if self.tally then return self.tally end
    local r = self.sv.raffle
    local byName, list = {}, {}
    local function Buyer(who, ts)
        local b = byName[who]
        if not b then
            b = { who = who, gold = 0, paid = 0, deposits = 0, mails = 0, first = ts, last = 0 }
            byName[who] = b
            list[#list + 1] = b
        end
        return b
    end
    local price = math.max(1, r.price)
    for _, d in ipairs(self.sv.deposits) do
        if self:Counts(d) then
            local b = Buyer(d.who, d.ts)
            b.gold = b.gold + d.amt
            b.paid = b.paid + math.floor(d.amt / price)   -- each payment on its own; the remainder is dropped
            if d.src == "mail" then b.mails = b.mails + 1 else b.deposits = b.deposits + 1 end
            b.first = math.min(b.first, d.ts)
            b.last = math.max(b.last, d.ts)
        end
    end
    self:MergeNameCase(byName)
    for who in pairs(r.adjust) do Buyer(who, math.huge) end
    for who in pairs(r.excluded) do Buyer(who, math.huge) end
    table.sort(list, function(a, b)
        if a.first ~= b.first then return a.first < b.first end
        return a.who < b.who
    end)
    local total, gold = 0, 0
    for _, b in ipairs(list) do
        local bought = b.paid
        local paidFor = bought
        if r.maxTickets > 0 and bought > r.maxTickets then bought = r.maxTickets end
        b.bought = bought
        b.refund = b.gold - bought * price
        b.overCap = paidFor - bought
        b.adjust = r.adjust[b.who] or 0
        b.excluded = r.excluded[b.who] == true
        b.tickets = b.excluded and 0 or math.max(0, bought + b.adjust)
        if b.tickets > 0 then
            b.from, b.to = total + 1, total + b.tickets
            total = total + b.tickets
        end
        gold = gold + b.gold
    end
    self.tally = { list = list, byName = byName, total = total, gold = gold }
    return self.tally
end

-- 1.6.4: a name typed in the wrong case (@marthowolf for @MarthOWolf) made a second buyer.
-- Hand changes saved under another spelling of a buyer's name move to the buyer's real
-- spelling. If both spellings had tickets added, the wrong-case one is dropped as a repeat.
function Raffle:MergeNameCase(byName)
    local r = self.sv.raffle
    local real = {}
    for who in pairs(byName) do real[zo_strlower(who)] = who end
    for _, list in ipairs({ r.adjust, r.excluded }) do
        local moves = {}
        for who, value in pairs(list) do
            local right = real[zo_strlower(who)]
            if right and right ~= who then moves[#moves + 1] = { who, right, value } end
        end
        for _, move in ipairs(moves) do
            local who, right, value = move[1], move[2], move[3]
            list[who] = nil
            local dropped = list == r.adjust and list[right] ~= nil
            if not dropped then list[right] = value end
            for _, c in ipairs(r.changes) do if c.who == who then c.who = right end end
            table.insert(r.changes, { ts = GetTimeStamp(), who = right, text = dropped
                and string.format("hand change under %s (%+d) dropped as a repeat of this one", who, value)
                or string.format("hand change typed as %s moved here", who) })
        end
    end
end

-- The real spelling of a typed name: a buyer, a member of any of your guilds, or a friend.
-- Returns the name, or nil plus up to 5 close matches.
function Raffle:FindAccount(typed)
    local want = zo_strlower(U.NormalizeName(typed))
    local close, seen = {}, {}
    local function Check(name)
        if not name or name == "" then return nil end
        local low = zo_strlower(name)
        if low == want then return name end
        if not seen[low] and #close < 5 and (low:find(want:sub(2), 1, true) or want:find(low:sub(2), 1, true)) then
            seen[low] = true
            close[#close + 1] = name
        end
    end
    for _, b in ipairs(self:GetTally().list) do
        local hit = Check(b.who)
        if hit then return hit end
    end
    for _, guildId in ipairs(U.GetGuildIds()) do
        for i = 1, GetNumGuildMembers(guildId) do
            local hit = Check((GetGuildMemberInfo(guildId, i)))
            if hit then return hit end
        end
    end
    for i = 1, GetNumFriends() do
        local hit = Check((GetFriendInfo(i)))
        if hit then return hit end
    end
    return nil, close
end

function Raffle:Change(who, text)
    table.insert(self.sv.raffle.changes, { ts = GetTimeStamp(), who = who, text = text })
    self.tally = nil
    GT.Report:RefreshIfShown()
end

function Raffle:CanChangeTickets()
    if self.sv.raffle.draw then
        U.Print("The winners are already drawn, so tickets can't change. Start a new raffle first.")
        return false
    end
    return true
end

function Raffle:AddTickets(who, n, why)
    if not self:CanChangeTickets() then return end
    local r = self.sv.raffle
    local new = (r.adjust[who] or 0) + n
    r.adjust[who] = new ~= 0 and new or nil
    local text = string.format("%s %d %s by hand", n > 0 and "added" or "removed", math.abs(n), math.abs(n) == 1 and "ticket" or "tickets")
    if why and why ~= "" then text = text .. ": " .. why end
    self:Change(who, text)
    U.Print("Raffle: %s %s.", who, text)
end

function Raffle:SetExcluded(who, on)
    if not self:CanChangeTickets() then return end
    self.sv.raffle.excluded[who] = on or nil
    self:Change(who, on and "left out of the draw" or "put back in the draw")
end

function Raffle:ResetHand(who)
    if not self:CanChangeTickets() then return end
    local r = self.sv.raffle
    r.adjust[who], r.excluded[who] = nil, nil
    self:Change(who, "hand changes undone")
end

-- Sales ---------------------------------------------------------------------------

function Raffle:StartNow()
    local r = self.sv.raffle
    if not self:HasSource() then
        U.Print("Choose how tickets are bought in /gtsettings under Raffle first: pick a guild for bank deposits, or turn on mailed gold.")
        return
    end
    r.startText = ""
    r.startedAt = GetTimeStamp()
    r.endedAt = nil
    self.tally = nil
    U.Print("Raffle ticket sales started. They end %s.", NiceDate(self:EndTime()))
    GT.Report:RefreshIfShown()
end

function Raffle:EndNow()
    GT.Actions.Confirm("End ticket sales", "End raffle ticket sales now? Deposits after this moment won't buy tickets.", function()
        self.sv.raffle.endedAt = GetTimeStamp()
        self.tally = nil
        U.Print("Raffle ticket sales ended. Click Draw winners in a minute, once the last deposits have arrived.")
        GT.Report:RefreshIfShown()
    end)
end

function Raffle:NewRaffle()
    local r = self.sv.raffle
    GT.Actions.Confirm("New raffle", "Put this raffle away and set up a new one? Its results are kept, and your settings (guild, price, winners, length) stay for the new raffle.", function()
        local tally = self:GetTally()
        table.insert(self.sv.past, 1, { guildId = r.guildId, prize = r.prize, price = r.price, start = self:StartTime(), finish = self:EndTime(),
            tickets = tally.total, gold = tally.gold, buyers = #tally.list, draw = r.draw, changes = r.changes })
        while #self.sv.past > 20 do table.remove(self.sv.past) end
        r.startText, r.startedAt, r.endedAt, r.draw, r.mailCheckedAt = "", nil, nil, nil, 0
        r.adjust, r.excluded, r.changes = {}, {}, {}
        self.tally = nil
        U.Print("Ready for a new raffle. Check the settings in /gtsettings under Raffle, then click Start sales now.")
        GT.Report:RefreshIfShown()
    end)
end

-- Draw ----------------------------------------------------------------------------

-- now: End and draw now skips the wait for late deposits and the mailbox check.
function Raffle:CanDraw(now)
    local status = self:Status()
    if status ~= "closed" then return false, "Ticket sales haven't ended yet." end
    local r = self.sv.raffle
    if not now and r.useBank and r.guildId ~= 0 and GetTimeStamp() < self:EndTime() + DRAW_DELAY_S then return false, "Wait a minute after sales end, so the last deposits can arrive." end
    if not now and r.useMail and r.mailCheckedAt < self:EndTime() then return false, "Open your mailbox once first, so gold mailed before the end counts." end
    if not self:IsCaughtUp() then return false, "The bank history is still loading (LibHistoire). Try again in a moment." end
    if self:GetTally().total == 0 then return false, "Nobody has any tickets." end
    return true
end

-- Picks one ticket among the tickets that may still win. Returns the result or nil.
function Raffle:DrawOne(tally, results)
    local r = self.sv.raffle
    local won, voided, usedTickets = {}, {}, {}
    for _, res in ipairs(results) do
        if res.void then voided[res.who] = true else won[res.who] = true end
        usedTickets[res.ticket] = true
    end
    -- Eligible tickets: every ticket not drawn before; with one win per person, none of a
    -- winner's; never those of someone whose win was voided (they couldn't take the prize).
    local pool = {}
    local poolSize = 0
    for _, b in ipairs(tally.list) do
        if b.tickets > 0 and not voided[b.who] and not (r.oneWin and won[b.who]) then
            for t = b.from, b.to do
                if not usedTickets[t] then
                    poolSize = poolSize + 1
                    pool[poolSize] = t
                end
            end
        end
    end
    if poolSize == 0 then return nil end
    local ticket = pool[math.random(poolSize)]
    for _, b in ipairs(tally.list) do
        if b.from and ticket >= b.from and ticket <= b.to then
            local res = { n = #results + 1, ticket = ticket, who = b.who, from = b.from, to = b.to, tickets = b.tickets, pool = poolSize, slot = #results + 1 }
            results[#results + 1] = res
            return res
        end
    end
end

-- Ends sales this second and draws at once (Albert, 1.6.3). Asks first.
function Raffle:EndAndDraw()
    local why
    if not self:IsCaughtUp() then why = "The bank history is still loading (LibHistoire). Try again in a moment." end
    if self:GetTally().total == 0 then why = "Nobody has any tickets yet." end
    if why then U.Print(why); return end
    GT.Actions.Confirm("End raffle and draw winners", "End ticket sales now and draw the winners right away?\n\nOnly tickets counted so far are in the draw: a deposit made in the last few seconds, or a mail you haven't opened yet, won't count. The draw can't be redone.", function()
        self.sv.raffle.endedAt = GetTimeStamp() - 1
        self.tally = nil
        self.lastStatus = "closed"
        self:Draw(true)
    end)
end

function Raffle:Draw(now)
    local ok, why = self:CanDraw(now)
    if not ok then U.Print(why); return end
    local r = self.sv.raffle
    local tally = self:GetTally()
    local draw = { ts = GetTimeStamp(), total = tally.total, results = {} }
    for _ = 1, r.winners do
        if not self:DrawOne(tally, draw.results) then break end
    end
    r.draw = draw
    for _, res in ipairs(draw.results) do
        U.Print("Raffle draw %d: ticket #%d of %d, %s (tickets %d-%d)%s.", res.n, res.ticket, tally.total, res.who, res.from, res.to, self:ForPrize(res))
    end
    if #draw.results < r.winners then
        U.Print("Only %d %s could be drawn: there aren't enough buyers.", #draw.results, #draw.results == 1 and "winner" or "winners")
    end
    U.Print("To announce the winners, click Winners to guild chat or Winners for Discord at the bottom of the Raffle tab.")
    GT.Report:Show("raffle")
end

-- A winner who can't take the prize: their win is voided and another ticket is drawn.
function Raffle:Redraw(who)
    local r = self.sv.raffle
    GT.Actions.Confirm("Draw a replacement", zo_strformat("Void <<1>>'s win and draw a replacement winner?", who), function()
        local draw = r.draw
        local voided
        for _, res in ipairs(draw.results) do
            if res.who == who and not res.void then res.void = true; voided = res; break end
        end
        if not voided then return end
        local res = self:DrawOne(self:GetTally(), draw.results)
        if res then
            res.replaces = who
            res.slot = Slot(voided)
            U.Print("Raffle draw %d (replaces %s): ticket #%d of %d, %s (tickets %d-%d)%s.", res.n, who, res.ticket, draw.total, res.who, res.from, res.to, self:ForPrize(res))
        else
            U.Print("No tickets are left to draw a replacement from.")
        end
        GT.Report:RefreshIfShown()
    end)
end

-- " for (prize)" when the prizes differ per winner, else "".
function Raffle:ForPrize(res)
    if #self:Prizes() < 2 then return "" end
    local prize = self:PrizeFor(Slot(res))
    return prize and (" for " .. prize) or ""
end

function Raffle:WinsOf(who)
    local wins = {}
    for _, res in ipairs(self.sv.raffle.draw and self.sv.raffle.draw.results or {}) do
        if res.who == who then wins[#wins + 1] = res end
    end
    return wins
end

-- Guild chat ----------------------------------------------------------------------
-- The addon can't send chat: each part goes in the guild chat box and you press Enter.

local function SplitParts(header, entries, closing)
    local parts, line = {}, header
    for _, entry in ipairs(entries) do
        local sep = (line == "") and "" or " "
        if #line + #sep + #entry > MAX_CHAT then
            parts[#parts + 1] = line
            line, sep = "", ""
        end
        line = line .. sep .. entry
    end
    if closing then
        if #line + #closing + 1 <= MAX_CHAT then line = line .. " " .. closing
        else parts[#parts + 1] = line; line = closing end
    end
    parts[#parts + 1] = line
    return parts
end

-- Prizes: one per line or separated by ";" (1.7.0). The first goes to the winner of draw 1,
-- and so on. A single prize is everyone's prize.
function Raffle:Prizes()
    local list = {}
    for raw in string.gmatch(self.sv.raffle.prize or "", "[^;\n]+") do
        local prize = zo_strtrim(raw)
        if prize ~= "" then list[#list + 1] = prize end
    end
    return list
end

function Raffle:PrizeFor(slot)
    local list = self:Prizes()
    if #list == 1 then return list[1] end
    return list[slot]
end

-- The raffle's name in posts: its prize, "4 prizes", or "the raffle".
function Raffle:PrizeText()
    local list = self:Prizes()
    if #list == 1 then return list[1] end
    if #list > 1 then return string.format("%d prizes", #list) end
    return "the raffle"
end

-- "1) A, 2) B" for posts.
function Raffle:PrizeListText()
    local list, parts = self:Prizes(), {}
    for i, prize in ipairs(list) do parts[#parts + 1] = string.format("%d) %s", i, prize) end
    return table.concat(parts, ", ")
end

function Raffle:SetPrizes(text)
    self:SetValue("prize", zo_strtrim(text or ""))
    local count = #self:Prizes()
    if count > 1 and count ~= self.sv.raffle.winners then
        self.sv.raffle.winners = math.min(20, count)
        U.Print("Raffle: %d prizes listed, so the number of winners is now %d.", count, self.sv.raffle.winners)
    end
end

function Raffle:AnnounceParts()
    local r = self.sv.raffle
    local start, finish = self:StartTime(), self:EndTime()
    local now = GetTimeStamp()
    local when
    if now < start then
        when = string.format("Ticket sales open in %s and run for %s.", NiceLeft(start - now), NiceLeft(finish - start))
    else
        when = string.format("Ticket sales end in %s.", NiceLeft(finish - now))
    end
    local rules = string.format("%d %s%s.", r.winners, r.winners == 1 and "winner" or "winners", (r.oneWin and r.winners > 1) and ", one win per person" or "")
    if r.maxTickets > 0 then rules = rules .. string.format(" Up to %d tickets each.", r.maxTickets) end
    local ways = {}
    if r.useBank and r.guildId ~= 0 then ways[#ways + 1] = string.format("deposit gold into the %s guild bank", U.GuildName(r.guildId)) end
    if r.useMail then
        local word = zo_strtrim(r.mailSubject or "")
        ways[#ways + 1] = string.format("mail gold to %s%s", GetDisplayName(), word ~= "" and string.format(" with \"%s\" in the subject", word) or "")
    end
    local prizes = #self:Prizes() > 1 and ("! Prizes: " .. self:PrizeListText() .. ".") or (" for " .. self:PrizeText() .. "!")
    local text = string.format("RAFFLE%s Tickets are %s each: %s (every %s in one deposit or mail is one ticket, so send a multiple of it). %s %s Good luck!",
        prizes, U.FormatGold(r.price), table.concat(ways, " or "), U.FormatGold(r.price), when, rules)
    self.announceWays, self.announceWhen, self.announceRules = ways, when, rules
    return SplitParts("", { text })
end

function Raffle:ResultParts()
    local draw = self.sv.raffle.draw
    local tally = self:GetTally()
    local buyers = 0
    for _, b in ipairs(tally.list) do if b.tickets > 0 then buyers = buyers + 1 end end
    local header = string.format("Raffle draw for %s: %d tickets from %d %s.", self:PrizeText(), draw.total, buyers, buyers == 1 and "buyer" or "buyers")
    local entries = {}
    for _, res in ipairs(draw.results) do
        if res.void then
            entries[#entries + 1] = string.format("Draw %d: %s (could not take the prize).", res.n, res.who)
        else
            entries[#entries + 1] = string.format("Draw %d: ticket #%d goes to %s (tickets %d-%d)%s%s.", res.n, res.ticket, res.who, res.from, res.to,
                self:ForPrize(res), res.replaces and (", replacing " .. res.replaces) or "")
        end
    end
    return SplitParts(header, entries, "Congratulations, and thanks to everyone who bought tickets!")
end

-- Discord ---------------------------------------------------------------------------
-- The same posts as several lines with Discord's **bold**, shown in the copy window.

function Raffle:ShowCopy(text, what)
    local Report = GT.Report
    Report.exportParts = { text }
    Report.exportIndex = 1
    if FuryGMTExport:IsHidden() then SCENE_MANAGER:ShowTopLevel(FuryGMTExport) end
    Report:ShowExportPart(0)
    U.Print("%s is in the copy window. Click Select all, press Ctrl+C, and paste it into Discord.", what)
end

function Raffle:DiscordAnnounce()
    local r = self.sv.raffle
    self:AnnounceParts()   -- fills announceWays, announceWhen, announceRules
    local lines = { string.format("**RAFFLE: %s**", self:PrizeText()) }
    local list = self:Prizes()
    if #list > 1 then
        lines[#lines + 1] = "Prizes:"
        for i, prize in ipairs(list) do lines[#lines + 1] = string.format("%d. %s", i, prize) end
    end
    lines[#lines + 1] = string.format("Tickets: **%s** each. To buy, %s. Every %s in one deposit or mail is one ticket, so send a multiple of it.",
        U.FormatGold(r.price), table.concat(self.announceWays, " or "), U.FormatGold(r.price))
    -- Discord shows <t:...> timestamps in each reader's own time zone.
    lines[#lines + 1] = string.format("Sales end <t:%d:F> (<t:%d:R>).", self:EndTime(), self:EndTime())
    lines[#lines + 1] = self.announceRules .. " Good luck!"
    return table.concat(lines, "\n")
end

function Raffle:DiscordResults()
    local draw = self.sv.raffle.draw
    local tally = self:GetTally()
    local buyers = 0
    for _, b in ipairs(tally.list) do if b.tickets > 0 then buyers = buyers + 1 end end
    local lines = { string.format("**Raffle results: %s**", self:PrizeText()),
        string.format("%d tickets from %d %s.", draw.total, buyers, buyers == 1 and "buyer" or "buyers"), "" }
    for _, res in ipairs(draw.results) do
        local prize = self:PrizeFor(Slot(res))
        if res.void then
            lines[#lines + 1] = string.format("~~Draw %d: %s~~ (could not take the prize)", res.n, res.who)
        else
            lines[#lines + 1] = string.format("Draw %d: **%s**%s, ticket #%d (held tickets %d-%d)%s", res.n, res.who,
                (#self:Prizes() > 1 and prize) and (" wins **" .. prize .. "**") or "", res.ticket, res.from, res.to,
                res.replaces and (", replacing " .. res.replaces) or "")
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Congratulations, and thanks to everyone who bought tickets!"
    return table.concat(lines, "\n")
end

function Raffle:Discord()
    if self:Status() == "drawn" then
        self:ShowCopy(self:DiscordResults(), "The winners post")
    elseif self:HasSource() and (self:Status() == "selling" or self:Status() == "scheduled") then
        self:ShowCopy(self:DiscordAnnounce(), "The raffle announcement")
    end
end

-- With a guild: into that guild's chat box. Without one: in the copy window, to paste anywhere
-- (Discord, a group chat).
function Raffle:Post(parts)
    local guildId = self.sv.raffle.guildId
    if guildId ~= 0 and U.IsPlayerInGuild(guildId) then
        GT:GetModule("trader"):PostToGuild(guildId, parts)
        return
    end
    local Report = GT.Report
    Report.exportParts = { table.concat(parts, "\n") }
    Report.exportIndex = 1
    if FuryGMTExport:IsHidden() then SCENE_MANAGER:ShowTopLevel(FuryGMTExport) end
    Report:ShowExportPart(0)
    U.Print("No raffle guild is set, so the text is in the copy window. Click Copy, then paste it where your group chats.")
end

function Raffle:Announce()
    local status = self:Status()
    if status ~= "scheduled" and status ~= "selling" then
        U.Print("Start ticket sales first (or set a start time in /gtsettings under Raffle).")
        return
    end
    if not self:HasSource() then
        U.Print("Choose how tickets are bought in /gtsettings under Raffle first.")
        return
    end
    self:Post(self:AnnounceParts())
end

function Raffle:PostResults()
    self:Post(self:ResultParts())
end

-- Report tab ----------------------------------------------------------------------

local STATUS_TEXT = {
    setup = "|cAAAAAANot started.|r Set it up in /gtsettings under Raffle, then click Start sales now.",
    scheduled = "|cFFCC66Sales start in %s|r (%s).",
    selling = "|cFFD700Sales end in %s|r (%s).",
    closed = "|cFF9933Sales ended %s.|r",
    drawn = "|c9FD49FWinners drawn %s.|r",
}

function Raffle:TabSummary()
    local r = self.sv.raffle
    local status = self:Status()
    local now = GetTimeStamp()
    local head
    if status == "setup" then head = STATUS_TEXT.setup
    elseif status == "scheduled" then head = string.format(STATUS_TEXT.scheduled, Clock(self:StartTime() - now), NiceDate(self:StartTime()))
    elseif status == "selling" then head = string.format(STATUS_TEXT.selling, Clock(self:EndTime() - now), NiceDate(self:EndTime()))
    elseif status == "closed" then head = string.format(STATUS_TEXT.closed, NiceDate(self:EndTime()))
    else head = string.format(STATUS_TEXT.drawn, NiceDate(r.draw.ts)) end
    if not self:HasSource() then return head end
    local tally = self:GetTally()
    local loading = self:IsCaughtUp() and "" or "  |cFFCC66Bank history still loading.|r"
    local where = {}
    if r.useBank and r.guildId ~= 0 then where[#where + 1] = U.GuildName(r.guildId) .. " bank" end
    if r.useMail then where[#where + 1] = "mail" end
    return string.format("%s  %s: %s, %s a ticket, %d %s%s. %d tickets, %s.%s", head, table.concat(where, " + "), self:PrizeText(),
        U.FormatGold(r.price), r.winners, r.winners == 1 and "winner" or "winners", (r.oneWin and r.winners > 1) and " (one each)" or "",
        tally.total, U.FormatGold(tally.gold), loading) .. self:PrizeWarning()
end

-- A warning on the top line when several prizes are listed but the number of winners differs.
function Raffle:PrizeWarning()
    local count = #self:Prizes()
    if count < 2 or count == self.sv.raffle.winners then return "" end
    return string.format("  |cFF9933%d prizes listed for %d winners.|r", count, self.sv.raffle.winners)
end

function Raffle:ResultText(b)
    local parts = {}
    for _, res in ipairs(self:WinsOf(b.who)) do
        local prize = #self:Prizes() > 1 and self:PrizeFor(Slot(res))
        parts[#parts + 1] = res.void and string.format("|c888888draw %d void|r", res.n)
            or (prize and string.format("|cFFD700WON %s|r", prize) or string.format("|cFFD700WON draw %d|r", res.n))
    end
    if #parts > 0 then return table.concat(parts, ", ") end
    if b.excluded then return "|cFF6666left out|r" end
    return ""
end

function Raffle:RowTooltip(b)
    local r = self.sv.raffle
    local lines = { b.who }
    lines[#lines + 1] = string.format("Paid %s: %d bank %s, %d %s.", U.FormatGold(b.gold), b.deposits, b.deposits == 1 and "deposit" or "deposits",
        b.mails, b.mails == 1 and "mail" or "mails")
    if b.overCap > 0 then lines[#lines + 1] = string.format("%d tickets over the cap of %d.", b.overCap, r.maxTickets) end
    if b.refund > 0 then lines[#lines + 1] = string.format("Not used: %s (each payment's remainder below the ticket price%s).", U.FormatGold(b.refund), b.overCap > 0 and ", and gold over the limit" or "") end
    for _, c in ipairs(r.changes) do
        if c.who == b.who then lines[#lines + 1] = string.format("%s: %s", U.FormatDate(c.ts), c.text) end
    end
    for _, res in ipairs(self:WinsOf(b.who)) do
        lines[#lines + 1] = string.format("Draw %d: ticket #%d of %d%s%s.", res.n, res.ticket, self.sv.raffle.draw.total, self:ForPrize(res), res.void and " (voided)" or "")
    end
    return table.concat(lines, "\n")
end

function Raffle:RowMenu(b)
    local items = GT.Report.ContactItems(b.who)
    local r = self.sv.raffle
    local wins = self:WinsOf(b.who)
    for _, res in ipairs(wins) do
        if not res.void then
            items[#items + 1] = { label = "Mail prize to " .. b.who, fn = function() self:MailWinner(res) end }
            items[#items + 1] = { label = "Void win, draw a replacement", fn = function() self:Redraw(b.who) end }
            break
        end
    end
    if not r.draw then
        items[#items + 1] = { label = "Add 1 ticket", fn = function() self:AddTickets(b.who, 1) end }
        items[#items + 1] = { label = "Add 5 tickets", fn = function() self:AddTickets(b.who, 5) end }
        if b.tickets > 0 then items[#items + 1] = { label = "Remove 1 ticket", fn = function() self:AddTickets(b.who, -1) end } end
        items[#items + 1] = { label = b.excluded and "Put back in the draw" or "Leave out of the draw", fn = function() self:SetExcluded(b.who, not b.excluded) end }
        if b.adjust ~= 0 or b.excluded then items[#items + 1] = { label = "Undo hand changes", fn = function() self:ResetHand(b.who) end } end
    end
    return items
end

function Raffle:MailWinner(res)
    local r = self.sv.raffle
    local prize = self:PrizeFor(Slot(res)) or self:PrizeText()
    local body = string.format("Congratulations! Your ticket #%d won draw %d of the raffle. Your prize: %s.\n\nYour code: ", res.ticket, res.n, prize)
    GT.Actions.Warn(res.who, "You won the raffle!", body, "mail")
end

Raffle.columns = {
    { title = "Buyer", width = 210, tip = "Who deposited or mailed gold during the sale, or got tickets by hand. In ticket-number order (first payment first)." },
    { title = "Tickets", width = 80, tip = "Tickets in the draw: gold / ticket price (up to the cap), plus or minus changes made by hand." },
    { title = "Numbers", width = 120, tip = "This buyer's ticket numbers. The draw picks a random number." },
    { title = "Gold", width = 120, tip = "Gold deposited or mailed during the sale." },
    { title = "Not used", width = 110, tip = "Gold that didn't buy a ticket: each payment's remainder below the ticket price (dropped, not carried over), and gold over the per-person limit." },
    { title = "Chance", width = 80, tip = "Share of all tickets." },
    { title = "Last payment", width = 150 },
    { title = "Result", width = 150, tip = "Who won which prize." },
}

function Raffle:TabRows()
    if not self:HasSource() then return {} end
    local tally = self:GetTally()
    local rows = {}
    for _, b in ipairs(tally.list) do
        local adjust = b.adjust ~= 0 and string.format(" |cAAAAAA(%+d)|r", b.adjust) or ""
        local row = {
            cells = {
                b.who,
                tostring(b.tickets) .. adjust,
                b.from and (b.from == b.to and ("#" .. b.from) or string.format("#%d-%d", b.from, b.to)) or "",
                b.gold > 0 and U.FormatGold(b.gold) or "",
                b.refund > 0 and U.FormatGold(b.refund) or "",
                tally.total > 0 and string.format("%.1f%%", b.tickets * 100 / tally.total) or "",
                b.last > 0 and U.FormatDate(b.last) or "",
                self:ResultText(b),
            },
            tooltip = self:RowTooltip(b),
        }
        rows[#rows + 1] = GT.Report.AddMenu(row, self:RowMenu(b))
    end
    return rows
end

function Raffle:TabExportLines()
    local r = self.sv.raffle
    local tally = self:GetTally()
    local lines = { "Buyer\tTickets\tFirst ticket\tLast ticket\tGold\tNot used\tBank deposits\tMails\tHand changes\tLeft out\tResult" }
    for _, b in ipairs(tally.list) do
        local results = {}
        for _, res in ipairs(self:WinsOf(b.who)) do results[#results + 1] = string.format("draw %d ticket %d%s", res.n, res.ticket, res.void and " void" or "") end
        lines[#lines + 1] = table.concat({ b.who, b.tickets, b.from or "", b.to or "", b.gold, b.refund, b.deposits, b.mails, b.adjust,
            b.excluded and "yes" or "", table.concat(results, "; ") }, "\t")
    end
    if r.draw then
        lines[#lines + 1] = ""
        for _, part in ipairs(self:ResultParts()) do lines[#lines + 1] = part end
    end
    return lines
end

function Raffle:TabFooter()
    local status = self:Status()
    local footer = {}
    if status == "setup" then
        footer[#footer + 1] = { label = "Start sales now", tip = "Starts ticket sales now. They run for the length set in /gtsettings under Raffle.", fn = function() self:StartNow() end }
    elseif status == "selling" then
        footer[#footer + 1] = { label = "End sales now", tip = "Ends ticket sales early, so you can draw a minute later. Asks first.", fn = function() self:EndNow() end }
        footer[#footer + 1] = { label = "End and draw now", tip = "Ends ticket sales and draws the winners right away, with the tickets counted so far. Asks first. The draw can't be redone.", fn = function() self:EndAndDraw() end }
    end
    if status == "scheduled" or status == "selling" then
        footer[#footer + 1] = { label = "Announce in guild", tip = "Puts a raffle announcement (prizes, price, how to buy, time left) in the guild chat box for you to press Enter. Without a raffle guild, shows it to copy.", fn = function() self:Announce() end }
        footer[#footer + 1] = { label = "Text for Discord", tip = "Shows the raffle announcement as text to copy and paste into Discord.", fn = function() self:Discord() end }
    end
    if status == "closed" then
        footer[#footer + 1] = { label = "Draw winners", tip = function() local ok, why = self:CanDraw(); return ok and "Draws the winners now. Each draw picks a random ticket. This can't be redone." or why end, fn = function() self:Draw() end }
    end
    if status == "drawn" then
        footer[#footer + 1] = { label = "Winners to guild chat", tip = "Puts the winners (and their prizes) in the guild chat box, one part at a time, for you to press Enter. Without a raffle guild, shows them to copy.", fn = function() self:PostResults() end }
        footer[#footer + 1] = { label = "Winners for Discord", tip = "Shows the winners and their prizes as text to copy and paste into Discord.", fn = function() self:Discord() end }
    end
    if status ~= "setup" then
        footer[#footer + 1] = { label = "New raffle", tip = "Puts this raffle away (its results are kept) and starts setting up the next one. Asks first.", fn = function() self:NewRaffle() end }
    end
    return footer
end

function Raffle:RegisterTab()
    GT.Report:RegisterTab({
        id = "raffle",
        title = function() return self:TabTitle() end,
        tip = "Raffle tickets bought with gold deposited into a guild bank or mailed to you, and the winners draw.",
        GetOffText = function() return GT:FeatureOffText(self.sv.enabled, "The raffle") end,
        GetSummary = function() return self:TabSummary() end,
        GetRows = function() return self:TabRows() end,
        columns = Raffle.columns,
        footer = function() return self:TabFooter() end,
        GetExportLines = function() return self:TabExportLines() end,
    })
end

-- /gt raffle add @name 3 [reason], /gt raffle remove @name 3 [reason] -----------------

function Raffle:Slash(args)
    local verb, rest = args:match("^(%S+)%s*(.*)$")
    verb = verb and zo_strlower(verb) or ""
    if verb == "add" or verb == "remove" then
        local name, count, why = rest:match("^(%S+)%s+(%d+)%s*(.*)$")
        if not name then
            U.Print("Usage: /gt raffle %s @name 3 (optional reason)", verb)
            return
        end
        if not self.sv.enabled then U.Print("The raffle is turned off. Turn it on in /gtsettings under Raffle."); return end
        local n = tonumber(count)
        if verb == "remove" then n = -n end
        local found, close = self:FindAccount(name)
        if found then
            self:AddTickets(found, n, why)
            return
        end
        local typed = U.NormalizeName(name)
        local hint = #close > 0 and ("\n\nDid you mean: " .. table.concat(close, ", ") .. "?") or ""
        U.Print("%s isn't a raffle buyer, a member of your guilds or a friend.%s", typed, #close > 0 and (" Did you mean: " .. table.concat(close, ", ") .. "?") or "")
        GT.Actions.Confirm("Unknown account", string.format("%s isn't a raffle buyer, a member of any of your guilds or on your friends list. Check the spelling.%s\n\nAdd the tickets to %s anyway?", typed, hint, typed), function()
            self:AddTickets(typed, n, why)
        end)
    else
        GT.Report:Show("raffle")
    end
end

-- Settings ------------------------------------------------------------------------

function Raffle:GuildChoices()
    local names, ids = { "(no guild)" }, { 0 }
    for _, guildId in ipairs(U.GetGuildIds()) do
        names[#names + 1] = U.GuildName(guildId)
        ids[#ids + 1] = guildId
    end
    return names, ids
end

function Raffle:Started()
    local start = self:StartTime()
    return start ~= nil and GetTimeStamp() >= start
end

function Raffle:SetValue(key, value)
    self.sv.raffle[key] = value
    self.tally = nil
    GT.Report:RefreshIfShown()
end

function Raffle:SetStartText(text)
    text = zo_strtrim(text or "")
    if text ~= "" and not Raffle.ParseTime(text) then
        U.Print("Type the start as YYYY-MM-DD HH:MM in your local time, for example 2026-11-23 20:00.")
        return
    end
    self.sv.raffle.startedAt = nil
    self.sv.raffle.endedAt = nil
    self:SetValue("startText", text)
end

function Raffle:BuildSettings(options)
    local sv, r = self.sv, self.sv.raffle
    local names, ids = self:GuildChoices()
    local function Locked() return r.draw ~= nil end
    local function SalesLocked() return r.draw ~= nil or self:Started() end
    options[#options + 1] = { type = "submenu", name = "Raffle", controls = {
        { type = "description", text = "Sell raffle tickets for gold deposited into a guild bank or mailed to you, then draw the winners in the Raffle tab (/gt raffle). Changes here apply to the current raffle until its winners are drawn." },
        { type = "checkbox", name = "Turn on the raffle", tooltip = "Reads guild bank gold deposits (through LibHistoire) and gold mails when you open your mailbox, and shows the Raffle tab.",
          getFunc = function() return sv.enabled end, setFunc = function(v) sv.enabled = v end, default = false, requiresReload = true },
        { type = "checkbox", name = "Chat line when someone buys tickets", tooltip = "Prints a line in your chat when a bank deposit during the sale buys tickets. Counted mails always get a line, since you are at your mailbox then. Only you see it.",
          getFunc = function() return sv.buyNotice end, setFunc = function(v) sv.buyNotice = v end, default = false },
        { type = "dropdown", name = "Raffle guild", choices = names, choicesValues = ids, tooltip = "The guild whose bank deposits buy tickets, and whose chat gets the announcement and results. Pick (no guild) for a mail-only raffle; posts then show as text to copy. Locked once sales start.",
          getFunc = function() return r.guildId end, setFunc = function(v) self:SetValue("guildId", v) end, disabled = SalesLocked },
        { type = "checkbox", name = "Guild bank deposits buy tickets", tooltip = "Gold deposited into the raffle guild's bank during the sale buys tickets. Locked once sales start.",
          getFunc = function() return r.useBank end, setFunc = function(v) self:SetValue("useBank", v) end, disabled = SalesLocked },
        { type = "checkbox", name = "Mailed gold buys tickets", tooltip = "Gold mailed to you during the sale buys tickets. The addon can only see mail while your mailbox is open: open it before you take the gold out of raffle mails, and once after sales end. Locked once sales start.",
          getFunc = function() return r.useMail end, setFunc = function(v) self:SetValue("useMail", v) end, disabled = SalesLocked },
        { type = "editbox", name = "Mail subject must include", tooltip = "Empty (the default): every mail with gold buys tickets, like every bank deposit. Type a word to count only mails whose subject contains it.",
          getFunc = function() return r.mailSubject end, setFunc = function(v) self:SetValue("mailSubject", zo_strtrim(v or "")) end, disabled = Locked },
        { type = "editbox", name = "Prizes (one per line, or separate with ;)", isMultiline = true, tooltip = "One prize per winner, in order: the first goes to the winner of draw 1, the second to draw 2, and so on. Listing several sets the number of winners to match. For one prize everyone wins, type it once.",
          getFunc = function() return r.prize end, setFunc = function(v) self:SetPrizes(v) end, disabled = Locked },
        { type = "slider", name = "Ticket price (gold)", min = 100, max = 100000, step = 100, tooltip = "Gold per ticket. Locked once sales start.",
          getFunc = function() return r.price end, setFunc = function(v) self:SetValue("price", v) end, disabled = SalesLocked },
        { type = "slider", name = "Number of winners", min = 1, max = 20, step = 1, tooltip = "How many tickets to draw, one per prize.",
          getFunc = function() return r.winners end, setFunc = function(v) self:SetValue("winners", v) end, disabled = Locked },
        { type = "checkbox", name = "One win per person", tooltip = "On: once someone wins, their other tickets are skipped. Off: someone with many tickets can win more than once.",
          getFunc = function() return r.oneWin end, setFunc = function(v) self:SetValue("oneWin", v) end, disabled = Locked },
        { type = "slider", name = "Most tickets per person (0 = no limit)", min = 0, max = 1000, step = 1, tooltip = "Gold over the limit shows as Not used.",
          getFunc = function() return r.maxTickets end, setFunc = function(v) self:SetValue("maxTickets", v) end, disabled = Locked },
        { type = "editbox", name = "Start (YYYY-MM-DD HH:MM)", tooltip = "When sales start, in your local time, for example 2026-11-23 20:00 (8:00 pm works too). Leave it empty and click Start sales now in the Raffle tab instead. A start in the past counts deposits since then.",
          getFunc = function() return r.startText end, setFunc = function(v) self:SetStartText(v) end, disabled = Locked },
        { type = "slider", name = "Sale length (hours)", min = 1, max = 336, step = 1, tooltip = "How long ticket sales run from the start. You can make it longer or shorter while sales run.",
          getFunc = function() return r.hours end, setFunc = function(v) r.endedAt = nil; self:SetValue("hours", v) end, disabled = Locked },
    } }
end
