import SwiftUI
import AppKit
import Combine
import UserNotifications

// MARK: - Data

struct LimitItem: Identifiable {
    let id: String
    let label: String
    let percent: Double
    let resetsAt: Date?
    let severity: String
}

struct LocalStats {
    var todayTokens = 0, todayOutput = 0, todayMessages = 0, todaySessions = 0
    var weekTokens = 0
    var daily: [Int] = Array(repeating: 0, count: 7)   // oldest → today
    var topModel = "—"
    var perSession: [String: Int] = [:]   // sessionId → tokens in last 7 days (incl. subagents)
}

struct SubagentInfo: Identifiable {
    let id: String
    let description: String, type: String, model: String
    let start: Date?, end: Date?
    let running: Bool
    let tokens: Int, toolCalls: Int
}

struct SessionInfo: Identifiable {
    let id: String          // sessionId
    let pid: Int32
    let name: String, folder: String, cwd: String
    let status: String, kind: String
    let startedAt: Date, updatedAt: Date
    var subagents: [SubagentInfo]
    var context = ContextInfo()

    var contextPercent: Double { context.limit > 0 ? Double(context.tokens) / Double(context.limit) * 100 : 0 }
    var idleFor: TimeInterval { status == "idle" ? Date().timeIntervalSince(updatedAt) : 0 }
    /// Prompt cache has expired, so the next message re-reads the whole context at full price.
    var cacheExpired: Bool { status == "idle" && context.tokens > 0 && idleFor > context.cacheTTL }
}

struct ContextInfo {
    var tokens = 0          // size of the last request sent = current context
    var limit = 0
    var model = ""
    var cacheTTL: TimeInterval = 300
}

/// Context window per model. Not stored in the logs: 1M is what Claude Code uses for the 5.x Opus/Fable/Sonnet
/// models here (sessions reached 966k, auto-compact fired at 976k); Haiku stays at 200k.
func contextLimit(for model: String) -> Int {
    model.contains("haiku") ? 200_000 : 1_000_000
}

enum SessionScanner {
    private static var cache: [String: (Date, SubagentInfo)] = [:]   // path → (mtime, parsed)
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    static func projectDir(for cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    static func scan() -> [SessionInfo] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        guard let files = try? fm.contentsOfDirectory(at: home.appendingPathComponent("sessions"),
                                                      includingPropertiesForKeys: nil) else { return [] }
        var out: [SessionInfo] = []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let pid = (o["pid"] as? NSNumber)?.int32Value, kill(pid, 0) == 0,
                  let sid = o["sessionId"] as? String, let cwd = o["cwd"] as? String else { continue }
            func ms(_ k: String) -> Date { Date(timeIntervalSince1970: ((o[k] as? NSNumber)?.doubleValue ?? 0) / 1000) }
            let subDir = home.appendingPathComponent("projects/\(projectDir(for: cwd))/\(sid)/subagents")
            out.append(SessionInfo(id: sid, pid: pid,
                                   name: o["name"] as? String ?? String(sid.prefix(8)),
                                   folder: (cwd as NSString).lastPathComponent, cwd: cwd,
                                   status: o["status"] as? String ?? "?", kind: o["kind"] as? String ?? "",
                                   startedAt: ms("startedAt"), updatedAt: ms("updatedAt"),
                                   subagents: subagents(in: subDir),
                                   context: context(of: home.appendingPathComponent("projects/\(projectDir(for: cwd))/\(sid).jsonl"))))
        }
        let rank = ["busy": 0, "shell": 1]
        return out.sorted { (rank[$0.status] ?? 2, -$0.updatedAt.timeIntervalSince1970) < (rank[$1.status] ?? 2, -$1.updatedAt.timeIntervalSince1970) }
    }

    /// Reads the tail of the main transcript and takes the last main-thread request's input size.
    static func context(of url: URL) -> ContextInfo {
        guard let h = try? FileHandle(forReadingFrom: url) else { return ContextInfo() }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 1_000_000 ? size - 1_000_000 : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return ContextInfo() }
        for line in text.split(separator: "\n").reversed() where line.contains("\"type\":\"assistant\"") {
            guard !line.contains("\"isSidechain\":true"),
                  let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any],
                  let model = msg["model"] as? String, model != "<synthetic>" else { continue }
            func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
            let cc = u["cache_creation"] as? [String: Any]
            let oneHour = ((cc?["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0) > 0
            return ContextInfo(tokens: n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens"),
                               limit: contextLimit(for: model), model: prettyModel(model),
                               cacheTTL: oneHour ? 3600 : 300)
        }
        return ContextInfo()
    }

    static func subagents(in dir: URL) -> [SubagentInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var list: [SubagentInfo] = []
        for f in files where f.pathExtension == "jsonl" {
            guard let mtime = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            let running = Date().timeIntervalSince(mtime) < 90
            if let c = cache[f.path], c.0 == mtime {
                let a = c.1
                list.append(SubagentInfo(id: a.id, description: a.description, type: a.type, model: a.model,
                                         start: a.start, end: a.end, running: running, tokens: a.tokens, toolCalls: a.toolCalls))
                continue
            }
            var meta: [String: Any] = [:]
            let metaURL = f.deletingPathExtension().appendingPathExtension("meta.json")
            if let d = try? Data(contentsOf: metaURL), let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { meta = m }
            var start: Date?, end: Date?, tokens = 0, tools = 0, model = meta["model"] as? String ?? ""
            var seen = Set<String>()
            if let text = try? String(contentsOf: f, encoding: .utf8) {
                text.enumerateLines { line, _ in
                    guard let d = line.data(using: .utf8),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
                    if let ts = o["timestamp"] as? String, let t = iso.date(from: ts) {
                        if start == nil { start = t }; end = t
                    }
                    guard o["type"] as? String == "assistant", let msg = o["message"] as? [String: Any] else { return }
                    if let m = msg["model"] as? String { model = m }
                    if let content = msg["content"] as? [[String: Any]] {
                        tools += content.filter { $0["type"] as? String == "tool_use" }.count
                    }
                    let key = (o["requestId"] as? String ?? "") + (msg["id"] as? String ?? "")
                    guard let u = msg["usage"] as? [String: Any], seen.insert(key).inserted else { return }
                    for k in ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"] {
                        tokens += (u[k] as? NSNumber)?.intValue ?? 0
                    }
                }
            }
            let a = SubagentInfo(id: f.lastPathComponent,
                                 description: meta["description"] as? String ?? "subagent",
                                 type: meta["agentType"] as? String ?? "", model: prettyModel(model),
                                 start: start, end: end, running: running, tokens: tokens, toolCalls: tools)
            cache[f.path] = (mtime, a)
            list.append(a)
        }
        return list.sorted { ($0.running ? 1 : 0, $0.start ?? .distantPast) > ($1.running ? 1 : 0, $1.start ?? .distantPast) }
    }
}

