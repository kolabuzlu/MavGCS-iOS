import MavlinkCore
import SwiftUI

/// Where to find the vehicle, how much to ask it for, and what the link is
/// doing once it is found.
///
/// Two columns, because the phone is always on its side: the connection on
/// the left, and on the right what is adjusted and watched while it is up.
/// Stacked in one list, the telemetry rates -- the setting most often
/// changed mid-flight -- sat below the fold under fields that are locked
/// while connected.
struct ConnectionSheet: View {
    @Environment(GcsModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 0) {
                // The button first: under the fields it fell below the fold
                // whenever UDP's extra row was showing, and it is the one
                // control on this side that is always wanted.
                Form {
                    connectSection
                    connectionSection
                }
                Form {
                    ratesSection
                    if model.vehicle.linkOpen {
                        linkSection
                        if model.vehicle.heard {
                            vehicleSection
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .monospacedDigit()
        .preferredColorScheme(.dark)
    }

    private var connectionSection: some View {
        @Bindable var model = model
        return Section {
            Picker("Link", selection: $model.form.type) {
                Text("UDP").tag(LinkType.udp)
                Text("TCP").tag(LinkType.tcp)
                Text("Demo").tag(LinkType.demo)
            }
            .pickerStyle(.segmented)
            // The demo has nothing to address: the aircraft is inside the app.
            if model.form.type != .demo {
                addressRows
            }
        } header: {
            Text("Connection")
        } footer: {
            Text(explanation)
        }
        .disabled(model.vehicle.linkOpen)
    }

    @ViewBuilder
    private var addressRows: some View {
        @Bindable var model = model
        Group {
            if model.form.type == .udp {
                Picker("UDP", selection: $model.form.udpMode) {
                    Text("Listen").tag(UdpMode.listen)
                    Text("Connect to").tag(UdpMode.connect)
                }
                .pickerStyle(.segmented)
            }
            if model.form.hostEditable {
                LabeledContent("Host") {
                    TextField("192.168.4.55", text: $model.form.host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
            } else {
                // A bound port listens on every interface, so there is no
                // address to type.
                LabeledContent("Host", value: "Any")
            }
            LabeledContent("Port") {
                TextField("14550", text: Binding(
                    get: { model.form.port },
                    set: { model.form.port = String($0.filter(\.isNumber).prefix(5)) }
                ))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
            }
        }
    }

    private var connectSection: some View {
        let open = model.vehicle.linkOpen
        return Section {
            Button {
                model.toggleConnection()
            } label: {
                Text(open ? "Disconnect" : "Connect")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(open ? Palette.red : Palette.green)
            .foregroundStyle(open ? Color.white : Palette.onGreen)
        }
    }

    /// Never locked: a rate is exactly what is worth changing on a live
    /// link, and a change goes to the vehicle the moment it is picked.
    private var ratesSection: some View {
        @Bindable var model = model
        let full = model.rates.full
        return Section {
            // Greyed rather than hidden while Full is on, as on the desktop:
            // they come back into force the moment it is turned off, and
            // the values they will return to should stay in view.
            rateRow("Attitude", selection: $model.rates.attitudeHz)
                .disabled(full)
            rateRow("GPS position", selection: $model.rates.positionHz)
                .disabled(full)
            Toggle("Full MAVLink telemetry", isOn: $model.rates.full)
                .tint(Palette.green)
        } header: {
            Text("Telemetry rates")
        } footer: {
            // Says what is in force now, the way the desktop's note does.
            Text(full
                ? "The flight controller decides every rate, and the two above are ignored. For fast links, and for capturing everything: a slow RC link cannot carry it, and drops whatever overflows. A change applies at once while connected."
                : "A radio link has a fixed budget, and it drops whatever overflows without regard for what mattered. Asking for less means what you do ask for actually arrives. Full MAVLink telemetry streams everything the flight controller sends at its own rates instead. A change applies at once while connected.")
        }
    }

    private func rateRow(_ label: String, selection: Binding<Float>) -> some View {
        LabeledContent(label) {
            Picker(label, selection: selection) {
                ForEach(Preferences.rateChoices, id: \.self) { hz in
                    Text("\(Int(hz)) Hz").tag(hz)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
        }
    }

    private var linkSection: some View {
        let link = model.vehicle.link
        return Section("Link") {
            LabeledContent("Receiving", value: "\(link.rxBytesPerSec) B/s · \(String(format: "%.0f", link.rxPerSec)) msg/s")
            LabeledContent("Sending", value: "\(link.txBytesPerSec) B/s · \(String(format: "%.0f", link.txPerSec)) msg/s")
            LabeledContent("Lost (last 10 s)", value: link.lossPercent.map { String(format: "%.1f%%", $0) } ?? "--")
            LabeledContent("Received / lost", value: "\(link.received) / \(link.lost)")
            LabeledContent("RSSI", value: model.vehicle.rssiPercent.map { String(format: "%.0f%%", $0) } ?? "--")
        }
    }

    private var vehicleSection: some View {
        Section("Vehicle") {
            LabeledContent("Autopilot", value: model.vehicle.autopilot)
            LabeledContent("Type", value: model.vehicle.vehicleType)
            LabeledContent("System", value: "\(model.vehicle.systemId) / \(model.vehicle.componentId)")
            LabeledContent("State", value: model.vehicle.systemStatus)
        }
    }

    private var explanation: String {
        switch (model.form.type, model.form.udpMode) {
        case (.udp, .listen):
            return "Waits on this port for whatever sends to this phone: a simulator, MAVProxy, or a radio set to send here."
        case (.udp, .connect):
            return "Speaks first, then listens for the answer. For WiFi bridges that wait to hear from the ground station, such as mLRS (192.168.4.55, port 14550)."
        case (.tcp, _):
            return "Connects to a TCP server, such as a simulator on port 5760."
        case (.demo, _):
            return "A simulated aircraft flying over Ankara, built into the app, for trying MavGCS with no drone at hand. It answers the mode buttons, arming, Fly Here and the guided controls as a real ArduPlane would. Nothing real is flying, and nothing leaves this phone."
        }
    }
}
