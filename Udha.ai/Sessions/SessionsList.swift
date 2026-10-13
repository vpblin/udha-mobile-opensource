import SwiftUI

/// The sessions master list.
///
/// One inset group per machine, where a dot and a coloured state word carry the
/// status — the same arrangement as the Mac's board, which is two columns for
/// the same reason this is two groups: the Mac's store holds devbox's sessions
/// alongside its own. Attention is shown, never sorted on: a list that reorders
/// itself as work progresses cannot be navigated from memory.
///
/// The one exception is the session that is actually blocking you. It is lifted
/// out of its group into a card at the top, answerable in two taps, because
/// scrolling a list of twenty-two to find the one that needs a word from you is
/// the failure this screen exists to prevent.
struct SessionsList: View {
    let bridge: UdhaBridge
    var selection: String?
    /// Phone chrome (large title, full-width groups) versus iPad master column.
    var compact: Bool = true
    /// Brings the iPad sidebar over. Nil on a phone, where the tab bar does it.
    var onMenu: (() -> Void)?
    var onSelect: (String) -> Void
    /// Opens the new-session sheet.
    var onNew: () -> Void = {}
    /// "New session here" on a folder: opens the sheet already filing into it.
    var onNewInFolder: (SessionFolder) -> Void = { _ in }
    /// Opens the new-folder sheet for the active host.
    var onNewFolder: () -> Void = {}
    /// Opens the command palette.
    var onSearch: () -> Void = {}
    /// Opens the Machines screen.
    var onOpenMachines: () -> Void = {}

    /// Session queued for removal, held while its confirmation is up.
    @State private var removing: SessionRow?
    /// Session being renamed, held while its sheet is up.
    @State private var renaming: SessionRow?
    /// Folder being renamed, with the machine it lives on.
    @State private var renamingFolder: FolderRef?
    /// "New folder…" from a session's menu: the session to file once the
    /// folder exists, on that session's machine.
    @State private var newFolderFor: SessionRow?

    struct FolderRef: Identifiable {
        var folder: SessionFolder
        var instanceID: String?
        var machine: String
        var id: String { folder.id }
    }
    /// Filters the list. Same fields the row shows, so whatever you can read you
    /// can also type.
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// Host order, deliberately unsorted, minus what is hidden.
    ///
    /// This used to sort by attention and then recency, which meant the list
    /// reshuffled itself every time a session changed phase — the one thing
    /// that makes a list you navigate by muscle memory unusable. The desktop
    /// renders its store in manual order and never sorts, so matching it means
    /// doing nothing here: folders in the host's order, each folder's members
    /// in the host's order, the loose rows after.
    private var ordered: [SessionRow] { bridge.visibleSessions }

    var body: some View {
        VStack(spacing: 0) {
            header
            if bridge.status.isReady && !bridge.sessions.isEmpty {
                SearchField(placeholder: compact ? "Sessions, machines, agents" : "Filter sessions",
                            text: $query,
                            focused: $searchFocused,
                            onSubmit: openTopMatch)
                    .padding(.horizontal, compact ? 20 : 16)
                    .padding(.bottom, 10)
            }
            content
        }
        .background(compact ? AnyShapeStyle(UdhaTheme.canvas) : AnyShapeStyle(Color.clear))
        .sheet(item: $renaming) { row in
            RenameSheet.session(bridge: bridge, row: row)
        }
        .sheet(item: $renamingFolder) { ref in
            RenameSheet.folder(bridge: bridge, folder: ref.folder, instanceID: ref.instanceID, machine: ref.machine)
        }
        .sheet(item: $newFolderFor) { row in
            RenameSheet.newFolder(bridge: bridge, instanceID: row.instanceID,
                                  machine: bridge.machineName(for: row)) { id in
                bridge.setFolder(sessionID: row.id, folderID: id)
            }
        }
        .confirmationDialog(
            "Remove \(removing?.label ?? "session")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let row = removing { bridge.closeSession(id: row.id) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text(SessionDestruction.removeExplanation)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if compact {
            LargeTitleHeader(title: "Sessions", subtitle: countsLine) {
                CircleButton(systemImage: "server.rack", action: onOpenMachines)
                    .accessibilityLabel("Machines")
                if canMakeFolders {
                    CircleButton(systemImage: "folder.badge.plus", action: onNewFolder)
                        .accessibilityLabel("New folder")
                }
                CircleButton(systemImage: "plus", prominent: true, action: onNew)
                    .accessibilityLabel("New session")
            }
        } else {
            PadListHeader(title: "Sessions", onMenu: onMenu) {
                if canMakeFolders {
                    CircleButton(systemImage: "folder.badge.plus", diameter: 40, action: onNewFolder)
                        .accessibilityLabel("New folder")
                }
                CircleButton(systemImage: "plus", diameter: 40, prominent: true, action: onNew)
                    .accessibilityLabel("New session")
            }
        }
    }

