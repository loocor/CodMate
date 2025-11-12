import SwiftUI

struct GlobalSearchPanel: View {
  @ObservedObject var viewModel: GlobalSearchViewModel
  let maxWidth: CGFloat
  let onSelect: (GlobalSearchResult) -> Void
  let onClose: () -> Void
  var contentHeight: CGFloat? = nil

  var body: some View {
    GlobalSearchPanelContent(
      viewModel: viewModel,
      onSelect: onSelect,
      onClose: onClose,
      contentHeight: contentHeight,
      isFloating: true
    )
    .padding(16)
    .frame(maxWidth: maxWidth)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.2), radius: 22, x: 0, y: 18)
  }
}

struct GlobalSearchPopoverPanel: View {
  @ObservedObject var viewModel: GlobalSearchViewModel
  @Binding var size: CGSize
  let minSize: CGSize
  let maxSize: CGSize
  let onSelect: (GlobalSearchResult) -> Void
  let onClose: () -> Void

  var body: some View {
    GlobalSearchPanelContent(
      viewModel: viewModel,
      onSelect: onSelect,
      onClose: onClose,
      contentHeight: size.height,
      isFloating: false
    )
    .padding(16)
    .frame(width: size.width)
    .overlay(alignment: .topTrailing) {
      GlobalSearchSubmitProxy(viewModel: viewModel)
    }
    .overlay(alignment: .bottomLeading) {
      PopoverResizeHandle(
        size: $size,
        minSize: minSize,
        maxSize: maxSize,
        expandFromLeadingEdge: true
      )
    }
  }
}

