import SwiftUI

struct SandboxApprovalEditor: View {
    @Binding var sandbox: SandboxMode
    @Binding var approval: ApprovalPolicy
    @Binding var fullAuto: Bool
    @Binding var dangerouslyBypass: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Sandbox").font(.subheadline)
                Picker("", selection: $sandbox) {
                    ForEach(SandboxMode.allCases) { s in Text(s.title).tag(s) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 360)
            }
            GridRow {
                Text("Approval").font(.subheadline)
                Picker("", selection: $approval) {
                    ForEach(ApprovalPolicy.allCases) { a in Text(a.title).tag(a) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 360)
            }
            GridRow {
                Text("Presets").font(.subheadline)
                HStack(spacing: 12) {
                    Toggle("Full Auto", isOn: $fullAuto)
                    Toggle("Danger Bypass", isOn: $dangerouslyBypass)
                }
            }
        }
    }
}

