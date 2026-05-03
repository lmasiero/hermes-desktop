import SwiftUI

private let sessionDetailBottomID = "session-detail-bottom"

private func sessionMessageScrollID(_ message: SessionMessage) -> String {
    "session-message-\(message.id)"
}

private func pendingTurnScrollID(_ turn: PendingSessionTurn) -> String {
    "pending-turn-\(turn.id.uuidString)"
}

private enum SessionScrollReason {
    case sessionChanged
    case messagesLoaded
    case pendingTurnChanged
    case messagesChangedWhilePending

    var delay: DispatchTimeInterval {
        switch self {
        case .sessionChanged:
            return .milliseconds(120)
        case .messagesLoaded:
            return .milliseconds(60)
        case .pendingTurnChanged, .messagesChangedWhilePending:
            return .milliseconds(40)
        }
    }

    var followUpDelay: DispatchTimeInterval? {
        switch self {
        case .sessionChanged:
            return .milliseconds(360)
        case .messagesLoaded:
            return .milliseconds(220)
        case .pendingTurnChanged, .messagesChangedWhilePending:
            return .milliseconds(140)
        }
    }

    var animated: Bool {
        switch self {
        case .sessionChanged, .messagesLoaded:
            return false
        case .pendingTurnChanged, .messagesChangedWhilePending:
            return true
        }
    }
}

private struct SessionScrollRequest: Equatable {
    let id = UUID()
    let reason: SessionScrollReason?

    init(reason: SessionScrollReason? = nil) {
        self.reason = reason
    }

    var isPending: Bool {
        reason != nil
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var appState: AppState

    let session: SessionSummary?
    let messages: [SessionMessage]
    let errorMessage: String?
    let conversationError: String?
    let isSendingMessage: Bool
    let pendingTurn: PendingSessionTurn?
    let onStartSession: (String, Bool) async -> Bool
    let onSendMessage: (String, Bool) async -> Bool

    @State private var showDeleteConfirmation = false
    @State private var scrollRequest = SessionScrollRequest()

    private var latestMessageScrollKey: String {
        "\(messages.count):\(messages.last?.id ?? "none")"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        scrollContent

                        Color.clear
                            .frame(height: 1)
                            .id(sessionDetailBottomID)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }
                .onChange(of: session?.id) { _, _ in
                    requestScrollToLatest(proxy, reason: .sessionChanged)
                }
                .onChange(of: latestMessageScrollKey) { _, _ in
                    guard session != nil, !messages.isEmpty else { return }
                    requestScrollToLatest(
                        proxy,
                        reason: pendingTurn == nil ? .messagesLoaded : .messagesChangedWhilePending
                    )
                }
                .onChange(of: pendingTurn?.id) { _, _ in
                    requestScrollToLatest(proxy, reason: .pendingTurnChanged)
                }
                .task(id: session?.id) {
                    requestScrollToLatest(proxy, reason: .sessionChanged)
                }
            }

            Divider()
                .opacity(0.6)