struct AppMem: Identifiable {
    let id: String          // display name
    let bytes: UInt64
    let processes: Int
    let isClaudeCode: Bool
}

struct MemStats {
    var total: UInt64 = 0, used: UInt64 = 0, app: UInt64 = 0, wired: UInt64 = 0
    var compressed: UInt64 = 0, cached: UInt64 = 0, swap: UInt64 = 0
    var pressure: Int32 = 1          // kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical
    var apps: [AppMem] = []
    var perPid: [Int32: UInt64] = [:] // footprint incl. child processes, for Claude Code sessions
    var unreadable = 0

    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var pressureText: String { pressure >= 4 ? "kritické" : pressure >= 2 ? "zvýšené" : "normální" }
}

enum MemScanner {
    static func scan() -> MemStats {
        var m = MemStats()
        m.total = ProcessInfo.processInfo.physicalMemory

        // System totals, computed the way Activity Monitor does
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            let pg = UInt64(vm_kernel_page_size)
            m.app = UInt64(vm.internal_page_count - vm.purgeable_count) * pg
            m.wired = UInt64(vm.wire_count) * pg
            m.compressed = UInt64(vm.compressor_page_count) * pg
            m.cached = UInt64(vm.external_page_count + vm.purgeable_count) * pg
            m.used = m.app + m.wired + m.compressed
        }
        var sw = xsw_usage(); var sz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &sz, nil, 0) == 0 { m.swap = sw.xsu_used }
        var lvl: Int32 = 1; sz = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl, &sz, nil, 0) == 0 { m.pressure = lvl }

        // Per process: physical footprint (= "Paměť" column), grouped by owning .app
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return m }
        var pids = [pid_t](repeating: 0, count: Int(n) * 2)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var foot: [pid_t: UInt64] = [:], parent: [pid_t: pid_t] = [:], group: [pid_t: String] = [:]
        var pathBuf = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(got) where pid > 0 {
            var ri = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard r == 0 else { m.unreadable += 1; continue }
            foot[pid] = ri.ri_phys_footprint
            var bsd = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
                parent[pid] = pid_t(bsd.pbi_ppid)
            }
            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let path = len > 0 ? String(cString: pathBuf) : ""
            group[pid] = groupName(path)
        }
        // Claude Code: `claude` processes plus everything they spawned (MCP servers, shells, dev servers)
        let roots = Set(group.filter { $0.value == "claude" }.map(\.key))
        func claudeRoot(_ pid: pid_t) -> pid_t? {
            var p = pid, hops = 0
            while hops < 12, p > 1 {
                if roots.contains(p) { return p }
                guard let pp = parent[p] else { return nil }
                p = pp; hops += 1
            }
            return nil
        }
        var byApp: [String: (UInt64, Int)] = [:]
        for (pid, bytes) in foot {
            if let root = claudeRoot(pid) {
                m.perPid[Int32(root), default: 0] += bytes
                byApp["Claude Code", default: (0, 0)].0 += bytes
                byApp["Claude Code", default: (0, 0)].1 += 1
            } else {
                let name = group[pid] ?? "?"
                byApp[name, default: (0, 0)].0 += bytes
                byApp[name, default: (0, 0)].1 += 1
            }
        }
        m.apps = byApp.map { AppMem(id: $0.key, bytes: $0.value.0, processes: $0.value.1, isClaudeCode: $0.key == "Claude Code") }
            .sorted { $0.bytes > $1.bytes }
        return m
    }

    /// "/Applications/Slack.app/Contents/Frameworks/Slack Helper (Renderer).app/…" → "Slack"
    static func groupName(_ path: String) -> String {
        // Claude Code installs as ~/.local/share/claude/versions/<version>
        if path.contains("/claude/versions/") || (path as NSString).lastPathComponent == "claude" { return "claude" }
        if path.hasSuffix("com.apple.Virtualization.VirtualMachine") { return "Virtuální stroj (Claude Cowork)" }
        if let r = path.range(of: ".app/") {
            let app = String(path[..<r.lowerBound])
            return (app as NSString).lastPathComponent
        }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "?" : name
    }
}

