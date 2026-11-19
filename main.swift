// NextMeeting - a menu bar calendar: shows the current or next meeting with a countdown,
// a one-click join link, and the rest of today and tomorrow in a dropdown.
// Reads the calendars added to macOS (System Settings > Internet Accounts).

import AppKit
import EventKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = EKEventStore()
    var statusItem: NSStatusItem!
    var timer: Timer?
    var hasAccess = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        setIcon()

        // Open at login by default, once; the menu toggle can turn it off.
        if !UserDefaults.standard.bool(forKey: "didSetLoginItem") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didSetLoginItem")
        }

        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                self.hasAccess = granted
                self.refresh()
                if CommandLine.arguments.contains("--dump") { self.dump() }
                // Preview: an unanswered invite that has a call link, else the next meeting.
                let start = Calendar.current.startOfDay(for: Date())
                let all = self.events(from: start, to: start.addingTimeInterval(14 * 86400))
                    .filter { !$0.isAllDay && self.isPending($0) }
                let pending = all.filter { $0.startDate > Date() } + all.filter { $0.startDate <= Date() }
                if CommandLine.arguments.contains("--test-reminder"),
                   let e = pending.first(where: { self.meetingLink($0) != nil }) ?? pending.first
                        ?? self.currentEvents().first ?? self.nextEvent() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.updateReminders(force: e) }
                }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: .EKEventStoreChanged, object: store)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh),
                                               name: NSWorkspace.didWakeNotification, object: nil)
        // Tick on the minute so the countdown stays exact.
        let now = Date()
        let nextMinute = Calendar.current.nextDate(after: now, matching: DateComponents(second: 1),
                                                   matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let t = Timer(fire: nextMinute, interval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Data

    func events(from start: Date, to end: Date) -> [EKEvent] {
        guard hasAccess else { return [] }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: pred)
            .filter { !isDeclined($0) && $0.status != .canceled }
            .sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                return $0.startDate < $1.startDate
            }
    }

    func isDeclined(_ e: EKEvent) -> Bool {
        e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined
    }

    func isPending(_ e: EKEvent) -> Bool {
        e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .pending
    }

    /// Timed events that are happening now, the shortest remaining first.
    func currentEvents() -> [EKEvent] {
        let now = Date()
        return events(from: now.addingTimeInterval(-86400), to: now.addingTimeInterval(60))
            .filter { !$0.isAllDay && $0.startDate <= now && $0.endDate > now }
            .sorted { $0.endDate < $1.endDate }
    }

    func nextEvent() -> EKEvent? {
        let now = Date()
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
        return events(from: now, to: endOfDay).first { !$0.isAllDay && $0.startDate > now }
    }

    // MARK: - Meeting links

    static let linkPattern = try! NSRegularExpression(pattern:
        #"https?://(?:[\w-]+\.)?(?:meet\.google\.com/[a-z0-9-]+|zoom\.us/(?:j|my|w)/[^\s<>"]+|teams\.microsoft\.com/l/meetup-join/[^\s<>"]+|teams\.live\.com/meet/[^\s<>"]+|[\w-]+\.webex\.com/[^\s<>"]+|around\.co/[^\s<>"]+|whereby\.com/[^\s<>"]+|app\.slack\.com/huddle/[^\s<>"]+)"#,
        options: [.caseInsensitive])

    func meetingLink(_ e: EKEvent) -> URL? {
        let sources = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }
        for s in sources {
            let range = NSRange(s.startIndex..., in: s)
            if let m = Self.linkPattern.firstMatch(in: s, range: range), let r = Range(m.range, in: s) {
                return URL(string: String(s[r]))
            }
        }
        return nil
    }

    func serviceName(_ url: URL) -> String {
        let h = url.host ?? ""
        if h.contains("meet.google") { return "Google Meet" }
        if h.contains("zoom") { return "Zoom" }
        if h.contains("teams") { return "Teams" }
        if h.contains("webex") { return "Webex" }
        if h.contains("slack") { return "Slack huddle" }
        return "meeting"
    }

    // MARK: - Formatting

    func duration(_ seconds: TimeInterval) -> String {
        let mins = max(1, Int((seconds / 60).rounded(.up)))
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    func longDuration(_ seconds: TimeInterval) -> String {
        let mins = max(1, Int((seconds / 60).rounded(.up)))
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    func truncate(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    func title(_ e: EKEvent) -> String {
        let t = (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "(No title)" : t
    }

    func colorBar(_ color: NSColor, striped: Bool = false, height: CGFloat = 14) -> NSImage {
        let img = NSImage(size: NSSize(width: 4, height: height), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            if striped {
                color.withAlphaComponent(0.35).setFill()
                path.fill()
                color.setFill()
                var y: CGFloat = 0
                while y < rect.height { NSRect(x: 0, y: y, width: 4, height: 2).fill(); y += 4 }
            } else {
                color.setFill()
                path.fill()
            }
            return true
        }
        return img
    }

    func color(_ e: EKEvent) -> NSColor {
        if let c = e.calendar?.cgColor, let ns = NSColor(cgColor: c) { return ns }
        return .systemBlue
    }

    // MARK: - Menu bar title

    func setIcon() {
        guard let button = statusItem.button else { return }
        let img = NSImage(systemSymbolName: "calendar", accessibilityDescription: "NextMeeting")
        img?.isTemplate = true
        button.image = img
        button.imagePosition = .imageOnly
        button.title = ""
    }

    @objc func refresh() {
        guard let button = statusItem.button else { return }
        let now = Date()
        var text: String?
        var event: EKEvent?

        if let cur = currentEvents().first {
            event = cur
            text = "\(truncate(title(cur), 30)) · \(duration(cur.endDate.timeIntervalSince(now))) left"
            // A meeting starting within 5 minutes takes over the countdown.
            if let next = nextEvent(), next.startDate.timeIntervalSince(now) <= 5 * 60 {
                event = next
                text = "\(truncate(title(next), 30)) · in \(duration(next.startDate.timeIntervalSince(now)))"
            }
        } else if let next = nextEvent() {
            event = next
            text = "\(truncate(title(next), 30)) · in \(duration(next.startDate.timeIntervalSince(now)))"
        }

        updateReminders()

        guard let text, let event else {
            setIcon()
            return
        }
        button.image = colorBar(color(event), striped: isPending(event))
        button.imagePosition = .imageLeading
        button.title = " " + text
    }

    // MARK: - Dropdown

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()

        if !hasAccess {
            let item = NSMenuItem(title: "Allow calendar access…", action: #selector(openPrivacy), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            addFooter(menu)
            return
        }

        // The meeting you're in gets the Now card; any other current or upcoming one a plain row.
        var featured: [(String, EKEvent)] = []
        var currents = currentEvents()
        if !currents.isEmpty {
            let cur = currents.removeFirst()
            menu.addItem(nowCardItem(cur, now: now, menu: menu))
            if currents.isEmpty { menu.addItem(.separator()) }
        }
        for cur in currents {
            featured.append(("Ending in \(longDuration(cur.endDate.timeIntervalSince(now)))", cur))
        }
        if let next = nextEvent(), next.startDate.timeIntervalSince(now) <= 30 * 60 {
            featured.append(("Starting in \(longDuration(next.startDate.timeIntervalSince(now)))", next))
        }
        for (header, e) in featured {
            menu.addItem(sectionHeader(header))
            menu.addItem(eventItem(e))
            if let link = meetingLink(e) {
                let join = NSMenuItem(title: "Join \(serviceName(link)) meeting", action: #selector(openURL(_:)), keyEquivalent: "")
                join.target = self
                join.representedObject = link
                join.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)
                menu.addItem(join)
            }
        }
        if !featured.isEmpty { menu.addItem(.separator()) }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let tomorrow = today.addingTimeInterval(86400)
        let dayAfter = tomorrow.addingTimeInterval(86400)

        let todayEvents = events(from: today, to: tomorrow).filter { $0.isAllDay || $0.endDate > now }
        menu.addItem(sectionHeader("Today"))
        if todayEvents.isEmpty {
            menu.addItem(disabledItem("Nothing else today"))
        } else {
            todayEvents.forEach { menu.addItem(eventItem($0)) }
        }

        let tomorrowEvents = events(from: tomorrow, to: dayAfter)
            .filter { $0.isAllDay ? cal.isDate($0.startDate, inSameDayAs: tomorrow) || $0.startDate < tomorrow : $0.startDate >= tomorrow }
        menu.addItem(sectionHeader("Tomorrow"))
        if tomorrowEvents.isEmpty {
            menu.addItem(disabledItem("Nothing scheduled"))
        } else {
            tomorrowEvents.forEach { menu.addItem(eventItem($0)) }
        }

        addFooter(menu)
    }

    func nowCardItem(_ e: EKEvent, now: Date, menu: NSMenu) -> NSMenuItem {
        let link = meetingLink(e)
        let total = e.endDate.timeIntervalSince(e.startDate)
        let card = NowCard(
            title: title(e),
            until: timeFormatter.string(from: e.endDate),
            progress: total > 0 ? now.timeIntervalSince(e.startDate) / total : 0,
            timeLeft: "\(longDuration(e.endDate.timeIntervalSince(now))) left",
            joinLabel: link.map { "Join \(serviceName($0))" },
            onJoin: { [weak menu] in
                menu?.cancelTracking()
                if let link { NSWorkspace.shared.open(link) }
            })
        let host = ClickThroughHostingView(rootView: card)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let item = NSMenuItem()
        item.view = host
        // ⌘J joins while the dropdown is open.
        if let link {
            let join = NSMenuItem(title: "Join \(serviceName(link))", action: #selector(openURL(_:)), keyEquivalent: "j")
            join.target = self
            join.representedObject = link
            join.isHidden = true
            join.allowsKeyEquivalentWhenHidden = true
            menu.addItem(join)
        }
        return item
    }

    // MARK: - Reminders

    var reminders: [String: ReminderPanel] = [:]
    var dismissedReminders: Set<String> = []
    var forcedReminder: EKEvent?   // the --test-reminder preview, kept until closed

    func reminderKey(_ e: EKEvent) -> String {
        "\(e.calendarItemIdentifier)@\(Int(e.startDate.timeIntervalSince1970))"
    }

    /// Shows a card 1 minute before each timed meeting; it stays until you join,
    /// dismiss it, or 5 minutes after the start.
    func updateReminders(force: EKEvent? = nil) {
        let now = Date()
        var due = events(from: now.addingTimeInterval(-5 * 60), to: now.addingTimeInterval(70))
            .filter { !$0.isAllDay && $0.startDate.timeIntervalSince(now) <= 61 && now.timeIntervalSince($0.startDate) < 5 * 60 }
            .filter { !dismissedReminders.contains(reminderKey($0)) }
        if let force { forcedReminder = force }
        if let f = forcedReminder, dismissedReminders.contains(reminderKey(f)) { forcedReminder = nil }
        if let f = forcedReminder, !due.contains(where: { reminderKey($0) == reminderKey(f) }) { due.append(f) }
        let dueKeys = Set(due.map(reminderKey))

        for (key, panel) in reminders where !dueKeys.contains(key) {
            panel.orderOut(nil)
            reminders[key] = nil
        }
        for (index, e) in due.enumerated() {
            let key = reminderKey(e)
            let card = reminderCard(e, key: key, now: now)
            let panel: ReminderPanel
            if let existing = reminders[key] {
                existing.setContent(card)
                panel = existing
            } else {
                panel = ReminderPanel(content: card)
                reminders[key] = panel
                place(panel, index: index, animated: true)
                continue
            }
            place(panel, index: index, animated: false)
        }
    }

    func reminderCard(_ e: EKEvent, key: String, now: Date) -> ReminderCard {
        let link = meetingLink(e)
        let delta = e.startDate.timeIntervalSince(now)
        var parts: [String] = []
        if delta > 30 { parts.append("Starts in 1 min") }
        else if delta > -60 { parts.append("Starting now") }
        else { parts.append("Started \(Int(-delta / 60)) min ago") }
        if let link { parts.append(serviceName(link)) }
        if isPending(e) { parts.append("not answered yet") }
        return ReminderCard(
            title: title(e),
            subtitle: parts.joined(separator: " · "),
            canJoin: link != nil,
            onJoin: { [weak self] in
                if let link { NSWorkspace.shared.open(link) }
                self?.closeReminder(key)
            },
            onClose: { [weak self] in self?.closeReminder(key) })
    }

    func closeReminder(_ key: String) {
        dismissedReminders.insert(key)
        guard let panel = reminders.removeValue(forKey: key) else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    /// Under the status item; a second reminder stacks below the first.
    func place(_ panel: ReminderPanel, index: Int, animated: Bool) {
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        // Right after launch the status item may not be placed yet: fall back to the top right.
        let buttonFrame = statusItem.button?.window?.frame ?? .zero
        let placed = buttonFrame.minY >= visible.maxY - 4
        let anchorX = placed ? buttonFrame.minX - 4 : visible.maxX - size.width - 12
        let top = placed ? buttonFrame.minY : visible.maxY
        let x = min(max(anchorX, visible.minX + 8), visible.maxX - size.width - 8)
        let y = top - 8 - size.height - CGFloat(index) * (size.height + 8)
        let target = NSRect(x: x, y: y, width: size.width, height: size.height)
        if animated {
            panel.setFrame(target.offsetBy(dx: 0, dy: 12), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    func addFooter(_ menu: NSMenu) {
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Calendar", action: #selector(openCalendar), keyEquivalent: "1")
        open.target = self
        menu.addItem(open)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NextMeeting", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func sectionHeader(_ text: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: text) }
        return disabledItem(text)
    }

    func disabledItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func eventItem(_ e: EKEvent) -> NSMenuItem {
        let time = e.isAllDay ? "All-day" : timeFormatter.string(from: e.startDate)
        let pending = isPending(e)
        let label = "\(pending ? "⚠︎ " : "")\(time) · \(truncate(title(e), 60))"
        let item = NSMenuItem(title: label, action: #selector(eventClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = e
        item.image = colorBar(color(e), striped: pending)

        // Submenu with details and actions.
        let sub = NSMenu()
        sub.autoenablesItems = false
        if !e.isAllDay {
            sub.addItem(disabledItem("\(timeFormatter.string(from: e.startDate)) – \(timeFormatter.string(from: e.endDate))"))
        }
        if let calName = e.calendar?.title { sub.addItem(disabledItem(calName)) }
        if let link = meetingLink(e) {
            let join = NSMenuItem(title: "Join \(serviceName(link)) meeting", action: #selector(openURL(_:)), keyEquivalent: "")
            join.target = self
            join.representedObject = link
            sub.addItem(join)
            let copy = NSMenuItem(title: "Copy meeting link", action: #selector(copyLink(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = link
            sub.addItem(copy)
        }
        let show = NSMenuItem(title: "Show in Calendar", action: #selector(showInCalendar(_:)), keyEquivalent: "")
        show.target = self
        show.representedObject = e
        sub.addItem(show)
        item.submenu = sub
        return item
    }

    /// Debug: writes the menu bar title and dropdown to ~/Library/Logs/NextMeeting.txt.
    func dump() {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        var lines = ["access: \(hasAccess)", "bar: \(statusItem.button?.title ?? "")", "---"]
        for c in store.calendars(for: .event) { lines.append("cal: \(c.source.title) / \(c.title) [\(c.source.sourceType.rawValue)]") }
        lines.append("---")
        for item in menu.items {
            lines.append(item.isSeparatorItem ? "-----" : item.title)
            for sub in item.submenu?.items ?? [] { lines.append("    > " + sub.title) }
        }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NextMeeting.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Actions

    @objc func eventClicked(_ sender: NSMenuItem) {
        guard let e = sender.representedObject as? EKEvent else { return }
        if let link = meetingLink(e) { NSWorkspace.shared.open(link) } else { showEvent(e) }
    }

    @objc func showInCalendar(_ sender: NSMenuItem) {
        guard let e = sender.representedObject as? EKEvent else { return }
        showEvent(e)
    }

    func showEvent(_ e: EKEvent) {
        // ical://ekevent/<id> opens the event in Calendar.
        let id = (e.calendarItemExternalIdentifier ?? e.calendarItemIdentifier)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        if let url = URL(string: "ical://ekevent/\(id)?method=show&options=more"), NSWorkspace.shared.open(url) { return }
        openCalendar()
    }

    @objc func openURL(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc func copyLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc func openCalendar() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }
}

// --render <dir>: draw the two cards with sample data to PNGs and quit.
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    MainActor.assumeIsolated {
        let card = NowCard(title: "Design review", until: "12:30", progress: 0.58,
                           timeLeft: "25 min left", joinLabel: "Join Google Meet", onJoin: {})
        let reminder = ReminderCard(title: "Weekly sync",
                                    subtitle: "Starts in 1 min · Google Meet · not answered yet",
                                    canJoin: true, onJoin: {}, onClose: {})
        renderPNG(card, dark: true, background: Color(white: 0.17), to: "\(dir)/now-dark.png")
        renderPNG(card, dark: false, background: Color(white: 0.96), to: "\(dir)/now-light.png")
        renderPNG(reminder, dark: true, background: Color(white: 0.24), to: "\(dir)/reminder-dark.png")
        renderPNG(reminder, dark: false, background: Color(white: 0.96), to: "\(dir)/reminder-light.png")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
