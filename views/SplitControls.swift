import AppKit
import SwiftUI

// Shared split primary button used across detail toolbar and list empty state
struct SplitPrimaryMenuButton: View {
  let title: String
  let systemImage: String
  let primary: () -> Void
  let items: [SplitMenuItem]

  var body: some View {
    let h: CGFloat = 24
    HStack(spacing: 0) {
      Button(action: primary) {
        Label(title, systemImage: systemImage)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.primary)
          .padding(.horizontal, 12)
          .frame(height: h)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Rectangle()
        .fill(Color.secondary.opacity(0.25))
        .frame(width: 1, height: h - 8)
        .padding(.vertical, 4)

      ChevronMenuButton(items: items)
        .frame(width: h, height: h)
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
    )
  }
}

struct SplitMenuItem: Identifiable {
  enum Kind {
    case action(title: String, disabled: Bool = false, _ run: () -> Void)
    case separator
    case submenu(title: String, items: [SplitMenuItem])
  }
  let id = UUID()
  let kind: Kind
}

struct ChevronMenuButton: NSViewRepresentable {
  let items: [SplitMenuItem]

  func makeCoordinator() -> Coordinator { Coordinator(items: items) }

  func makeNSView(context: Context) -> NSButton {
    let btn = NSButton(
      title: "", target: context.coordinator, action: #selector(Coordinator.openMenu(_:)))
    btn.isBordered = false
    btn.bezelStyle = .regularSquare
    if let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
      btn.image = img
    }
    btn.translatesAutoresizingMaskIntoConstraints = false
    return btn
  }

  func updateNSView(_ nsView: NSButton, context: Context) {
    context.coordinator.items = items
  }

  final class Coordinator: NSObject {
    var items: [SplitMenuItem]
    private var runs: [() -> Void] = []
    init(items: [SplitMenuItem]) { self.items = items }

    @objc func openMenu(_ sender: NSButton) {
      let menu = NSMenu()
      runs.removeAll(keepingCapacity: true)
      func build(_ items: [SplitMenuItem], into menu: NSMenu) {
        for item in items {
          switch item.kind {
          case .separator:
            menu.addItem(.separator())
          case .action(let title, let disabled, let run):
            let mi = NSMenuItem(
              title: title, action: #selector(Coordinator.fire(_:)), keyEquivalent: "")
            mi.tag = runs.count
            mi.target = self
            mi.isEnabled = !disabled
            menu.addItem(mi)
            runs.append(run)
          case .submenu(let title, let children):
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            build(children, into: sub)
            mi.submenu = sub
            menu.addItem(mi)
          }
        }
      }
      build(items, into: menu)
      let location = NSPoint(x: sender.bounds.midX, y: sender.bounds.maxY - 3)
      menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc func fire(_ sender: NSMenuItem) {
      let idx = sender.tag
      guard idx >= 0 && idx < runs.count else { return }
      runs[idx]()
    }
  }
}