func gb(_ b: UInt64) -> String {
    let g = Double(b) / 1_073_741_824
    return g >= 1 ? String(format: "%.1f GB", g) : String(format: "%.0f MB", Double(b) / 1_048_576)
}

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let defaults = UserDefaults.standard
    private var inBundle: Bool { Bundle.main.bundleIdentifier != nil }

    var enabled: Bool {
        get { defaults.object(forKey: "notificationsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notificationsEnabled") }
    }

    func setUp() {
        guard inBundle else { return }   // UNUserNotificationCenter needs an .app bundle
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Fires at most once per `key` (persisted, so restarts don't repeat alerts).
    func send(key: String? = nil, title: String, body: String) {
        guard enabled else { return }
        if let key {
            var fired = Set(defaults.stringArray(forKey: "firedAlerts") ?? [])
            guard fired.insert(key).inserted else { return }
            defaults.set(Array(fired.suffix(300)), forKey: "firedAlerts")
        }
        if inBundle {
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        } else {
            let esc = { (x: String) in x.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "'") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
            try? p.run()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

struct Tip: Identifiable {
    let id: String
    let icon: String
    let text: String
    let urgent: Bool
}

func prettyModel(_ m: String) -> String {
    m.replacingOccurrences(of: "claude-", with: "")
        .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"-(\d+)-(\d+)$"#, with: " $1.$2", options: .regularExpression)
        .replacingOccurrences(of: "-", with: " ").capitalized
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var limits: [LimitItem] = []
    @Published var plan = ""
    @Published var local = LocalStats()
    @Published var updated: Date?
    @Published var error: String?
    @Published var sessions: [SessionInfo] = []
    @Published var sessionsOpen = false
    @Published var openSessions = Set<String>()

    private var timer: Timer?
    private var fastTimer: Timer?
    private var scanningSessions = false

    @Published var mem = MemStats()
    @Published var memHistory: [Double] = []   // used fraction, one sample per 10 s
    @Published var memOpen = false
    @Published var memDesktop = UserDefaults.standard.object(forKey: "memDesktop") as? Bool ?? true {
        didSet { UserDefaults.standard.set(memDesktop, forKey: "memDesktop") }
    }
    private var scanningMem = false

    func refreshMemory() {
        guard !scanningMem else { return }
        scanningMem = true
        Task.detached {
            let m = MemScanner.scan()
            await MainActor.run {
                self.mem = m
                self.memHistory = Array((self.memHistory + [m.usedFraction]).suffix(90))
                self.scanningMem = false
                if m.pressure >= 4, let top = m.apps.first {
                    let hour = Int(Date().timeIntervalSince1970) / 3600
                    Notifier.shared.send(key: "mem-\(hour)", title: "Kritické zatížení paměti",
                                         body: "Nejvíc bere \(top.id) (\(gb(top.bytes))). Swap \(gb(m.swap)).")
                }
            }
        }
    }

    @Published var notificationsOn = Notifier.shared.enabled { didSet { Notifier.shared.enabled = notificationsOn } }
    private var lastStatus: [String: String] = [:]

    func refreshSessions() {
        guard !scanningSessions else { return }
        scanningSessions = true
        Task.detached {
            let list = SessionScanner.scan()
            await MainActor.run {
                self.sessionAlerts(list)
                self.sessions = list; self.scanningSessions = false
            }
        }
    }

    private func sessionAlerts(_ list: [SessionInfo]) {
        let first = lastStatus.isEmpty
        for s in list {
            let was = lastStatus[s.id]
            if !first, let was, was != "idle", s.status == "idle" {
                Notifier.shared.send(title: "\(s.name) čeká na tebe",
                                     body: "Session v \(s.folder) dokončila práci.")
            }
            for t in [80.0, 90.0] where s.contextPercent >= t {
                Notifier.shared.send(key: "ctx-\(s.id)-\(Int(t))",
                                     title: "Kontext \(s.name): \(Int(s.contextPercent)) %",
                                     body: t >= 90 ? "Blíží se auto-compact. Zadej /compact, nebo začni novou session."
                                                   : "Na nový úkol je lepší nová session (nebo /compact).")
            }
        }
        lastStatus = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.status) })
    }

    private func limitAlerts() {
        for l in limits where l.id.hasSuffix("session") || l.id.hasSuffix("weekly_all") {
            let stamp = Int(l.resetsAt?.timeIntervalSince1970 ?? 0) / 3600
            for t in [80.0, 95.0] where l.percent >= t {
                Notifier.shared.send(key: "lim-\(l.id)-\(Int(t))-\(stamp)",
                                     title: "\(l.label): \(Int(l.percent)) % limitu",
                                     body: resetText(l.resetsAt).capitalized + ".")
            }
        }
    }

    /// Practical advice derived from limits + open sessions.
    var tips: [Tip] {
        var out: [Tip] = []
        if let sess = limits.first(where: { $0.id.hasSuffix("session") }), let f = forecast(sess), !f.contains("vystačíš") {
            out.append(Tip(id: "pace", icon: "speedometer", text: f + " – zvolni, nebo dej lehčí úkoly menšímu modelu.", urgent: true))
        }
        if let w = limits.first(where: { $0.id.hasSuffix("weekly_all") }), w.percent >= 70 {
            out.append(Tip(id: "week", icon: "calendar", text: "Týdenní limit \(Int(w.percent)) % – \(resetText(w.resetsAt)).", urgent: w.percent >= 90))
        }
        for s in sessions {
            if s.contextPercent >= 70 {
                out.append(Tip(id: "ctx-\(s.id)", icon: "rectangle.stack.badge.minus",
                               text: "\(s.name): kontext \(Int(s.contextPercent)) % – na nový úkol nová session, jinak /compact.",
                               urgent: s.contextPercent >= 85))
            }
        }
        if mem.pressure >= 2 {
            let idleCC = sessions.filter { $0.status == "idle" && $0.idleFor > 3600 }
            let idleBytes = idleCC.reduce(UInt64(0)) { $0 + (mem.perPid[$1.pid] ?? 0) }
            var t = "Paměť pod tlakem (\(mem.pressureText), swap \(gb(mem.swap)))."
            if let top = mem.apps.first { t += " Nejvíc: \(top.id) \(gb(top.bytes))." }
            if idleBytes > 300_000_000 { t += " \(idleCC.count) session nečinných přes 1 h drží \(gb(idleBytes)) – zavři je." }
            out.append(Tip(id: "mem", icon: "memorychip", text: t, urgent: mem.pressure >= 4))
        }
        let cold = sessions.filter { $0.contextPercent < 70 && $0.cacheExpired && $0.context.tokens >= 150_000 }
        if !cold.isEmpty {
            let names = cold.prefix(3).map(\.name).joined(separator: ", ") + (cold.count > 3 ? " +\(cold.count - 3)" : "")
            out.append(Tip(id: "cache", icon: "snowflake",
                           text: "Vychladlá cache: \(names). Další zpráva znovu načte celý kontext (150k+). Na nové téma raději novou session.",
                           urgent: false))
        }
        return out
    }

    func start() {
        refresh()
        refreshSessions()
        refreshMemory()
        fastTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in self.refreshSessions(); self.refreshMemory() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        refreshSessions()
        Task.detached {
            let local = LocalScanner.scan()
            let remote = await RemoteUsage.fetch()
            await MainActor.run {
                self.local = local
                switch remote {
                case .success(let r):
                    self.limits = r.limits; self.plan = r.plan
                    self.updated = Date(); self.error = nil
                    self.limitAlerts()
                case .failure(let e):
                    self.error = e.message
                }
            }
        }
    }
}

struct WidgetError: Error { let message: String }

enum RemoteUsage {
    struct Result { let limits: [LimitItem]; let plan: String }

    static func credentials() -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["claudeAiOauth"] as? [String: Any]
    }

    static func planName(_ sub: String?, _ tier: String?) -> String {
        var s = (sub ?? "").capitalized
        if let t = tier, let r = t.range(of: #"max_(\d+)x"#, options: .regularExpression) {
            s += " · Max " + t[r].replacingOccurrences(of: "max_", with: "")
        }
        return s
    }

    static func fetch() async -> Swift.Result<Result, WidgetError> {
        guard let c = credentials(), let token = c["accessToken"] as? String else {
            return .failure(WidgetError(message: "Nenalezen login Claude Code"))
        }
        if let exp = c["expiresAt"] as? Double, exp / 1000 < Date().timeIntervalSince1970 {
            return .failure(WidgetError(message: "Token vypršel – otevři Claude Code"))
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["limits"] as? [[String: Any]] else {
                return .failure(WidgetError(message: "API HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"))
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let iso2 = ISO8601DateFormatter()
            let items: [LimitItem] = arr.enumerated().map { i, l in
                let kind = l["kind"] as? String ?? "?"
                var label: String
                switch kind {
                case "session": label = "Session (5 h)"
                case "weekly_all": label = "Týden – vše"
                default:
                    let scope = l["scope"] as? [String: Any]
                    let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                    label = "Týden – " + (model ?? kind)
                }
                let r = l["resets_at"] as? String ?? ""
                return LimitItem(id: "\(i)-\(kind)", label: label,
                                 percent: (l["percent"] as? NSNumber)?.doubleValue ?? 0,
                                 resetsAt: iso.date(from: r) ?? iso2.date(from: r),
                                 severity: l["severity"] as? String ?? "normal")
            }
            return .success(Result(limits: items,
                                   plan: planName(c["subscriptionType"] as? String, c["rateLimitTier"] as? String)))
        } catch {
            return .failure(WidgetError(message: "Offline"))
        }
    }
}

enum LocalScanner {
    static func scan() -> LocalStats {
        var s = LocalStats()
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let weekStart = cal.date(byAdding: .day, value: -6, to: today),
              let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return s }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var seen = Set<String>(), sessions = Set<String>(), models: [String: Int] = [:]

        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  m >= weekStart, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            text.enumerateLines { line, _ in
                guard line.contains("\"type\":\"assistant\""), line.contains("\"usage\""),
                      let d = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let ts = o["timestamp"] as? String, let date = iso.date(from: ts), date >= weekStart,
                      let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] else { return }
                let key = (o["requestId"] as? String ?? "") + (msg["id"] as? String ?? "")
                if !key.isEmpty { if seen.contains(key) { return }; seen.insert(key) }
                func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
                let out = n("output_tokens")
                let total = n("input_tokens") + out + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
                let day = cal.dateComponents([.day], from: weekStart, to: cal.startOfDay(for: date)).day ?? 0
                if (0..<7).contains(day) { s.daily[day] += total }
                s.weekTokens += total
                if let sid = o["sessionId"] as? String { s.perSession[sid, default: 0] += total }
                if date >= today {
                    s.todayTokens += total; s.todayOutput += out; s.todayMessages += 1
                    if let sid = o["sessionId"] as? String { sessions.insert(sid) }
                    if let model = msg["model"] as? String { models[model, default: 0] += total }
                }
            }
        }
        s.todaySessions = sessions.count
        if let top = models.max(by: { $0.value < $1.value })?.key {
            s.topModel = prettyModel(top)
        }
        return s
    }
}

