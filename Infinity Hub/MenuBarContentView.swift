import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var battery: BatteryViewModel
    @ObservedObject var loginItem: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                if battery.deviceGroups.isEmpty {
                    emptyState
                } else {
                    ForEach(battery.deviceGroups) { group in
                        deviceGroupCard(group)
                    }
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "computermouse")
                .font(.system(size: 20, weight: .medium))

            Text("No devices connected")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 2)
        .background(cardBackground.opacity(0))
    }

    @ViewBuilder
    private func deviceGroupCard(
        _ group: AccessoryDisplayGroup
    ) -> some View {
        if group.items.count > 1 {
            groupedBatteryCard(
                title: group.title,
                items: group.items
            )
        } else if let state = group.items.first {
            batteryCard(state: state)
        }
    }

    private func batteryCard(
        state: AccessoryDisplayState
    ) -> some View {
        batteryRow(state)
            .background {
                cardBackground
            }
    }

    private func groupedBatteryCard(
        title: String?,
        items: [AccessoryDisplayState]
    ) -> some View {
        VStack(spacing: 0) {
            if let title {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .padding(.trailing, 16)
                    .padding(.top, 10)
//                    .padding(.bottom, 20)
            }

            ForEach(items) { state in
                if state.id != items.first?.id {
                    Divider()
//                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                        .opacity(0.7)
                }
                batteryRow(state)
            }
        }
        .background {
            cardBackground
        }
    }

    private func batteryRow(
        _ state: AccessoryDisplayState
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: state.kind.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(state.isPresent ? Color.primary : Color.secondary)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 8) {
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
                        HStack(spacing: 2) {
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
        .padding(.vertical, 14)
        .padding(.leading, 8)
        .padding(.trailing, 20)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.quaternary.opacity(0.5))
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

#if DEBUG
@MainActor
private struct MenuBarContentPreview: View {
    @StateObject private var battery: BatteryViewModel
    @StateObject private var loginItem: LoginItemController

    init(deviceGroups: [AccessoryDisplayGroup]) {
        _battery = StateObject(
            wrappedValue: BatteryViewModel(
                previewDeviceGroups: deviceGroups
            )
        )
        _loginItem = StateObject(
            wrappedValue: LoginItemController(
                previewIsEnabled: false
            )
        )
    }

    var body: some View {
        MenuBarContentView(
            battery: battery,
            loginItem: loginItem
        )
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .padding(24)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

private enum MenuBarPreviewData {
    static let singlePaired = [
        AccessoryDisplayGroup(
            id: "preview.single.receiver",
            title: nil,
            items: [
                mouse(
                    id: "preview.single.mouse",
                    name: "Mouse",
                    level: 93,
                    connection: "2.4 GHz"
                ),
                receiver(
                    id: "preview.single.receiver",
                    name: "Receiver",
                    level: 100
                ),
            ]
        ),
    ]

    static let bluetoothAndReceiver = [
        AccessoryDisplayGroup(
            id: "preview.bluetooth.mouse",
            title: nil,
            items: [
                mouse(
                    id: "preview.bluetooth.mouse",
                    name: "AM Infinity .97",
                    level: 90,
                    connection: "Bluetooth"
                ),
            ]
        ),
        AccessoryDisplayGroup(
            id: "preview.bluetooth.receiver",
            title: nil,
            items: [
                receiver(
                    id: "preview.bluetooth.receiver",
                    name: "AM Infinity .97 Receiver",
                    level: 100
                ),
            ]
        ),
    ]

    static let twoReceivers = [
        AccessoryDisplayGroup(
            id: "preview.97.receiver",
            title: "AM Infinity .97",
            items: [
                mouse(
                    id: "preview.97.mouse",
                    name: "Mouse",
                    level: 90,
                    connection: "2.4 GHz"
                ),
                receiver(
                    id: "preview.97.receiver",
                    name: "Receiver",
                    level: 100,
                    isCharged: true
                ),
            ]
        ),
        AccessoryDisplayGroup(
            id: "preview.8k.receiver",
            title: "AM Infinity",
            items: [
                mouse(
                    id: "preview.8k.mouse",
                    name: "Mouse",
                    level: 80,
                    connection: "2.4 GHz"
                ),
                receiver(
                    id: "preview.8k.receiver",
                    name: "Receiver",
                    level: 100
                ),
            ]
        ),
    ]

    static let bluetoothAnd8K = [
        AccessoryDisplayGroup(
            id: "preview.mixed.bluetooth",
            title: nil,
            items: [
                mouse(
                    id: "preview.mixed.bluetooth",
                    name: "AM Infinity .97",
                    level: 90,
                    connection: "Bluetooth"
                ),
            ]
        ),
        AccessoryDisplayGroup(
            id: "preview.mixed.8k",
            title: "AM Infinity",
            items: [
                mouse(
                    id: "preview.mixed.8k.mouse",
                    name: "Mouse",
                    level: 80,
                    connection: "2.4 GHz"
                ),
                receiver(
                    id: "preview.mixed.8k.receiver",
                    name: "Receiver",
                    level: 100
                ),
            ]
        ),
    ]

    static let empty: [AccessoryDisplayGroup] = []

    private static func mouse(
        id: String,
        name: String,
        level: Int,
        connection: String
    ) -> AccessoryDisplayState {
        AccessoryDisplayState(
            id: id,
            kind: .mouse,
            name: name,
            level: level,
            isPresent: true,
            isCharging: false,
            isCharged: false,
            detail: connection
        )
    }

    private static func receiver(
        id: String,
        name: String,
        level: Int,
        isCharged: Bool = false
    ) -> AccessoryDisplayState {
        AccessoryDisplayState(
            id: id,
            kind: .receiver,
            name: name,
            level: level,
            isPresent: true,
            isCharging: false,
            isCharged: isCharged,
            detail: nil
        )
    }
}

#Preview("Single Paired · 2.4 GHz") {
    MenuBarContentPreview(
        deviceGroups: MenuBarPreviewData.singlePaired
    )
}

#Preview("Bluetooth + Receiver") {
    MenuBarContentPreview(
        deviceGroups: MenuBarPreviewData.bluetoothAndReceiver
    )
}

#Preview("Two Receivers") {
    MenuBarContentPreview(
        deviceGroups: MenuBarPreviewData.twoReceivers
    )
}

#Preview("Bluetooth + 8K") {
    MenuBarContentPreview(
        deviceGroups: MenuBarPreviewData.bluetoothAnd8K
    )
}

#Preview("Empty State") {
    MenuBarContentPreview(
        deviceGroups: MenuBarPreviewData.empty
    )
}
#endif