private struct GlobalSearchPanelContent: View {
  @ObservedObject var viewModel: GlobalSearchViewModel
  let onSelect: (GlobalSearchResult) -> Void
  let onClose: () -> Void
  var contentHeight: CGFloat? = nil
  var isFloating: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      controls
      content
      progressRow
    }
  }

  private var header: some View {
    HStack {
      Spacer(minLength: 0)
      Picker("Scope", selection: $viewModel.filter) {
        ForEach(GlobalSearchFilter.allCases, id: \.self) { filter in
          Text(filter.title).tag(filter)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .controlSize(.large)
      .frame(minWidth: 320, maxWidth: 860)
      Spacer(minLength: 0)
    }
  }

  private var controls: some View {
    HStack {
      Spacer(minLength: 0)
      ToolbarSearchField(
        placeholder: "Type to search",
        text: $viewModel.query,
        onFocusChange: { viewModel.setFocus($0) },
        onSubmit: { viewModel.submit() },
        autofocus: viewModel.hasFocus,
        onCancel: onClose
      )
      .frame(minWidth: 320, maxWidth: 860, minHeight: 36)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private var progressRow: some View {
    if let progress = viewModel.ripgrepProgress {
      let summary =
        "\(progress.message) · Files: \(progress.filesProcessed) · Matches: \(progress.matchesFound)"
      HStack(spacing: 8) {
        if progress.isFinished {
          Image(systemName: progress.isCancelled ? "xmark.circle" : "checkmark.circle")
            .foregroundStyle(progress.isCancelled ? Color.red : Color.green)
        } else {
          ProgressView().controlSize(.small)
        }
        Text(summary)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
        if !progress.isFinished {
          Button("Cancel") {
            viewModel.cancelBackgroundSearch()
          }
          .buttonStyle(.bordered)
          .controlSize(.mini)
        }
      }
      .padding(.vertical, 2)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  @ViewBuilder
  private var content: some View {
    let isEmpty = viewModel.filteredResults.isEmpty
    if viewModel.isSearching && viewModel.filteredResults.isEmpty {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Searching…")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 8)
    } else {
      ScrollView(showsIndicators: true) {
        LazyVStack(spacing: 0) {
          let count = viewModel.filteredResults.count
          ForEach(Array(viewModel.filteredResults.enumerated()), id: \.1.id) { index, element in
            Button {
              onSelect(element)
            } label: {
              resultRow(element)
                .background(rowBackground(for: index, total: count))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
          }
        }
      }
      .frame(height: max(contentHeight ?? CGFloat(isEmpty ? 150 : 320), 150))
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        if isEmpty {
          VStack(spacing: 4) {
            Text("No matches yet")
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
            Text("Try another keyword or widen the scope.")
              .font(.system(size: 12))
              .foregroundStyle(.tertiary)
              .multilineTextAlignment(.center)
            if isFloating {
              Text("Press Esc to close")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }

  private func resultRow(_ result: GlobalSearchResult) -> some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack {
        Circle()
          .fill(Color.accentColor.opacity(0.15))
        Image(systemName: result.kind.symbolName)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(Color.accentColor)
      }
      .frame(width: 32, height: 32)

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline) {
          Text(result.displayTitle)
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
          Spacer()
          if let detail = result.detailLine {
            Text(detail)
              .font(.system(size: 11))
              .foregroundStyle(.tertiary)
          }
        }
        if let snippet = result.snippet {
          snippetText(snippet)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        } else if let note = result.note, let comment = note.comment, !comment.isEmpty {
          Text(clean(comment))
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        } else if let project = result.project, let overview = project.overview {
          Text(clean(overview))
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func rowBackground(for index: Int, total: Int) -> some View {
    let radius: CGFloat = 12
    let isFirst = index == 0
    let isLast = index == total - 1
    let color = Color.white.opacity(index.isMultiple(of: 2) ? 0.05 : 0.02)
    return UnevenRoundedRectangle(
      cornerRadii: RectangleCornerRadii(
        topLeading: isFirst ? radius : 0,
        bottomLeading: isLast ? radius : 0,
        bottomTrailing: isLast ? radius : 0,
        topTrailing: isFirst ? radius : 0
      ),
      style: .continuous
    )
    .fill(color)
  }

  private func snippetText(_ snippet: GlobalSearchSnippet) -> Text {
    let text = snippet.text
    guard let highlight = snippet.highlightRange else {
      return Text(text)
    }
    let lower = max(0, min(highlight.lowerBound, text.count))
    let upper = max(lower, min(highlight.upperBound, text.count))
    let startIdx = text.index(text.startIndex, offsetBy: lower)
    let midIdx = text.index(text.startIndex, offsetBy: upper)
    let prefix = String(text[..<startIdx])
    let match = String(text[startIdx..<midIdx])
    let suffix = String(text[midIdx...])
    return Text(prefix)
      .foregroundStyle(.secondary)
      + Text(match).foregroundStyle(Color.accentColor)
      + Text(suffix).foregroundStyle(.secondary)
  }

  private func clean(_ text: String) -> String {
    text.sanitizedSnippetText()
  }
}

private struct GlobalSearchSubmitProxy: View {
  @ObservedObject var viewModel: GlobalSearchViewModel

  var body: some View {
    Button(action: { viewModel.submit() }) {
      EmptyView()
    }
    .keyboardShortcut(.return, modifiers: [])
    .opacity(0)
    .frame(width: 0, height: 0)
    .allowsHitTesting(false)
  }
}

private struct PopoverResizeHandle: View {
  @Binding var size: CGSize
  let minSize: CGSize
  let maxSize: CGSize
  @State private var dragOrigin: CGSize?
  var expandFromLeadingEdge = false

  var body: some View {
    Image(systemName: iconName)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(.secondary)
      .padding(8)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let origin = dragOrigin ?? size
            if dragOrigin == nil { dragOrigin = size }
            let deltaWidth = expandFromLeadingEdge ? -value.translation.width : value.translation.width
            let proposed = CGSize(
              width: origin.width + deltaWidth,
              height: origin.height + value.translation.height
            )
            size = CGSize(
              width: clamp(proposed.width, min: minSize.width, max: maxSize.width),
              height: clamp(proposed.height, min: minSize.height, max: maxSize.height)
            )
          }
          .onEnded { _ in
            dragOrigin = nil
          }
      )
      .accessibilityLabel("Resize search popover")
  }

  private var iconName: String {
    expandFromLeadingEdge ? "arrow.up.right.and.arrow.down.left" : "arrow.up.left.and.arrow.down.right"
  }

  private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
    Swift.min(Swift.max(value, min), max)
  }
}
