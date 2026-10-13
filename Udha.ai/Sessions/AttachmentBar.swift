import SwiftUI
import PhotosUI

/// The row of staged images sitting on top of the composer, and the control that
/// adds one.
///
/// A chip rather than a preview pane: what you need to know is that the image is
/// there, that it is the right one, and whether it has landed on the machine that
/// will read it. The path it was given is deliberately not shown — it is a
/// `/tmp` name with a salt in it, and the thumbnail says far more about whether
/// you picked the right screenshot.
struct AttachmentBar: View {
    let bridge: UdhaBridge
    let sessionID: String

    private var items: [SessionAttachment] { bridge.attachments(for: sessionID) }

    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { chip($0) }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
    }

    private func chip(_ item: SessionAttachment) -> some View {
        HStack(spacing: 9) {
            thumbnail(item)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(UdhaFont.medium(12.5))
                    .foregroundStyle(UdhaTheme.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(note(item))
                    .font(UdhaFont.regular(11))
                    .foregroundStyle(item.failure == nil ? UdhaTheme.tertiary : UdhaTheme.badInk)
                    .lineLimit(1)
            }
            .frame(maxWidth: 150, alignment: .leading)

            Button {
                bridge.removeAttachment(item.id, from: sessionID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(UdhaTheme.tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
        }
        .padding(.leading, 6)
        .padding(.trailing, 2)
        .frame(height: 48)
        .background(UdhaTheme.card,
                    in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: UdhaTheme.Radius.control, style: .continuous)
                .strokeBorder(item.failure == nil ? UdhaTheme.separator : UdhaTheme.bad,
                              lineWidth: item.failure == nil ? 0.5 : 1.5)
        }
    }

    @ViewBuilder
    private func thumbnail(_ item: SessionAttachment) -> some View {
        ZStack {
            if let image = item.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(UdhaTheme.fill)
                Image(systemName: "photo")
                    .font(.system(size: 12))
                    .foregroundStyle(UdhaTheme.tertiary)
            }
            // An image that has not landed yet is dimmed and marked. Send is off
            // behind it, and this is what says why.
            if item.isInFlight {
                Rectangle().fill(Color.black.opacity(0.5))
                ProgressView().controlSize(.mini).tint(.white)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func note(_ item: SessionAttachment) -> String {
        if let failure = item.failure { return failure }
        return item.isInFlight ? "staging… \(item.sizeText)" : item.sizeText
    }
}

/// The add button. A `PhotosPicker` rather than a camera sheet or a file
/// browser: the thing being sent is almost always a screenshot, and a screenshot
/// is in the photo library a second after it is taken.
struct AttachmentPickerButton: View {
    let bridge: UdhaBridge
    let sessionID: String

    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $picked,
                     maxSelectionCount: 4,
                     matching: .images,
                     photoLibrary: .shared()) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundStyle(UdhaTheme.secondary)
                .background(UdhaTheme.fill, in: Circle())
        }
        .buttonStyle(PressDim())
        .accessibilityLabel("Attach an image")
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            // Cleared straight away so picking the same photo twice in a row is
            // two attachments, not one ignored tap.
            picked = []
            for item in items { load(item) }
        }
    }

    private func load(_ item: PhotosPickerItem) {
        Task {
            // `loadTransferable` hands back the original representation — several
            // megabytes for a modern screenshot. Shrinking happens in the bridge,
            // off the main actor, before any of it reaches the wire.
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            let name = item.itemIdentifier.map { "screenshot-\($0.prefix(6))" } ?? "screenshot"
            await MainActor.run {
                bridge.stageAttachment(for: sessionID, data: data, name: name)
            }
        }
    }
}