// MARK: - Formatting

func compact(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
    if d >= 1e3 { return String(format: "%.0fk", d / 1e3) }
    return "\(n)"
}

func resetText(_ d: Date?) -> String {
    guard let d else { return "" }
    let secs = Int(d.timeIntervalSinceNow)
    if secs <= 0 { return "reset teď" }
    if secs < 86400 {
        let h = secs / 3600, m = (secs % 3600) / 60
        return h > 0 ? "reset za \(h) h \(m) min" : "reset za \(m) min"
    }
    let f = DateFormatter(); f.locale = Locale(identifier: "cs_CZ"); f.dateFormat = "EEE H:mm"
    return "reset " + f.string(from: d)
}

func duration(_ secs: TimeInterval) -> String {
    let t = Int(max(0, secs))
    if t < 60 { return "\(t) s" }
    if t < 3600 { return "\(t / 60) min" }
    if t < 86400 { return "\(t / 3600) h \((t % 3600) / 60) min" }
    return "\(t / 86400) d \((t % 86400) / 3600) h"
}

/// Linear burn-rate forecast for the 5-hour session window.
func forecast(_ item: LimitItem) -> String? {
    guard let reset = item.resetsAt, item.percent >= 1 else { return nil }
    let elapsed = Date().timeIntervalSince(reset.addingTimeInterval(-5 * 3600))
    guard elapsed > 600 else { return nil }
    let hitAt = Date().addingTimeInterval((100 - item.percent) / (item.percent / elapsed))
    if hitAt >= reset { return "Tímto tempem vystačíš do resetu" }
    return "Tímto tempem limit v " + hitAt.formatted(date: .omitted, time: .shortened)
}

