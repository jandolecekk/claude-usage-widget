# Claude usage widget

A small macOS menu bar app that shows how much of your Claude plan you have used, what your Claude Code sessions are doing, and how your Mac's memory is holding up.

The menu bar icon shows the current 5-hour session limit in % and the number of Claude Code sessions that are working right now. Click it to open a Liquid Glass panel with the details.

The UI is in Czech by default. Switch to English with the **EN** button in the panel header (or right-click → *Switch to English*). The choice is remembered.

Requires macOS 26 (Tahoe) and the Swift toolchain from the Xcode Command Line Tools. Full Xcode is not needed.

## What it shows

- **Plan limits**: the 5-hour session, the weekly limit and per-model weekly limits, with reset times and a forecast of when you hit the session limit at your current pace.
- **Claude Code today and over 7 days**: tokens (including cache), output tokens, replies and sessions, plus a 7-day sparkline.
- **Open sessions**: status (working / running a command / waiting), uptime, tokens, RAM, context window fill, cache state, and subagents with their duration, tokens and tool calls.
- **Tips**: pace against the session limit, weekly limit ≥ 70 %, context ≥ 70 %, cold cache (idle longer than the cache TTL with a context of 150k+), memory pressure.
- **Mac memory**: used / total, app / wired / compressed, swap, pressure, top apps. An optional small glass card for the desktop.

## Where the data comes from

- **Plan limits**: `api.anthropic.com/api/oauth/usage`, the undocumented endpoint that `/usage` in Claude Code uses. The OAuth token is read from the Keychain item `Claude Code-credentials` via `/usr/bin/security`. The widget never refreshes or stores the token; if it has expired, open Claude Code.
- **Usage stats**: local Claude Code logs in `~/.claude/projects/**/*.jsonl`.
- **Sessions**: `~/.claude/sessions/<pid>.json` (live PIDs only); subagents from `~/.claude/projects/<cwd>/<session>/subagents/*.jsonl` and `.meta.json`.
- **Context window**: not stored in the logs. The widget assumes 1M tokens for the 5.x Opus / Fable / Sonnet models (auto-compact was observed at 976k) and 200k for Haiku; see `contextLimit(for:)`. Cache TTL is 1 h when `usage.cache_creation.ephemeral_1h_input_tokens` is present, otherwise 5 min.
- **Memory**: totals computed the way Activity Monitor does (app = internal − purgeable, wired, compressor pages), swap from `vm.swapusage`, pressure from `kern.memorystatus_vm_pressure_level`. Per process it uses `ri_phys_footprint` (Activity Monitor's *Memory* column), grouped by the owning `.app`. Claude Code = every `claude` process plus everything it spawned (MCP servers, shells, dev servers). Root processes can't be read.

Plan limits refresh every 5 minutes; sessions and memory every 10 seconds. Refresh manually with the arrow button or right-click → *Refresh*.

## Notifications

- Session or weekly limit at ≥ 80 % and ≥ 95 % (once per reset window).
- A session goes from working to waiting.
- Session context at ≥ 80 % and ≥ 90 % (once per session).
- Critical memory pressure (at most once an hour).

Turn them off with the bell in the panel header.

## Build and run

```sh
./build.sh              # builds ClaudeUsage.app (ad-hoc signed; notifications need an .app bundle)
open ClaudeUsage.app
```

Start at login (run from this folder; `sed` fills in where the app lives):

```sh
sed "s|__APP_DIR__|$PWD|" com.jandolecek.claude-usage-widget.plist > ~/Library/LaunchAgents/com.jandolecek.claude-usage-widget.plist
launchctl load ~/Library/LaunchAgents/com.jandolecek.claude-usage-widget.plist
```

Quit with the power button in the panel (desktop mode: right-click → *Quit widget*).

Other modes:

- `--desktop`: a floating glass card on the desktop instead of the menu bar icon. Drag to move; the position is remembered.
- `--dump`: print what the widget sees (sessions, usage, memory) to the terminal, for debugging.

## Notes

- **The icon is missing from the menu bar?** On a MacBook with a notch, macOS hides status items that don't fit to the right of the notch, without any warning. The widget asks for a slot near the clock (`NSStatusItem Preferred Position ClaudeUsage` in `com.jandolecek.claude-usage`); ⌘-drag the icon to move it. If it is still hidden, make room by turning off other menu bar items (System Settings → Menu Bar) or by shortening wide ones.
- The panel scrolls when it is taller than the screen.
- `@State` doesn't compile without Xcode (the macro plugin is missing), so UI state lives in `UsageStore`.

## License

[MIT](LICENSE)
