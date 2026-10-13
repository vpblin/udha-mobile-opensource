import SwiftUI

/// The videos master list: the recording library living on the host.
///
/// Read-only about the *content* and deliberately so — recording, joining and
/// re-rendering need the camera, the screen and the encoder, all of which are
/// on the Mac. What travels well is the library itself: what exists, what it
/// is called, and what can go. So this tab lists, retitles and deletes, and
/// hands you the share link for anything already published.
struct VideosList: View {
    let bridge: UdhaBridge
    var selection: String?
    var compact: Bool = true
    var onMenu: (() -> Void)?
    var onSelect: (String) -> Void

    @State private var renaming: VideoItem?
    /// Video queued for deletion, held while its confirmation is up.
    @State private var deleting: VideoItem?

    var body: some View {
        VStack(spacing: 0) {
            if compact {
                LargeTitleHeader(title: "Videos", subtitle: subtitle) { EmptyView() }
            } else {
                PadListHeader(title: "Videos", onMenu: onMenu) { EmptyView() }
            }

            if let host = bridge.videoHost {
                HStack {
                    if bridge.videoHosts.count > 1 {
                        Picker("Library on", selection: Binding(get: { bridge.videoHostID ?? "" },
                            set: { bridge.selectVideoHost($0) })) {
                            ForEach(bridge.videoHosts) { machine in
                                Text(machine.displayName).tag(machine.id)
                            }
                        }
                    } else {
                        Label(host.displayName, systemImage: "laptopcomputer")
                            .font(.subheadline).foregroundStyle(UdhaTheme.secondary)
                    }
                    Spacer()
                }.padding(.horizontal, 20).padding(.bottom, 10)
            }
            content
        }
        .background(compact ? AnyShapeStyle(UdhaTheme.canvas) : AnyShapeStyle(Color.clear))
        // Opening the tab is the moment the library is worth re-asking for:
        // the Mac may have finished rendering something since the handshake.
        .task { bridge.listVideos() }
        .sheet(item: $renaming) { video in
            RenameSheet.video(bridge: bridge, video: video)
        }
        .confirmationDialog(
            "Delete \(deleting?.title ?? "video")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let video = deleting { bridge.deleteVideo(id: video.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(VideoDestruction.explanation)
        }
    }

    private var subtitle: String {
        guard bridge.status.isReady else { return "Connecting" }
        if bridge.checkingVideoSupport && !bridge.canBrowseVideos { return "Checking video libraries" }
        guard bridge.canBrowseVideos else { return "Mac video library unavailable" }
        if bridge.videosLoading && bridge.videos.isEmpty { return "Loading recordings" }
        return bridge.videos.isEmpty ? "Nothing recorded" : "\(bridge.videos.count) recordings"
    }

    @ViewBuilder
    private var content: some View {
        if !bridge.status.isReady {
            ConnectionState(bridge: bridge)
        } else if !bridge.canBrowseVideos {
            VStack(spacing: 16) {
                EmptyHint(systemImage: "film",
                          title: bridge.checkingVideoSupport ? "Checking video libraries" : (bridge.hasOnlineMac ? "Video library unavailable" : "Connect your Mac"),
                          subtitle: bridge.checkingVideoSupport ? "Waiting for your machines to report their capabilities."
                            : (bridge.hasOnlineMac ? "Reconnect to check video support. If your Mac still does not support videos, update Udha on that Mac."
                               : "Videos live on your Mac. Open Udha there and keep it connected to browse recordings."))
                Button("Reconnect") { Task { await bridge.retry() } }
            }.frame(maxHeight: .infinity)
        } else if let error = bridge.videoLibraryError, bridge.videos.isEmpty {
            VStack(spacing: 16) {
                EmptyHint(systemImage: "film", title: "Couldn’t load videos", subtitle: error)
                Button("Try again") { bridge.listVideos() }
            }.frame(maxHeight: .infinity)
        } else if bridge.videosLoading && bridge.videos.isEmpty {
            ProgressView("Loading recordings…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if bridge.videos.isEmpty {
            EmptyHint(systemImage: "film",
                      title: "No videos yet",
                      subtitle: "Recordings made on \(hostName) show up here.")
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                MasterList(items: bridge.videos, compact: compact) { video in
                    Button { onSelect(video.id) } label: { videoRow(video) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename…") { renaming = video }
                            Divider()
                            Button("Delete", role: .destructive) { deleting = video }
                                .disabled(video.busy)
                        }
                }
                .padding(.horizontal, compact ? 16 : 12)
                .padding(.bottom, 20)
            }
            .refreshable { bridge.listVideos() }
        }
    }

    private var hostName: String { bridge.videoHost?.displayName ?? "your Mac" }