func usageColor(_ p: Double) -> Color {
    p >= 90 ? Color(red: 1, green: 0.38, blue: 0.35) :
    p >= 70 ? Color(red: 1, green: 0.72, blue: 0.3) :
              Color(red: 0.85, green: 0.47, blue: 0.34)   // Claude terracotta
}

// MARK: - Views

struct Ring: View {
    let item: LimitItem
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.14), lineWidth: 9)
                Circle().trim(from: 0, to: max(0.004, min(item.percent, 100) / 100))
                    .stroke(usageColor(item.percent).gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: usageColor(item.percent).opacity(0.5), radius: 6)
                VStack(spacing: -2) {
                    Text("\(Int(item.percent))").font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("%").font(.system(size: 11, weight: .medium)).opacity(0.6)
                }
            }
            .frame(width: 84, height: 84)
            Text(item.label).font(.system(size: 12, weight: .semibold))
            Text(resetText(item.resetsAt)).font(.system(size: 10.5)).opacity(0.6)
        }
        .frame(maxWidth: .infinity)
    }
}

struct Bar: View {
    let item: LimitItem
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.label).font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text("\(Int(item.percent)) %").font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.14))
                    Capsule().fill(usageColor(item.percent).gradient)
                        .frame(width: max(6, g.size.width * min(item.percent, 100) / 100))
                }
            }.frame(height: 6)
        }
    }
}

struct Sparkline: View {
    let values: [Int]
    var body: some View {
        let mx = max(values.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: 3)
                    .fill(i == values.count - 1 ? AnyShapeStyle(usageColor(0).gradient) : AnyShapeStyle(Color.primary.opacity(0.32)))
                    .frame(height: max(3, 34 * CGFloat(v) / CGFloat(mx)))
            }
        }.frame(height: 34)
    }
}

struct Stat: View {
    let value: String, label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(label).font(.system(size: 10)).opacity(0.6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusDot: View {
    let status: String
    var color: Color {
        switch status {
        case "busy": return Color(red: 0.35, green: 0.9, blue: 0.5)
        case "shell": return Color(red: 0.4, green: 0.7, blue: 1)
        default: return Color.primary.opacity(0.35)
        }
    }
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .shadow(color: status == "idle" ? .clear : color.opacity(0.8), radius: 4)
    }
}

struct SubagentRow: View {
    let a: SubagentInfo
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: a.running ? "circle.dotted" : "checkmark.circle.fill")
                .font(.system(size: 10)).foregroundStyle(a.running ? Color.green : Color.primary.opacity(0.4))
                .symbolEffect(.rotate, isActive: a.running)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.description).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text([a.type, a.model].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 9.5)).opacity(0.5).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                if let st = a.start {
                    Text(duration((a.running ? Date() : (a.end ?? st)).timeIntervalSince(st)))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                }
                Text("\(compact(a.tokens)) tok · \(a.toolCalls) nástr.").font(.system(size: 9.5)).opacity(0.5)
            }
        }
    }
}

struct ContextBar: View {
    let s: SessionInfo
    var color: Color {
        s.contextPercent >= 85 ? Color(red: 1, green: 0.38, blue: 0.35) :
        s.contextPercent >= 70 ? Color(red: 1, green: 0.72, blue: 0.3) : Color(red: 0.4, green: 0.75, blue: 1)
    }
    var body: some View {
        HStack(spacing: 7) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(color.gradient).frame(width: max(3, g.size.width * min(s.contextPercent, 100) / 100))
                }
            }.frame(height: 4)
            Text("\(compact(s.context.tokens)) / \(compact(s.context.limit))")
                .font(.system(size: 9.5, design: .rounded)).opacity(0.6)
            if s.cacheExpired {
                Image(systemName: "snowflake").font(.system(size: 8.5)).opacity(0.5)
                    .help("Cache vypršela – další zpráva znovu načte celý kontext")
            }
        }
        .help("Kontext \(Int(s.contextPercent)) % · \(s.context.model) · cache TTL \(Int(s.context.cacheTTL / 60)) min")
    }
}

