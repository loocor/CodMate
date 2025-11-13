import AppKit
import SwiftUI

extension ContentView {
  // Sticky detail action bar at the top of the detail column
  var detailActionBar: some View {
    HStack(spacing: 12) {
      // Left: view mode segmented (Timeline | Git Review | Terminal)
      Group {
        #if canImport(SwiftTerm) && !APPSTORE
          let items: [SegmentedIconPicker<ContentView.DetailTab>.Item] = [
            .init(title: "Timeline", systemImage: "clock", tag: .timeline),
            .init(title: "Terminal", systemImage: "terminal", tag: .terminal),
          ]
          let selection = Binding<ContentView.DetailTab>(
            get: { selectedDetailTab },
            set: { newValue in
              if newValue == .terminal {
                if hasAvailableEmbeddedTerminal() {
                  if let focused = focusedSummary, runningSessionIDs.contains(focused.id) {
                    selectedTerminalKey = focused.id
                  } else if let anchorId = fallbackRunningAnchorId() {
                    selectedTerminalKey = anchorId
                  } else {
                    selectedTerminalKey = runningSessionIDs.first
                  }
                  selectedDetailTab = .terminal
                } else if let focused = focusedSummary {
                  pendingTerminalLaunch = PendingTerminalLaunch(session: focused)
                }
              } else {
                selectedDetailTab = newValue
              }
            }
          )
          SegmentedIconPicker(items: items, selection: selection)
        #else
          let items: [SegmentedIconPicker<ContentView.DetailTab>.Item] = [
            .init(title: "Timeline", systemImage: "clock", tag: .timeline)
          ]
          SegmentedIconPicker(items: items, selection: $selectedDetailTab)
        #endif
      }

      Spacer(minLength: 12)

      // Right: New…, Resume…, Reveal, Prompts, Export/Return, Max
      if let focused = focusedSummary {
        // New split control: hidden in Terminal tab
        if selectedDetailTab != .terminal {
          let embeddedPreferredNew =
            viewModel.preferences.defaultResumeUseEmbeddedTerminal && !AppSandbox.isEnabled
          SplitPrimaryMenuButton(
            title: "New",
            systemImage: "plus",
            primary: {
              if embeddedPreferredNew {
                startEmbeddedNew(for: focused)
              } else {
                // default: external terminal flow
                startNewSession(for: focused)
              }
            },
            items: {
              var items: [SplitMenuItem] = []
              // Grouped flat menu
              // Upper group: current provider quick targets
              let currentSrc = focused.source
              let currentKind = currentSrc.projectSource
              let currentName = currentSrc.branding.displayName
              items.append(
                .init(
                  kind: .action(title: "\(currentName) with Terminal") {
                    launchNewSession(for: focused, using: currentSrc, style: .terminal)
                  }))
              items.append(
                .init(
                  kind: .action(title: "\(currentName) with iTerm2") {
                    launchNewSession(for: focused, using: currentSrc, style: .iterm)
                  }))
              items.append(
                .init(
                  kind: .action(title: "\(currentName) with Warp") {
                    launchNewSession(for: focused, using: currentSrc, style: .warp)
                  }))

              // Add remote options for current provider
              let enabledRemoteHosts = viewModel.preferences.enabledRemoteHosts
              if !enabledRemoteHosts.isEmpty {
                items.append(.init(kind: .separator))
                for host in enabledRemoteHosts.sorted() {
                  let remoteSrc: SessionSource
                  if currentKind == .codex {
                    remoteSrc = .codexRemote(host: host)
                  } else {
                    remoteSrc = .claudeRemote(host: host)
                  }
                  let remoteName = remoteSrc.branding.displayName
                  items.append(
                    .init(
                      kind: .action(title: "\(remoteName) with Terminal") {
                        launchNewSession(for: focused, using: remoteSrc, style: .terminal)
                      }))
                  items.append(
                    .init(
                      kind: .action(title: "\(remoteName) with iTerm2") {
                        launchNewSession(for: focused, using: remoteSrc, style: .iterm)
                      }))
                  items.append(
                    .init(
                      kind: .action(title: "\(remoteName) with Warp") {
                        launchNewSession(for: focused, using: remoteSrc, style: .warp)
                      }))
                }
              }

              // Divider
              items.append(.init(kind: .separator))
              // Lower group: alternate provider quick targets
              let allowed = viewModel.allowedSources(for: focused)
              // Compute alternate src from allowed set; fallback to opposite of current
              let altSrc: SessionSource? = {
                let desiredKind: ProjectSessionSource = (currentKind == .codex) ? .claude : .codex
                if allowed.contains(desiredKind) {
                  return desiredKind.sessionSource
                }
                if let otherKind = allowed.first(where: { $0 != currentKind }) {
                  return otherKind.sessionSource
                }
                return desiredKind.sessionSource
              }()
              if let alt = altSrc {
                let altName = alt.branding.displayName
                items.append(
                  .init(
                    kind: .action(title: "\(altName) with Terminal") {
                      launchNewSession(for: focused, using: alt, style: .terminal)
                    }))
                items.append(
                  .init(
                    kind: .action(title: "\(altName) with iTerm2") {
                      launchNewSession(for: focused, using: alt, style: .iterm)
                    }))
                items.append(
                  .init(
                    kind: .action(title: "\(altName) with Warp") {
                      launchNewSession(for: focused, using: alt, style: .warp)
                    }))

                // Add remote options for alternate provider
                if !enabledRemoteHosts.isEmpty {
                  items.append(.init(kind: .separator))
                  for host in enabledRemoteHosts.sorted() {
                    let remoteSrc: SessionSource
                    if alt.projectSource == .codex {
                      remoteSrc = .codexRemote(host: host)
                    } else {
                      remoteSrc = .claudeRemote(host: host)
                    }
                    let remoteName = remoteSrc.branding.displayName
                    items.append(
                      .init(
                        kind: .action(title: "\(remoteName) with Terminal") {
                          launchNewSession(for: focused, using: remoteSrc, style: .terminal)
                        }))
                    items.append(
                      .init(
                        kind: .action(title: "\(remoteName) with iTerm2") {
                          launchNewSession(for: focused, using: remoteSrc, style: .iterm)
                        }))
                    items.append(
                      .init(
                        kind: .action(title: "\(remoteName) with Warp") {
                          launchNewSession(for: focused, using: remoteSrc, style: .warp)
                        }))
                  }
                }
              }
              // Third group: New With Context…
              items.append(.init(kind: .separator))
              items.append(
                .init(
                  kind: .action(title: "New With Context…") {
                    showNewWithContext = true
                  }))
              return items
            }()
          )
        }

        // Resume split control: hidden in Terminal tab
        if selectedDetailTab != .terminal {
          let defaultApp = viewModel.preferences.defaultResumeExternalApp
          let embeddedPreferred =
            viewModel.preferences.defaultResumeUseEmbeddedTerminal && !AppSandbox.isEnabled
          SplitPrimaryMenuButton(
            title: "Resume",
            systemImage: "play.fill",
            primary: {
              if embeddedPreferred {
                startEmbedded(for: focused)
              } else {
                openPreferredExternal(for: focused)
              }
            },
            items: {
              var items: [SplitMenuItem] = []
              let baseApps: [TerminalApp] = [.terminal, .iterm2, .warp]
              let apps = embeddedPreferred ? baseApps : baseApps.filter { $0 != defaultApp }
              for app in apps {
                switch app {
                case .terminal:
                  items.append(
                    .init(
                      kind: .action(title: "Terminal") {
                        launchResume(for: focused, using: focused.source, style: .terminal)
                      }))
                case .iterm2:
                  items.append(
                    .init(
                      kind: .action(title: "iTerm2") {
                        launchResume(for: focused, using: focused.source, style: .iterm)
                      }))
                case .warp:
                  items.append(
                    .init(
                      kind: .action(title: "Warp") {
                        launchResume(for: focused, using: focused.source, style: .warp)
                      }))
                default:
                  break
                }
              }
              let enabledRemoteHosts = viewModel.preferences.enabledRemoteHosts
              if !enabledRemoteHosts.isEmpty {
                items.append(.init(kind: .separator))
                let currentKind = focused.source.projectSource
                for host in enabledRemoteHosts.sorted() {
                  let remoteSrc: SessionSource =
                    (currentKind == .codex)
                    ? .codexRemote(host: host)
                    : .claudeRemote(host: host)
                  let remoteName = remoteSrc.branding.displayName
                  items.append(
                    .init(
                      kind: .action(title: "\(remoteName) with Terminal") {
                        launchResume(for: focused, using: remoteSrc, style: .terminal)
                      }))
                  items.append(
                    .init(
                      kind: .action(title: "\(remoteName) with iTerm2") {
                        launchResume(for: focused, using: remoteSrc, style: .iterm)
                      }))
                  items.append(
                    .init(
                      kind: .action(title: "\(remoteName) with Warp") {
                        launchResume(for: focused, using: remoteSrc, style: .warp)
                      }))
                }
              }
              if !embeddedPreferred && viewModel.preferences.defaultResumeUseEmbeddedTerminal
                && !AppSandbox.isEnabled
              {
                items.append(.init(kind: .separator))
                items.append(
                  .init(
                    kind: .action(title: "Embedded") {
                      launchResume(for: focused, using: focused.source, style: .embedded)
                    }))
              }
              return items
            }()
          )
        }

        // Reveal in Finder (chromed icon)
        ChromedIconButton(systemImage: "macwindow", help: "Reveal in Finder") {
          viewModel.reveal(session: focused)
        }

        // Prompts (only when embedded terminal is running)
        if runningSessionIDs.contains(focused.id) {
          ChromedIconButton(systemImage: "text.insert", help: "Prompts") {
            showPromptPicker.toggle()
          }
          .popover(isPresented: $showPromptPicker) {
            PromptsPopover(
              workingDirectory: workingDirectory(for: focused),
              terminalKey: focused.id,
              builtin: builtinPrompts(),
              query: $promptQuery,
              loaded: $loadedPrompts,
              hovered: $hoveredPromptKey,
              pendingDelete: $pendingDelete,
              onDismiss: { showPromptPicker = false }
            )
          }
        }

        // Export Markdown or Return to History
        if selectedDetailTab != .terminal {
          ChromedIconButton(
            systemImage: "square.and.arrow.up", help: "Export conversation as Markdown"
          ) {
            exportMarkdownForFocused()
          }
        } else {
          ChromedIconButton(systemImage: "arrow.uturn.backward", help: "Return to History") {
            // Close the terminal currently displayed in the Terminal tab.
            // In Terminal tab, we always show focused.id's terminal (see ContentView+MainDetail.swift:30-32),
            // so we must close focused.id to ensure we close what the user sees.
            // Previously used activeTerminalKey() which could point to a different session during fast switches.
            let id = focused.id
            softReturnPending = true
            requestStopEmbedded(forID: id)
          }
        }
      }

    }
  }
}

