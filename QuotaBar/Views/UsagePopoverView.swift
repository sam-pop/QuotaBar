import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var viewModel: AccountsViewModel

    /// Widest matrix we draw inline (≈3 accounts); beyond that the columns scroll horizontally.
    private static let maxMatrixWidth: CGFloat = 680
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

    /// Single account keeps the original 320-pt column; 2+ accounts widen to fit the matrix.
    private var popoverWidth: CGFloat {
        accountCount <= 1 ? 320 : min(matrixOuterWidth, Self.maxMatrixWidth)
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
        if matrixOuterWidth > Self.maxMatrixWidth {
            ScrollView(.horizontal, showsIndicators: true) { content }
        } else {
            content
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "sparkle").foregroundStyle(.orange)
            Text("QuotaBar").font(.system(.headline, weight: .semibold))
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

    /// A provider's own logo for a menu item, sized like the SF Symbol it replaces — the
    /// vector asset would otherwise draw at its natural 24 pt. Claude's is tinted at the call
    /// site; OpenAI's brand mark is black/white, so it inherits the menu's color.
    private func providerMark(_ name: String) -> some View {
        Image(name).renderingMode(.template).resizable().scaledToFit().frame(width: 12, height: 12)
    }

    private var addAccountControls: some View {
        VStack(spacing: 4) {
            // Once an add-account login is running, its own controls replace the button that
            // started it — starting a second one would be refused anyway.
            if viewModel.loginAffordance(for: nil) == .none {
                Menu {
                    Button {
                        Task { await viewModel.beginAddAccountLogin(provider: .anthropic) }
                    } label: { Label { Text("Claude") } icon: {
                        providerMark("ProviderMarkClaude")
                            .foregroundStyle(Color(nsColor: ProviderShape.claudeBrand))
                    } }
                        .help("Opens claude.ai in your browser to sign in")
                    Button {
                        Task { await viewModel.beginAddAccountLogin(provider: .openai) }
                    } label: { Label { Text("OpenAI / Codex") } icon: { providerMark("ProviderMarkOpenAI") } }
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
