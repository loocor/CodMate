import SwiftUI
import AppKit

extension ContentView {
    // Sticky detail action bar at the top of the detail column
    var detailActionBar: some View {
        HStack(spacing: 12) {
            // Left: view mode segmented (Timeline | Git Review | Terminal)
            Group {
                #if canImport(SwiftTerm) && !APPSTORE
                    let hasTerminal = hasAvailableEmbeddedTerminal()
                    let items: [SegmentedIconPicker<ContentView.DetailTab>.Item] = [
                        .init(title: "Timeline", systemImage: "clock", tag: .timeline),
                        .init(title: "Git Review", systemImage: "arrow.triangle.branch", tag: .review),
                        .init(title: "Terminal", systemImage: "terminal", tag: .terminal, isEnabled: hasTerminal)
                    ]
                    let selection = Binding<ContentView.DetailTab>(
                        get: {
                            // Always return the actual selectedDetailTab to ensure correct highlighting
                            return selectedDetailTab
                        },
                        set: { newValue in
                            // Re-evaluate terminal availability at SET time to get fresh value
                            let currentHasTerminal = hasAvailableEmbeddedTerminal()
                            if newValue == .terminal {
                                guard currentHasTerminal else {
                                    return
                                }
                                // When switching to terminal, ensure selectedTerminalKey points to focused session's terminal
                                if let focused = focusedSummary, runningSessionIDs.contains(focused.id) {
                                    selectedTerminalKey = focused.id
                                } else if let anchorId = fallbackRunningAnchorId() {
                                    selectedTerminalKey = anchorId
                                } else {
                                    // Fallback: use any available terminal
                                    selectedTerminalKey = runningSessionIDs.first
                                }
                            }
                            selectedDetailTab = newValue
                        }
                    )
                    SegmentedIconPicker(items: items, selection: selection)
                #else
                    let items: [SegmentedIconPicker<ContentView.DetailTab>.Item] = [
                        .init(title: "Timeline", systemImage: "clock", tag: .timeline),
                        .init(title: "Git Review", systemImage: "arrow.triangle.branch", tag: .review)
                    ]
                    SegmentedIconPicker(items: items, selection: $selectedDetailTab)
                #endif
            }

            Spacer(minLength: 12)

            // Right: New…, Resume…, Reveal, Prompts, Export/Return, Max
            if let focused = focusedSummary {
                // New split control: hidden in Terminal tab
                if selectedDetailTab != .terminal {
                    let embeddedPreferredNew = viewModel.preferences.defaultResumeUseEmbeddedTerminal && !AppSandbox.isEnabled
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
                            let currentName = currentSrc.branding.displayName
                            items.append(.init(kind: .action(title: "\(currentName) with Terminal") {
                                launchNewSession(for: focused, using: currentSrc, style: .terminal)
                            }))
                            items.append(.init(kind: .action(title: "\(currentName) with iTerm2") {
                                launchNewSession(for: focused, using: currentSrc, style: .iterm)
                            }))
                            items.append(.init(kind: .action(title: "\(currentName) with Warp") {
                                launchNewSession(for: focused, using: currentSrc, style: .warp)
                            }))
                            // Divider
                            items.append(.init(kind: .separator))
                            // Lower group: alternate provider quick targets
                            let allowed = viewModel.allowedSources(for: focused)
                            // Compute alternate src from allowed set; fallback to opposite of current
                            let altSrc: SessionSource? = {
                                let desired: SessionSource = (currentSrc == .codex) ? .claude : .codex
                                if allowed.contains(where: { $0.sessionSource == desired }) { return desired }
                                // If not allowed, pick any other allowed different from current
                                if let other = allowed.first(where: { $0.sessionSource != currentSrc })?.sessionSource { return other }
                                return desired
                            }()
                            if let alt = altSrc {
                                let altName = alt.branding.displayName
                                items.append(.init(kind: .action(title: "\(altName) with Terminal") {
                                    launchNewSession(for: focused, using: alt, style: .terminal)
                                }))
                                items.append(.init(kind: .action(title: "\(altName) with iTerm2") {
                                    launchNewSession(for: focused, using: alt, style: .iterm)
                                }))
                                items.append(.init(kind: .action(title: "\(altName) with Warp") {
                                    launchNewSession(for: focused, using: alt, style: .warp)
                                }))
                            }
                            // Third group: New With Context…
                            items.append(.init(kind: .separator))
                            items.append(.init(kind: .action(title: "New With Context…") {
                                showNewWithContext = true
                            }))
                            return items
                        }()
                    )
                }

                // Resume split control: hidden in Terminal tab
                if selectedDetailTab != .terminal {
                    let defaultApp = viewModel.preferences.defaultResumeExternalApp
                    let embeddedPreferred = viewModel.preferences.defaultResumeUseEmbeddedTerminal && !AppSandbox.isEnabled
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
                                    items.append(.init(kind: .action(title: "Terminal") {
                                        viewModel.copyResumeCommandsRespectingProject(session: focused)
                                        _ = viewModel.openAppleTerminal(at: workingDirectory(for: focused))
                                        Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Command copied. Paste it in the opened terminal.") }
                                    }))
                                case .iterm2:
                                    items.append(.init(kind: .action(title: "iTerm2") {
                                        let cmd = viewModel.buildResumeCLIInvocationRespectingProject(session: focused)
                                        viewModel.openPreferredTerminalViaScheme(app: .iterm2, directory: workingDirectory(for: focused), command: cmd)
                                    }))
                                case .warp:
                                    items.append(.init(kind: .action(title: "Warp") {
                                        viewModel.copyResumeCommandsRespectingProject(session: focused)
                                        viewModel.openPreferredTerminalViaScheme(app: .warp, directory: workingDirectory(for: focused))
                                        Task { await SystemNotifier.shared.notify(title: "CodMate", body: "Command copied. Paste it in the opened terminal.") }
                                    }))
                                default:
                                    break
                                }
                            }
                            if !embeddedPreferred && viewModel.preferences.defaultResumeUseEmbeddedTerminal && !AppSandbox.isEnabled {
                                items.append(.init(kind: .separator))
                                items.append(.init(kind: .action(title: "Embedded") { startEmbedded(for: focused) }))
                            }
                            return items
                        }()
                    )
                }

                // Reveal in Finder (chromed icon)
                ChromedIconButton(systemImage: "finder", help: "Reveal in Finder") {
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
                    ChromedIconButton(systemImage: "square.and.arrow.up", help: "Export conversation as Markdown") {
                        exportMarkdownForFocused()
                    }
                } else {
                    ChromedIconButton(systemImage: "arrow.uturn.backward", help: "Return to History") {
                        let id = activeTerminalKey() ?? focused.id
                        softReturnPending = true
                        requestStopEmbedded(forID: id)
                    }
                }
            }

        }
    }
}

