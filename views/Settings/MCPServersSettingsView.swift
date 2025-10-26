import SwiftUI
import UniformTypeIdentifiers
import AppKit

@available(macOS 15.0, *)
struct MCPServersSettingsPane: View {
    @StateObject private var vm = MCPServersViewModel()
    @State private var showImportConfirmation = false
    var openMCPMateDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("MCP Servers").font(.title2).fontWeight(.bold)
            Text("Add servers via Uni-Import, manage capabilities, or advanced integration with MCPMate.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            TabView(selection: $vm.activeTab) {
                Tab(value: MCPServersViewModel.Tab.importWizard) { mcpImportTab } label: {
                    Label("Import", systemImage: "tray.and.arrow.down")
                }

                Tab(value: MCPServersViewModel.Tab.servers) { mcpServersTab } label: {
                    Label("Servers", systemImage: "server.rack")
                }

                Tab(value: MCPServersViewModel.Tab.advanced) { mcpAdvancedTab } label: {
                    Label("Advanced", systemImage: "wand.and.stars")
                }
            }
            .tabViewStyle(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { Task { await vm.loadServers() } }
            .alert("Import Servers?", isPresented: $showImportConfirmation) {
                Button("Import", role: .none) {
                    Task { await vm.importDrafts() }
                }
                Button("Discard Drafts", role: .destructive) {
                    vm.clearImport()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Import \(vm.drafts.count) server(s) into CodMate?")
            }
        }
    }

    private var mcpImportTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uni-Import").font(.headline).fontWeight(.semibold)
            Text("Paste or drop JSON/TOML payloads to stage MCP servers before importing.")
                .font(.caption)
                .foregroundColor(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .foregroundStyle(.quaternary)
                    .frame(height: 120)
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down").font(.title3)
                    Text("Drop text files or snippets here")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onDrop(of: [UTType.json, UTType.plainText, UTType.fileURL], isTargeted: nil) { providers in
                handleImportProviders(providers)
            }

            HStack(spacing: 8) {
                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first(where: { !$0.isEmpty }) {
                        vm.loadText(text)
                    }
                }
                .buttonBorderShape(.roundedRectangle)
                .controlSize(.small)

                Button {
                    vm.clearImport()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.importText.isEmpty && vm.drafts.isEmpty && vm.importError == nil)
            }

            if vm.isParsing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Parsing input…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let err = vm.importError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.red)
            } else if !vm.drafts.isEmpty {
                Label("Detected \(vm.drafts.count) server(s). Review details below.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            TextEditor(text: Binding(get: { vm.importText }, set: { _ in }))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .disabled(true)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            if !vm.drafts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Detected: \(vm.drafts.count) server(s)").font(.subheadline).fontWeight(.medium)
                    ForEach(Array(vm.drafts.enumerated()), id: \.offset) { (_, draft) in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: draft.kind == .stdio ? "terminal" : (draft.kind == .sse ? "dot.radiowaves.left.and.right" : "globe"))
                                Text(draft.name ?? "(unnamed)")
                                    .font(.subheadline)
                                Spacer()
                            }
                            if let url = draft.url, !url.isEmpty {
                                Text(url)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if let description = draft.meta?.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Button(action: { showImportConfirmation = true }) {
                    Label("Import", systemImage: "tray.and.arrow.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isParsing)
            }
        }
        .padding(8)
    }

    private var mcpServersTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MCP Server List").font(.headline).fontWeight(.semibold)
            if vm.servers.isEmpty {
                Text("No servers installed. Use Import to add one.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                List {
                    ForEach(vm.servers) { s in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: s.kind == .stdio ? "terminal" : (s.kind == .sse ? "dot.radiowaves.left.and.right" : "globe"))
                                Text(s.name).font(.subheadline).fontWeight(.medium)
                                Spacer()
                                Toggle("Enabled", isOn: Binding(get: { s.enabled }, set: { v in Task { await vm.setServerEnabled(s, v) } }))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                            }
                            if let desc = s.meta?.description, !desc.isEmpty {
                                Text(desc).font(.caption).foregroundColor(.secondary)
                            }
                            HStack(spacing: 12) {
                                if let url = s.url, !url.isEmpty { Label(url, systemImage: "link").font(.caption).foregroundColor(.secondary) }
                                if let cmd = s.command, !cmd.isEmpty { Label(cmd, systemImage: "terminal").font(.caption).foregroundColor(.secondary) }
                            }
                            if !s.capabilities.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Capabilities").font(.caption).foregroundColor(.secondary)
                                    ForEach(s.capabilities) { cap in
                                        HStack {
                                            Text(cap.name).font(.caption)
                                            Spacer()
                                            Toggle("", isOn: Binding(get: { cap.enabled }, set: { v in Task { await vm.setCapabilityEnabled(s, cap, v) } }))
                                                .toggleStyle(.switch)
                                                .labelsHidden()
                                        }
                                    }
                                }
                            }
                            HStack {
                                Button(action: { Task { await vm.refreshCapabilities(for: s) } }) { Label("Refresh Capabilities", systemImage: "arrow.clockwise") }
                                    .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.inset)
                .controlSize(.small)
                .environment(\.defaultMinListRowHeight, 18)
                .frame(maxHeight: .infinity)
            }
        }
        .task { await vm.loadServers() }
        .padding(8)
    }

    private var mcpAdvancedTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image("MCPMateLogo")
                    .resizable()
                    .frame(width: 48, height: 48)
                    .cornerRadius(12)
                VStack(alignment: .leading, spacing: 0) {
                    Text("MCPMate").font(.headline)
                    Text("A 'Maybe All-in-One' MCP service manager for developers and creators.")
                        .font(.subheadline).fontWeight(.semibold)
                }
            }
            Text("MCPMate offers advanced MCP server management beyond CodMate's basic import and enable/disable controls.")
                .font(.body).foregroundColor(.secondary)
            Text("Download MCPMate to configure MCP servers alongside CodMate.")
                .font(.subheadline).foregroundColor(.secondary)
            Button(action: openMCPMateDownload) { Label("Download MCPMate", systemImage: "arrow.down.circle.fill").labelStyle(.titleAndIcon) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .font(.body.weight(.semibold))
        }
        .padding(8)
    }

    private func handleImportProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    guard let text = readText(from: data as? NSSecureCoding) else { return }
                    handled = true
                    DispatchQueue.main.async {
                        vm.loadText(text)
                    }
                }
                handled = true
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.json.identifier, options: nil) { data, _ in
                    guard let text = readText(from: data as? NSSecureCoding) else { return }
                    handled = true
                    DispatchQueue.main.async {
                        vm.loadText(text)
                    }
                }
                handled = true
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { data, _ in
                    guard let text = readText(from: data as? NSSecureCoding) else { return }
                    handled = true
                    DispatchQueue.main.async {
                        vm.loadText(text)
                    }
                }
                handled = true
                continue
            }
            if provider.canLoadObject(ofClass: String.self) {
                provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string = string else { return }
                    handled = true
                    DispatchQueue.main.async {
                        vm.loadText(string)
                    }
                }
                handled = true
            }
        }
        return handled
    }

    private func readText(from representation: NSSecureCoding?) -> String? {
        if let string = representation as? String { return string }
        if let url = representation as? URL {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        if let data = representation as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return try? String(contentsOf: url, encoding: .utf8)
            }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}
