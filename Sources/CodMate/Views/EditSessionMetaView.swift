import SwiftUI

struct EditSessionMetaView: View {
    @ObservedObject var viewModel: SessionListViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit Session")
                    .font(.title3).bold()
                Spacer()
            }

            TextField("Name (optional)", text: $viewModel.editTitle)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 8) {
                Text("Comment (optional)").font(.subheadline)
                TextEditor(text: $viewModel.editComment)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
            }

            HStack {
                Button("Cancel") { viewModel.cancelEdits() }
                Spacer()
                Button("Save") { Task { await viewModel.saveEdits() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520)
    }
}

