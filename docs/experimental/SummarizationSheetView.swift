import SwiftUI

struct SummarizationSheetView: View {
    @ObservedObject var viewModel: SessionListViewModel
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("Generate Title & Summary")
                    .font(.headline)
                
                Spacer()
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top)
            
            // Session name
            if let session = viewModel.summarizationSession {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Session:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(session.readableTitle)
                        .font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
            
            Divider()
            
            // Progress section
            VStack(spacing: 16) {
                // Stage label
                Text(viewModel.summarizationStage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                // Progress bar
                ProgressView(value: viewModel.summarizationProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 400)
                
                // Error message
                if let error = viewModel.summarizationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                // Results
                if let title = viewModel.summarizationResultTitle,
                   let summary = viewModel.summarizationResultSummary {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Generated Title:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(title)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Generated Summary:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(summary)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }
                    .padding()
                    .background(.quaternary.opacity(0.5))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
            
            Spacer()
            
            // Dismiss button
            Button("Done") {
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
            .padding(.bottom)
        }
        .frame(width: 500, height: 400)
    }
}