// MARK: - SegmentedIconPicker (AppKit-backed)
struct SegmentedIconPicker<Selection: Hashable>: NSViewRepresentable {
  struct Item {
    let title: String
    let systemImage: String
    let tag: Selection
    let isEnabled: Bool

    init(title: String, systemImage: String, tag: Selection, isEnabled: Bool = true) {
      self.title = title
      self.systemImage = systemImage
      self.tag = tag
      self.isEnabled = isEnabled
    }
  }

  let items: [Item]
  @Binding var selection: Selection
  var isInteractive: Bool = true
  var iconScale: CGFloat = 1

  func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection, items: items, iconScale: iconScale)
  }

  func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl()
    control.translatesAutoresizingMaskIntoConstraints = true
    control.segmentStyle = .automatic
    control.controlSize = .regular
    control.trackingMode = .selectOne
    control.target = context.coordinator
    control.action = #selector(Coordinator.changed(_:))
    control.setContentHuggingPriority(.required, for: .horizontal)
    control.setContentCompressionResistancePriority(.required, for: .horizontal)
    rebuild(control)
    context.coordinator.control = control
    context.coordinator.isInteractive = isInteractive
    return control
  }

  func updateNSView(_ control: NSSegmentedControl, context: Context) {
    // Update coordinator's items to ensure it has the latest data
    context.coordinator.items = items
    context.coordinator.iconScale = iconScale

    if control.segmentCount != items.count { rebuild(control) }
    for (i, it) in items.enumerated() {
      control.setLabel(it.title, forSegment: i)
      if let img = NSImage(systemSymbolName: it.systemImage, accessibilityDescription: nil) {
        // Use template mode to allow proper tinting in selected state
        img.isTemplate = true

        // Apply icon scaling
        let scaledImg = scaleImage(img, scale: iconScale)
        control.setImage(scaledImg, forSegment: i)
        control.setImageScaling(.scaleNone, forSegment: i)
      }
      control.setEnabled(it.isEnabled, forSegment: i)
    }
    if let idx = items.firstIndex(where: { $0.tag == selection }) {
      control.selectedSegment = idx
    } else {
      control.selectedSegment = -1
    }
    context.coordinator.isInteractive = isInteractive
  }

  private func scaleImage(_ image: NSImage, scale: CGFloat) -> NSImage {
    let originalSize = image.size
    let scaledSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)

    // Add left padding to the icon
    let leftPadding: CGFloat = 4
    let newSize = NSSize(width: scaledSize.width + leftPadding, height: scaledSize.height)

    let scaledImage = NSImage(size: newSize)
    scaledImage.isTemplate = true  // Preserve template mode for proper tinting
    scaledImage.lockFocus()
    image.draw(
      in: NSRect(x: leftPadding, y: 0, width: scaledSize.width, height: scaledSize.height),
      from: NSRect(origin: .zero, size: originalSize),
      operation: .copy,
      fraction: 1.0)
    scaledImage.unlockFocus()
    return scaledImage
  }

  private func rebuild(_ control: NSSegmentedControl) {
    control.segmentCount = items.count
    for (i, it) in items.enumerated() {
      control.setLabel(it.title, forSegment: i)
      if let img = NSImage(systemSymbolName: it.systemImage, accessibilityDescription: nil) {
        // Use template mode to allow proper tinting in selected state
        img.isTemplate = true
        let scaledImg = scaleImage(img, scale: iconScale)
        control.setImage(scaledImg, forSegment: i)
        control.setImageScaling(.scaleNone, forSegment: i)
      }
      control.setEnabled(it.isEnabled, forSegment: i)
    }
  }

  final class Coordinator: NSObject {
    weak var control: NSSegmentedControl?
    var selection: Binding<Selection>
    var items: [Item]
    var isInteractive: Bool = true
    var iconScale: CGFloat = 1.0

    init(selection: Binding<Selection>, items: [Item], iconScale: CGFloat = 1.0) {
      self.selection = selection
      self.items = items
      self.iconScale = iconScale
    }

    @objc func changed(_ sender: NSSegmentedControl) {
      guard isInteractive else { return }
      let idx = sender.selectedSegment
      guard idx >= 0 && idx < items.count else { return }
      // Directly update the binding
      selection.wrappedValue = items[idx].tag
    }
  }
}

