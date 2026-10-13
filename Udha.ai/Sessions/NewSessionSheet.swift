import SwiftUI

/// Start a session on the Mac from the phone: pick a folder, optionally cut a
/// worktree for it, and hand Claude a first prompt.
///
/// The prompt field is the reason this screen is worth having. Creating an idle
/// pane you then have to type into is barely better than walking to the Mac;
/// creating one that is already working is the actual feature.
struct NewSessionSheet: View {
    let bridge: UdhaBridge
    /// "New session here" on a folder: the session is filed in it on the
    /// host the moment it exists, rather than landing loose and needing a
    /// second trip to the menu.
    var folder: SessionFolder? = nil
    #if DEBUG
    /// Opens this sheet already in a given state. Synthetic taps do not reach
    /// SwiftUI's gesture recognisers in the Simulator, so screens behind a tap
    /// are otherwise unreachable without hands — see BRIDGE_V2_PLAN 6.4.
    var debugScreen: String? = nil
    #endif

    @Environment(\.dismiss) private var dismiss

    @State private var directory = ""
    @State private var label = ""
    @State private var prompt = ""
    /// Which CLI runs. The host defaults to Claude when this is absent, which
    /// is what every phone-started session used to be regardless of intent.
    @State private var tool: SessionTool = .claude
    /// Same default the host uses when no mode is sent, so the picker opens on
    /// what you would have got anyway. Re-derived when the tool changes: the
    /// ladders are four rungs each but they are not the same four.
    @State private var permission: PermissionMode = .acceptEdits

    @State private var useWorktree = false
    @State private var newBranch = true
    @State private var branch = ""
    @State private var base = ""

    @State private var browsing = false

    /// Whether the chosen folder is inside a git repo, per the host's own
    /// answer. Derived rather than stored: a recents chip and the picker's
    /// "Use this folder" both bypass the entry that carries `isRepo`, and the
    /// branch listing is the reply that settles it either way.
    private var isRepo: Bool {
        guard let listing = bridge.branchListing else { return false }
        return listing.error == nil && !listing.names.isEmpty
    }

    /// The repo root the host resolved, which is what worktree paths hang off.
    /// Differs from `directory` whenever you pick a subfolder of a repo.
    private var repoRoot: String { bridge.branchListing?.directory ?? directory }

