# Claude usage widget

Ikona v horní liště (menu bar) s % session limitu a počtem pracujících session; klik otevře Liquid Glass panel. Volitelně `--desktop` = plovoucí karta na ploše (SwiftUI `.glassEffect`). `--dump` vypíše data do terminálu.

- **Limity plánu** (session 5 h, týden, týden pro jednotlivé modely) z `api.anthropic.com/api/oauth/usage` – nedokumentovaný endpoint, který používá `/usage` v Claude Code. Token se čte z Keychainu (`Claude Code-credentials`) přes `/usr/bin/security`; widget ho nikdy neobnovuje sám.
- **Claude Code dnes / 7 dní** z lokálních logů `~/.claude/projects/**/*.jsonl` (tokeny vč. cache, odpovědi, sessions).
- Obnova každých 5 min, ručně šipkou nebo pravým klikem. Tažením se přesouvá, pozice se pamatuje.

Build: `./build.sh` → `ClaudeUsage.app` (ad-hoc podepsaný bundle, nutný kvůli notifikacím). Spuštění: `open ClaudeUsage.app`.
Spuštění po přihlášení: `cp com.jandolecek.claude-usage-widget.plist ~/Library/LaunchAgents/ && launchctl load ~/Library/LaunchAgents/com.jandolecek.claude-usage-widget.plist`
Ukončení: ikona ⏻ v panelu (desktop režim: pravý klik → Ukončit widget).

Sessions: `~/.claude/sessions/<pid>.json` (živé PID), subagenti `~/.claude/projects/<cwd>/<session>/subagents/*.jsonl` + `.meta.json`. Pozn.: `@State` nejde bez Xcode (chybí macro plugin) → UI stav drží `UsageStore`.

## Notifikace a doporučení
- Limit session/týden ≥ 80 % a ≥ 95 % (jednou za reset okno).
- Session přešla z „pracuje / běží příkaz“ na „čeká“.
- Kontext session ≥ 80 % a ≥ 90 % (jednou za session).
- Doporučení v panelu: tempo vs. session limit, týden ≥ 70 %, kontext ≥ 70 %, vychladlá cache (idle > TTL a kontext ≥ 150k).
- Kontextové okno: v logu není, předpoklad 1M pro 5.x Opus/Fable/Sonnet (auto-compact pozorován na 976k), 200k Haiku – `contextLimit(for:)`.
- Cache TTL podle `usage.cache_creation.ephemeral_1h_input_tokens` (1 h, jinak 5 min).
- Zvonek v panelu notifikace vypne/zapne.

## Paměť (RAM)
- Sekce „Mac · paměť“ v panelu + malá skleněná karta na ploše (přepínač v panelu / pravý klik → Skrýt).
- Součty jako Monitor aktivity: aplikace = internal − purgeable, pevná = wired, komprese = compressor pages; swap z `vm.swapusage`; tlak z `kern.memorystatus_vm_pressure_level` (1/2/4).
- Procesy: `ri_phys_footprint` (= sloupec Paměť), seskupené podle nejvyšší `.app`; Claude Code = `claude` + všechny jeho podprocesy (MCP, shelly, dev servery). Root procesy (CrowdStrike, JumpCloud…) číst nejdou.
- Notifikace při kritickém tlaku (max 1×/h), doporučení při zvýšeném (vč. RAM nečinných session).