struct MemSparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            let pts = values.enumerated().map { i, v in
                CGPoint(x: values.count < 2 ? 0 : g.size.width * CGFloat(i) / CGFloat(values.count - 1),
                        y: g.size.height * (1 - CGFloat(min(v, 1))))
            }
            ZStack {
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: CGPoint(x: f.x, y: g.size.height)); pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height)); p.closeSubpath()
                }.fill(LinearGradient(colors: [usageColor(0).opacity(0.45), usageColor(0).opacity(0.05)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f); pts.dropFirst().forEach { p.addLine(to: $0) }
                }.stroke(usageColor(0), lineWidth: 1.5)
            }
        }
        .frame(height: 30)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct MemorySection: View {
    @ObservedObject var store: UsageStore
    var pressureColor: Color {
        store.mem.pressure >= 4 ? Color(red: 1, green: 0.38, blue: 0.35) :
        store.mem.pressure >= 2 ? Color(red: 1, green: 0.72, blue: 0.3) : Color(red: 0.35, green: 0.85, blue: 0.5)
    }
    var body: some View {
        let m = store.mem
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { store.memOpen.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("MAC · PAMĚŤ").font(.system(size: 9.5, weight: .semibold)).kerning(0.8).opacity(0.55)
                    Circle().fill(pressureColor).frame(width: 7, height: 7)
                    Text("tlak \(m.pressureText)").font(.system(size: 10.5)).foregroundStyle(pressureColor)
                    Spacer()
                    Text("\(gb(m.used)) / \(gb(m.total))").font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).opacity(0.4)
                        .rotationEffect(.degrees(store.memOpen ? 90 : 0))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)

            GeometryReader { g in
                // stacked bar: app · wired · compressed
                let w = g.size.width, t = Double(max(m.total, 1))
                HStack(spacing: 1) {
                    Rectangle().fill(Color(red: 0.4, green: 0.7, blue: 1)).frame(width: w * Double(m.app) / t)
                    Rectangle().fill(Color(red: 0.75, green: 0.55, blue: 1)).frame(width: w * Double(m.wired) / t)
                    Rectangle().fill(Color(red: 1, green: 0.72, blue: 0.3)).frame(width: w * Double(m.compressed) / t)
                    Spacer(minLength: 0)
                }
                .background(Color.primary.opacity(0.12))
                .clipShape(Capsule())
            }.frame(height: 6)

            HStack(spacing: 10) {
                legend(Color(red: 0.4, green: 0.7, blue: 1), "aplikace", m.app)
                legend(Color(red: 0.75, green: 0.55, blue: 1), "pevná", m.wired)
                legend(Color(red: 1, green: 0.72, blue: 0.3), "komprese", m.compressed)
                Spacer(minLength: 0)
                Text("swap \(gb(m.swap))").font(.system(size: 9.5)).foregroundStyle(m.swap > 4_000_000_000 ? Color.orange : Color.primary.opacity(0.6))
            }

            if store.memOpen {
                MemSparkline(values: store.memHistory)
                VStack(spacing: 6) {
                    ForEach(m.apps.prefix(8)) { a in
                        HStack(spacing: 6) {
                            Text(a.id).font(.system(size: 11, weight: a.isClaudeCode ? .semibold : .regular)).lineLimit(1)
                                .foregroundStyle(a.isClaudeCode ? usageColor(0) : Color.primary)
                            if a.processes > 1 {
                                Text("\(a.processes)×").font(.system(size: 9.5)).opacity(0.45)
                            }
                            Spacer()
                            Text(gb(a.bytes)).font(.system(size: 11, weight: .medium, design: .rounded))
                        }
                    }
                }
                HStack {
                    Text(m.unreadable > 0 ? "\(m.unreadable) systémových procesů (root) nelze přečíst" : "").font(.system(size: 9)).opacity(0.4)
                    Spacer()
                    Button("Monitor aktivity") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                    }.buttonStyle(.plain).font(.system(size: 9.5)).foregroundStyle(usageColor(0))
                }
            }
            Toggle("Widget paměti na ploše", isOn: $store.memDesktop)
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10.5))
        }
    }

    func legend(_ c: Color, _ label: String, _ b: UInt64) -> some View {
        HStack(spacing: 3) {
            Circle().fill(c).frame(width: 5, height: 5)
            Text("\(label) \(gb(b))").font(.system(size: 9.5)).opacity(0.65)
        }
    }
}

struct MemoryWidget: View {
    @ObservedObject var store: UsageStore
    var body: some View {
        let m = store.mem
        let pc: Color = m.pressure >= 4 ? Color(red: 1, green: 0.38, blue: 0.35)
                      : m.pressure >= 2 ? Color(red: 1, green: 0.72, blue: 0.3) : Color(red: 0.35, green: 0.85, blue: 0.5)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "memorychip").font(.system(size: 12, weight: .semibold)).foregroundStyle(pc)
                Text("Paměť").font(.system(size: 13, weight: .bold))
                Spacer()
                Text(m.pressureText).font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(pc.opacity(0.25), in: Capsule()).foregroundStyle(pc)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", Double(m.used) / 1_073_741_824))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("/ \(Int((Double(m.total) / 1_073_741_824).rounded())) GB").font(.system(size: 12)).opacity(0.6)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(gb(m.swap)).font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(m.swap > 4_000_000_000 ? Color.orange : Color.white)
                    Text("swap").font(.system(size: 9.5)).opacity(0.6)
                }
            }
            MemSparkline(values: store.memHistory)
            VStack(spacing: 4) {
                ForEach(m.apps.prefix(4)) { a in
                    HStack {
                        Text(a.id).font(.system(size: 10.5)).lineLimit(1)
                            .foregroundStyle(a.isClaudeCode ? usageColor(0) : Color.white)
                        Spacer()
                        Text(gb(a.bytes)).font(.system(size: 10.5, weight: .medium, design: .rounded))
                    }
                }
            }.opacity(0.9)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 210)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(10)
        .contextMenu {
            Button("Skrýt widget paměti") { store.memDesktop = false }
            Button("Monitor aktivity") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
        }
    }
}

struct TipsSection: View {
    let tips: [Tip]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DOPORUČENÍ").font(.system(size: 9.5, weight: .semibold)).kerning(0.8).opacity(0.55)
            ForEach(tips) { t in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: t.icon).font(.system(size: 11))
                        .foregroundStyle(t.urgent ? Color(red: 1, green: 0.45, blue: 0.4) : Color(red: 1, green: 0.72, blue: 0.3))
                        .frame(width: 16)
                    Text(t.text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct SessionRow: View {
    let s: SessionInfo
    let tokens: Int
    @ObservedObject var store: UsageStore
    var open: Bool { store.openSessions.contains(s.id) }
    var ram: UInt64 { store.mem.perPid[s.pid] ?? 0 }

    var statusText: String {
        switch s.status {
        case "busy": return "pracuje"
        case "shell": return "běží příkaz"
        case "idle": return "čeká · " + duration(Date().timeIntervalSince(s.updatedAt))
        default: return s.status
        }
    }

    var body: some View {
        let running = s.subagents.filter(\.running).count
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) {
                    if open { store.openSessions.remove(s.id) } else { store.openSessions.insert(s.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    StatusDot(status: s.status)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(s.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            if s.kind == "bg" {
                                Text("BG").font(.system(size: 8, weight: .bold))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.15), in: Capsule())
                            }
                        }
                        Text("\(s.folder) · \(statusText)").font(.system(size: 9.5)).opacity(0.55).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(duration(Date().timeIntervalSince(s.startedAt)) + (ram > 0 ? " · " + gb(ram) : ""))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        Text(compact(tokens) + " tok" + (s.subagents.isEmpty ? "" : " · \(running > 0 ? "\(running)/" : "")\(s.subagents.count) ag."))
                            .font(.system(size: 9.5)).opacity(0.5)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).opacity(0.4)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if s.context.limit > 0 {
                ContextBar(s: s).padding(.leading, 15)
            }

            if open {
                VStack(alignment: .leading, spacing: 7) {
                    if s.subagents.isEmpty {
                        Text("Žádní subagenti").font(.system(size: 10.5)).opacity(0.5)
                    } else {
                        ForEach(s.subagents.prefix(8)) { SubagentRow(a: $0) }
                        if s.subagents.count > 8 {
                            Text("+ \(s.subagents.count - 8) dalších").font(.system(size: 9.5)).opacity(0.45)
                        }
                    }
                    HStack(spacing: 12) {
                        Button("Otevřít složku") { NSWorkspace.shared.open(URL(fileURLWithPath: s.cwd)) }
                        Text("PID \(s.pid)").opacity(0.45)
                    }
                    .font(.system(size: 9.5)).buttonStyle(.plain).foregroundStyle(usageColor(0))
                }
                .padding(.leading, 15)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct SessionsSection: View {
    @ObservedObject var store: UsageStore
    var open: Bool { store.sessionsOpen }
    var body: some View {
        let busy = store.sessions.filter { $0.status != "idle" }.count
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy) { store.sessionsOpen.toggle() } } label: {
                HStack {
                    Text("SESSIONS").font(.system(size: 9.5, weight: .semibold)).kerning(0.8).opacity(0.55)
                    Text("\(store.sessions.count) otevřených · \(busy) aktivních").font(.system(size: 10.5)).opacity(0.75)
                    if let top = store.sessions.map(\.contextPercent).max(), top >= 1 {
                        Text("· max kontext \(Int(top)) %").font(.system(size: 10.5))
                            .foregroundStyle(top >= 85 ? Color.red : top >= 70 ? Color.orange : Color.primary.opacity(0.75))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).opacity(0.4)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(store.sessions) { SessionRow(s: $0, tokens: store.local.perSession[$0.id] ?? 0, store: store) }
                }.transition(.opacity)
            }
        }
    }
}

struct CardBackground: ViewModifier {
    let popover: Bool
    func body(content: Content) -> some View {
        if popover {
            content   // the menu-bar popover already brings its own Liquid Glass
        } else {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous)).padding(12)
        }
    }
}