    /// Folders are per machine, and the button makes one on the host you
    /// chose — a box whose agent predates folders gets no button rather than
    /// one that quietly does nothing.
    private var canMakeFolders: Bool {
        bridge.status.isReady && bridge.canUseFolders(onInstance: nil)
    }

    /// The one line under the title, in the desktop's own words.
    private var countsLine: String {
        guard bridge.status.isReady else { return bridge.status.shortLabel }
        let needs = ordered.count { $0.attention == .needsYou }
        let working = ordered.count { $0.attention == .working }
        let quiet = ordered.count - needs - working
        guard !ordered.isEmpty else { return "Nothing running" }
        var parts: [String] = []
        if needs > 0 { parts.append("\(needs) waiting") }
        parts.append("\(working) working")
        parts.append("\(quiet) quiet")
        return parts.joined(separator: " · ")
    }

    /// Return on the keyboard opens the one session you were obviously after.
    private func openTopMatch() {
        guard let first = groups.flatMap(\.rows).first else { return }
        searchFocused = false
        onSelect(first.id)
    }

    // MARK: - Grouping

    /// Sessions split by the machine running them.
    ///
    /// A group per machine rather than one flat list, because the rows genuinely
    /// come from two computers: the Mac forwards the box's sessions along with
    /// its own, and before the wire carried `host` they arrived indistinguishable
    /// — fifteen box sessions reading as though they were on the Mac.
    private struct MachineGroup: Identifiable {
        /// "" for the host this client is talking to.
        var id: String
        var name: String
        /// The socket this machine's rows came down, so folder verbs go to
        /// the machine that keeps the folder. Nil for a group made only of
        /// rows another machine forwarded — those offer no folder actions.
        var instanceID: String?
        /// What the filter left. These are the rows drawn.
        var rows: [SessionRow]
        /// Every session on this machine, filter or no filter — the header
        /// counts come from here, so typing into the search box never makes a
        /// machine look like it shed half its work.
        var all: [SessionRow]
        /// The machine's folders, in the machine's order, minus hidden ones.
        var folders: [SessionFolder]
        /// Whether folder verbs are offered for this machine.
        var supportsFolders: Bool

        /// The folder's members among `rows`, in the machine's order.
        func members(of folder: SessionFolder) -> [SessionRow] {
            rows.filter { $0.folderID == folder.id }
        }

        /// Filed nowhere, or filed in a folder this machine no longer has.
        var loose: [SessionRow] {
            let known = Set(folders.map(\.id))
            return rows.filter { $0.folderID.map { !known.contains($0) } ?? true }
        }

