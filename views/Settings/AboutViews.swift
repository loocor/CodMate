import SwiftUI
import AppKit

@available(macOS 15.0, *)
struct OpenSourceLicensesView: View {
    let repoURL: URL
    @State private var content: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Open Source Licenses")
                    .font(.title3).fontWeight(.semibold)
                Spacer()
                Button("Open on GitHub") { openOnGitHub() }
            }
            .padding(.bottom, 4)

            if content.isEmpty {
                ProgressView()
                    .task { await loadContent() }
            } else {
                ScrollView {
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func openOnGitHub() {
        // Point to the file in the default branch
        let url = URL(string: repoURL.absoluteString + "/blob/main/THIRD-PARTY-NOTICES.md")!
        NSWorkspace.shared.open(url)
    }

    private func candidateLocalURLs() -> [URL] {
        var urls: [URL] = []
        if let bundled = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md") {
            urls.append(bundled)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(cwd.appendingPathComponent("THIRD-PARTY-NOTICES.md"))
        // When running from Xcode/DerivedData, try a few parents
        let execDir = Bundle.main.bundleURL
        urls.append(execDir.appendingPathComponent("Contents/Resources/THIRD-PARTY-NOTICES.md"))
        return urls
    }

    private func loadContent() async {
        for url in candidateLocalURLs() {
            if FileManager.default.fileExists(atPath: url.path),
                let data = try? Data(contentsOf: url),
                let text = String(data: data, encoding: .utf8)
            {
                await MainActor.run { self.content = text }
                return
            }
        }
        // Fallback to remote raw file on GitHub if local not found
        if let remote = URL(
            string: "https://raw.githubusercontent.com/loocor/CodMate/main/THIRD-PARTY-NOTICES.md")
        {
            do {
                let (data, _) = try await URLSession.shared.data(from: remote)
                if let text = String(data: data, encoding: .utf8) {
                    await MainActor.run { self.content = text }
                }
            } catch {
                await MainActor.run {
                    self.content =
                        "Unable to load licenses. Please see THIRD-PARTY-NOTICES.md in the repository."
                }
            }
        }
    }
}
