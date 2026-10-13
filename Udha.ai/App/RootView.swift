import SwiftUI

/// Which master list the shell is showing.
///
/// Ordered as the design's tab bar orders it — Sessions first because it is why
/// the app exists, Machines beside it because the two are read together.
enum UdhaTab: String, Hashable, CaseIterable {
    case sessions, machines, meetings, agents, videos

    var label: String {
        switch self {
        case .sessions: return "Sessions"
        case .machines: return "Machines"
        case .meetings: return "Meetings"
        case .agents:   return "Agents"
        case .videos:   return "Videos"
        }
    }

    var icon: String {
        switch self {
        case .sessions: return "terminal"
        case .machines: return "server.rack"
        case .meetings: return "video"
        case .agents:   return "cpu"
        case .videos:   return "film"
        }
    }
}

/// Top-level shell: auth gate, then the five-tab master/detail app.
struct RootView: View {
    @StateObject private var auth0 = Auth0Manager()
    @State private var bridge: UdhaBridge?
    /// Built before the bridge and outlives any one connection: recordings
    /// belong to this device, not to whichever Mac happens to be reachable.
    @State private var meetingStore = MeetingStore()
    @EnvironmentObject private var notifications: NotificationManager
    @Environment(\.scenePhase) private var scenePhase
    /// The accent is a stored preference, and the tokens read it statically —
    /// so the shell is re-identified on a change to repaint everything at once.
    @State private var appearance = UdhaAppearance.shared

    #if DEBUG
    @State private var mockHost: MockHost?
    private var isMock: Bool { MockHost.isEnabled }
    #else
    private var isMock: Bool { false }
    #endif

    var body: some View {
        Group {
            if !auth0.isAuthenticated && !isMock {
                LoginView(auth0: auth0)
            } else if let bridge {
                ShellView(bridge: bridge)
            } else {
                ZStack {
                    UdhaTheme.canvas.ignoresSafeArea()
                    ProgressView().tint(UdhaTheme.accent)
                }
                .onAppear { startBridge() }
            }
        }
        // Light and dark both ship in the palette, so the system setting is
        // honoured rather than overridden. Forcing light was the old language's
        // decision, and it made the app the only thing on the phone still
        // glowing at midnight.
        .id(appearance.accent)
        .tint(UdhaTheme.accent)
        .onChange(of: auth0.isAuthenticated) { _, isAuthed in
            if isAuthed { startBridge() }
        }
        // The app holds no connection while it is away — iOS suspends the
        // process within seconds anyway, so the honest model is "die quietly,
        // resync fast on return" rather than a keepalive that only ever runs
        // during the scraps of runtime the OS hands back.
        //
        // Only `.background` and `.active` are acted on. `.inactive` fires for
        // a pulled-down notification shade or the app switcher, and tearing the
        // socket down for those would cost a re-handshake every time someone
        // glanced at a notification.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: bridge?.appDidEnterBackground()
            case .active:     bridge?.appWillEnterForeground()
            default:          break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceTokenReceived)) { note in
            guard let token = note.object as? String else { return }
            bridge?.registerDeviceToken(token)
        }
        .onChange(of: bridge?.status) { _, status in
            guard status == .ready, let token = notifications.deviceToken else { return }
            bridge?.registerDeviceToken(token)
        }
        .onOpenURL { url in
            guard url.scheme == "udha" else { return }
            switch url.host {
            case "session":
                let id = url.lastPathComponent
                guard !id.isEmpty, id != "session" else { return }
                bridge?.openSession(id: id)
            case "live":
                // Tapping the recording Live Activity. Without this the Lock
                // Screen indicator was a dead end.
                NotificationCenter.default.post(name: .openLiveMeetingRequested, object: nil)
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSessionRequested)) { note in
            guard let id = note.object as? String else { return }
            bridge?.openSession(id: id)
        }
    }

    private func startBridge() {
        guard bridge == nil else { return }
        #if DEBUG
        if isMock {
            let b = UdhaBridge(auth0: auth0, meetingStore: meetingStore)
            let host = MockHost(bridge: b)
            bridge = b
            mockHost = host
            host.start()
            return
        }
        #endif
        guard auth0.isAuthenticated else { return }
        let b = UdhaBridge(auth0: auth0, meetingStore: meetingStore)
        bridge = b
        Task { await b.connect() }
    }
}

