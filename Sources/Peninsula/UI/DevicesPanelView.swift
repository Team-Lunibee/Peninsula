import SwiftUI

/// Connected Bluetooth devices and what is left in them.
///
/// Earbuds get three readings because that is how they actually run down —
/// one bud always dies first, and a single averaged number hides exactly the
/// thing you needed to know.
struct DevicesPanelView: View {
    let model: NotchViewModel

    private var devices: [BluetoothBattery.Device] { model.bluetooth.devices }

    var body: some View {
        Group {
            if devices.isEmpty {
                empty
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(devices) { device in
                            card(device)
                                .transition(.blurFade(radius: 8))
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.transition(Preferences.shared.motion), value: devices)
    }

    private func card(_ device: BluetoothBattery.Device) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: device.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 20)

                Text(device.name)
                    .rasterisedText()
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack(spacing: 14) {
                if let main = device.main {
                    reading(label: "Battery", level: main)
                }
                if let left = device.left {
                    reading(label: "Left", level: left)
                }
                if let right = device.right {
                    reading(label: "Right", level: right)
                }
                if let caseLevel = device.caseLevel {
                    reading(label: "Case", level: caseLevel)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minWidth: 180, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.06))
        )
    }

    private func reading(label: LocalizedStringKey, level: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.4))

            HStack(spacing: 5) {
                Text("\(level)%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(level)))
                    .animation(Motion.content(Preferences.shared.motion), value: level)
                    .foregroundStyle(colour(for: level))

                Capsule()
                    .fill(.white.opacity(0.16))
                    .frame(width: 34, height: 3.5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(colour(for: level))
                            .frame(width: 34 * CGFloat(level) / 100)
                    }
            }
        }
    }

    /// Same thresholds macOS uses for its own battery menu, so the colours
    /// agree with the rest of the system.
    private func colour(for level: Int) -> Color {
        switch level {
        case ..<10: .red
        case ..<20: .orange
        default: .white.opacity(0.85)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "wave.3.right.circle")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("No devices connected")
                .rasterisedText()
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text("Only devices that report a battery level appear here")
                .rasterisedText()
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.32))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
