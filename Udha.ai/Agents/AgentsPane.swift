import SwiftUI

/// The agents master list — reusable prompts kept on the host.
struct AgentsList: View {
    let bridge: UdhaBridge
    var selection: String?
    var compact: Bool = true
    var onMenu: (() -> Void)?
    var onSelect: (String) -> Void

    @State private var query = ""

    private var matches: [BridgeAgent] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return bridge.agents }
        return bridge.agents.filter {
            $0.name.lowercased().contains(trimmed) || $0.summary.lowercased().contains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if compact {
                LargeTitleHeader(title: "Agents", subtitle: subtitle) { EmptyView() }
            } else {
                PadListHeader(title: "Agents", onMenu: onMenu) { EmptyView() }
            }

            if !bridge.agents.isEmpty {
                SearchField(placeholder: "Filter agents", text: $query)
                    .padding(.horizontal, compact ? 20 : 16)
                    .padding(.bottom, 10)
            }

            if bridge.agents.isEmpty {
                EmptyHint(systemImage: "cpu",
                          title: "No agents",
                          subtitle: "Agents defined on your Mac show up here.")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    MasterList(items: matches, compact: compact) { agent in
                        Button { onSelect(agent.id) } label: { row(agent) }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, compact ? 16 : 12)
                    .padding(.bottom, 20)
                }
                .refreshable { bridge.refresh() }
            }
        }
        .background(compact ? AnyShapeStyle(UdhaTheme.canvas) : AnyShapeStyle(Color.clear))
    }

    private var subtitle: String {
        bridge.agents.isEmpty ? "None defined" : "\(bridge.agents.count) reusable prompts"
    }

    private func row(_ agent: BridgeAgent) -> some View {
        let style = MasterSelection(compact: compact, selected: agent.id == selection)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name)
                    .font(UdhaFont.rowTitle)
                    .foregroundStyle(style.label)
                    .lineLimit(1)
                Text(agent.summary)
                    .font(UdhaFont.regular(13))
                    .lineSpacing(2)
                    .foregroundStyle(style.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
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
}

/// One agent: what it does, where it will run, and the exact prompt that runs.
///
/// The prompt is shown verbatim rather than summarised — you are about to let
/// this loose on a repository, so the thing you approve should be the thing
/// that executes.
struct AgentDetail: View {
    let bridge: UdhaBridge
    let agent: BridgeAgent
    var onBack: (() -> Void)? = nil

    @State private var showingFolder = false
    @State private var directory: String?

    private var target: String? { directory ?? agent.directory }

    var body: some View {
        VStack(spacing: 0) {
            DetailNavBar(
                backTitle: onBack == nil ? nil : "Agents",
                onBack: onBack,
                showsSeparator: false
            ) {
                CircleButton(systemImage: "folder", diameter: 36) { showingFolder = true }
                    .accessibilityLabel("Choose a folder")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(agent.name)
                            .font(UdhaFont.screenTitle)
                            .foregroundStyle(UdhaTheme.label)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(agent.summary)
                            .font(UdhaFont.regular(15))
                            .lineSpacing(3)
                            .foregroundStyle(UdhaTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 4)

                    HStack(spacing: 8) {
                        PrimaryButton(title: runLabel, systemImage: "play.fill") {
                            bridge.runAgent(agent, directory: target)
                        }
                        .disabled(!bridge.status.isReady)

                        SecondaryButton(title: "Folder…") { showingFolder = true }
                    }

                    if let target {
                        QuietPill(target, icon: "folder").padding(.horizontal, 4)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeader(title: "Prompt", note: "\(agent.body.count) lines")
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(agent.body.enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line)
                                    .font(UdhaFont.mono(12.5))
                                    .foregroundStyle(UdhaTheme.Term.out)
                                    .lineSpacing(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(UdhaTheme.Term.background,
                                    in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.card,
                                                         style: .continuous))
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 36)
            }
        }
        .background(UdhaTheme.canvas)
        .sheet(isPresented: $showingFolder) {
            DirectoryPicker(bridge: bridge) { picked in
                directory = picked
                showingFolder = false
            }
        }
    }

    private var runLabel: String {
        guard let target, !target.isEmpty else { return "Run…" }
        return "Run in \((target as NSString).lastPathComponent)"
    }
}
