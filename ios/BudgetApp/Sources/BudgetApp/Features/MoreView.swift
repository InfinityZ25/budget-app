import SwiftUI

struct MoreView: View {
    @Bindable var store: FinanceStore

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    GoalsView(goals: store.goals)
                } label: {
                    Label("Saving and debt plans", systemImage: "flag.checkered")
                }
                NavigationLink {
                    ConnectionsView(store: store)
                } label: {
                    Label("Banks and statements", systemImage: "building.columns")
                }
                NavigationLink {
                    AssistantView(store: store)
                } label: {
                    Label("Finance assistant", systemImage: "message.badge.waveform")
                }
                NavigationLink {
                    ReceiptScannerView()
                } label: {
                    Label("Receipt scanner", systemImage: "doc.viewfinder")
                }
            }
            .navigationTitle("More")
        }
    }
}

struct ConnectionsView: View {
    @Bindable var store: FinanceStore

    var body: some View {
        List {
            Section("Connected and manual accounts") {
                ForEach(store.accounts) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(account.name).font(.body.weight(.medium))
                            Spacer()
                            Text(account.source.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(AppDesign.money(account.balanceCents)).monospacedDigit()
                    }
                }
            }
            Section("Statements") {
                if store.statements.isEmpty {
                    Text("Upload or enter statement metadata from Add.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.statements) { statement in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statement.fileName).font(.body.weight(.medium))
                        Text("\(statement.importedCount) imported transactions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                NavigationLink {
                    PlaidConnectView(store: store)
                } label: {
                    Label("Connect bank with Plaid", systemImage: "link.circle")
                }
                Button {
                    Task { await store.syncPlaidTransactions() }
                } label: {
                    Label("Sync Plaid transactions", systemImage: "arrow.triangle.2.circlepath")
                }
                if let summary = store.lastPlaidSyncSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                NavigationLink {
                    StatementImportView(store: store)
                } label: {
                    Label("Import statement", systemImage: "square.and.arrow.down")
                }
            }
        }
        .navigationTitle("Banks")
    }
}

struct AssistantView: View {
    @Bindable var store: FinanceStore
    @State private var message = ""
    @State private var voiceSession = VoiceSessionManager()
    @State private var showingThreads = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if store.assistantMessages.isEmpty {
                            AssistantEmptyState()
                        }
                        ForEach(store.assistantMessages) { item in
                            AssistantMessageBubble(message: item)
                                .id(item.id)
                        }
                        if let status = store.assistantTypingStatus {
                            Label(status, systemImage: status.hasPrefix("Finished") ? "checkmark.circle.fill" : "ellipsis.message")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("assistant-bottom")
                    }
                    .padding()
                }
                .onChange(of: store.assistantMessages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: store.assistantMessages.last?.content) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: store.assistantTypingStatus) { _, _ in
                    scrollToBottom(proxy)
                }
            }
            AssistantComposer(message: $message, voiceSession: voiceSession) {
                let outgoing = message
                message = ""
                Task { await store.askAssistant(outgoing) }
            }
        }
        .navigationTitle("Assistant")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    voiceSession.stop()
                    Task { await store.createNewAssistantConversation() }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                Button {
                    showingThreads = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
        }
        .sheet(isPresented: $showingThreads) {
            AssistantThreadsView(store: store, voiceSession: voiceSession, isPresented: $showingThreads)
        }
        .onAppear {
            configureVoiceCallbacks()
        }
        .onDisappear {
            voiceSession.stop()
            store.finishVoiceAssistantMessage(status: nil)
        }
    }

    private func configureVoiceCallbacks() {
        voiceSession.onUserTranscript = { text in
            store.appendVoiceUserMessage(text)
        }
        voiceSession.onAssistantDelta = { delta in
            store.appendVoiceAssistantDelta(delta)
        }
        voiceSession.onAssistantFinished = {
            store.finishVoiceAssistantMessage(status: nil)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.snappy(duration: 0.25)) {
            proxy.scrollTo("assistant-bottom", anchor: .bottom)
        }
    }
}

