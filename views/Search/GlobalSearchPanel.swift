import SwiftUI

struct GlobalSearchPanel: View {
  @ObservedObject var viewModel: GlobalSearchViewModel
  let maxWidth: CGFloat
  let onSelect: (GlobalSearchResult) -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      controls
      content
      progressRow
    }
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
    .overlay(alignment: .topTrailing) {
      Button(action: { viewModel.submit() }) {
        EmptyView()
      }
      .keyboardShortcut(.return, modifiers: [])
      .opacity(0)
      .frame(width: 0, height: 0)
      .allowsHitTesting(false)
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Text("Global Search")
        .font(.system(size: 14, weight: .semibold))
      Spacer()
    }
  }

  private var controls: some View {
    HStack(spacing: 12) {
      Picker("Scope", selection: $viewModel.filter) {
        ForEach(GlobalSearchFilter.allCases, id: \.self) { filter in
          Text(filter.title).tag(filter)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .controlSize(.large)
      .frame(minHeight: 36)
      Spacer(minLength: 8)
      ToolbarSearchField(
        placeholder: "Type to search",
        text: $viewModel.query,
        onFocusChange: { viewModel.setFocus($0) },
        onSubmit: { viewModel.submit() },
        autofocus: viewModel.hasFocus,
        onCancel: onClose
      )
      .frame(minWidth: 220, minHeight: 36)
    }
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
        Spacer()
        if !progress.isFinished {
          Button("Cancel") {
            viewModel.cancelBackgroundSearch()
          }
          .buttonStyle(.bordered)
          .controlSize(.mini)
        }
      }
      .padding(.vertical, 2)
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
      .frame(height: isEmpty ? 150 : 320)
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