    private func videoRow(_ video: VideoItem) -> some View {
        let style = MasterSelection(compact: compact, selected: video.id == selection)
        return HStack(spacing: 12) {
            LiveDot(color: dotColor(video),
                    animated: video.stage == .capturing || video.stage == .composing,
                    hollow: video.stage == .needsProcessing)
            VStack(alignment: .leading, spacing: 3) {
                // No trailing clock: `listMeta` below already carries the
                // duration, and printing it twice on a 56pt row is noise.
                Text(video.title)
                    .font(UdhaFont.rowTitle)
                    .foregroundStyle(style.label)
                    .lineLimit(1)
                Text(video.listMeta)
                    .font(UdhaFont.regular(13))
                    .foregroundStyle(video.stage == .failed && !style.selected
                                     ? UdhaTheme.badInk : style.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(style.chevron)
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 56)
        .background(style.background)
        .contentShape(Rectangle())
    }

    /// The dot says whether the video is finished, still cooking, or broken —
    /// the only three things worth telling apart at a glance.
    private func dotColor(_ video: VideoItem) -> Color {
        switch video.stage {
        case .failed:                            return UdhaTheme.bad
        case .capturing, .transcribing, .composing, .needsProcessing:
                                                 return UdhaTheme.accent
        case .ready, .unknown:                   return UdhaTheme.good
        }
    }
}

/// What deleting a video actually does, in the two places that ask.
enum VideoDestruction {
    static let explanation =
        "Deletes the recording and its rendered files on your Mac. This cannot be undone. "
        + "A published link stops working."
}

// MARK: - Detail

/// One video: what it is, what it was made of, and the three things this
/// device can honestly do with it — open the share link, retitle it, bin it.
struct VideoDetail: View {
    let bridge: UdhaBridge
    let video: VideoItem
    var onBack: (() -> Void)? = nil
    /// Clears the shell's selection once the row is gone.
    var onDeleted: () -> Void = {}

    @Environment(\.openURL) private var openURL
    @State private var renaming = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            DetailNavBar(
                backTitle: onBack == nil ? nil : "Videos",
                onBack: onBack,
                showsSeparator: false
            ) {
                Menu {
                    Button("Rename…") { renaming = true }
                    Divider()
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                        .disabled(video.busy)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(UdhaTheme.label)
                        .background(UdhaTheme.fill, in: Circle())
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(video.title)
                            .font(UdhaFont.screenTitle)
                            .foregroundStyle(UdhaTheme.label)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(video.detailStamp)
                            .font(UdhaFont.regular(13))
                            .foregroundStyle(UdhaTheme.secondary)
                    }
                    .padding(.horizontal, 4)

                    if let url = video.shareURL {
                        PrimaryButton(title: "Open link", systemImage: "arrow.up.right") {
                            openURL(url)
                        }
                    }

                    if let reason = video.failureReason, !reason.isEmpty {
                        UdhaCard(ring: UdhaTheme.bad) {
                            Text(reason)
                                .font(UdhaFont.mono(12.5))
                                .foregroundStyle(UdhaTheme.badInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    facts
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 36)
            }
        }
        .background(UdhaTheme.canvas)
        .sheet(isPresented: $renaming) {
            RenameSheet.video(bridge: bridge, video: video)
        }
        .confirmationDialog("Delete \(video.title)?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                bridge.deleteVideo(id: video.id)
                onDeleted()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(VideoDestruction.explanation)
        }
    }

    private var facts: some View {
        var rows: [(String, String)] = [
            ("Status", video.stage.label),
            ("Recorded", video.sourcesLabel),
        ]
        if !video.orientations.isEmpty {
            rows.append(("Rendered", video.orientations.joined(separator: " · ")))
        }
        if let url = video.shareURL {
            rows.append(("Link", url.absoluteString))
            if video.isPasswordProtected {
                rows.append(("Password", "the link asks for one"))
            }
        } else {
            // Said plainly rather than left as a missing button: the file is on
            // the Mac and a phone cannot play what it cannot reach.
            rows.append(("Link", "not published — the file is only on \(hostName)"))
        }
        return UdhaCard(insets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, item in
                if index > 0 { CardDivider() }
                HStack(alignment: .top, spacing: 12) {
                    Text(item.0)
                        .font(UdhaFont.regular(14))
                        .foregroundStyle(UdhaTheme.secondary)
                        .frame(width: 84, alignment: .leading)
                    Text(item.1)
                        .font(UdhaFont.medium(14))
                        .foregroundStyle(UdhaTheme.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
            }
        }
    }

    private var hostName: String { bridge.activeInstance?.displayName ?? "your Mac" }
}