        /// The folders drawn: with a search on, only the ones holding a
        /// match; without one every folder, empty or not, so it can be seen
        /// and filed into.
        func shownFolders(searching: Bool) -> [SessionFolder] {
            searching ? folders.filter { !members(of: $0).isEmpty } : folders
        }
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var groups: [MachineGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        var order: [String] = []
        var byMachine: [String: [SessionRow]] = [:]
        // Keyed on the machine that served the row, not on `host`. `host` is
        // only set on a row one machine forwarded about another, so with the
        // client subscribed to the whole fleet every machine's own rows would
        // otherwise collapse into a single group wearing the active host's name.
        for row in ordered {
            let key = bridge.machineName(for: row)
            if byMachine[key] == nil { order.append(key) }
            byMachine[key, default: []].append(row)
        }
        // A machine with folders but no visible sessions still has a group:
        // a folder you just made must be somewhere on screen to file into.
        for instance in bridge.instances where !bridge.folders(onInstance: instance.id).isEmpty {
            let key = instance.displayName
            if byMachine[key] == nil {
                order.append(key)
                byMachine[key] = []
            }
        }
        // The machine you are connected to leads, whatever order its rows
        // happened to arrive in.
        let home = bridge.activeInstance?.displayName
        order.sort { a, b in a == home && b != home }
        return order.map { key in
            let all = byMachine[key] ?? []
            // The socket: from an owned row, else from the instance list by
            // name. A group of forwarded rows alone has neither.
            let instanceID = all.first { $0.host == nil }?.instanceID
                ?? bridge.instances.first { $0.displayName == key }?.id
            let owned = all.contains { $0.host == nil } || all.isEmpty
            return MachineGroup(id: key,
                                name: key,
                                instanceID: instanceID,
                                rows: trimmed.isEmpty ? all : all.filter { $0.matches(trimmed) },
                                all: all,
                                folders: owned ? bridge.folders(onInstance: instanceID).filter { !$0.hidden } : [],
                                supportsFolders: owned && instanceID != nil && bridge.canUseFolders(onInstance: instanceID))
        }
    }

    private var matchCount: Int { groups.reduce(0) { $0 + $1.rows.count } }

    /// One line of the machine's card: a folder header or a session, the
    /// session indented when it is inside an open folder.
    private enum Line: Identifiable {
        case folder(SessionFolder)
        case session(SessionRow, filed: Bool)
        case emptyFolder(SessionFolder)

        var id: String {
            switch self {
            case .folder(let f):        return "f:" + f.id
            case .session(let r, _):    return "s:" + r.id
            case .emptyFolder(let f):   return "e:" + f.id
            }
        }
    }

    /// Folders first, then the loose rows — each in the machine's own order.
    /// Sessions used to be bucketed Needs you / Working / Quiet, which meant
    /// a row jumped to a different part of the group every time its phase
    /// changed. A folder is the one grouping you chose.
    private func lines(_ group: MachineGroup) -> [Line] {
        var out: [Line] = []
        for folder in group.shownFolders(searching: searching) {
            out.append(.folder(folder))
            guard bridge.isExpanded(folder) else { continue }
            let members = group.members(of: folder)
            if members.isEmpty {
                out.append(.emptyFolder(folder))
            } else {
                out += members.map { .session($0, filed: true) }
            }
        }
        out += group.loose.map { .session($0, filed: false) }
        return out
    }

