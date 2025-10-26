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

                // Sessions diagnostics
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sessions Root").font(.headline).fontWeight(.semibold)
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

                // Providers diagnostics
                VStack(alignment: .leading, spacing: 10) {
                    Text("Providers").font(.headline).fontWeight(.semibold)
                    if let p = vm.providers {
                        settingsCard {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                Text("Config Path").font(.subheadline)
                                Text(p.configPath).font(.caption).frame(
                                    maxWidth: .infinity, alignment: .trailing)
                            }
                            GridRow {
                                Text("Providers Count").font(.subheadline)
                                Text("\(p.providers.count)").frame(
                                    maxWidth: .infinity, alignment: .trailing)
                            }
                            GridRow {
                                Text("Duplicate IDs").font(.subheadline)
                                let d = p.duplicateIDs
                                Text(d.isEmpty ? "(none)" : d.joined(separator: ", "))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            GridRow {
                                Text("Stray Bodies").font(.subheadline)
                                Text("\(p.strayManagedBodies)").frame(
                                    maxWidth: .infinity, alignment: .trailing)
                            }
                            }
                            HStack(spacing: 8) {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(p.canonicalRegion, forType: .string)
                                } label: {
                                    Label("Copy Canonical Region", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                                Button {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: p.configPath))
                                } label: {
                                    Label("Open config.toml", systemImage: "square.and.pencil")
                                }
                                .buttonStyle(.bordered)
                            }
                            ScrollView {
                                Text(
                                    p.canonicalRegion.isEmpty
                                        ? "(no providers configured)" : p.canonicalRegion
                                )
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8).fill(
                                        Color(nsColor: .textBackgroundColor))
                                )
                            }.frame(maxHeight: 220)
                        }
                    } else {
                        Text("No data yet. Click Run Diagnostics.").font(.caption).foregroundStyle(
                            .secondary)
                    }
                }

                // CLI diagnostics
                VStack(alignment: .leading, spacing: 10) {
                    Text("CLI & PATH").font(.headline).fontWeight(.semibold)
                    settingsCard {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Preferred").font(.subheadline)
                            Text(preferences.codexExecutableURL.path).font(.caption).frame(
                                maxWidth: .infinity, alignment: .trailing)
                        }
                        GridRow {
                            Text("Resolved").font(.subheadline)
                            Text(vm.resolvedCodexPath ?? "(not found)").font(.caption).frame(
                                maxWidth: .infinity, alignment: .trailing)
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
