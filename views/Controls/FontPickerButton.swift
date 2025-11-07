import SwiftUI
import AppKit

struct FontPickerButton: View {
    @Binding var fontName: String
    @Binding var fontSize: Double

    @StateObject private var controller = FontPanelController()

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(displayLabel)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: openFontPanel) {
                Image(systemName: "textformat.size")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Choose terminal font and size")
        }
    }

    private func openFontPanel() {
        controller.present(currentFont: resolvedFont) { newFont in
            fontName = newFont.fontName
            fontSize = Double(newFont.pointSize)
        }
    }

    private var resolvedFont: NSFont {
        TerminalFontResolver.resolvedFont(name: fontName, size: CGFloat(fontSize))
    }

    private var displayLabel: String {
        let name = resolvedFont.displayName ?? resolvedFont.fontName
        return String(format: "%@ – %.1f pt", name, fontSize)
    }
}

private final class FontPanelController: NSObject, ObservableObject {
    private var onChange: ((NSFont) -> Void)?
    private var currentFont: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func present(currentFont: NSFont, onChange: @escaping (NSFont) -> Void) {
        self.currentFont = currentFont
        self.onChange = onChange
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(currentFont, isMultiple: false)
        manager.orderFrontFontPanel(self)
        manager.fontPanel(true)?.makeKeyAndOrderFront(self)
    }

    @objc private func changeFont(_ sender: NSFontManager) {
        let converted = sender.convert(currentFont)
        currentFont = converted
        onChange?(converted)
    }
}