// MARK: - SegmentedIconPicker (AppKit-backed)
private struct SegmentedIconPicker<Selection: Hashable>: NSViewRepresentable {
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let control = NSSegmentedControl()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.segmentStyle = .rounded
        control.controlSize = .regular
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        rebuild(control)
        // Left align: only pin leading/top/bottom
        container.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            control.topAnchor.constraint(equalTo: container.topAnchor),
            control.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        context.coordinator.control = control
        context.coordinator.isInteractive = isInteractive
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let control = context.coordinator.control else { return }
        if control.segmentCount != items.count { rebuild(control) }
        for (i, it) in items.enumerated() {
            control.setLabel(it.title, forSegment: i)
            if let img = NSImage(systemSymbolName: it.systemImage, accessibilityDescription: nil) {
                control.setImage(img, forSegment: i)
                control.setImageScaling(.scaleProportionallyDown, forSegment: i)
            }
            control.setEnabled(it.isEnabled, forSegment: i)
        }
        if let idx = items.firstIndex(where: { $0.tag == selection }) { control.selectedSegment = idx }
        else { control.selectedSegment = -1 }
        context.coordinator.isInteractive = isInteractive
    }

    private func rebuild(_ control: NSSegmentedControl) {
        control.segmentCount = items.count
        for (i, it) in items.enumerated() {
            control.setLabel(it.title, forSegment: i)
            if let img = NSImage(systemSymbolName: it.systemImage, accessibilityDescription: nil) {
                control.setImage(img, forSegment: i)
                control.setImageScaling(.scaleProportionallyDown, forSegment: i)
            }
            control.setEnabled(it.isEnabled, forSegment: i)
        }
    }

    final class Coordinator: NSObject {
        weak var control: NSSegmentedControl?
        var parent: SegmentedIconPicker
        var isInteractive: Bool = true
        init(_ parent: SegmentedIconPicker) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) {
            guard isInteractive else { return }
            let idx = sender.selectedSegment
            guard idx >= 0 && idx < parent.items.count else { return }
            parent.selection = parent.items[idx].tag
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
                .frame(minWidth: h) // keep a minimum square feel when padding is small
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
                    Task { await PresetPromptsStore.shared.openOrCreatePreferredFile(for: workingDirectory, withTemplate: builtin) }
                } label: { Image(systemName: "wrench.and.screwdriver") }
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
                                    Task { await PresetPromptsStore.shared.delete(prompt: sp.prompt, location: location(of: sp), workingDirectory: workingDirectory) }
                                    reload()
                                } label: { Image(systemName: "minus.circle") }
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
                            Task { _ = await PresetPromptsStore.shared.add(prompt: p, for: workingDirectory); reload() }
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
        return loaded.filter { $0.label.lowercased().contains(q) || $0.command.lowercased().contains(q) }
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

// MARK: - SplitPrimaryMenuButton (unified split button)
private struct SplitPrimaryMenuButton: View {
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

private struct SplitMenuItem: Identifiable {
    enum Kind {
        case action(title: String, disabled: Bool = false, _ run: () -> Void)
        case separator
        case submenu(title: String, items: [SplitMenuItem])
    }
    let id = UUID()
    let kind: Kind
}

private struct ChevronMenuButton: NSViewRepresentable {
    let items: [SplitMenuItem]

    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.openMenu(_:)))
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
                        let mi = NSMenuItem(title: title, action: #selector(Coordinator.fire(_:)), keyEquivalent: "")
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
            let location = NSPoint(x: sender.bounds.midX, y: sender.bounds.maxY-3)
            menu.popUp(positioning: nil, at: location, in: sender)
        }

        @objc func fire(_ sender: NSMenuItem) {
            let index = sender.tag
            guard index >= 0 && index < runs.count else { return }
            runs[index]()
        }
    }
}
