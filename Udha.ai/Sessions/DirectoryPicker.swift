import SwiftUI

/// Walks the host's filesystem one level at a time via `list_directory`.
/// Used to bind an agent to a repo, and to pick a root for a new session.
///
/// Three things make this navigable on a phone rather than a folder list you
/// scroll forever: recent projects as one-tap chips, a breadcrumb you can jump
/// backwards through, and a marker on folders that are actually git repos —
/// which are, in practice, the only folders worth starting a session in.
struct DirectoryPicker: View {
    let bridge: UdhaBridge
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showHidden = false

    private var listing: DirectoryListing? { bridge.directoryListing }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Choose a folder", onCancel: { dismiss() }) {
                Button {
                    showHidden.toggle()
                    bridge.listDirectory(path: listing?.path ?? "", showHidden: showHidden)
                } label: {
                    Image(systemName: showHidden ? "eye" : "eye.slash")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(showHidden ? UdhaTheme.accent : UdhaTheme.secondary)
                }
                .buttonStyle(PressDim())
                .accessibilityLabel(showHidden ? "Hide dotfiles" : "Show dotfiles")
            }

            breadcrumb
            recents
            entries
        }
        .background(UdhaTheme.canvas)
        .task {
            bridge.listDirectory(path: "", showHidden: showHidden)
            bridge.listRecentDirectories()
        }
    }

    /// Tappable path segments. On a phone the full path rarely fits, so this
    /// scrolls horizontally and stays pinned to the tail — the part you are
    /// actually in.
    private var breadcrumb: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(crumbs.enumerated()), id: \.element.path) { index, crumb in
                        // The root crumb is itself a "/", so a separator only
                        // goes before the *second* segment onward — otherwise
                        // the bar opens with "//Users".
                        if index > 1 {
                            Text("/")
                                .font(UdhaFont.mono(12))
                                .foregroundStyle(UdhaTheme.tertiary.opacity(0.6))
                        }
                        Button {
                            bridge.listDirectory(path: crumb.path, showHidden: showHidden)
                        } label: {
                            Text(crumb.name)
                                .font(UdhaFont.mono(12))
                                .foregroundStyle(crumb.path == listing?.path
                                                 ? UdhaTheme.label : UdhaTheme.secondary)
                        }
                        .buttonStyle(PressDim())
                    }
                }
                .padding(.horizontal, 16)
            }
            .defaultScrollAnchor(.trailing)

            if let path = listing?.path, !path.isEmpty {
                Button { onPick(path) } label: {
                    Pill("Use this", tint: UdhaTheme.accent, solid: true)
                }
                .buttonStyle(PressDim())
                .padding(.trailing, 16)
            }
        }
        .frame(height: 44)
    }

    /// The host's own LRU of session directories. Almost every new session
    /// starts in a folder you have used before, so this is the short path.
    @ViewBuilder
    private var recents: some View {
        if !bridge.recentDirectories.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(bridge.recentDirectories, id: \.self) { dir in
                        Button { onPick(dir) } label: {
                            QuietPill((dir as NSString).lastPathComponent, icon: "clock")
                        }
                        .buttonStyle(PressDim())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
    }

    private var entries: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let listing {
                    UdhaCard(insets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)) {
                        if !listing.parent.isEmpty {
                            row(name: "..", icon: "arrow.up.left", isRepo: false) {
                                bridge.listDirectory(path: listing.parent, showHidden: showHidden)
                            } trailing: { EmptyView() }
                        }
                        ForEach(Array(listing.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 || !listing.parent.isEmpty { CardDivider(inset: 46) }
                            row(name: entry.name,
                                icon: entry.isRepo ? "shippingbox" : "folder",
                                isRepo: entry.isRepo) {
                                bridge.listDirectory(path: entry.path, showHidden: showHidden)
                            } trailing: {
                                Button { onPick(entry.path) } label: {
                                    Pill("Use", tint: UdhaTheme.accentInk)
                                }
                                .buttonStyle(PressDim())
                            }
                        }
                    }

                    if let error = listing.error {
                        Text(error)
                            .font(UdhaFont.regular(13.5))
                            .foregroundStyle(UdhaTheme.badInk)
                            .padding(16)
                    } else if listing.entries.isEmpty && listing.parent.isEmpty {
                        Text("No folders here")
                            .font(UdhaFont.regular(13.5))
                            .foregroundStyle(UdhaTheme.tertiary)
                            .padding(24)
                    }
                } else {
                    ProgressView().tint(UdhaTheme.accent).padding(44)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Rows

    private func row<T: View>(
        name: String,
        icon: String,
        isRepo: Bool,
        open: @escaping () -> Void,
        @ViewBuilder trailing: () -> T
    ) -> some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(isRepo ? UdhaTheme.accent : UdhaTheme.secondary)
                        .frame(width: 20)
                    Text(name)
                        .font(UdhaFont.regular(16))
                        .foregroundStyle(UdhaTheme.label)
                        .lineLimit(1)
                    if isRepo {
                        Text("git")
                            .font(UdhaFont.mono(10))
                            .foregroundStyle(UdhaTheme.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(UdhaTheme.fill, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 52)
    }

    /// `/Users/alex/code` -> [/, Users, alex, code], each with its full path so
    /// tapping one jumps straight there.
    private var crumbs: [(name: String, path: String)] {
        guard let path = listing?.path, !path.isEmpty else { return [] }
        var out: [(name: String, path: String)] = [("/", "/")]
        var running = ""
        for part in path.split(separator: "/") {
            running += "/" + part
            out.append((String(part), running))
        }
        return out
    }
}