struct WidgetView: View {
    @ObservedObject var store: UsageStore
    var popover = false

    var body: some View {
        let rings = store.limits.filter { $0.id.hasSuffix("session") || $0.id.hasSuffix("weekly_all") }
        let bars = store.limits.filter { !rings.map(\.id).contains($0.id) }

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 14, weight: .bold)).foregroundStyle(usageColor(0))
                Text("Claude").font(.system(size: 15, weight: .bold))
                if !store.plan.isEmpty {
                    Text(store.plan).font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.12), in: Capsule())
                }
                Spacer()
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }.buttonStyle(.plain).opacity(0.6).help("Obnovit")
                Button { store.notificationsOn.toggle() } label: {
                    Image(systemName: store.notificationsOn ? "bell.fill" : "bell.slash").font(.system(size: 11, weight: .semibold))
                }.buttonStyle(.plain).opacity(0.6).help(store.notificationsOn ? "Notifikace zapnuté" : "Notifikace vypnuté")
                if popover {
                    Button { NSApp.terminate(nil) } label: {
                        Image(systemName: "power").font(.system(size: 11, weight: .semibold))
                    }.buttonStyle(.plain).opacity(0.6).help("Ukončit")
                }
            }

            if rings.isEmpty {
                Text(store.error ?? "Načítám…").font(.system(size: 12)).opacity(0.7)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                HStack(spacing: 8) { ForEach(rings) { Ring(item: $0) } }
                if let f = rings.first(where: { $0.id.hasSuffix("session") }).flatMap(forecast) {
                    Label(f, systemImage: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 10.5)).opacity(0.7).frame(maxWidth: .infinity)
                }
            }

            if !bars.isEmpty {
                VStack(spacing: 10) { ForEach(bars) { Bar(item: $0) } }
            }

            Divider().overlay(Color.primary.opacity(0.2))

            VStack(alignment: .leading, spacing: 10) {
                Text("CLAUDE CODE · DNES").font(.system(size: 9.5, weight: .semibold)).kerning(0.8).opacity(0.55)
                HStack {
                    Stat(value: compact(store.local.todayTokens), label: "tokenů")
                    Stat(value: compact(store.local.todayOutput), label: "output")
                    Stat(value: "\(store.local.todayMessages)", label: "odpovědí")
                    Stat(value: "\(store.local.todaySessions)", label: "sessions")
                }
                HStack(alignment: .bottom, spacing: 12) {
                    Sparkline(values: store.local.daily)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(compact(store.local.weekTokens)).font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text("7 dní").font(.system(size: 10)).opacity(0.6)
                    }
                }
            }

            if !store.tips.isEmpty {
                Divider().overlay(Color.primary.opacity(0.2))
                TipsSection(tips: store.tips)
            }
            Divider().overlay(Color.primary.opacity(0.2))
            SessionsSection(store: store)
            Divider().overlay(Color.primary.opacity(0.2))
            MemorySection(store: store)

            HStack {
                Text(store.local.topModel).font(.system(size: 10))
                Spacer()
                if let e = store.error, !rings.isEmpty {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10))
                } else if let u = store.updated {
                    Text("aktualizováno " + u.formatted(date: .omitted, time: .shortened)).font(.system(size: 10))
                }
            }.opacity(0.5)
        }
        .foregroundStyle(popover ? Color.primary : .white)
        .padding(popover ? 18 : 20)
        .frame(width: 320)
        .modifier(CardBackground(popover: popover))
        .contextMenu {
            Button("Obnovit") { store.refresh() }
            Divider()
            Button("Ukončit widget") { NSApp.terminate(nil) }
        }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    var bag: AnyCancellable?
    // menu bar mode
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    // desktop memory card
    var memWindow: NSWindow?
    var memHost: NSHostingView<MemoryWidget>?
    var memBag: AnyCancellable?
    // desktop mode (--desktop)
    var window: NSWindow!
    var host: NSHostingView<WidgetView>!

    func applicationDidFinishLaunching(_ n: Notification) {
        if CommandLine.arguments.contains("--desktop") { setUpDesktop() } else { setUpMenuBar() }
        Notifier.shared.setUp()
        memBag = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncMemoryWindow() }
        }
        syncMemoryWindow()
        store.start()
    }

    // MARK: menu bar

    func setUpMenuBar() {
        // The menu bar here is full and new items land behind the notch: ask for a slot near the clock
        // (position = points from the right edge). ⌘-dragging the icon later overrides this.
        let posKey = "NSStatusItem Preferred Position ClaudeUsage"
        if UserDefaults.standard.object(forKey: posKey) == nil { UserDefaults.standard.set(300, forKey: posKey) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "ClaudeUsage"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let vc = NSHostingController(rootView: WidgetView(store: store, popover: true))
        vc.sizingOptions = [.preferredContentSize]
        popover.contentViewController = vc

        updateStatusTitle()
        bag = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusTitle() }
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refreshSessions()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// "✳ 6 %  ●2": session limit + number of sessions currently working.
    func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let session = store.limits.first { $0.id.hasSuffix("session") }
        let busy = store.sessions.filter { $0.status != "idle" }.count
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        let title = NSMutableAttributedString()
        let pct = session.map { "\(Int($0.percent))%" } ?? "–"
        var pctColor = NSColor.labelColor
        if let p = session?.percent, p >= 70 { pctColor = NSColor(usageColor(p)) }
        title.append(NSAttributedString(string: " " + pct, attributes: [.font: font, .foregroundColor: pctColor]))
        if store.mem.pressure >= 2 {
            title.append(NSAttributedString(string: " ▲", attributes: [.font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: store.mem.pressure >= 4 ? NSColor.systemRed : NSColor.systemOrange, .baselineOffset: 1.5]))
        }
        if store.tips.contains(where: \.urgent) {
            title.append(NSAttributedString(string: " ⚠︎", attributes: [.font: font, .foregroundColor: NSColor.systemOrange]))
        }
        if busy > 0 {
            title.append(NSAttributedString(string: " ●", attributes: [.font: NSFont.systemFont(ofSize: 7),
                                                                     .foregroundColor: NSColor.systemGreen,
                                                                     .baselineOffset: 1.5]))
            title.append(NSAttributedString(string: "\(busy)", attributes: [.font: font]))
        }
        let img = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude")?
            .withSymbolConfiguration(.init(pointSize: 12.5, weight: .semibold))
        img?.isTemplate = true
        button.image = img
        button.imagePosition = .imageLeading
        button.attributedTitle = title
        if store.error != nil { button.toolTip = store.error } else { button.toolTip = "Claude usage" }
    }

    // MARK: desktop memory card

    func syncMemoryWindow() {
        guard store.memDesktop else { memWindow?.orderOut(nil); return }
        if memWindow == nil {
            let host = NSHostingView(rootView: MemoryWidget(store: store))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 230, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = host
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isMovableByWindowBackground = true
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.setFrameAutosaveName("MemoryWidget")
            if !(w.setFrameUsingName("MemoryWidget") && w.frame.width > 10), let s = (NSScreen.screens.first { $0.localizedName.contains("Built-in") } ?? NSScreen.screens.first)?.visibleFrame {
                // under the system widgets (calendar/weather + photos) in the left column
                w.setFrame(NSRect(x: s.minX + 4, y: s.maxY - 370 - 260, width: 230, height: 260), display: false)
            }
            memWindow = w; memHost = host
        }
        guard let w = memWindow, let host = memHost else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        if size.width > 0, size.height > 0, size != w.frame.size {
            let top = NSPoint(x: w.frame.minX, y: w.frame.maxY)
            w.setContentSize(size); w.setFrameTopLeftPoint(top)
        }
        if !w.isVisible { w.orderFrontRegardless() }
    }

    // MARK: desktop

    // Grow/shrink with the content while keeping the top-left corner fixed.
    func fitToContent() {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let top = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(size)
        window.setFrameTopLeftPoint(top)
    }

    func setUpDesktop() {
        host = NSHostingView(rootView: WidgetView(store: store))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 344, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.setFrameAutosaveName("ClaudeUsageWidget")
        let restored = window.setFrameUsingName("ClaudeUsageWidget") && window.frame.width > 10
        if !restored, let s = NSScreen.main?.visibleFrame {
            // below the system widgets in the top-left column
            window.setFrame(NSRect(x: s.minX + 4, y: s.maxY - 300 - 300, width: 344, height: 300), display: false)
        }
        fitToContent()
        window.orderFrontRegardless()
        bag = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitToContent() }
        }
    }
}