private struct AssistantEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "message.badge.waveform")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Ask about your finances")
                .font(.title3.weight(.semibold))
            Text("Type or use the microphone. Voice transcripts and replies appear as normal messages.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppDesign.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct AssistantMessageBubble: View {
    let message: AssistantMessage

    var body: some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 6) {
            if message.content.isEmpty && message.isStreaming {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Thinking…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(renderedContent)
                    .textSelection(.enabled)
            }
            if message.isStreaming {
                Text("Typing…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
        .background(message.role == "user" ? Color.accentColor.opacity(0.14) : AppDesign.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var renderedContent: AttributedString {
        (try? AttributedString(markdown: message.content)) ?? AttributedString(message.content)
    }
}

private struct AssistantComposer: View {
    @Binding var message: String
    @Bindable var voiceSession: VoiceSessionManager
    let send: () -> Void

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if voiceSession.isActive {
                Label(voiceSession.status.label, systemImage: voiceSession.status == .speaking ? "speaker.wave.2.fill" : "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            HStack(spacing: 10) {
                TextField("Ask about spending, debt, or cashflow", text: $message, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button {
                    voiceSession.toggle()
                } label: {
                    Image(systemName: voiceSession.isActive ? "mic.fill" : "mic")
                        .font(.title3)
                        .foregroundStyle(voiceSession.isActive ? .white : Color.accentColor)
                        .frame(width: 38, height: 38)
                        .background(voiceSession.isActive ? Color.red : Color.secondary.opacity(0.18), in: Circle())
                        .symbolEffect(.pulse, isActive: voiceSession.isActive)
                }
                .accessibilityLabel(voiceSession.isActive ? "Stop voice" : "Start voice")
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(trimmedMessage.isEmpty)
            }
        }
        .padding()
        .background(.bar)
    }
}

private struct AssistantThreadsView: View {
    @Bindable var store: FinanceStore
    @Bindable var voiceSession: VoiceSessionManager
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.assistantConversations) { conversation in
                    Button {
                        voiceSession.stop()
                        Task {
                            await store.selectAssistantConversation(conversation)
                            isPresented = false
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: conversation.id == store.selectedAssistantConversationID ? "checkmark.circle.fill" : "message")
                                .foregroundStyle(conversation.id == store.selectedAssistantConversationID ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.title)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                Text(threadSubtitle(conversation))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        let conversation = store.assistantConversations[index]
                        Task { await store.deleteAssistantConversation(conversation) }
                    }
                }
            }
            .navigationTitle("Conversations")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        voiceSession.stop()
                        Task {
                            await store.createNewAssistantConversation()
                            isPresented = false
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
        }
    }

    private func threadSubtitle(_ conversation: AssistantConversation) -> String {
        let messageCount = conversation.messages.count
        let formattedDate = conversation.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(messageCount) message\(messageCount == 1 ? "" : "s") · \(formattedDate)"
    }
}

struct ReceiptScannerView: View {
    @State private var showingScanner = false
    @State private var scannedPages = 0
    @State private var recognizedText = ""
    @State private var parsedItems: [ReceiptLineItemDraft] = []

    var body: some View {
        List {
            Section {
                Label("On-device receipt scanning", systemImage: "doc.viewfinder")
                    .font(.headline)
                Text("Scan a receipt with the iPhone document camera. Text is recognized on device and converted into editable receipt line items.")
                    .foregroundStyle(.secondary)
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan Receipt", systemImage: "camera.viewfinder")
                }
                if scannedPages > 0 {
                    Text("\(scannedPages) receipt page\(scannedPages == 1 ? "" : "s") scanned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Parsed line items") {
                if parsedItems.isEmpty {
                    Text(scannedPages == 0 ? "Scan a receipt to preview parsed items." : "No line items were confidently detected. You can still use the raw OCR text below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(parsedItems) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                            if !item.categoryName.isEmpty {
                                Text(item.categoryName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(AppDesign.money(item.amountCents))
                            .monospacedDigit()
                    }
                }
            }
            if !recognizedText.isEmpty {
                Section("Raw OCR") {
                    Text(recognizedText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Receipt")
        .sheet(isPresented: $showingScanner) {
            DocumentScannerView { result in
                scannedPages = result.pageCount
                recognizedText = result.recognizedText
                parsedItems = result.lineItems
                showingScanner = false
            }
        }
    }
}