    private var canStart: Bool {
        // A switch mid-sheet leaves the bridge pairing with the new host; the
        // create would be dropped for want of an active instance.
        guard bridge.status.isReady else { return false }
        guard !directory.isEmpty, !bridge.isCreatingSession else { return false }
        if useWorktree {
            if newBranch { return !branch.trimmingCharacters(in: .whitespaces).isEmpty }
            return !base.isEmpty
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "New session", onCancel: { dismiss() })

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if bridge.instances.count > 1 { machineField }
                    folderField
                    if let folder { filedUnder(folder) }
                    labelField
                    if isRepo { worktreeSection }
                    toolField
                    permissionField
                    promptField
                    if let error = bridge.lastSessionError {
                        errorNote(error)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }

            SheetActionBar(title: "Start session",
                           busyTitle: "Starting…",
                           busy: bridge.isCreatingSession,
                           enabled: canStart,
                           action: start)
        }
        .background(UdhaTheme.canvas)
        .sheet(isPresented: $browsing) {
            DirectoryPicker(bridge: bridge) { picked in
                choose(picked)
                browsing = false
            }
        }
        .onAppear {
            bridge.clearSessionError()
            bridge.listRecentDirectories()
            #if DEBUG
            switch debugScreen {
            case "browse":
                browsing = true
            case "worktree":
                choose("/Users/alex/code/health-tracker")
                useWorktree = true
                newBranch = true
                branch = "udha/intake-fix"
                bridge.listBranches(in: "/Users/alex/code/health-tracker")
            default:
                break
            }
            #endif
        }
        // Default the base to whatever the repo is on. Picking a base is the
        // step you least want to think about, and HEAD is nearly always right.
        // A machine switch re-handshakes; the new host's recents can only be
        // asked for once it answers.
        .onChange(of: bridge.status) { _, status in
            if status == .ready { bridge.listRecentDirectories() }
        }
        .onChange(of: bridge.branchListing?.current) { _, current in
            guard base.isEmpty, let current else { return }
            base = current
        }
    }

    // MARK: - Fields

    /// Which machine the session lands on.
    ///
    /// Not a preference stored on this screen: picking one switches the whole
    /// client, because the folder browser, the recents and the branch list all
    /// have to come from the machine that will run the session. That is also
    /// why choosing here throws away the path you had — it belongs to the
    /// machine you just left.
    private var machineField: some View {
        field("Machine", note: bridge.status.isReady ? nil : "connecting…") {
            HStack(spacing: 8) {
                ForEach(bridge.instances) { instance in
                    let active = instance.id == bridge.activeInstanceID
                    Button {
                        guard !active else { return }
                        directory = ""
                        branch = ""
                        base = ""
                        useWorktree = false
                        bridge.clearSessionError()
                        bridge.selectInstance(instance.id)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: instance.systemImage)
                                .font(.system(size: 13, weight: .medium))
                            Text(instance.displayName)
                                .font(UdhaFont.medium(14))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(active ? UdhaTheme.onAccent
                                                : (instance.isOnline ? UdhaTheme.label : UdhaTheme.tertiary))
                        .background(active ? UdhaTheme.accent : UdhaTheme.fill,
                                    in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                         style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressDim())
                    .disabled(!instance.isOnline)
                }
            }
        }
    }

    /// Claude / ChatGPT / Qwen, the same three the Mac offers.
    private var toolField: some View {
        field("Tool", note: tool.isLocal ? "runs on the machine itself" : nil) {
            HStack(spacing: 8) {
                ForEach(SessionTool.allCases) { option in
                    let on = option == tool
                    Button {
                        tool = option
                        // Never leave a rung selected that this CLI has no name
                        // for — the host would silently fall back to its own
                        // default and the picker would be lying.
                        if !option.modes.contains(permission) {
                            permission = option.defaultMode
                        }
                    } label: {
                        Text(option.label)
                            .font(UdhaFont.medium(15))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(on ? UdhaTheme.onAccent : UdhaTheme.label)
                            .background(on ? UdhaTheme.accent : UdhaTheme.fill,
                                        in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                             style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressDim())
                }
            }
        }
    }

    /// Where the session lands on the board. "Folder" above is the
    /// directory; this is the group, in the desktop's word for it.
    private func filedUnder(_ folder: SessionFolder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UdhaTheme.accent)
            Text("Filed under ")
                .font(UdhaFont.regular(13))
                .foregroundStyle(UdhaTheme.secondary)
            + Text(folder.name)
                .font(UdhaFont.semibold(13))
                .foregroundStyle(UdhaTheme.label)
        }
        .padding(.top, -8)
    }

    private var folderField: some View {
        field("Folder") {
            Button { browsing = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: directory.isEmpty ? "folder.badge.plus" : "folder")
                        .font(.system(size: 15))
                        .foregroundStyle(directory.isEmpty ? UdhaTheme.tertiary : UdhaTheme.accent)
                    Text(directory.isEmpty
                         ? "Choose a folder on \(bridge.activeInstance?.displayName ?? "your Mac")"
                         : directory)
                        .font(UdhaFont.mono(13))
                        .foregroundStyle(directory.isEmpty ? UdhaTheme.tertiary : UdhaTheme.label)
                        .lineLimit(1)
                        // A long path is most useful from its leaf back; the
                        // placeholder is a sentence and reads from the front.
                        .truncationMode(directory.isEmpty ? .tail : .head)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(UdhaTheme.tertiary.opacity(0.6))
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(UdhaTheme.fill,
                            in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                 style: .continuous))
            }
            .buttonStyle(PressDim())
        }
    }

    private var labelField: some View {
        field("Label") {
            plainField("project name", text: $label, mono: false)
        }
    }

    private var promptField: some View {
        field("First prompt", note: "optional · sent once \(tool.label) is up") {
            TextField("what should it start on?", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(UdhaFont.regular(15))
                .foregroundStyle(UdhaTheme.label)
                .lineLimit(3...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(UdhaTheme.fill,
                            in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                 style: .continuous))
        }
    }

    /// The Mac's dropdown, as chips. Four options on a phone are easier to hit
    /// than a menu, and having them all visible means the dangerous one is a
    /// deliberate choice rather than something you land on by scrolling.
    private var permissionField: some View {
        field("Permissions") {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(tool.modes) { mode in
                            let selected = mode == permission
                            Button { permission = mode } label: {
                                HStack(spacing: 5) {
                                    if mode.isDangerous {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 10))
                                    }
                                    Text(mode.shortLabel).font(UdhaFont.medium(13.5))
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .foregroundStyle(foreground(for: mode, selected: selected))
                                .background(background(for: mode, selected: selected), in: Capsule())
                            }
                            .buttonStyle(PressDim())
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollClipDisabled()

                Text(permission.detail(for: tool))
                    .font(UdhaFont.regular(12.5))
                    .foregroundStyle(permission.isDangerous ? UdhaTheme.badInk : UdhaTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func foreground(for mode: PermissionMode, selected: Bool) -> Color {
        if selected { return mode.isDangerous ? .white : UdhaTheme.onAccent }
        return mode.isDangerous ? UdhaTheme.badInk : UdhaTheme.label
    }

    private func background(for mode: PermissionMode, selected: Bool) -> Color {
        if selected { return mode.isDangerous ? UdhaTheme.bad : UdhaTheme.accent }
        return mode.isDangerous ? UdhaTheme.badTint : UdhaTheme.fill
    }

    // MARK: - Worktree

    private var worktreeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            UdhaCard {
                Toggle(isOn: $useWorktree) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Work on a separate branch")
                            .font(UdhaFont.medium(15))
                            .foregroundStyle(UdhaTheme.label)
                        Text("Cuts a git worktree so this session can't collide with your others.")
                            .font(UdhaFont.regular(12.5))
                            .foregroundStyle(UdhaTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(UdhaTheme.accent)
            }

            if useWorktree {
                SegmentedTabs(
                    items: [(true, "New branch", nil), (false, "Existing branch", nil)],
                    selection: $newBranch
                )

                if newBranch {
                    plainField("branch name, e.g. udha/intake-fix", text: $branch, mono: true)
                    basePicker(title: "Cut from")
                } else {
                    basePicker(title: "Branch")
                }

                if let path = worktreePathPreview {
                    Text(path)
                        .font(UdhaFont.mono(11.5))
                        .foregroundStyle(UdhaTheme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
    }

    /// Branches come from the host; until they land this is empty rather than
    /// a free-text field, because a mistyped ref just fails on the far side.
    private func basePicker(title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(title)
            if let listing = bridge.branchListing, !listing.ordered.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(listing.ordered, id: \.self) { name in
                            Button { base = name } label: {
                                Text(name)
                                    .font(UdhaFont.mono(12))
                                    .padding(.horizontal, 11)
                                    .frame(height: 30)
                                    .foregroundStyle(name == base ? UdhaTheme.onAccent : UdhaTheme.label)
                                    .background(name == base ? UdhaTheme.accent : UdhaTheme.fill,
                                                in: Capsule())
                            }
                            .buttonStyle(PressDim())
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollClipDisabled()
            } else if let error = bridge.branchListing?.error {
                Text(error)
                    .font(UdhaFont.regular(12.5))
                    .foregroundStyle(UdhaTheme.badInk)
            } else {
                HStack(spacing: 8) {
                    ProgressView().tint(UdhaTheme.secondary).controlSize(.small)
                    Text("Reading branches…")
                        .font(UdhaFont.regular(12.5))
                        .foregroundStyle(UdhaTheme.tertiary)
                }
                .frame(height: 30)
            }
        }
    }

    /// Where the worktree will land. Shown because the host picks the path by
    /// convention — `<repo>-wt/<leaf>` — and a folder appearing next to your
    /// repo unannounced is a bad surprise.
    private var worktreePathPreview: String? {
        let name = newBranch ? branch.trimmingCharacters(in: .whitespaces) : base
        guard !name.isEmpty, !repoRoot.isEmpty else { return nil }
        let leaf = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(repoRoot)-wt/\(leaf)"
    }

    // MARK: - Building blocks

    private func field<C: View>(
        _ title: String,
        note: String? = nil,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Eyebrow(title)
                if let note {
                    Text(note)
                        .font(UdhaFont.regular(12))
                        .foregroundStyle(UdhaTheme.tertiary)
                }
            }
            content()
        }
    }

    private func plainField(_ placeholder: String, text: Binding<String>, mono: Bool) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(mono ? UdhaFont.mono(14) : UdhaFont.regular(15))
            .foregroundStyle(UdhaTheme.label)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(UdhaTheme.fill,
                        in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                             style: .continuous))
    }

    private func errorNote(_ message: String) -> some View {
        // Git's own words, forwarded from the host — "a branch named 'x'
        // already exists" beats anything this screen would paraphrase.
        UdhaCard(ring: UdhaTheme.bad) {
            Text(message)
                .font(UdhaFont.mono(12.5))
                .foregroundStyle(UdhaTheme.badInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func choose(_ path: String) {
        directory = path
        if label.isEmpty { label = (path as NSString).lastPathComponent }
        base = ""
        useWorktree = false
        bridge.clearSessionError()
        // Ask the host whether this is a repo and what it can branch from. One
        // round trip settles both, and it is right even when the folder came
        // from a recents chip that never went through a directory listing.
        bridge.listBranches(in: path)
    }

    private func start() {
        var spec: BridgeOutbound.WorktreeSpec? = nil
        if useWorktree {
            let name = newBranch ? branch.trimmingCharacters(in: .whitespaces) : base
            spec = .init(branch: name, base: newBranch ? base : "", isNewBranch: newBranch)
        }
        bridge.createSession(
            directory: useWorktree ? repoRoot : directory,
            label: label.trimmingCharacters(in: .whitespaces),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            tool: tool,
            permission: permission,
            worktree: spec,
            folder: folder?.id
        )
    }
}