@main
struct Main {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--dump") {   // print what the widget sees, for debugging
            let local = LocalScanner.scan()
            for x in SessionScanner.scan() {
                print("\(x.status)\t\(x.name)\t\(x.folder)\tup \(duration(Date().timeIntervalSince(x.startedAt)))\t\(compact(local.perSession[x.id] ?? 0)) tok\t\(x.subagents.count) agents\tctx \(compact(x.context.tokens))/\(compact(x.context.limit)) \(Int(x.contextPercent))% ttl \(Int(x.context.cacheTTL/60))m\(x.cacheExpired ? " EXPIRED" : "")")
                for a in x.subagents.prefix(3) {
                    print("    \(a.running ? "RUN" : "done")\t\(a.description)\t\(a.model)\t\(a.start.map { duration((a.end ?? $0).timeIntervalSince($0)) } ?? "-")\t\(compact(a.tokens)) tok\t\(a.toolCalls) tools")
                }
            }
            print("today \(compact(local.todayTokens)) tok, week \(compact(local.weekTokens))")
            let m = MemScanner.scan()
            print("mem used \(gb(m.used))/\(gb(m.total)) app \(gb(m.app)) wired \(gb(m.wired)) compr \(gb(m.compressed)) swap \(gb(m.swap)) pressure \(m.pressure) unreadable \(m.unreadable)")
            for a in m.apps.prefix(10) { print("  \(gb(a.bytes))\t\(a.processes)x\t\(a.id)") }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