    /// The session that has been waiting longest, lifted out of the list.
    ///
    /// Shown even when several are waiting: the row stays in its group too, so
    /// nothing disappears, and the group badge still says how many there are.
    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !bridge.status.isReady {
            ConnectionState(bridge: bridge)
        } else if bridge.sessions.isEmpty {
            VStack(spacing: 16) {
                EmptyHint(
                    systemImage: "terminal",
                    title: "No sessions running",
                    subtitle: "Start one on \(bridge.activeInstance?.displayName ?? "your host")."
                )
                PrimaryButton(title: "New session", systemImage: "plus", action: onNew)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if compact {
            phoneList
        } else {
            padList
        }
    }

    /// Phone: a blocked card, then one inset group per machine.
    private var phoneList: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                if query.isEmpty {
                    AttentionInbox(bridge: bridge, onOpen: onSelect)
                }
                ForEach(groups) { group in
                    VStack(spacing: 0) {
                        GroupHeader(name: group.name,
                                    count: "\(group.all.count) session\(group.all.count == 1 ? "" : "s")",
                                    badge: badge(for: group),
                                    badgeTint: badgeTint(for: group),
                                    online: isOnline(group))
                        let lines = lines(group)
                        if lines.isEmpty {
                            noMatches(in: group.name)
                        } else {
                            InsetGroup(items: lines, separatorInset: 35) { line in
                                phoneLine(line, in: group)
                            }
                        }
                    }
                }
                if matchCount == 0 && groups.isEmpty {
                    noMatches(in: "the fleet")
                }
                hiddenBar
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 24)
        }
        .refreshable { bridge.refresh() }
    }

    @ViewBuilder
    private func phoneLine(_ line: Line, in group: MachineGroup) -> some View {
        switch line {
        case .folder(let folder):
            folderButton(folder, in: group) { folderRow(folder, in: group) }
        case .session(let row, let filed):
            sessionButton(row) { phoneRow(row).padding(.leading, filed ? 22 : 0) }
        case .emptyFolder:
            emptyFolderNote
        }
    }

    /// "N folders and M sessions hidden · Unhide all", pinned under the list.
    /// Hidden rows are still sent by the host precisely so this can count
    /// them, and unhiding is the one thing you can do to something you
    /// cannot see.
    @ViewBuilder
    private var hiddenBar: some View {
        let counts = bridge.hiddenCounts
        if counts.folders > 0 || counts.sessions > 0 {
            let parts = [
                counts.folders > 0 ? "\(counts.folders) \(counts.folders == 1 ? "folder" : "folders")" : nil,
                counts.sessions > 0 ? "\(counts.sessions) \(counts.sessions == 1 ? "session" : "sessions")" : nil,
            ].compactMap { $0 }
            HStack(spacing: 10) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(UdhaTheme.tertiary)
                Text(parts.joined(separator: " and ") + " hidden")
                    .font(UdhaFont.regular(13))
                    .foregroundStyle(UdhaTheme.secondary)
                Spacer(minLength: 0)
                Button("Unhide all") { bridge.unhideAll() }
                    .font(UdhaFont.semibold(13))
                    .foregroundStyle(UdhaTheme.accent)
                    .buttonStyle(PressDim())
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(UdhaTheme.fill, in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control, style: .continuous))
        }
    }

    private var emptyFolderNote: some View {
        Text("No sessions here yet")
            .font(UdhaFont.regular(13))
            .foregroundStyle(UdhaTheme.tertiary)
            .padding(.leading, 36)
            .padding(.trailing, 14)
            .frame(minHeight: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// iPad: a flat run of selectable rows, because the column is narrow and a
    /// card inside a card reads as noise at that width.
    private var padList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if query.isEmpty { AttentionInbox(bridge: bridge, onOpen: onSelect) }
                ForEach(groups) { group in
                    if groups.count > 1 {
                        GroupHeader(name: group.name,
                                    count: "\(group.all.count)",
                                    badge: badge(for: group),
                                    badgeTint: badgeTint(for: group),
                                    online: isOnline(group))
                            .padding(.top, 10)
                    }
                    let lines = lines(group)
                    ForEach(lines) { line in
                        switch line {
                        case .folder(let folder):
                            folderButton(folder, in: group) { folderRow(folder, in: group).padding(.top, 4) }
                        case .session(let row, let filed):
                            sessionButton(row) { padRow(row) }.padding(.leading, filed ? 18 : 0)
                        case .emptyFolder:
                            emptyFolderNote
                        }
                    }
                    if lines.isEmpty { noMatches(in: group.name) }
                }
                hiddenBar.padding(.top, 10)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .refreshable { bridge.refresh() }
    }

    private func isOnline(_ group: MachineGroup) -> Bool {
        guard !group.id.isEmpty else { return true }
        return bridge.instances.first { $0.displayName == group.id }?.isOnline ?? true
    }

    private func badge(for group: MachineGroup) -> String? {
        let needs = group.all.count { $0.attention == .needsYou }
        if needs > 0 { return "\(needs) waiting" }
        let working = group.all.count { $0.attention == .working }
        return working > 0 ? "\(working) working" : "Connected"
    }

    private func badgeTint(for group: MachineGroup) -> Color {
        let needs = group.all.count { $0.attention == .needsYou }
        if needs > 0 { return UdhaTheme.badInk }
        let working = group.all.count { $0.attention == .working }
        return working > 0 ? UdhaTheme.accentInk : UdhaTheme.goodInk
    }

    // MARK: - Rows

    private func sessionButton<C: View>(_ row: SessionRow, @ViewBuilder label: () -> C) -> some View {
        Button { onSelect(row.id) } label: { label() }
            .buttonStyle(.plain)
            // Same verbs, same wording and same order as the Mac's sidebar
            // context menu, so the two apps agree about what "Terminate" and
            // "Remove" each mean.
            .contextMenu {
                if bridge.canRename(row) {
                    Button("Rename…") { renaming = row }
                }
                Button("Duplicate") { bridge.duplicateSession(id: row.id) }
                if bridge.canSwitchLogin(row) {
                    Menu("Switch Claude login") { LoginSwitchItems(bridge: bridge, row: row) }
                }
                if bridge.canUseFolders(row) {
                    Menu("Move to folder…") {
                        let list = bridge.folders(for: row)
                        ForEach(list) { folder in
                            Button {
                                bridge.setFolder(sessionID: row.id, folderID: folder.id)
                            } label: {
                                if folder.id == row.folderID {
                                    Label(folder.name, systemImage: "checkmark")
                                } else {
                                    Text(folder.name)
                                }
                            }
                        }
                        if row.folderID != nil {
                            if !list.isEmpty { Divider() }
                            Button("Remove from folder") { bridge.setFolder(sessionID: row.id, folderID: nil) }
                        }
                        Divider()
                        Button("New folder…") { newFolderFor = row }
                    }
                    Button("Hide") { bridge.setHidden(sessionID: row.id, hidden: true) }
                }
                if bridge.canDrive(row) {
                    // The desktop drags; a phone has no room for a handle in a
                    // context menu's worth of row, so the same order edit is
                    // two buttons. Sent as the machine's whole list, like the drag.
                    Button("Move up") { bridge.nudgeSession(id: row.id, up: true) }
                    Button("Move down") { bridge.nudgeSession(id: row.id, up: false) }
                }
                Divider()
                Button("Terminate") { bridge.killSession(id: row.id) }
                Button("Remove", role: .destructive) { removing = row }
            }
    }

    // MARK: - Folders

    /// One folder in a machine's group — the desktop's row: chevron · folder
    /// glyph · name · "N needs you" · count. A tap folds it.
    private func folderButton<C: View>(_ folder: SessionFolder, in group: MachineGroup,
                                       @ViewBuilder label: () -> C) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { bridge.toggle(folder) }
        } label: { label() }
            .buttonStyle(.plain)
            // Same verbs, same wording and same order as the Mac's folder menu.
            .contextMenu {
                if group.supportsFolders {
                    Button("Rename folder…") {
                        renamingFolder = FolderRef(folder: folder, instanceID: group.instanceID, machine: group.name)
                    }
                    // New sessions start on the host you chose, so the offer is
                    // only made where it can be kept.
                    if group.instanceID == bridge.activeInstanceID {
                        Button("New session here") { onNewInFolder(folder) }
                    }
                }
                Button(bridge.isExpanded(folder) ? "Collapse" : "Expand") {
                    withAnimation(.easeOut(duration: 0.18)) { bridge.toggle(folder) }
                }
                if group.supportsFolders {
                    Button("Hide folder") { bridge.setFolderHidden(id: folder.id, hidden: true, onInstance: group.instanceID) }
                    Button("Move up") { bridge.nudgeFolder(id: folder.id, up: true, onInstance: group.instanceID) }
                    Button("Move down") { bridge.nudgeFolder(id: folder.id, up: false, onInstance: group.instanceID) }
                    Divider()
                    Button("Ungroup") { bridge.deleteFolder(id: folder.id, onInstance: group.instanceID) }
                }
            }
    }

    private func folderRow(_ folder: SessionFolder, in group: MachineGroup) -> some View {
        let members = group.members(of: folder)
        let needsYou = members.count { $0.attention == .needsYou }
        let expanded = bridge.isExpanded(folder)
        return HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(UdhaTheme.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 12)
            Image(systemName: "folder")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(UdhaTheme.accent)
            Text(folder.name)
                .font(UdhaFont.semibold(15))
                .foregroundStyle(UdhaTheme.label)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if needsYou > 0 {
                Pill("\(needsYou) needs you", tint: UdhaTheme.badInk)
            }
            Text("\(members.count)")
                .font(UdhaFont.regular(13))
                .monospacedDigit()
                .foregroundStyle(UdhaTheme.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(expanded ? UdhaTheme.fill.opacity(0.5) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name), \(members.count) sessions" + (needsYou > 0 ? ", \(needsYou) need you" : ""))
    }

    private func phoneRow(_ row: SessionRow) -> some View {
        let status = row.status
        let tint = UdhaTheme.ink(for: status.tone)
        return HStack(spacing: 12) {
            StatusDot(tone: status.tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(UdhaFont.rowTitle)
                    .foregroundStyle(UdhaTheme.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    // Never `fixedSize`. For a tool-using session `status.label`
                    // is the command Claude is running — "Running S=/tmp/claude
                    // -1000/-home-dev-…" — and a row that refuses to truncate
                    // it demands 900pt, which drags the whole card off both
                    // edges of the phone. It truncates; the model, which is
                    // short and the thing you actually scan for, does not.
                    Text(row.attention == .needsYou ? "Waiting on you" : row.compactStatusLabel)
                        .font(UdhaFont.semibold(13))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if status.tone == .working || status.tone == .needsYou {
                        TypingDots(color: UdhaTheme.color(for: status.tone))
                            .layoutPriority(1)
                    }
                    if let model = row.modelBadge {
                        Text(model)
                            .font(UdhaFont.regular(13))
                            .foregroundStyle(UdhaTheme.tertiary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 0)
                    // A row forwarded by another machine can be read but not
                    // opened — its own host is not subscribed. Saying so on the
                    // row beats a dead tap and an error.
                    if !bridge.canDrive(row) {
                        Image(systemName: "eye")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(UdhaTheme.tertiary)
                            .layoutPriority(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UdhaTheme.tertiary.opacity(0.55))
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .background(row.id == selection ? UdhaTheme.accentTint : .clear)
        .opacity(row.isTerminal ? 0.55 : 1)
        .contentShape(Rectangle())
    }

    private func padRow(_ row: SessionRow) -> some View {
        let status = row.status
        let style = MasterSelection(compact: false, selected: row.id == selection)
        return HStack(spacing: 12) {
            StatusDot(tone: status.tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(UdhaFont.medium(15.5))
                    .foregroundStyle(style.label)
                    .lineLimit(1)
                Text(SessionRow.collapsePaths(in: row.statusLine))
                    .font(UdhaFont.regular(12.5))
                    .foregroundStyle(style.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let context = row.contextPercent {
                Text("\(context)%")
                    .font(UdhaFont.regular(12))
                    .monospacedDigit()
                    .foregroundStyle(style.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 56)
        .background(style.background,
                    in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control, style: .continuous))
        .opacity(row.isTerminal ? 0.6 : 1)
        .contentShape(Rectangle())
    }

    /// Filtered to nothing. Says so rather than leaving a blank run, which would
    /// read as the machine having no sessions.
    private func noMatches(in machine: String) -> some View {
        Text("Nothing on \(machine) matches “\(query)”")
            .font(UdhaFont.regular(13))
            .foregroundStyle(UdhaTheme.tertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension UdhaBridge.Status {
    /// Two or three words for the subtitle under a large title, where the full
    /// `ConnectionState` panel has no room to go.
    var shortLabel: String {
        switch self {
        case .disconnected: return "Offline"
        case .connecting:   return "Connecting…"
        case .awaitingHost: return "No host online"
        case .pairing:      return "Pairing…"
        case .ready:        return "Connected"
        case .failed:       return "Disconnected"
        }
    }
}

extension SessionRow {
    /// One line combining the headline verb and its detail, as the design's
    /// row does — "Needs approval · edit asana_sync.py".
    var statusLine: String {
        if let detail = statusDetail, !detail.isEmpty, detail != statusLabel {
            return "\(statusLabel) · \(detail)"
        }
        return statusLabel
    }
}

// MARK: - Connection

struct ConnectionState: View {
    let bridge: UdhaBridge

    var body: some View {
        VStack(spacing: 14) {
            switch bridge.status {
            case .connecting, .pairing:
                ProgressView().tint(UdhaTheme.accent)
                Text(bridge.status == .pairing ? "Pairing…" : "Connecting…")
                    .font(UdhaFont.regular(15))
                    .foregroundStyle(UdhaTheme.secondary)

            case .awaitingHost:
                EmptyHint(systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                          title: "No host online",
                          subtitle: "Start Udha on your Mac, or wake the forge daemon.")

            case .failed(let message):
                EmptyHint(systemImage: "exclamationmark.triangle", title: "Disconnected", subtitle: message)
                SecondaryButton(title: "Retry") { Task { await bridge.retry() } }

            case .disconnected:
                EmptyHint(systemImage: "wifi.slash", title: "Offline")

            case .ready:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