// MARK: - Shell

/// One adaptive layout rather than separate phone and tablet screens.
///
/// Past ~1000pt the list and the detail sit side by side and the tab list moves
/// into a sidebar you bring over from the master column's menu button. Below it
/// they are two screens with push navigation and a five-tab bar — which is what
/// the design draws, and it is also what an iPad in portrait or a half-width
/// Split View should get, since what matters is available width, not device
/// class.
struct ShellView: View {
    @Bindable var bridge: UdhaBridge

    @State private var tab: UdhaTab = .sessions
    /// Compact only: whether the detail screen is pushed over the list.
    @State private var pushed = false
    /// Wide only: the slide-over sidebar that holds the tab list.
    @State private var sidebarOpen = false
    /// Whether the master column is collapsed, giving the detail the full width.
    @AppStorage("shell.listHidden") private var listHidden = false
    /// Hides every bar too, so nothing but the pane is left.
    ///
    /// Deliberately independent of `listHidden` rather than the next rung of a
    /// ladder. Chaining them meant reaching full screen cost three taps and a
    /// trip through a state you did not want. Two switches compose; a cycle
    /// does not.
    @AppStorage("shell.fullScreen") private var fullScreen = false
    @State private var paletteOpen = false
    @State private var voiceOpen = false
    @State private var newSessionOpen = false
    /// "New session here" on a folder: the folder the sheet files it in.
    @State private var newSessionFolder: SessionFolder?
    @State private var newFolderOpen = false
    @State private var settingsOpen = false
    @State private var recorder: LocalMeetingRecorder
    @State private var notesEngine: MeetingNotesEngine
    @State private var retranscriber: MeetingRetranscriber

    /// Selection is per-tab so switching away and back keeps your place.
    @State private var sessionID: String?
    @State private var meetingID: String?
    @State private var videoID: String?
    @State private var agentID: String?
    @State private var machineID: String?

    init(bridge: UdhaBridge) {
        _bridge = Bindable(wrappedValue: bridge)
        // The recorder writes straight into the same store the bridge reads,
        // so a finished recording is on disk and in the list without a round
        // trip through anything that can be offline.
        _recorder = State(initialValue: LocalMeetingRecorder(store: bridge.meetingStore))
        _notesEngine = State(initialValue: MeetingNotesEngine(store: bridge.meetingStore))
        _retranscriber = State(initialValue: MeetingRetranscriber(store: bridge.meetingStore))
    }

