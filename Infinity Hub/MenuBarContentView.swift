import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var battery: BatteryViewModel
    @ObservedObject var loginItem: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 6) {
                ForEach(battery.accessories) { state in
                    batteryCard(
                        state: state,
                        symbol: state.kind.symbol
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if hasNotices {
                notices
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            footer
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(width: 300)
        .onAppear {
            loginItem.refreshStatus()
            battery.refresh(showActivity: false)
        }
    }

    // MARK: - Battery cards

    private func batteryCard(
        state: AccessoryDisplayState,
        symbol: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(state.isPresent ? Color.primary : Color.secondary)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(state.name)
                            .font(.subheadline.weight(.semibold))

                        if let detail = state.detail {
                            Text("·")
                                .foregroundStyle(.secondary)
                            Text(detail)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .font(.subheadline)

                    Spacer()

                    if let level = state.level {
                        HStack(spacing: 4) {
                            if state.isCharging || state.isCharged {
                                Image(systemName: "bolt.fill")
                                    .font(.caption2)
                            }
                            Text("\(level)%")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(batteryColor(state))
                    }
                }

                if state.level != nil {
                    levelBar(state: state)
                }
            }
            .padding(.bottom, 2)
        }
        .padding(.vertical, 12)
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
    }

    private func levelBar(state: AccessoryDisplayState) -> some View {
        GeometryReader { proxy in
            let fraction = Double(state.level ?? 0) / 100
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary.opacity(0.8))
                Capsule()
                    .fill(barStyle(state))
                    .frame(width: max(4, proxy.size.width * fraction))
                    .opacity(state.level == nil ? 0 : 1)
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.3), value: state.level)
    }

    private func barStyle(_ state: AccessoryDisplayState) -> LinearGradient {
        let color = batteryColor(state)
        return LinearGradient(
            colors: [color.opacity(0.65), color],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Notices

    private var hasNotices: Bool {
        battery.message != nil
            || loginItem.requiresApproval
            || loginItem.errorMessage != nil
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = battery.message {
                Label(message, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            if loginItem.requiresApproval {
                Label(
                    "Approve Infinity Hub in System Settings → Login Items.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }

            if let errorMessage = loginItem.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Menu {
                Toggle(
                    "Start at Login",
                    isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.setEnabled($0) }
                    )
                )

                Divider()

                Button("Quit Infinity Hub") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(.quaternary.opacity(0.6), in: Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Button {
                battery.refresh()
            } label: {
                Group {
                    if battery.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.quaternary.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(battery.isRefreshing)
            .help("Refresh battery levels")
        }
    }

    // MARK: - Color

    private func batteryColor(_ state: AccessoryDisplayState) -> Color {
        guard state.isPresent, let level = state.level else {
            return .secondary
        }
        if state.isCharging || state.isCharged {
            return .green
        }
        if level <= 10 {
            return .red
        }
        if level <= 25 {
            return .orange
        }
        return .primary
    }
}
