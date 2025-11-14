import SwiftUI

extension GitChangesPanel {
    var leftPane: some View {
        VStack(spacing: 6) {
            // Toolbar - Search fills
            GeometryReader { _ in
                let spacing: CGFloat = 8
                HStack(spacing: spacing) {
                    // Search box expands to fill
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search", text: $treeQuery)
                            .textFieldStyle(.plain)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2))
                    )
                    .frame(maxWidth: .infinity)

                    // Collapse/Expand buttons
                    HStack(spacing: 0) {
                        // Collapse All button
                        Button {
                            if mode == .browser {
                                expandedDirsBrowser.removeAll()
                            } else {
                                expandedDirsStaged.removeAll()
                                expandedDirsUnstaged.removeAll()
                            }
                        } label: {
                            Image(systemName: "arrow.up.right.and.arrow.down.left")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                            }
                        }

                        // (Graph toggle moved to header segmented control)

                        // Expand All button
                        Button {
                            if mode == .browser {
                                expandedDirsBrowser = Set(allDirectoryKeys(nodes: browserNodes))
                            } else {
                                expandedDirsStaged = Set(allDirectoryKeys(nodes: cachedNodesStaged))
                                expandedDirsUnstaged = Set(allDirectoryKeys(nodes: cachedNodesUnstaged))
                            }
                        } label: {
                            Image(systemName: "arrow.down.left.and.arrow.up.right")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 32)

            // Inline commit message (one line, auto-grow; no button) - only in Diff mode
            if mode == .diff {
                GeometryReader { gr in
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $vm.commitMessage)
                            .font(.system(.body))
                            .textEditorStyle(.plain)
                            .frame(minHeight: 20)
                            .frame(height: min(200, max(20, commitInlineHeight)))
                            .padding(.leading, 6)
                            .padding(.top, 6)
                            .padding(.bottom, 6)
                            .padding(.trailing, wandReservedTrailing)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25))
                            )
                        .onChange(of: vm.commitMessage) { _, _ in
                            // account for trailing reserve space
                            let w = max(10, gr.size.width - 12 - wandReservedTrailing)
                            commitInlineHeight = measureCommitHeight(vm.commitMessage, width: w)
                        }
                        if vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Press Command+Return to commit")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 6)
                                .padding(.leading, 10)
                                .allowsHitTesting(false)
                        }

                        // Wand button at top-right of the commit message box
                        HStack { Spacer() }
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    vm.generateCommitMessage(providerId: preferences.commitProviderId, modelId: preferences.commitModelId)
                                } label: {
                                    ZStack(alignment: .bottomTrailing) {
                                        Circle()
                                            .fill(hoverWand ? Color.accentColor.opacity(0.15) : Color.clear)
                                            .frame(width: wandButtonSize - 1, height: wandButtonSize - 1)
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(hoverWand ? Color.accentColor : Color.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .frame(width: wandButtonSize, height: wandButtonSize)
                                .contentShape(Rectangle())
                                .padding(.top, 4) // keep top-anchored; don't move when TextEditor grows
                                .padding(.trailing, 4)
                                .onHover { hoverWand = $0 }
                                .opacity((vm.isGenerating && vm.generatingRepoPath == vm.repoRoot?.path) ? 0.4 : 1.0)
                                .animation((vm.isGenerating && vm.generatingRepoPath == vm.repoRoot?.path) ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: vm.isGenerating)
                                .disabled(vm.isGenerating && vm.generatingRepoPath == vm.repoRoot?.path)
                                .help("AI generate commit message from staged changes")
                            }
                    }
                }
                .frame(height: min(200, max(20, commitInlineHeight)) + 12)
            }

            // Trees in VS Code-style sections
            ScrollView {
                if mode == .diff {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Staged section
                        HStack(spacing: 6) {
                            Button {
                                stagedCollapsed.toggle()
                            } label: {
                                Image(systemName: stagedCollapsed ? "chevron.right" : "chevron.down")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .frame(width: chevronWidth)
                            Text("Staged Changes (\(vm.changes.filter { $0.staged != nil }.count))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { stagedCollapsed.toggle() }
                        .onHover { hoverStagedHeader = $0 }
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(hoverStagedHeader ? Color.secondary.opacity(0.06) : Color.clear)
                        )
                        .frame(height: 22)
                        .contextMenu {
                            Button("Unstage All") {
                                let paths = allPaths(in: .staged)
                                Task { await vm.unstage(paths: paths) }
                            }
                        }
                        if !stagedCollapsed {
                            treeRows(nodes: displayedStaged, depth: 1, scope: .staged)
                        }

                        // Unstaged section
                        HStack(spacing: 6) {
                            Button { unstagedCollapsed.toggle() } label: {
                                Image(systemName: unstagedCollapsed ? "chevron.right" : "chevron.down")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .frame(width: chevronWidth)
                            // Show all files with worktree changes, even if they also have staged changes (MM)
                            Text("Changes (\(vm.changes.filter { $0.worktree != nil }.count))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { unstagedCollapsed.toggle() }
                        .onHover { hoverUnstagedHeader = $0 }
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(hoverUnstagedHeader ? Color.secondary.opacity(0.06) : Color.clear)
                        )
                        .frame(height: 22)
                        .contextMenu {
                            Button("Stage All") {
                                let paths = allPaths(in: .unstaged)
                                Task { await vm.stage(paths: paths) }
                            }
                        }
                        if !unstagedCollapsed {
                            treeRows(nodes: displayedUnstaged, depth: 1, scope: .unstaged)
                        }
                    }
                } else {
                    browserTreeView
                }
            }
            // Provide a generic context menu on empty area as well
            .contextMenu {
                Button("Stage All") {
                    let paths = allPaths(in: .unstaged)
                    Task { await vm.stage(paths: paths) }
                }
                Button("Unstage All") {
                    let paths = allPaths(in: .staged)
                    Task { await vm.unstage(paths: paths) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
