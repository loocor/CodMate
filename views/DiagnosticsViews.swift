import SwiftUI
import AppKit

@available(macOS 15.0, *)
struct DiagnosticsSection: View {
    @ObservedObject var preferences: SessionPreferencesStore
    @State private var running = false
    @State private var lastResult: SessionsDiagnostics? = nil
    @State private var lastError: String? = nil
    private let service = SessionsDiagnosticsService()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics")
                .font(.headline)
                .foregroundColor(.primary)

            HStack(spacing: 8) {
                Button(action: runDiagnostics) {
                    if running { ProgressView().controlSize(.small) }
                    Text(running ? "Diagnosing…" : "Diagnose Sessions Directory")
                }
                .disabled(running)

                if let result = lastResult,
                    result.current.enumeratedJsonlCount == 0,
                    result.defaultRoot.enumeratedJsonlCount > 0,
                    preferences.sessionsRoot.path != result.defaultRoot.path
                {
                    Button("Switch to Default Path") {
                        preferences.sessionsRoot = URL(
                            fileURLWithPath: result.defaultRoot.path, isDirectory: true)
                    }
                }

                if lastResult != nil {
                    Button("Save Report…", action: saveReport)
                }
            }

            if let error = lastError { Text(error).foregroundStyle(.red).font(.caption) }

            if let result = lastResult {
                DiagnosticsReportView(result: result)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    )
            }
        }
    }

    private func runDiagnostics() {
        running = true
        lastError = nil
        lastResult = nil
        let current = preferences.sessionsRoot
        let home = FileManager.default.homeDirectoryForCurrentUser
        let def = SessionPreferencesStore.defaultSessionsRoot(for: home)
        Task {
            let res = await service.run(currentRoot: current, defaultRoot: def)
            await MainActor.run {
                self.lastResult = res
                self.running = false
            }
        }
    }

    private func saveReport() {
        guard let result = lastResult else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(result)
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd-HHmmss"
            let ts = df.string(from: result.timestamp)
            panel.nameFieldStringValue = "CodMate-Sessions-Diagnostics-\(ts).json"
            panel.begin { resp in
                if resp == .OK, let url = panel.url {
                    do { try data.write(to: url, options: .atomic) } catch {
                        self.lastError = "Failed to save report: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            self.lastError = "Failed to prepare report: \(error.localizedDescription)"
        }
    }
}

@available(macOS 15.0, *)
struct DiagnosticsReportView: View {
    let result: SessionsDiagnostics
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timestamp: \(formatDate(result.timestamp))").font(.caption)
            let same = result.current.path == result.defaultRoot.path
            Group {
                Text(same ? "Sessions Root (= Default)" : "Current Root")
                    .font(.subheadline).bold()
                DiagnosticsProbeView(p: result.current)
            }
            if !same {
                Group {
                    Text("Default Root").font(.subheadline).bold().padding(.top, 4)
                    DiagnosticsProbeView(p: result.defaultRoot)
                }
            }

            if !result.suggestions.isEmpty {
                Text("Suggestions").font(.subheadline).bold().padding(.top, 4)
                ForEach(result.suggestions, id: \.self) { s in
                    Text("• \(s)").font(.caption)
                }
            }
        }
    }

    private func formatDate(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df.string(from: d)
    }
}

@available(macOS 15.0, *)
struct DiagnosticsProbeView: View {
    let p: SessionsDiagnostics.Probe
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Path: \(p.path)").font(.caption)
            Text("Exists: \(p.exists ? "yes" : "no")").font(.caption)
            Text("Directory: \(p.isDirectory ? "yes" : "no")").font(.caption)
            Text(".jsonl files: \(p.enumeratedJsonlCount)").font(.caption)
            if !p.sampleFiles.isEmpty {
                Text("Samples:").font(.caption)
                ForEach(p.sampleFiles.prefix(5), id: \.self) { s in
                    Text("• \(s)").font(.caption2)
                }
                if p.sampleFiles.count > 5 {
                    Text("(\(p.sampleFiles.count - 5) more…)").font(.caption2).foregroundStyle(
                        .secondary)
                }
            }
            if let err = p.enumeratorError {
                Text("Enumerator Error: \(err)").font(.caption).foregroundStyle(.red)
            }
        }
    }
}
