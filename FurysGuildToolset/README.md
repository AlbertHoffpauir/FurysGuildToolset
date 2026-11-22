# Fury's Guild Management Toolset (ESO addon) v1.8.1

**AI disclosure:** Most of this addon's code was written with an AI coding assistant (Claude by Anthropic), working from my designs and instructions. I test every release in game in my own guilds before it goes up, and I maintain it. Please report any problem in the comments.

**Every feature starts turned off.** Nothing runs, alerts, logs or mails until you turn it on. Open `/gtsettings`, tick your guilds under "Guilds to get alerts from", and turn on the features you want, when you want them. (Updating from an older version keeps your settings exactly as they were.)

An officer toolkit for Elder Scrolls Online. It watches your guild banks and rosters, tells you when something needs attention, and lets you deal with it in a click or two. **Right-click any row for what you can do with it** (whisper, mail, set rank, kick and so on). The line at the top of each tab and each row's hover text remind you. It has twelve modules:

1. **Bank alerts.** Flags anyone who withdraws more than X stacks (or X gold) in one day, counted midnight to midnight on your PC's clock (or within a rolling window of X hours, if you prefer). You get a chat and on-screen alert as it happens while you're online, and a summary when you log in. Each alert is one summary line: how many stacks and items were taken, how many came back whole and partly used, and when. Stacks put back whole don't count. Hover an alert for the full item list and what was put back. **Right-click an alert for its options:** Whisper, Mail, Warn by whisper or by mail, Demote, Set rank (pick any rank below yours; ranks without bank access are marked "no bank"), Add to guild note (adds one short line to the end of their guild note, such as "Bank Nov 18: took 41 stacks (157 items), put back 0 whole/0 partly. Demoted.", keeping what's already there), Kick, Kick and blacklist (or Blacklist once they have left), and Dismiss. Anything that changes the guild asks first, and nothing is sent until you press Enter or Send. Optional **auto-demote** (off by default) is described below.
2. **Bank hoppers.** Lists people who joined and then left within X hours, Right-click one to blacklist, watch, dismiss, whisper or mail them. It also keeps an account-wide watchlist that alerts you when a known hopper joins any of your guilds.
3. **History.** A log of bank item, bank gold and roster events (joins, leaves, kicks, promotions, demotions, blacklist changes) for all your guilds, kept for 90 days by default (up to 20,000 events). Filter by type, time range (1, 7, 30 or 90 days) and guild (a drop-down that remembers your choice), search by name or item, or switch to a per-member totals view. Item withdrawals are matched with later deposits of the same item by the same member (within 72 hours, adjustable for each guild), so you can see what was put back: "returned after 4m" for a stack put back whole, "returned 199 of 200" for one that came back partly used. "Show: Bank items" marks every withdrawal as returned whole, returned partly or not returned, and the top line counts them, so you can see who took what and what came back.
4. **Bank space.** Alerts when a guild bank reaches X% full (default 90%, set for each guild). The game only lets addons read guild bank slots while that bank is open, so the count is taken each time you open a guild bank. Between visits you see the last count and how long ago it was taken. See it on the Bank space tab, `/gt space` or `/gt status`.
5. **Guild Crier.** A clickable menu of guild, zone and whisper messages, with a weighted rotation that remembers its place between sessions, and a reminder that keeps its timing across logins and reloads. It comes with generic sample messages, including a Tips section with 19 tips for newer players; replace them with your own in the Crier settings. Updates never replace your messages. To add tips from a newer version to your list, use "Import new tips" in the Crier settings. `/crier` or `/gt crier`, with its own settings panel, "Fury's Guild Management - Crier". Keybinds are under Controls > Keybindings > Fury's Guild Management.
6. **Members.** Every member of your guilds with their rank, how long they've held it, when they were last promoted, when they were last online and their guild note. Shown in columns with color-coded ranks. Filter by guild or rank, hide offline members, click a column header to sort (click again to reverse), keep ranks grouped together or not, and search names, ranks and notes. Right-click a member to whisper or mail them (blank, or with the contact text you set in settings), Set rank, Kick, or Kick and blacklist; each change asks first. A blacklist can mail them the reason (see Kick and blacklist mails below). The game doesn't record when someone got their rank, so rank dates come from roster history. If someone's last rank change is older than the history the addon has, it shows "since before (date)". "Last online" is when they last logged off, which is what the game provides.
7. **Inactive.** Officers offline longer than 30 days, members longer than 21 days and recruits longer than 14 days, shown in sortable columns with the same rank filter and grouping as Members. **Right-click a member for:** mail them the "we miss you" text (editable in settings), a blank mail, Set rank, Kick, Kick and blacklist (or Blacklist once they have left), and Dismiss. There's no whisper here, since they're offline. For example, pick Rank: Recruit and click Offline to go through recruits from most to least inactive. All three limits are adjustable for each guild, and in that guild's Rules section you choose for each rank whether the officer, member or recruit limit applies, or no check. Dismissed members come back once they log in and go over the limit again. The top line shows how many guild slots each guild uses and how many are open (out of 500). A login alert can tell you how many are over the limit. Kick here counts as a kick for inactivity and can mail them why and that they're welcome back (see Kick and blacklist mails below).
8. **Trader.** Trader management: weekly totals for each guild, lined up with the trader week (it starts when traders change hands on Tuesday): which trader you had, guild store sales and the tax the guild earned, what the trader really cost (the winning bid plus any trader hired outright), revenue (the tax plus gold members deposited) minus that cost in green or red, and gold in and out (gold out includes the trader cost, heraldry and member withdrawals). Hover a week for every bid placed for it and whether it won or was refunded, the week-to-week change in revenue, item deposits and withdrawals, and joins, leaves and kicks. "View: traders" shows each trader you held, for how many weeks in a row, what it cost against the revenue it brought in, and its revenue per week compared with the trader before it. The top line shows your current trader, the bank gold (counted when you open that guild bank) and when traders change next. Keeps 12 weeks by default (up to 52). The first time, it reads back as far as the first-run look-back setting allows. `/gt trader`.
9. **Member sales.** For any trader week, what each member sold in the guild store, what it sold for, the tax that earned, and the gold and items they gave or took. Filter by guild, pick the week (or "All weeks" for each member's totals over everything the addon has stored, up to the "Weeks to keep" setting, 12 by default), and click a column header to sort. Right-click a member to start a whisper, a mail (for a seller it comes filled in with a congratulations note on their place and sales), or a shout-out in guild chat. **Post top ten** puts the week's (or all time) top ten sellers in the guild chat box. Nothing is sent until you press Send or Enter. `/gt sales`.
10. **Automatic actions (Auto tab).** Everything the addon does by itself is announced and logged: auto-demotes, the automatic demotion mail, and hoppers added to the watchlist. When someone is auto-demoted you get a breakdown in chat (and, if you turn it on, a big alert window that stays on screen until you close it): their old and new rank, the rule they hit, how much they took and between which times, and each withdrawal (time, item and stack size). The rank change is marked confirmed only once the guild roster shows the new rank, and the demotion mail is marked sent only when the server confirms it. If the mail fails you get a notice with the reason, and Send the demotion mail in its right-click menu. Skipped auto-demotes (for example, the person is at or above your rank) and the per-session limit are logged too. Hover a row for the full list of withdrawals. Kept 90 days by default. `/gt auto`.
11. **Recruiting (Recruit tab).** Tools for finding and welcoming new members, each part off until you turn it on (see Recruiting below). `/gt recruit`.
12. **Raffle.** Sell raffle tickets for gold deposited into a guild bank or mailed to you, see how many tickets each person bought, and draw the winners when sales end. Works without a guild too, for housing, fashion or other groups. Off until you turn it on (see Raffle below). `/gt raffle`.

Every tab has an **Export / copy** button: the current view as comma-separated text (CSV). Fields that contain a comma are wrapped in quotes. Press **Select all**, then Ctrl+C, and paste into Excel (then Data > Text to Columns > Comma), Google Sheets (Split text to columns) or Discord, or save it as a .csv file. Large exports are split into parts.

Hover over any button, tab or column header for a short tip on what it does.

On first install the addon looks back 30 days (adjustable in settings), as far as the game and LibHistoire have data. Old bank withdrawals over your limits show up as alerts for you to review. Nothing is done to anyone for those.

## Install

1. Install the required libraries from ESOUI or Minion: **LibHistoire** (AddOn version 1112 or newer) and **LibAddonMenu-2.0** (version 43 or newer).
2. Copy the `FurysGuildToolset` folder to `Documents/Elder Scrolls Online/live/AddOns/`.
3. **Choose your guilds:** in settings, "Guilds to get alerts from" has a checkbox per guild. None are ticked at first. Bank, hopper and watchlist alerts, inactivity, bank space (and auto-demote, if you turn it on) only happen in ticked guilds. The History tab still logs every guild. `/gt guilds` shows which are on.
4. **Set each guild's rules:** every ticked guild gets its own "Rules for (guild)" section in settings, so one guild can allow 10 stacks a day and another 40. It holds that guild's bank limits, ignored ranks and names, warning and demotion texts, demote-to rank, auto-demote, put-back time, bank space alert, hopper settings, inactivity limits (including the limit for each rank) and contact texts. "Copy rules from" gives a guild the same settings as another. Guilds that aren't ticked get no section (tick one and reload to add it).
5. **Turn on the features you want:** bank alerts, hopper report, history log, bank space alerts, weekly trader totals, inactivity alerts (per guild), the kick and blacklist mails (per guild) and the login and alert options all start off.
6. Settings: the gear at the top right of the report window, Esc > Settings > Add-Ons > Fury's Guild Management, or `/gtsettings`.

## Commands

| Command | What it does |
|---|---|
| `/gt` | Open the report window (`/gt bank`, `/gt hoppers`, `/gt watchlist`, `/gt history`, `/gt space`, `/gt members`, `/gt inactive`, `/gt trader`, `/gt sales`, `/gt auto`, `/gt recruit`, `/gt raffle`) |
| `/gt tour` | Start or stop the recruiting zone tour |
| `/gt raffle add @name 3 (reason)` | Give someone raffle tickets by hand (`/gt raffle remove @name 3` takes them away). Logged with the reason. Capitals don't matter: the name is matched to a raffle buyer, a member of your guilds or a friend, and if none match it suggests close names and asks before adding |
| `/gt status` | What history has loaded per guild, and the biggest withdrawers against your thresholds |
| `/gt reset` | Rebuild bank alerts and the hopper report from the logged history with your current settings, no reload. Actions you already took are kept |
| `/gt reset full` | Wipe the log and the trader week totals, reload the UI and download the look-back period again. Settings and the watchlist are kept |
| `/crier` | Open the Guild Crier menu |

## Bank alert settings (defaults, set per guild)

| Setting | Default |
|---|---|
| Count by | Stacks: each withdrawal counts as 1, so a stack of recipes = 1. Can switch to item quantity |
| Count per | Calendar day, midnight to midnight on your PC's clock (5 stacks Saturday night and 5 Sunday morning count as 5 each day). Can switch to a rolling window of X hours |
| Warn / Demote / Kick at | 0 / 50 / 0 (stacks, or items if you switch; 0 = never) |
| Gold warn / demote / kick at | 50,000 / 200,000 / 500,000 |
| Ignore top N ranks | 2 (Guild Master and the rank below it) |
| Ignore rank names / @names | empty, comma separated |
| Bank alerts | Off until you turn on "Enable bank alerts" |
| Gold withdrawals | Off until you turn on "Watch gold withdrawals too" |
| Auto-demote | Off |

Deposits never count, so officers stocking the bank never trigger anything. A stack the same member puts back whole (same item, same count, within 72 hours by default) stops counting toward the limits, and an alert that falls below every limit is marked "under limits after returns". A stack that comes back partly used (199 of 200) still counts. Auto-demote acts the moment someone reaches the limit, so a later return doesn't undo it. Withdrawals do count, so add bankers and officers who restock to the ignore lists.

## Auto-demote (optional, off by default)

Settings > Rules for (guild) > "Auto-demote at the demote threshold", for each guild separately. When on, the addon demotes someone with no dialog when they reach the demote threshold, with these limits:

- Only withdrawals made after you turn it on count. Turning it on never acts on old history.
- Never anyone at or above your rank, and never ignored names or ranks.
- At most 5 per session over all guilds (adjustable under Guild bank alerts), so a bad threshold can't sweep the guild.
- Only in guilds ticked under "Guilds to get alerts from", and only while you're logged in.

The demotion mail is a separate setting, "Send the demotion mail automatically", also off by default. When it's off, the alert shows "(mail not sent)" with Send the demotion mail in its right-click menu. When it's on, the mail goes out after the demotion, once you're out of combat and not using the mailbox yourself. Kick and blacklist always need your click.

"Note the reason in their guild note" (off by default) adds one line to the end of their guild note after an auto-demote, for example "Bank Nov 18: took 41 stacks (157 items), put back 0 whole/0 partly. Auto-demoted (limit 15 per day)." Their note is kept, the same line is never added twice, and nothing is written if the note would go over the game's 254 characters. Whether the line was added shows in chat and in the Auto tab.

With "Alert window for auto-demotes" on (Settings > Automatic actions, off by default), every auto-demote opens a big alert window that stays until you close it with Close, the X or Esc. If several people are demoted before you close it, they're listed in the same window instead of stacking up new ones, and Open log takes you to the Auto tab. You also get a chat breakdown of why, and each one is kept in the Auto tab with the withdrawals behind it, whether the server confirmed the new rank, and whether the mail was sent. Press "Test the alert window" to see it. The addon never kicks anyone by itself, so there's no kick alert.

## Warning and demotion mails

Warn and Demote open a filled-in mail ("On (date) you withdrew (amount)..."): the date, the amount, the guild, and your bank rules (taken from the Crier's "Guild Bank 101" message unless you fill in "Bank rules" in settings). Both texts are editable for each guild in settings. You press Send.

## Kick and blacklist mails (optional, off by default)

Settings > Rules for (guild) > "Mail when you kick or blacklist", for each guild separately:

- **Mail members kicked for inactivity.** Kick on the Inactive tab mails them why they were removed (days offline and the limit for their rank) and that they're welcome back if they return to the game.
- **Mail members you blacklist.** Kick and blacklist, or Blacklist, on any tab (Members, Inactive, Bank, Hoppers, Watchlist) mails them the reason.

Kick, Kick and blacklist and Blacklist open a confirm window. When blacklisting it has a reason box, filled in for you (for example "took 41 stacks from the bank on Nov 18" or your "Blacklist reason" setting) that you can change. The reason becomes their blacklist note and goes in the mail. The window's **Send mail** button turns the mail on or off for that one person, and hovering it shows the whole mail. The mail is sent after you click Confirm, in the background (normal postage), once you're out of combat and not using the mailbox yourself, and chat tells you when the server confirms it. Both texts are editable: `<<1>>` = @name, `<<2>>` = guild, then `<<3>>` = days offline and `<<4>>` = their limit (kick), or `<<3>>` = the reason (blacklist).

## Recruiting (optional, every part off by default)

Turn on what you want in `/gtsettings` under **Recruiting**. The Recruit tab's top line shows the guild you recruit for, its members and open slots (out of 500), pending applications, and whether it has a trader this week.

- **Zone ads and zone tour.** Write a zone ad for each guild (`{guild}` becomes the guild's name). "Put ad in chat" (a button and a keybind) puts it in the zone chat box and you press Enter. When your ad goes out, that zone goes on cooldown (15 minutes by default, up to 4 hours; it counts from each post, so set it longer than a whole tour takes if you run the tour twice) and the Recruit tab lists every zone as ready or on cooldown. If you try to post in a zone that's still on cooldown, it asks first. **Start tour:** the ad goes in the chat box, and each time you press Enter to post it you travel to the next ready zone's open world (through a guildmate or friend standing in the zone itself, never one inside a dungeon, delve, trial or other instance, or a house you own there) and the ad is waiting in the chat box when you arrive. Nothing moves until you post. If a jump fails (for example "not in same group", or the person moved), it tries the next person in that zone, then the next ready zone, and stops the tour only after 8 failed tries. Right-click a zone to travel there, clear its cooldown, or leave it out of the tour. There's also a keybind that travels once to the next ready zone.
- **Status bar.** A small bar on screen (off by default; turn it on for the zone tour only or always) shows the guild you recruit for, zones posted out of the total (for example 5/23, zones on cooldown out of every zone the tour can visit), pending guild applications, and whether whisper leads are listening. Drag it anywhere; it hides in menus like the rest of the HUD.
- **Invite from player names in chat.** Right-click a name in chat for "Invite to (guild)", for each guild where your rank can invite.
- **Whisper leads.** When someone whispers one of your keywords (inv, invite, join, guild by default), you get a chat line with an [Invite] link and a row on the Recruit tab. Nobody is invited until you click.
- **Join notices.** A chat line when someone joins a guild where you can invite, with the member count, open slots, a warning when the guild is nearly full, and a note when it has no trader this week.
- **Each guild has its own welcome.** Welcomes only happen in guilds you turn them on for, each with its own message and mail (pick the guild under "Welcome settings for" and tick "Welcome new members in this guild"). Your other guilds get nothing, and join notices only show for the guild you recruit for and guilds with welcomes on.
- **Welcome message.** When a new member joins while online, the welcome (`{new}` = their @name) goes into that guild's chat box and you press Enter. If you're typing, or you welcomed someone a few minutes ago, you get a [Say welcome] link instead. You can welcome only the people you invited or accepted (the default, so two officers don't both welcome the same person) or everyone who joins.
- **Welcome mail.** For new members who joined while offline: a [Write welcome mail] link and a row on the Recruit tab open the mail filled in for you to send. Tick "Mail new members who join while online too" to mail everyone who joins. Turn on "Send the welcome mail automatically" to have it sent in the background instead (normal postage), like the demotion mail.

## Raffle (optional, off by default)

Turn it on in `/gtsettings` under **Raffle** (reload when asked), then set it up there. The raffle settings also have their own panel, "Fury's Guild Management - Raffle", which the **Raffle settings** button and **New / other raffles > New raffle** on the Raffle tab open. The settings work on the raffle shown on the Raffle tab:

- **How tickets are bought:** gold deposited into the raffle guild's bank, gold mailed to you, or both. Pick "(no guild)" for a mail-only raffle, for groups that aren't a guild.
- **Prizes:** one per line (or separated by `;`). The first goes to the winner of draw 1, the second to draw 2, and so on, and the number of winners is set to match. For one prize, type it once. List the prize names here, not the codes themselves, since they appear in the posts.
- **Ticket price, number of winners, one win per person** (on by default; off lets someone with many tickets win more than once), and an optional **most tickets per person**.
- **Start and length:** type a start time (YYYY-MM-DD HH:MM in your local time; a start in the past counts payments since then) or leave it empty and click **Start sales now** on the Raffle tab. Sales run for the number of hours you set, and you can make that longer or shorter while they run.

**Countdown.** While sales run, the Raffle tab button and the top line count down to the end, second by second.

**Several raffles at once.** **New / other raffles > Add another raffle to sell at the same time** sets up a second (third, ...) raffle with its own prizes, price, sale times, draw and posts. The same button switches between raffles. A payment that only one raffle could take counts for it as described below. When two raffles could take the same payment (the same guild bank, or both take mail, and both are selling):

- **Mail** counts for the raffle whose **mail subject keyword** is in the subject (for example "gold" for one raffle and "pet" for another). Each raffle that takes mail needs its own keyword.
- **Bank deposits** count for the raffle whose ticket price the deposit is an **exact multiple** of. Give each raffle its own odd price, such as 1,001g and 1,003g; a new raffle gets one automatically. The Raffle tab warns you when two prices or keywords are too alike.
- Anything still unclear (a deposit that fits no price or two, a mail with no keyword or two) goes to **Unassigned payments** (in the New / other raffles menu) instead of being dropped. Right-click one there to count it for a raffle or ignore it, and undo either later. A raffle can't draw while an unassigned payment might be for it.
- Once a raffle's winners are drawn (or it's put away), the payments it counted stay with it.

**Counting tickets.** The amount alone decides: each deposit or mail during the sale buys its amount divided by the ticket price, rounded down. With a 1,000g ticket, 5,000g buys 5 tickets and 5,600g also buys 5; the extra 600g is dropped, not carried over to the next payment. Pick a round ticket price such as 1,000g or 5,000g so multiples are easy. Plain donations to the bank during the sale buy tickets too. Gold that didn't buy a ticket, and gold over the per-person limit, shows as **Not used**. The Raffle tab lists every buyer with their tickets, ticket numbers, gold, gold not used and chance. Right-click a buyer to whisper or mail them, add or remove tickets by hand, or leave them out of the draw. Every change by hand is logged and shown when you hover the row. Everything is saved, so reloads and logouts lose nothing.

- **Bank deposits** are read from guild history through LibHistoire. The raffle has its own reader, so the first time you turn it on it reads back as far as the first-run look-back setting, and deposits are kept for 45 days.
- **Mailed gold:** the game only shows an addon your mail while your mailbox is open. Each time you open it, every mail with gold attached is recorded once, with the time it arrived. You don't have to open each mail. Every mail with gold counts, like every bank deposit (you can type a word in settings to count only mails with it in the subject). A mail is also recorded when you open it and right before you take its gold, and each counted mail prints a line in chat.

**The draw.** When sales end you get a notice. Click **Draw winners** (or, while sales run, **End and draw now** to end them and draw at once with the tickets counted so far). Draw winners waits a minute for the last bank deposits to arrive and, for mail raffles, until you've opened your mailbox once after the end. Tickets are numbered in order of each buyer's first payment, and each draw picks a random ticket. With one win per person, earlier winners' tickets are skipped. The draw can't be redone. If a winner can't take the prize, right-click them and pick **Void win, draw a replacement**. **Winners to guild chat** puts the winners and their prizes in the guild chat box (one part at a time) for you to press Enter, for example "Draw 1: ticket #137 goes to @Name (tickets 120-141) for Prize A". **Winners for Discord** shows the same as Discord-ready text (bold names, one winner per line) in a copy window. While sales run, **Announce in guild** and **Text for Discord** do the same for the prizes, price, how to buy and time left; the Discord text shows the end time in each reader's own time zone. Without a raffle guild, the guild buttons show the text to copy instead. Right-click a winner for **Mail prize**, a mail filled in with their winning ticket, ready for you to add the code. **New / other raffles > New raffle** puts the finished raffle away (its results are kept), keeps your settings, and opens the raffle settings so you can set up the next one.

## What the ESO API allows

| Need | Allowed? | How the addon does it |
|---|---|---|
| Read bank, roster and guild store sales history | Yes, through the guild history API | All history comes through LibHistoire, which handles every server request and keeps history gap-free between sessions. The addon remembers the last event it processed per guild, so each login picks up where you left off, and new events arrive live while you play. |
| Demote, set rank, kick, blacklist | Yes, within your rank's permissions | Right-click menu items with a confirmation window. Only auto-demote (if you turn it on) acts without a click. |
| Send mail | Yes | Warn and Demote open a filled-in mail for you to send. The optional auto-demote mail is sent by itself, and the optional kick and blacklist mails are sent after you confirm the kick or blacklist. |
| Send whispers | **No.** Addons can't send chat messages | "Warn" by whisper puts the text in your chat box and you press Enter. Zone ads, welcomes and raffle posts work the same way. |
| Read your mail | Only while your mailbox is open | The raffle records gold mails each time you open your mailbox. |
| Invite and travel | Yes | Invites happen only when you click Invite. The zone tour travels once each time you post your ad; there is no automatic loop. |
| Act while you're offline | **No.** Addons only run while you're logged in | Anything that happened while you were offline is processed at your next login and shown as alerts. |

## Saved data

Settings and the log are saved account-wide, separately for NA and EU, in `SavedVariables/FurysGuildToolset.lua`.

## Credits

- Guild history is read through **LibHistoire** by sirinsidiator (Artistic License 2.0).
- Settings panels use **LibAddonMenu-2.0** by Seerah and sirinsidiator.
- Game API details from the ESOUI wiki and ZeniMax's ESO UI source code.
- Thanks to Dack for code review feedback on how guild history should be read.

The Guild Crier started as my own separate addon, "Fury's Guild Crier", and is now part of this toolset.
