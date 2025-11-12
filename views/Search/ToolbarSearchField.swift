import SwiftUI

#if os(macOS)
import AppKit

struct ToolbarSearchField: NSViewRepresentable {
  let placeholder: String
  @Binding var text: String
  var onFocusChange: (Bool) -> Void
  var onSubmit: () -> Void
  var autofocus: Bool = false
  var onCancel: (() -> Void)? = nil

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField(frame: .zero)
    field.placeholderString = placeholder
    field.delegate = context.coordinator
    field.focusRingType = .none
    field.sendsSearchStringImmediately = false
    field.sendsWholeSearchString = true
    field.cell?.usesSingleLineMode = true
    field.translatesAutoresizingMaskIntoConstraints = false
    field.bezelStyle = .roundedBezel
    if autofocus {
      DispatchQueue.main.async {
        if field.window?.firstResponder !== field {
          field.window?.makeFirstResponder(field)
        }
      }
    }
    return field
  }

  func updateNSView(_ nsView: NSSearchField, context: Context) {
    let editor = nsView.currentEditor()
    let window = nsView.window
    let isFirstResponder = {
      guard let window else { return false }
      if let editor { return window.firstResponder === editor }
      return window.firstResponder === nsView
    }()

    if !isFirstResponder, nsView.stringValue != text {
      nsView.stringValue = text
    }
    if nsView.placeholderString != placeholder {
      nsView.placeholderString = placeholder
    }

    let shouldAutofocus = autofocus

    if shouldAutofocus && !isFirstResponder {
      // Robust focusing for popover presentation: try now and re-try shortly after
      DispatchQueue.main.async { [weak nsView] in
        guard shouldAutofocus, let nsView, let window = nsView.window else { return }
        if let editor = nsView.currentEditor(), window.firstResponder === editor { return }
        window.makeFirstResponder(nsView)

        // Re-try after the popover finishes becoming key to avoid focus races
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak nsView] in
          guard shouldAutofocus, let nsView = nsView, let window = nsView.window else { return }
          let editor = nsView.currentEditor()
          let isFocused = (editor != nil && window.firstResponder === editor) || window.firstResponder === nsView
          if !isFocused { window.makeFirstResponder(nsView) }
        }
        // Final retry for stubborn focus contention
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak nsView] in
          guard shouldAutofocus, let nsView = nsView, let window = nsView.window else { return }
          let editor = nsView.currentEditor()
          let isFocused = (editor != nil && window.firstResponder === editor) || window.firstResponder === nsView
          if !isFocused { window.makeFirstResponder(nsView) }
        }
      }
    }
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    let parent: ToolbarSearchField

    init(_ parent: ToolbarSearchField) {
      self.parent = parent
    }

    @MainActor
    func controlTextDidBeginEditing(_ obj: Notification) {
      parent.onFocusChange(true)
    }

    @MainActor
    func controlTextDidEndEditing(_ obj: Notification) {
      parent.onFocusChange(false)
    }

    @MainActor
    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSSearchField else { return }
      if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
      parent.text = field.stringValue
    }

    @MainActor
    func searchFieldDidEndSearching(_ sender: NSSearchField) {
      parent.text = sender.stringValue
      parent.onFocusChange(false)
    }

    @MainActor
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      switch commandSelector {
      case #selector(NSResponder.insertNewline(_:)):
        parent.onSubmit()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        let wasEmpty = parent.text.isEmpty
        parent.text = ""
        parent.onFocusChange(false)
        if wasEmpty { parent.onCancel?() }
        return true
      default:
        return false
      }
    }
  }
}
#endif
