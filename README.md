# Fury's Guild Management Toolset

**AI disclosure:** This addon's code was written with the assistance of an AI coding assistant (Claude by Anthropic), working from my designs and instructions. I test every release in game in my own guilds before it goes up, and I maintain it.

An Elder Scrolls Online addon for guild leaders and officers: guild bank theft and bank-space alerts, a bank-hopper report and watchlist, a log of every automatic action with the reason, member status and inactivity alerts, weekly trader sales, tax, bids and donations, a history log with export, recruiting tools (zone ads and zone tour, whisper leads, welcomes), a raffle (tickets bought with guild bank or mailed gold, and the winners draw), guild events from sesh sign-ups in Discord (who's missing, invites, guild ads, Group Finder listings), and the Guild Crier message menu. Every feature starts turned off; turn on what you want in `/gtsettings`.

## Downloads

- **The addon:** get it from [ESOUI](https://www.esoui.com/downloads/info5063.html) or Minion. The same files are in [`FurysGuildToolset/`](FurysGuildToolset/) here, and as [FurysGuildToolset-1.24.3.zip](https://github.com/AlbertHoffpauir/FurysGuildToolset/raw/main/downloads/FurysGuildToolset-1.24.3.zip).
- **Requires:** LibHistoire (1112 or newer) and LibAddonMenu-2.0 (43 or newer), installed separately.

## Repository layout

| Folder | What |
|---|---|
| `FurysGuildToolset/` | The addon, exactly as it goes into `Documents\Elder Scrolls Online\live\AddOns`. See its [README](FurysGuildToolset/README.md). |
| `downloads/` | Ready-made zip for each release. |

## Credits

- Guild history is read through **LibHistoire** by sirinsidiator (Artistic License 2.0).
- Settings panels use **LibAddonMenu-2.0** by Seerah and sirinsidiator.
- Game API details from the ESOUI wiki and ZeniMax's ESO UI source code.
- Thanks to Dack for code review feedback on how guild history should be read.

License: MIT (see [LICENSE](LICENSE)).