            composerDock
        }
        .alert("Delete this session?", isPresented: $showDeleteConfirmation, presenting: session) { session in
            Button("Delete", role: .destructive) {
                Task {
                    await appState.deleteSession(session)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text(L10n.string(
                "“%@” will be removed from Hermes Desktop and deleted on the remote Hermes host as well. This action cannot be undone.",
                session.resolvedTitle
            ))
        }
    }

    @ViewBuilder
    private var scrollContent: some View {
        if let session {
            SessionSummaryPanel(
                session: session,
                isDeleting: appState.isDeletingSession && appState.selectedSessionID == session.id,
                onDelete: { showDeleteConfirmation = true }
            )

            if let errorMessage {
                HermesSurfacePanel {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            transcriptContent(for: session)
        } else if let pendingTurn, pendingTurn.sessionID == nil {
            HermesSurfacePanel(
                title: "Starting Session"
            ) {
                PendingSessionTurnView(turn: pendingTurn, showPrompt: true)
                    .id(pendingTurnScrollID(pendingTurn))
            }
        } else {
            HermesSurfacePanel {
                ContentUnavailableView(
                    "Start or select a session",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Write below to begin a new Hermes conversation, or choose an existing session from the list.")
                )
                .frame(maxWidth: .infinity, minHeight: 320)
            }
        }
    }

    @ViewBuilder
    private func transcriptContent(for session: SessionSummary) -> some View {
        let matchingPendingTurn = pendingTurn?.sessionID == session.id ? pendingTurn : nil

        if messages.isEmpty && matchingPendingTurn == nil {
            HermesSurfacePanel {
                ContentUnavailableView(
                    "No transcript entries",
                    systemImage: "text.bubble",
                    description: Text("This session has no readable message rows yet.")
                )
                .frame(maxWidth: .infinity, minHeight: 280)
            }
        } else {
            HermesSurfacePanel(
                title: "Transcript",
                subtitle: "Messages are shown in the order Hermes stored them for this session."
            ) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageCard(message: message)
                            .id(sessionMessageScrollID(message))
                    }

                    if let matchingPendingTurn {
                        PendingSessionTurnView(
                            turn: matchingPendingTurn,
                            showPrompt: !messages.containsUserPrompt(matchingPendingTurn.prompt)
                        )
                        .id(pendingTurnScrollID(matchingPendingTurn))
                    }
                }
            }
        }
    }

    private var composerDock: some View {
        SessionComposerPanel(
            title: session == nil ? "New Session" : "Continue Session",
            placeholder: session == nil ? "Start a new Hermes session…" : "Write a reply to continue this session…",
            errorMessage: conversationError,
            isSending: isSendingMessage,
            onSend: session == nil ? onStartSession : onSendMessage
        )
        .id(session?.id ?? "new-session")
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }

    private func requestScrollToLatest(_ proxy: ScrollViewProxy, reason: SessionScrollReason) {
        let request = SessionScrollRequest(reason: reason)
        scrollRequest = request

        scheduleScrollToLatest(
            proxy,
            request: request,
            reason: reason,
            delay: reason.delay,
            completesRequest: reason.followUpDelay == nil
        )

        if let followUpDelay = reason.followUpDelay {
            scheduleScrollToLatest(
                proxy,
                request: request,
                reason: reason,
                delay: followUpDelay,
                completesRequest: true
            )
        }
    }

    private func scheduleScrollToLatest(
        _ proxy: ScrollViewProxy,
        request: SessionScrollRequest,
        reason: SessionScrollReason,
        delay: DispatchTimeInterval,
        completesRequest: Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard scrollRequest == request else { return }
            let target = latestScrollTarget

            if reason.animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(target.id, anchor: target.anchor)
                }
            } else {
                proxy.scrollTo(target.id, anchor: target.anchor)
            }

            guard completesRequest else { return }
            scrollRequest = SessionScrollRequest()
        }
    }

    private var latestScrollTarget: (id: String, anchor: UnitPoint) {
        if let pendingTurn,
           pendingTurn.sessionID == nil || pendingTurn.sessionID == session?.id {
            return (pendingTurnScrollID(pendingTurn), .bottom)
        }

        if let lastMessage = messages.last {
            return (sessionMessageScrollID(lastMessage), .top)
        }

        return (sessionDetailBottomID, .bottom)
    }
}

private struct SessionSummaryPanel: View {
    let session: SessionSummary
    let isDeleting: Bool
    let onDelete: () -> Void

    var body: some View {
        HermesSurfacePanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.resolvedTitle)
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(session.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 12)

                    HStack(spacing: 8) {
                        if let model = session.displayModel {
                            HermesBadge(text: model, tint: .orange)
                        }

                        if let count = session.messageCount {
                            HermesBadge(text: L10n.string("%@ messages", "\(count)"), tint: .accentColor)
                        }

                        Button(action: onDelete) {
                            Group {
                                if isDeleting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "trash")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .foregroundStyle(.red)
                            .frame(minWidth: 14, minHeight: 14)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.red.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string("Delete session"))
                        .accessibilityLabel(L10n.string("Delete session"))
                        .disabled(isDeleting)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        sessionDates
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sessionDates
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sessionDates: some View {
        if let startedAt = session.startedAt?.dateValue {
            HermesLabeledValue(
                label: "Started",
                value: DateFormatters.shortDateTimeFormatter().string(from: startedAt)
            )
        }

        if let lastActive = session.lastActive?.dateValue {
            HermesLabeledValue(
                label: "Last active",
                value: DateFormatters.shortDateTimeFormatter().string(from: lastActive)
            )
        }
    }
}

private struct SessionComposerPanel: View {
    let title: String
    let placeholder: String
    let errorMessage: String?
    let isSending: Bool
    let onSend: (String, Bool) async -> Bool

    @State private var draft = ""
    @State private var autoApproveCommands = false
    @State private var isExpanded = false
    @FocusState private var isEditorFocused: Bool

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !isSending && !trimmedDraft.isEmpty
    }

    private var shouldUseExpandedEditor: Bool {
        isExpanded || draft.contains("\n") || draft.count > 96
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(Color.accentColor)

                Text(L10n.string(title))
                    .font(.headline)

                Spacer()
            }