    var body: some View {
        GeometryReader { geo in
            let stacked = geo.size.width < 1000
            let listWidth: CGFloat = geo.size.width >= 1300 ? 392 : 344

            ZStack {
                UdhaTheme.canvas.ignoresSafeArea()

                if stacked {
                    compactLayout
                } else {
                    wideLayout(listWidth: listWidth)
                }

                if !stacked && sidebarOpen {
                    sidebar
                }
            }
            .overlay {
                if voiceOpen {
                    VoiceOverlay(bridge: bridge) { voiceOpen = false }
                }
                if paletteOpen {
                    CommandPalette(
                        bridge: bridge,
                        onDismiss: { paletteOpen = false },
                        onNavigate: { destination in
                            paletteOpen = false
                            apply(destination)
                        }
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openLiveMeetingRequested)) { _ in
                tab = .meetings
                // If the Mac is the one recording, land on its live pane.
                if !recorder.state.isActive, let hostLive = bridge.liveMeetingID {
                    select(hostLive, in: .meetings)
                } else if recorder.state.isActive {
                    withAnimation(.easeOut(duration: 0.25)) { pushed = true }
                }
            }
            .sheet(isPresented: $settingsOpen) {
                UdhaSettingsSheet()
            }
            .sheet(isPresented: $newSessionOpen, onDismiss: { newSessionFolder = nil }) {
                #if DEBUG
                NewSessionSheet(bridge: bridge, folder: newSessionFolder, debugScreen: MockHost.autoScreen)
                #else
                NewSessionSheet(bridge: bridge, folder: newSessionFolder)
                #endif
            }
            .sheet(isPresented: $newFolderOpen) {
                RenameSheet.newFolder(bridge: bridge, instanceID: nil,
                                      machine: bridge.activeInstance?.displayName ?? "your Mac")
            }
            // Two triggers, because `session_created` and the fleet push that
            // carries the row are separate messages arriving in either order.
            // Whichever lands second is the one that navigates.
            .onChange(of: bridge.lastCreatedSessionID) { _, _ in showCreatedSession() }
            .onChange(of: bridge.sessions.map(\.id)) { _, _ in showCreatedSession() }
            .animation(.easeInOut(duration: 0.22), value: sidebarOpen)
            #if DEBUG
            .task {
                guard let screen = MockHost.autoScreen else { return }
                try? await Task.sleep(nanoseconds: 900_000_000)
                switch screen {
                case "meetings": tab = .meetings; select(bridge.meetings.first?.id, in: .meetings)
                case "agents":   tab = .agents;   select(bridge.agents.first?.id, in: .agents)
                case "machines": tab = .machines; select(bridge.instances.first?.id, in: .machines)
                case "live":     tab = .meetings; await recorder.start(); pushed = true
                case "new", "browse", "worktree":
                                 newSessionOpen = true
                case "palette":  paletteOpen = true
                case "voice":    voiceOpen = true
                case "sessions":
                    let index = MockHost.autoSelectIndex ?? 0
                    select(bridge.sessions.indices.contains(index)
                           ? bridge.sessions[index].id : bridge.sessions.first?.id,
                           in: .sessions)
                case "sidebar":  withAnimation { sidebarOpen = true }
                case "settings": settingsOpen = true
                case "machines-list": tab = .machines
                case "meetings-list": tab = .meetings
                case "agents-list":   tab = .agents
                case "videos-list":   tab = .videos
                case "list":     break
                default:         break
                }
            }
            #endif
        }
        .task { bridge.refresh() }
    }

    // MARK: - Layouts

    /// Phone: one screen at a time, with the tab bar under the list and a
    /// composer or a tab bar under the detail depending on what it is.
    private var compactLayout: some View {
        ZStack {
            if pushed && hasDetail {
                VStack(spacing: 0) {
                    detailColumn(compact: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if detailKeepsTabBar && !fullScreen { tabBar }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(1)
            } else {
                VStack(spacing: 0) {
                    listColumn(compact: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    tabBar
                }
                .transition(.opacity)
            }
        }
    }

    /// iPad: master and detail side by side, with the tab list behind a
    /// slide-over so neither column pays for it.
    private func wideLayout(listWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            if !listHidden && !fullScreen {
                listColumn(compact: false)
                    .frame(width: listWidth)
                    .background(UdhaTheme.list)
                    .hairline(.trailing)
                    .transition(.move(edge: .leading))
            }
            detailColumn(compact: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topLeading) {
            if (listHidden || fullScreen) && tab != .sessions { escapeButton }
        }
    }

    private var tabBar: some View {
        UdhaTabBar(
            items: UdhaTab.allCases.map { item in
                UdhaTabBar.Item(
                    id: item.rawValue,
                    label: item.label,
                    systemImage: item.icon,
                    badge: item == .sessions ? bridge.needsYouCount : nil,
                    recording: item == .meetings && isRecording
                )
            },
            selection: Binding(
                get: { tab.rawValue },
                set: { raw in
                    guard let next = UdhaTab(rawValue: raw) else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        tab = next
                        pushed = false
                    }
                }
            )
        )
    }

    private var isRecording: Bool {
        recorder.state.isActive || bridge.liveMeeting != nil
    }

    // MARK: - Sidebar

    /// The iPad's tab list, as a slide-over. Everything in it is a 52pt target,
    /// and the dimmed content behind it dismisses on a tap.
    private var sidebar: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.easeOut(duration: 0.22)) { sidebarOpen = false } }

            VStack(alignment: .leading, spacing: 4) {
                Text("Udha")
                    .font(UdhaFont.bold(26))
                    .foregroundStyle(UdhaTheme.label)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)

                ForEach(UdhaTab.allCases, id: \.self) { item in
                    sidebarRow(item)
                }

                Spacer(minLength: 0)

                Button {
                    sidebarOpen = false
                    paletteOpen = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 16, weight: .semibold))
                        Text("What can Udha do?").font(UdhaFont.semibold(16))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .foregroundStyle(UdhaTheme.accentInk)
                    .background(UdhaTheme.accentTint,
                                in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                     style: .continuous))
                }
                .buttonStyle(PressDim())
            }
            .padding(.horizontal, 14)
            .padding(.top, 34)
            .padding(.bottom, 18)
            .frame(width: 332)
            .frame(maxHeight: .infinity)
            .background {
                Rectangle().fill(.regularMaterial).overlay(UdhaTheme.sidebar).ignoresSafeArea()
            }
            .shadow(color: .black.opacity(0.35), radius: 30, x: 12)
            .transition(.move(edge: .leading))
        }
    }

    private func sidebarRow(_ item: UdhaTab) -> some View {
        let on = item == tab
        let count = sidebarCount(item)
        return Button {
            withAnimation(.easeOut(duration: 0.22)) {
                tab = item
                sidebarOpen = false
                listHidden = false
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 22)
                    .foregroundStyle(on ? UdhaTheme.onAccent : UdhaTheme.accent)
                Text(item.label)
                    .font(UdhaFont.medium(17))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item == .meetings && isRecording {
                    RecordingDot()
                }
                if let count {
                    Text(count)
                        .font(UdhaFont.regular(14))
                        .monospacedDigit()
                        .foregroundStyle(on ? UdhaTheme.onAccent : UdhaTheme.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .foregroundStyle(on ? UdhaTheme.onAccent : UdhaTheme.label)
            .background(on ? UdhaTheme.accent : .clear,
                        in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                             style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
    }

    private func sidebarCount(_ item: UdhaTab) -> String? {
        switch item {
        case .sessions: return bridge.sessions.isEmpty ? nil : "\(bridge.sessions.count)"
        case .machines: return bridge.instances.isEmpty ? nil : "\(bridge.instances.count)"
        case .meetings: return bridge.meetings.isEmpty ? nil : "\(bridge.meetings.count)"
        case .agents:   return bridge.agents.isEmpty ? nil : "\(bridge.agents.count)"
        case .videos:   return bridge.videos.isEmpty ? nil : "\(bridge.videos.count)"
        }
    }

    // MARK: - Columns

    @ViewBuilder
    private func listColumn(compact: Bool) -> some View {
        let onMenu: (() -> Void)? = compact
            ? nil
            : { withAnimation(.easeOut(duration: 0.22)) { sidebarOpen = true } }

        switch tab {
        case .sessions:
            SessionsList(bridge: bridge, selection: sessionID,
                         compact: compact, onMenu: onMenu,
                         onSelect: { select($0, in: .sessions) },
                         onNew: { newSessionOpen = true },
                         onNewInFolder: { folder in
                             newSessionFolder = folder
                             newSessionOpen = true
                         },
                         onNewFolder: { newFolderOpen = true },
                         onSearch: { paletteOpen = true },
                         onOpenMachines: { tab = .machines })
        case .machines:
            MachinesList(bridge: bridge, selection: machineID,
                         compact: compact, onMenu: onMenu) { select($0, in: .machines) }
        case .meetings:
            MeetingsList(bridge: bridge, recorder: recorder, notes: notesEngine,
                         selection: meetingID,
                         compact: compact, onMenu: onMenu,
                         onSettings: { settingsOpen = true },
                         onSelect: { select($0, in: .meetings) },
                         onOpenLive: { withAnimation(.easeOut(duration: 0.25)) { pushed = true } })
        case .agents:
            AgentsList(bridge: bridge, selection: agentID,
                       compact: compact, onMenu: onMenu) { select($0, in: .agents) }
        case .videos:
            VideosList(bridge: bridge, selection: videoID,
                       compact: compact, onMenu: onMenu) { select($0, in: .videos) }
        }
    }

    /// Whether there is anything to push to on a phone.
    private var hasDetail: Bool {
        switch tab {
        case .sessions: return sessionID.flatMap { bridge.session(id: $0) } != nil
        case .machines: return machineID != nil
        case .meetings: return recorder.state.isActive || meetingID != nil
        case .agents:   return agentID.flatMap { bridge.agent(id: $0) } != nil
        case .videos:   return videoID.flatMap { bridge.video(id: $0) } != nil
        }
    }

    /// A detail screen that ends in a composer owns the bottom of the display;
    /// one that does not keeps the tab bar, so you can leave without going back
    /// first. That is the rule the design draws across its five screens.
    private var detailKeepsTabBar: Bool {
        switch tab {
        case .sessions: return false
        case .meetings: return !(recorder.state.isActive || meetingID == bridge.liveMeetingID)
        default:        return true
        }
    }

    @ViewBuilder
    private func detailColumn(compact: Bool) -> some View {
        let back: (() -> Void)? = compact
            ? { withAnimation(.easeOut(duration: 0.25)) { pushed = false } }
            : nil

        switch tab {
        case .sessions:
            if let id = sessionID ?? (compact ? nil : bridge.sessions.first?.id),
               bridge.session(id: id) != nil {
                SessionDetail(bridge: bridge, sessionID: id,
                              fullScreen: $fullScreen,
                              onBack: back,
                              onCommands: { paletteOpen = true })
            } else {
                detailPlaceholder("terminal", "No session selected")
            }

        case .machines:
            // Defaults to the machine you are talking to, which is the one the
            // numbers can actually be read for.
            if let id = machineID ?? (compact ? nil : (bridge.activeInstanceID ?? bridge.instances.first?.id)),
               bridge.instances.contains(where: { $0.id == id }) {
                MachineDetail(bridge: bridge, machineID: id, onBack: back)
            } else {
                detailPlaceholder("server.rack", "No machine selected")
            }

        case .meetings:
            if recorder.state.isActive {
                LiveMeetingView(bridge: bridge, recorder: recorder, notes: notesEngine, onBack: back)
            } else if let id = meetingID, id == bridge.liveMeetingID, let live = bridge.liveMeeting {
                // A meeting the Mac is recording right now needs the live pane,
                // not the stored-detail pane — the stored transcript is empty
                // until the call ends.
                HostLiveMeetingView(bridge: bridge, meeting: live, onBack: back)
            } else if let id = meetingID, let meeting = bridge.meeting(id: id) {
                MeetingDetail(bridge: bridge, meeting: meeting,
                              notesEngine: notesEngine, retranscriber: retranscriber,
                              onBack: back)
            } else {
                detailPlaceholder("video", "No meeting selected")
            }

        case .agents:
            if let id = agentID ?? (compact ? nil : bridge.agents.first?.id),
               let agent = bridge.agent(id: id) {
                AgentDetail(bridge: bridge, agent: agent, onBack: back)
            } else {
                detailPlaceholder("cpu", "No agent selected")
            }

        case .videos:
            if let id = videoID ?? (compact ? nil : bridge.videos.first?.id),
               let video = bridge.video(id: id) {
                VideoDetail(bridge: bridge, video: video, onBack: back, onDeleted: { videoID = nil })
            } else {
                detailPlaceholder("film", "No video selected")
            }
        }
    }

    private func detailPlaceholder(_ icon: String, _ title: String) -> some View {
        ZStack {
            UdhaTheme.canvas
            EmptyHint(systemImage: icon, title: title)
        }
    }

    // MARK: - Selection

    /// The only chrome left when the bars are gone. Small and low-contrast, but
    /// always present — a mode you cannot see how to leave is a trap.
    private var escapeButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if fullScreen { fullScreen = false } else { listHidden = false }
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .foregroundStyle(UdhaTheme.label)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(PressDim())
        .padding(.leading, 12)
        .padding(.top, 12)
    }

    private func select(_ id: String?, in target: UdhaTab) {
        guard let id else { return }
        switch target {
        case .sessions:
            sessionID = id
        case .meetings:
            meetingID = id
            bridge.loadMeeting(id: id)
            bridge.clearAsk()
        case .videos:
            videoID = id
        case .agents:
            agentID = id
        case .machines:
            machineID = id
            // Opening a machine is when its vitals are worth the host's time.
            bridge.refreshStats()
        }
        withAnimation(.easeOut(duration: 0.25)) {
            sidebarOpen = false
            pushed = true
        }
    }

    /// Navigate to a just-created session, but only once its row actually
    /// exists — selecting on the id alone parks the detail pane on its
    /// placeholder until the fleet catches up.
    private func showCreatedSession() {
        guard let created = bridge.lastCreatedSessionID,
              bridge.sessions.contains(where: { $0.id == created }) else { return }
        newSessionOpen = false
        tab = .sessions
        select(created, in: .sessions)
        bridge.clearLastCreated()
    }

    private func apply(_ destination: PaletteDestination) {
        switch destination {
        case .session(let id):
            tab = .sessions
            select(id, in: .sessions)
        case .meeting(let id):
            tab = .meetings
            select(id, in: .meetings)
        case .agents:
            tab = .agents
        case .record:
            tab = .meetings
            Task {
                await recorder.start()
                withAnimation(.easeOut(duration: 0.25)) { pushed = true }
            }
        case .voice:
            voiceOpen = true
        case .newSession:
            newSessionOpen = true
        case .newFolder:
            newFolderOpen = true
        case .machines:
            tab = .machines
        case .settings:
            settingsOpen = true
        }
    }
}

// MARK: - Login

struct LoginView: View {
    @ObservedObject var auth0: Auth0Manager

    var body: some View {
        ZStack {
            UdhaTheme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                Image(systemName: "terminal.fill")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(UdhaTheme.accent)
                    .padding(.bottom, 22)
                Text("Udha")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(UdhaTheme.label)
                Text("Your agents, your calls, from anywhere")
                    .font(UdhaFont.regular(16))
                    .foregroundStyle(UdhaTheme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                Spacer()

                if let error = auth0.error {
                    Text(error)
                        .font(UdhaFont.regular(13))
                        .foregroundStyle(UdhaTheme.badInk)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                }

                Button {
                    Task { await auth0.login() }
                } label: {
                    HStack(spacing: 10) {
                        if auth0.isLoading { ProgressView().tint(UdhaTheme.onAccent) }
                        Text(auth0.isLoading ? "Signing in…" : "Sign in")
                            .font(UdhaFont.button)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(UdhaTheme.onAccent)
                    .background(UdhaTheme.accent,
                                in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                     style: .continuous))
                }
                .buttonStyle(PressDim())
                .disabled(auth0.isLoading)
                .padding(.horizontal, 24)

                Text("v\(APP_VERSION)")
                    .font(UdhaFont.mono(11))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .padding(.vertical, 18)
            }
        }
    }
}

let APP_VERSION = "5.0.0"
