import SwiftUI

/// Rename something on the host, from the phone or iPad.
///
/// One sheet for every rename in the app — a session's label, a video's title.
/// The name being edited is the *host's*, not a nickname the device keeps to
/// itself, and the note under the field says so: a name that only changed here
/// would be worse than no rename at all.
struct RenameSheet: View {
    /// The sheet's title and its button — "Rename" for a rename, "New folder"
    /// / "Create" for the one case where the name is being given for the
    /// first time.
    var title: String = "Rename"
    var actionTitle: String = "Rename"
    /// The caption over the field — "Name", "Title".
    var fieldTitle: String = "Name"
    /// One line under the field saying where else this lands.
    var note: String?
    let initialName: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool

    init(title: String = "Rename",
         actionTitle: String = "Rename",
         fieldTitle: String = "Name",
         note: String? = nil,
         initialName: String,
         onSave: @escaping (String) -> Void) {
        self.title = title
        self.actionTitle = actionTitle
        self.fieldTitle = fieldTitle
        self.note = note
        self.initialName = initialName
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmed.isEmpty && trimmed != initialName }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title, onCancel: { dismiss() })

            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(fieldTitle)
                TextField("name", text: $name)
                    .textFieldStyle(.plain)
                    .font(UdhaFont.regular(16))
                    .foregroundStyle(UdhaTheme.label)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(UdhaTheme.fill,
                                in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                     style: .continuous))
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
                if let note {
                    Text(note)
                        .font(UdhaFont.regular(12))
                        .foregroundStyle(UdhaTheme.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            Spacer(minLength: 0)

            SheetActionBar(title: actionTitle, enabled: canSave, action: save)
        }
        .background(UdhaTheme.canvas)
        // Tall enough for the field, the note and the button, and no taller: a
        // rename is one line of typing and should not cover the pane.
        .presentationDetents([.height(250)])
        .presentationDragIndicator(.visible)
        // The field is the only thing on the screen, so it takes focus without
        // being asked — with a keyboard attached you type straight over the old
        // name, and without one the keyboard is already up.
        .onAppear { focused = true }
        // Esc is what a keyboard expects to close this with; a sheet has no
        // other way to answer it.
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func save() {
        guard canSave else { return }
        onSave(trimmed)
        dismiss()
    }
}

extension RenameSheet {
    /// The session flavour, so both call sites word it the same way.
    static func session(bridge: UdhaBridge, row: SessionRow) -> RenameSheet {
        RenameSheet(
            fieldTitle: "Name",
            note: "Renames it on \(bridge.activeInstance?.displayName ?? "your Mac") too.",
            initialName: row.label
        ) { name in
            bridge.renameSession(id: row.id, to: name)
        }
    }

    /// A folder's name. Folders are the host's too — the same list the Mac's
    /// board shows — so the note says the same thing.
    static func folder(bridge: UdhaBridge, folder: SessionFolder, instanceID: String?, machine: String) -> RenameSheet {
        RenameSheet(
            fieldTitle: "Folder",
            note: "Renames it on \(machine) too.",
            initialName: folder.name
        ) { name in
            bridge.renameFolder(id: folder.id, to: name, onInstance: instanceID)
        }
    }

    /// A new folder, named before it exists. The desktop makes "New folder"
    /// and opens the row for typing; a sheet is the phone's version of the
    /// same one step. `onCreate` gets the fresh id, so "New folder…" on a
    /// session can file it straight in.
    static func newFolder(bridge: UdhaBridge, instanceID: String?, machine: String,
                          onCreate: @escaping (String) -> Void = { _ in }) -> RenameSheet {
        RenameSheet(
            title: "New folder",
            actionTitle: "Create",
            fieldTitle: "Folder",
            note: "Made on \(machine); the Mac's board shows it too.",
            initialName: ""
        ) { name in
            if let id = bridge.createFolder(name: name, onInstance: instanceID) { onCreate(id) }
        }
    }

    /// The video flavour. A published video's public page is retitled too,
    /// which is worth saying before someone renames one that is shared.
    static func video(bridge: UdhaBridge, video: VideoItem) -> RenameSheet {
        RenameSheet(
            fieldTitle: "Title",
            note: video.isPublished
                ? "Retitles the shared link too."
                : "Renames it on \(bridge.activeInstance?.displayName ?? "your Mac") too.",
            initialName: video.title
        ) { title in
            bridge.renameVideo(id: video.id, to: title)
        }
    }
}

// MARK: - Shared sheet chrome

/// A sheet's top bar: Cancel on the left, the title centred, and whatever the
/// sheet needs on the right.
struct SheetHeader<Trailing: View>: View {
    var title: String
    var onCancel: () -> Void
    @ViewBuilder var trailing: Trailing

    init(title: String, onCancel: @escaping () -> Void,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.onCancel = onCancel
        self.trailing = trailing()
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(UdhaFont.navTitle)
                .foregroundStyle(UdhaTheme.label)
            HStack {
                Button("Cancel", action: onCancel)
                    .font(UdhaFont.regular(16))
                    .foregroundStyle(UdhaTheme.accent)
                    .buttonStyle(PressDim())
                Spacer(minLength: 0)
                trailing
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UdhaTheme.separator).frame(height: 0.5)
        }
    }
}

/// A sheet's bottom action: one full-width accent button on the chrome bar.
struct SheetActionBar: View {
    var title: String
    var busyTitle: String?
    var busy: Bool = false
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        ChromeBar {
            Button(action: action) {
                HStack(spacing: 10) {
                    if busy { ProgressView().tint(UdhaTheme.onAccent) }
                    Text(busy ? (busyTitle ?? title) : title).font(UdhaFont.button)
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(enabled ? UdhaTheme.onAccent : UdhaTheme.tertiary)
                .background(enabled ? UdhaTheme.accent : UdhaTheme.fill,
                            in: RoundedRectangle(cornerRadius: UdhaTheme.Radius.control,
                                                 style: .continuous))
            }
            .buttonStyle(PressDim())
            .disabled(!enabled)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }
}
