import SwiftUI

/// View for editing session metadata (title and comment)
struct EditSessionMetaView: View {
    @ObservedObject var viewModel: SessionListViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Session Name", text: $viewModel.editTitle, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Custom Title")
                } footer: {
                    Text("Override the default session ID display name")
                }
                
                Section {
                    TextField("Notes", text: $viewModel.editComment, axis: .vertical)
                        .lineLimit(3...10)
                } header: {
                    Text("Comments")
                } footer: {
                    Text("Add notes or description for this session")
                }
                
                if let session = viewModel.editingSession {
                    Section("Session Info") {
                        LabeledContent("Session ID") {
                            Text(session.displayName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        
                        LabeledContent("Started") {
                            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        LabeledContent("Working Directory") {
                            Text(session.cwd)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelEdits()
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await viewModel.saveEdits()
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

#Preview {
    let preferences = SessionPreferencesStore()
    let viewModel = SessionListViewModel(preferences: preferences)
    
    // Set up a sample editing session
    Task {
        await viewModel.beginEditing(session: SessionSummary(
            id: "test-session-id",
            fileURL: URL(fileURLWithPath: "/tmp/test.jsonl"),
            fileSizeBytes: 1024,
            startedAt: Date(),
            endedAt: nil,
            cliVersion: "1.0.0",
            cwd: "/Users/test/project",
            originator: "test",
            instructions: "Test instructions",
            model: "gpt-4",
            approvalPolicy: nil,
            userMessageCount: 5,
            assistantMessageCount: 5,
            toolInvocationCount: 2,
            responseCounts: [:],
            turnContextCount: 10,
            eventCount: 15,
            lineCount: 100,
            lastUpdatedAt: Date()
        ))
    }
    
    return EditSessionMetaView(viewModel: viewModel)
}