// MARK: - Chromed icon button to match split buttons
private struct ChromedIconButton: View {
  let systemImage: String
  var help: String? = nil
  let action: () -> Void
  var body: some View {
    let h: CGFloat = 24
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(height: h)
        .frame(minWidth: h)  // keep a minimum square feel when padding is small
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
    )
    .help(help ?? "")
  }
}

// MARK: - Prompts popover content
private struct PromptsPopover: View {
  let workingDirectory: String
  let terminalKey: String
  let builtin: [PresetPromptsStore.Prompt]
  @Binding var query: String
  @Binding var loaded: [ContentView.SourcedPrompt]
  @Binding var hovered: String?
  @Binding var pendingDelete: ContentView.SourcedPrompt?
  let onDismiss: () -> Void
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Preset Prompts").font(.headline)
        Spacer()
        Button {
          Task {
            await PresetPromptsStore.shared.openOrCreatePreferredFile(
              for: workingDirectory, withTemplate: builtin)
          }
        } label: {
          Image(systemName: "wrench.and.screwdriver")
        }
        .buttonStyle(.plain)
        .help("Open prompts file")
      }
      TextField("Search or type a new command", text: $query)
        .textFieldStyle(.roundedBorder)
        .frame(width: 320)
        .focused($searchFocused)
        .onChange(of: query) { _, _ in reload() }

      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          let rows = filtered()
          ForEach(rows.indices, id: \.self) { idx in
            let sp = rows[idx]
            let rowKey = sp.command
            HStack(spacing: 8) {
              if hovered == rowKey {
                Button {
                  Task {
                    await PresetPromptsStore.shared.delete(
                      prompt: sp.prompt, location: location(of: sp),
                      workingDirectory: workingDirectory)
                  }
                  reload()
                } label: {
                  Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help("Remove")
              }
              Text(sp.label)
                .font(.system(size: 13, weight: .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 8)
            .padding(.trailing, 24)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(idx % 2 == 0 ? Color.secondary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
            .onHover { inside in
              if inside { hovered = rowKey } else if hovered == rowKey { hovered = nil }
            }
            .onTapGesture {
              #if canImport(SwiftTerm) && !APPSTORE
                TerminalSessionManager.shared.send(to: terminalKey, text: sp.command)
              #else
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(sp.command, forType: .string)
              #endif
              // Auto-dismiss popover after selecting a preset
              onDismiss()
            }
          }
          if shouldOfferAdd() {
            Button {
              let p = PresetPromptsStore.Prompt(label: query, command: query)
              Task {
                _ = await PresetPromptsStore.shared.add(prompt: p, for: workingDirectory)
                reload()
              }
            } label: {
              Label("Add \(query)", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.top, 6)
            .padding(.trailing, 24)
          }
        }
      }
      .frame(height: 160)
    }
    .padding(12)
    .onAppear {
      reload()
      // Focus search field by default for quick keyboard input
      DispatchQueue.main.async { self.searchFocused = true }
    }
  }

  private func location(of sp: ContentView.SourcedPrompt) -> PresetPromptsStore.PromptLocation {
    switch sp.source {
    case .project: return .project
    case .user: return .user
    case .builtin: return .builtin
    }
  }

  private func filtered() -> [ContentView.SourcedPrompt] {
    if query.trimmingCharacters(in: .whitespaces).isEmpty { return loaded }
    let q = query.lowercased()
    return loaded.filter {
      $0.label.lowercased().contains(q) || $0.command.lowercased().contains(q)
    }
  }

  private func shouldOfferAdd() -> Bool {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return false }
    return !loaded.contains(where: { $0.command == q })
  }

  private func reload() {
    Task {
      let store = PresetPromptsStore.shared
      let project = await store.loadProjectOnly(for: workingDirectory)
      let user = await store.loadUserOnly()
      let hidden = await store.loadHidden(for: workingDirectory)
      var seen = Set<String>()
      var out: [ContentView.SourcedPrompt] = []
      func push(_ p: PresetPromptsStore.Prompt, _ src: ContentView.SourcedPrompt.Source) {
        if hidden.contains(p.command) { return }
        if seen.insert(p.command).inserted {
          out.append(ContentView.SourcedPrompt(prompt: p, source: src))
        }
      }
      project.forEach { push($0, .project) }
      user.forEach { push($0, .user) }
      builtin.forEach { push($0, .builtin) }
      await MainActor.run { loaded = out }
    }
  }
}