            if let errorMessage, !errorMessage.isEmpty {
                HermesInsetSurface {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            composerInput
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var composerInput: some View {
        if shouldUseExpandedEditor {
            VStack(alignment: .leading, spacing: 10) {
                promptEditor(height: 96, placeholderPadding: EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 12))
                    .frame(height: 108)

                HStack {
                    Spacer(minLength: 8)
                    controlCluster
                }
            }
        } else {
            HStack(alignment: .center, spacing: 10) {
                promptEditor(height: 28, placeholderPadding: EdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 0))
                    .frame(minWidth: 80)

                controlCluster
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 42)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .onTapGesture {
                expandEditor()
            }
        }
    }

    private func promptEditor(height: CGFloat, placeholderPadding: EdgeInsets) -> some View {
        ZStack(alignment: .topLeading) {
            if shouldUseExpandedEditor {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            }

            if draft.isEmpty {
                Text(L10n.string(placeholder))
                    .foregroundStyle(.tertiary)
                    .padding(placeholderPadding)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $draft)
                .font(.body)
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .focused($isEditorFocused)
                .padding(.horizontal, shouldUseExpandedEditor ? 7 : 0)
                .padding(.vertical, shouldUseExpandedEditor ? 5 : 0)
                .frame(height: height)
                .disabled(isSending)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else {
                        return .ignored
                    }

                    submit()
                    return .handled
                }
        }
        .overlay {
            if shouldUseExpandedEditor {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private var controlCluster: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $autoApproveCommands) {
                Label(L10n.string("Auto-approve commands"), systemImage: "checkmark.shield")
            }
            .toggleStyle(.checkbox)
            .disabled(isSending)
            .help(L10n.string("Runs this turn with Hermes command approval bypassed."))

            Button {
                submit()
            } label: {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill")

                        Text("⌘↩")
                            .font(.caption2.monospaced().weight(.semibold))
                    }
                    .frame(minWidth: 48)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help(L10n.string("Send with Command-Return"))
            .accessibilityLabel(L10n.string("Send"))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func submit() {
        let prompt = trimmedDraft
        guard !isSending, !prompt.isEmpty else { return }
        let shouldAutoApprove = autoApproveCommands
        autoApproveCommands = false
        isExpanded = false
        isEditorFocused = false
        draft = ""

        Task {
            let didSend = await onSend(prompt, shouldAutoApprove)
            if !didSend && draft.isEmpty {
                draft = prompt
                isExpanded = prompt.contains("\n") || prompt.count > 96
            }
        }
    }

    private func expandEditor() {
        guard !isSending else { return }
        isExpanded = true
        DispatchQueue.main.async {
            isEditorFocused = true
        }
    }
}

private struct PendingSessionTurnView: View {
    let turn: PendingSessionTurn
    let showPrompt: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showPrompt {
                PendingBubble(
                    title: "You",
                    icon: "person.crop.circle.fill",
                    content: turn.prompt,
                    tint: .green
                )
            }

            HermesInsetSurface {
                HStack(alignment: .center, spacing: 12) {
                    ProgressView()
                        .controlSize(.small)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(L10n.string("Hermes is working"))
                                .font(.subheadline.weight(.semibold))

                            if turn.autoApproveCommands {
                                HermesBadge(text: "Auto-approve", tint: .orange)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct PendingBubble: View {
    let title: String
    let icon: String
    let content: String
    let tint: Color

    var body: some View {
        HermesInsetSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)

                    Text(L10n.string(title))
                        .font(.subheadline.weight(.semibold))

                    Spacer()
                }

                Text(content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct MessageCard: View {
    let message: SessionMessage

    var body: some View {
        HermesInsetSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    HermesBadge(
                        text: displayRole,
                        tint: roleTint,
                        isMonospaced: false
                    )

                    Spacer()

                    if let timestamp = message.timestamp?.dateValue {
                        Text(DateFormatters.shortDateTimeFormatter().string(from: timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let content = message.content, !content.isEmpty {
                    Text(content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(L10n.string("No text payload"))
                        .foregroundStyle(.secondary)
                        .italic()
                }

                if let metadata = message.displayMetadata, !metadata.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("Metadata"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(metadata.keys.sorted(), id: \.self) { key in
                            if let value = metadata[key] {
                                HermesInsetSurface {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(key)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)

                                        Text(value.displayString)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var displayRole: String {
        message.role.displayTitle
    }

    private var roleTint: Color {
        switch message.role {
        case .assistant:
            return .blue
        case .user:
            return .green
        case .system:
            return .orange
        case .event, .custom:
            return .secondary
        }
    }
}

private extension Array where Element == SessionMessage {
    func containsUserPrompt(_ prompt: String) -> Bool {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else { return false }

        return contains { message in
            guard message.role == .user,
                  let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return content == normalizedPrompt
        }
    }
}
