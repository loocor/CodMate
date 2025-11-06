import SwiftUI

struct SandboxPermissionsView: View {
    @ObservedObject var manager = SandboxPermissionsManager.shared
    @State private var isRequesting = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Folder Access Permissions")
                .font(.title)
                .padding(.top)
            
            if !manager.needsAuthorization {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("All permissions granted")
                        .font(.headline)
                    Text("CodMate has access to all required directories.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("CodMate needs access to the following directories:")
                        .font(.headline)
                    
                    Text("Due to App Sandbox security, you must explicitly grant access to these folders. Your data never leaves your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Divider()
                    
                    ForEach(manager.missingPermissions) { directory in
                        PermissionRow(
                            directory: directory,
                            hasPermission: manager.hasPermission(for: directory),
                            onRequest: {
                                isRequesting = true
                                Task {
                                    _ = await manager.requestPermission(for: directory)
                                    isRequesting = false
                                }
                            }
                        )
                    }
                    
                    Divider()
                    
                    if !manager.missingPermissions.isEmpty {
                        Button {
                            isRequesting = true
                            Task {
                                _ = await manager.requestAllMissingPermissions()
                                isRequesting = false
                            }
                        } label: {
                            HStack {
                                if isRequesting {
                                    ProgressView()
                                        .controlSize(.small)
                                        .padding(.trailing, 4)
                                }
                                Text("Grant All Permissions")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isRequesting)
                    }
                }
                .padding()
            }
            
            Spacer()
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            manager.checkPermissions()
        }
    }
}

private struct PermissionRow: View {
    let directory: SandboxPermissionsManager.RequiredDirectory
    let hasPermission: Bool
    let onRequest: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(directory.displayName)
                        .font(.headline)
                    if hasPermission {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Text(directory.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(directory.rawValue)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            
            Spacer()
            
            if !hasPermission {
                Button("Grant Access") {
                    onRequest()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    SandboxPermissionsView()
}
