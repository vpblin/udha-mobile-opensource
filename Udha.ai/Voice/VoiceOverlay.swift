import SwiftUI

/// The voice sheet: claim the agent from the Mac, hold to speak, hand it back.
///
/// Presented as a bottom card over whatever you were doing, because talking to
/// the agent is almost always *about* the thing on screen.
struct VoiceOverlay: View {
    @Bindable var bridge: UdhaBridge
    var onDismiss: () -> Void

    @State private var draft = ""
    private var voice: VoiceSession { bridge.voice }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                meter
                content
            }
            .frame(maxWidth: 620)
            .background(UdhaTheme.card,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(UdhaTheme.separator, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
            .padding(16)
        }
    }

    /// A bar meter across the top of the card. It reads as "the mic is open"
    /// far faster than a label does.
    private var meter: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<30, id: \.self) { i in
                Capsule()
                    .fill(voice.state == .active ? UdhaTheme.accent : UdhaTheme.tertiary.opacity(0.5))
                    .frame(width: 3, height: barHeight(i))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .padding(.horizontal, 20)
        .background(UdhaTheme.fill)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 0, topTrailingRadius: 22,
                                          style: .continuous))
    }

    private func barHeight(_ index: Int) -> CGFloat {
        guard voice.pttHeld else { return 3 }
        return 3 + abs(sin(Double(index) * 1.7)) * 28
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch voice.state {
            case .idle, .releasing:
                Text("The agent is on your Mac")
                    .font(UdhaFont.semibold(20))
                    .foregroundStyle(UdhaTheme.label)
                if let error = voice.lastError {
                    Text(error)
                        .font(UdhaFont.regular(14))
                        .foregroundStyle(UdhaTheme.badInk)
                        .padding(.top, 8)
                }
                actions {
                    PrimaryButton(title: "Take over") { bridge.claimVoice() }
                        .disabled(!bridge.status.isReady)
                    SecondaryButton(title: "Cancel", action: onDismiss)
                }

            case .claiming:
                HStack(spacing: 10) {
                    ProgressView().tint(UdhaTheme.accent)
                    Text("Claiming…")
                        .font(UdhaFont.semibold(20))
                        .foregroundStyle(UdhaTheme.label)
                }
                actions { SecondaryButton(title: "Cancel", action: onDismiss) }

            case .active:
                activeBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var activeBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let last = voice.messages.last {
                Text(last.text)
                    .font(UdhaFont.regular(17))
                    .lineSpacing(4)
                    .foregroundStyle(UdhaTheme.label)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(voice.inputMode == .voice ? "Hold to speak" : "Type to the agent")
                    .font(UdhaFont.semibold(20))
                    .foregroundStyle(UdhaTheme.label)
            }

            Picker("Mode", selection: Bindable(voice).inputMode) {
                ForEach(VoiceSession.InputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.top, 16)

            if voice.inputMode == .voice {
                holdButton.padding(.top, 16)
            } else {
                HStack(spacing: 9) {
                    TextField("Message the agent…", text: $draft)
                        .textFieldStyle(.plain)
                        .font(UdhaFont.regular(16))
                        .foregroundStyle(UdhaTheme.label)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(UdhaTheme.fill, in: Capsule())
                        .onSubmit { voice.sendText(draft); draft = "" }
                    Button {
                        voice.sendText(draft); draft = ""
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(UdhaTheme.onAccent)
                            .background(UdhaTheme.accent, in: Circle())
                    }
                    .buttonStyle(PressDim())
                }
                .padding(.top, 16)
            }

            actions {
                SecondaryButton(title: "Hand back") {
                    bridge.releaseVoice()
                    onDismiss()
                }
                Spacer(minLength: 0)
                Text(voice.pttHeld ? "listening" : "release to send")
                    .font(UdhaFont.regular(12))
                    .foregroundStyle(UdhaTheme.tertiary)
            }
        }
    }

    private var holdButton: some View {
        Text(voice.pttHeld ? "Release to send" : "Hold to speak")
            .font(UdhaFont.button)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .foregroundStyle(UdhaTheme.onAccent)
            .background(voice.pttHeld ? UdhaTheme.bad : UdhaTheme.accent,
                        in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.card, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !voice.pttHeld { voice.pttHeld = true } }
                    .onEnded { _ in voice.pttHeld = false }
            )
    }

    private func actions<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.top, 18)
    }
}
