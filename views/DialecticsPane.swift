import SwiftUI
import AppKit

@available(macOS 15.0, *)
struct DialecticsPane: View {
    @ObservedObject var preferences: SessionPreferencesStore
    @StateObject private var vm = DialecticsVM()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Dialectics")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Deep diagnostics for sessions, providers, and environment")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { await vm.runAll(preferences: preferences) }
                    } label: {
                        Label("Run Diagnostics", systemImage: "stethoscope")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        vm.saveReport(preferences: preferences)
                    } label: {
                        Label("Save Report…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }

                // App & OS
                VStack(alignment: .leading, spacing: 10) {
                    Text("Environment").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("App Version").font(.subheadline)
                            Text(vm.appVersion).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("Build Time").font(.subheadline)
                            Text(vm.buildTime).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("macOS").font(.subheadline)
                            Text(vm.osVersion).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        }
                    }
                }

                // Codex sessions diagnostics
                VStack(alignment: .leading, spacing: 10) {
                    Text("Codex Sessions Root").font(.headline).fontWeight(.semibold)
                    if let s = vm.sessions {
                        settingsCard {
                            DiagnosticsReportView(result: s)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        Text("No data yet. Click Run Diagnostics.").font(.caption).foregroundStyle(
                            .secondary)
                    }
                }

                // Claude sessions diagnostics (moved above Notes)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Claude Sessions Directory").font(.headline).fontWeight(.semibold)
                    if let s = vm.sessions {
                        settingsCard {
                            if let cc = s.claudeCurrent {
                                DataPairReportView(current: cc, defaultProbe: s.claudeDefault)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            } else {
                                DataPairReportView(current: s.claudeDefault, defaultProbe: s.claudeDefault)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    } else {
                        Text("No data yet. Click Run Diagnostics.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Notes diagnostics
                VStack(alignment: .leading, spacing: 10) {
                    Text("Notes Directory").font(.headline).fontWeight(.semibold)
                    if let s = vm.sessions {
                        settingsCard {
                            DataPairReportView(current: s.notesCurrent, defaultProbe: s.notesDefault)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        Text("No data yet. Click Run Diagnostics.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                // Projects diagnostics
                VStack(alignment: .leading, spacing: 10) {
                    Text("Projects Directory").font(.headline).fontWeight(.semibold)
                    if let s = vm.sessions {
                        settingsCard {
                            DataPairReportView(current: s.projectsCurrent, defaultProbe: s.projectsDefault)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        Text("No data yet. Click Run Diagnostics.").font(.caption).foregroundStyle(.secondary)
                    }
                }


                // CLI diagnostics
                VStack(alignment: .leading, spacing: 10) {
                    Text("CLI & PATH").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("codex on PATH").font(.subheadline)
                            Text(vm.codexPresent ? (vm.codexVersion ?? "Yes") : "N/A")
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("claude on PATH").font(.subheadline)
                            Text(vm.claudePresent ? (vm.claudeVersion ?? "Yes") : "N/A")
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("PATH").font(.subheadline)
                            Text(vm.pathEnv).font(.caption).lineLimit(2).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        }
                    }
                }
            }
            .task { await vm.runAll(preferences: preferences) }
    }

    // Helper function to create settings card
    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(10)
        .background(Color(nsColor: .separatorColor).opacity(0.35))
        .cornerRadius(10)
    }
}
