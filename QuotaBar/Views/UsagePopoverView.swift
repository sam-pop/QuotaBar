import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var viewModel: AccountsViewModel

    /// Horizontal padding wrapping the matrix (matches `matrix`'s `.padding(.horizontal, 12)`).
    private static let matrixHPadding: CGFloat = 24

    private var accountCount: Int { viewModel.accounts.count }

    /// The matrix's grid width: label column + one column per account + hairline separators.
    private var matrixGridWidth: CGFloat {
        UsageMatrixView.labelWidth
            + UsageMatrixView.columnWidth * CGFloat(accountCount)
            + CGFloat(max(accountCount - 1, 0)) * 0.5
    }

    /// Grid plus its surrounding padding — the width the matrix actually needs.
    private var matrixOuterWidth: CGFloat { matrixGridWidth + Self.matrixHPadding }

    /// The screen the popover opens on: `NSScreen.main` is the screen with the key window.
    /// The fallback only matters headless (no screens attached).
    private var visibleWidth: CGFloat { NSScreen.main?.visibleFrame.width ?? 1440 }

    /// Single account keeps the original 320-pt column; 2+ accounts widen to fit the matrix,
    /// up to what the screen can show.
    private var popoverWidth: CGFloat {
        PopoverLayout.width(accountCount: accountCount, matrixOuterWidth: matrixOuterWidth,
                            visibleWidth: visibleWidth)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if viewModel.accounts.isEmpty {
                emptyState
            } else if accountCount == 1 {
                // Single account keeps the taller, sparkline-forward layout.
                singleAccountList
            } else {
                matrix
            }

            addAccountControls
            Divider()
            footer.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: popoverWidth)
    }

    private var singleAccountList: some View {
        VStack(spacing: 14) {
            ForEach(viewModel.accountViews) { view in
                AccountRowView(viewModel: viewModel, accountView: view)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var matrix: some View {
        let content = UsageMatrixView(viewModel: viewModel, columns: viewModel.accountViews)
            .padding(.horizontal, 12).padding(.vertical, 10)
        if PopoverLayout.scrolls(matrixOuterWidth: matrixOuterWidth, visibleWidth: visibleWidth) {
            ScrollView(.horizontal, showsIndicators: true) { content }
        } else {
            content
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            // The symbol takes the title's own font so it scales with it and sits on the
            // same cap height.
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
            Text("QuotaBar").font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.title2).foregroundStyle(.secondary)
            Text("No accounts yet").font(.callout).fontWeight(.medium)
            Text("Add an account below to start tracking its usage.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20).padding(.horizontal, 16)
    }

    /// A provider's own logo for a menu item. Sizing and tint both live in the `NSImage`
    /// (see `ProviderShape.menuImage`) because SwiftUI's `NSMenuItem` bridge drops `.frame`
    /// and `.foregroundStyle` on a non-SF image.
    @ViewBuilder
    private func providerMark(_ shape: ProviderShape) -> some View {
        if let image = shape.menuImage(pointSize: 14) { Image(nsImage: image) }
    }

    private var addAccountControls: some View {
        VStack(spacing: 4) {
            // Once an add-account login is running, its own controls replace the button that
            // started it — starting a second one would be refused anyway.
            if viewModel.loginAffordance(for: nil) == .none {
                Menu {
                    Button {
                        Task { await viewModel.beginAddAccountLogin(provider: .anthropic) }
                    } label: { Label { Text("Claude") } icon: { providerMark(.claudeMark) } }
                        .help("Opens claude.ai in your browser to sign in")
                    Button {
                        Task { await viewModel.beginAddAccountLogin(provider: .openai) }
                    } label: { Label { Text("OpenAI / Codex") } icon: { providerMark(.openAIMark) } }
                        .help("Opens auth.openai.com in your browser to sign in with your ChatGPT account")
                } label: {
                    Label("Add account…", systemImage: "plus.circle")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            } else {
                LoginPill(viewModel: viewModel, accountID: nil)
            }

            if let error = viewModel.addAccountError {
                Text(error).font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3)
            } else {
                Text("One account at a time — sign in with the browser.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                Text("Bar:").font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: $viewModel.menuBarDisplayMode) {
                    ForEach(MenuBarDisplayMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Spacer()
                Toggle("Launch at login", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { _ in viewModel.toggleLaunchAtLogin() }
                ))
                .toggleStyle(.switch).controlSize(.mini).font(.caption2)
            }

            if viewModel.notificationsAuthorized == false {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bell.slash")
                        Text("Notifications off — enable in System Settings").lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Button {
                    Task { await viewModel.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless).help("Refresh all now")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
