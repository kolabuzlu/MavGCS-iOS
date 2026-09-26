import MavlinkCore
import SwiftUI

/// The data fields under the HUD: the desktop's and the Android build's
/// sixteen, four rows of four, in their order. Three names are shortened
/// to fit a phone's cell on one line; nothing else differs.
struct TelemetryGrid: View {
    let vehicle: VehicleState
    @Binding var speedInKph: Bool

    var body: some View {
        let unit = speedInKph ? "kph" : "m/s"
        // Either speed turns both: they are the same quantity measured two
        // ways, and one in kph beside the other in m/s invites exactly the
        // comparison that would then be wrong.
        let swapUnit = { speedInKph.toggle() }
        let fields: [Field] = [
            Field("AirSpeed (\(unit))", speed(vehicle.airSpeedMs), onTap: swapUnit),
            Field("GroundSpeed (\(unit))", speed(vehicle.groundSpeedMs), onTap: swapUnit),
            Field("Vert Speed (m/s)", readout(vehicle.climbMs, digits: 1)),
            Field("Altitude (m)", readout(vehicle.altRelM, digits: 1)),
            Field("Rangefinder (m)", readout(vehicle.rangefinderM, digits: 2)),
            Field("Dist to Home (m)", readout(vehicle.distToHomeM, digits: 0)),
            Field("Dist to WP (m)", readout(vehicle.distToWpM, digits: 0)),
            Field("Sat Count", vehicle.satellites.flatMap { $0 > 0 ? String($0) : nil } ?? "--"),
            Field("Roll (deg)", readout(vehicle.rollDeg, digits: 1)),
            Field("Pitch (deg)", readout(vehicle.pitchDeg, digits: 1)),
            Field("Yaw (deg)", readout(vehicle.yawDeg, digits: 1)),
            Field("Gps HDOP", readout(vehicle.hdop, digits: 2)),
            Field("Wind Dir (deg)", readout(vehicle.windDirectionDeg, digits: 0)),
            Field("Wind Vel (kph)", readout(vehicle.windSpeedMs.map { $0 * msToKph }, digits: 1)),
            Field("QNH", readout(vehicle.qnhHpa, digits: 1)),
            Field("Terrain Alt (m)", readout(vehicle.terrainAltM, digits: 1)),
        ]
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(0..<(fields.count / 4), id: \.self) { row in
                GridRow {
                    ForEach(0..<4, id: \.self) { column in
                        cell(fields[row * 4 + column])
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func speed(_ metersPerSecond: Float?) -> String {
        readout(metersPerSecond.map { speedInKph ? $0 * msToKph : $0 }, digits: 1)
    }

    private func cell(_ field: Field) -> some View {
        VStack(spacing: 1) {
            Text(field.label)
                .font(.system(size: 8))
                .foregroundStyle(Palette.onSurfaceVariant)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(field.value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole cell, caption included, so the tap need not find the figure.
        .contentShape(Rectangle())
        .onTapGesture { field.onTap?() }
    }

    private struct Field {
        let label: String
        let value: String
        let onTap: (() -> Void)?

        init(_ label: String, _ value: String, onTap: (() -> Void)? = nil) {
            self.label = label
            self.value = value
            self.onTap = onTap
        }
    }
}
