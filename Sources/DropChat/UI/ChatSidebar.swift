import DropChatCore
import DroppyKit
import SwiftUI

/// The floating window's chat list: open, rename or delete a saved chat.
struct ChatSidebar: View {
    @ObservedObject var app: AppModel
    @ObservedObject var session: ChatSession
    @Environment(\.chatTheme) private var theme

    @State private var hoveredID: UUID?
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var deletingID: UUID?
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            Text("Chats")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.secondary)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .background(WindowDragArea())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if app.recentConversations.isEmpty {
                        Text(app.settings.general.saveHistory ? "Saved chats show up here." : "History is off in settings.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, DroppySpacing.sm)
                    }
                    ForEach(app.recentConversations) { summary in
                        row(summary)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .onChange(of: renameFocused) { _, focused in
            if !focused { commitRename() }
        }
    }

    @ViewBuilder
    private func row(_ summary: ConversationStore.Summary) -> some View {
        if renamingID == summary.id {
            TextField("Chat name", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(theme.primary)
                .focused($renameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { renamingID = nil }
                .padding(.horizontal, DroppySpacing.sm)
                .padding(.vertical, DroppySpacing.xsm)
                .background(theme.raisedFill, in: RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
                .onAppear { renameFocused = true }
        } else if deletingID == summary.id {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                Text("Delete \u{201C}\(summary.title)\u{201D}?")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.primary)
                    .lineLimit(2)
                HStack(spacing: DroppySpacing.xs) {
                    Button("Cancel") { deletingID = nil }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    Button("Delete") {
                        deletingID = nil
                        app.deleteConversation(summary.id)
                    }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                }
            }
            .padding(DroppySpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.raisedFill, in: RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
        } else {
            let isCurrent = summary.id == session.conversation.id
            let isHovered = hoveredID == summary.id
            HStack(spacing: DroppySpacing.xs) {
                Button {
                    session.open(summary.id)
                } label: {
                    Text(summary.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(summary.title)
                if isHovered {
                    Menu {
                        actions(summary)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                }
            }
            .foregroundStyle(isCurrent ? theme.primary : theme.secondary)
            .padding(.horizontal, DroppySpacing.sm)
            .frame(minHeight: 26)
            .background(
                isCurrent ? theme.userBubble : (isHovered ? theme.raisedFill : Color.clear),
                in: RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
            )
            .onHover { inside in
                if inside { hoveredID = summary.id } else if hoveredID == summary.id { hoveredID = nil }
            }
            .contextMenu { actions(summary) }
        }
    }

    @ViewBuilder
    private func actions(_ summary: ConversationStore.Summary) -> some View {
        Button("Rename") {
            deletingID = nil
            renameText = summary.title
            renamingID = summary.id
        }
        Button("Delete", role: .destructive) {
            renamingID = nil
            deletingID = summary.id
        }
    }

    private func commitRename() {
        guard let id = renamingID else { return }
        renamingID = nil
        app.renameConversation(id, to: renameText)
    }
}
