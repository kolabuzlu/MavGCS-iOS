import MavlinkCore
import SwiftUI

/// Where to find the vehicle, and what the link is doing once it is found.
struct ConnectionSheet: View {
    @Environment(GcsModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        let open = model.vehicle.linkOpen
        NavigationStack {
            Form {
                Section {
                    Picker("Link", selection: $model.form.type) {
                        Text("UDP").tag(LinkType.udp)
                        Text("TCP").tag(LinkType.tcp)
                    }
                    .pickerStyle(.segmented)
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
                        // A bound port listens on every interface, so there is
                        // no address to type.
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
                } footer: {
                    Text(explanation)
                }
                .disabled(open)

                Section {
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

                if open {
                    Section("Link") {
                        let link = model.vehicle.link
                        LabeledContent("Receiving", value: "\(link.rxBytesPerSec) B/s · \(String(format: "%.0f", link.rxPerSec)) msg/s")
                        LabeledContent("Sending", value: "\(link.txBytesPerSec) B/s · \(String(format: "%.0f", link.txPerSec)) msg/s")
                        LabeledContent("Lost (last 10 s)", value: link.lossPercent.map { String(format: "%.1f%%", $0) } ?? "--")
                        LabeledContent("Received / lost", value: "\(link.received) / \(link.lost)")
                        LabeledContent("RSSI", value: model.vehicle.rssiPercent.map { String(format: "%.0f%%", $0) } ?? "--")
                    }
                    if model.vehicle.heard {
                        Section("Vehicle") {
                            LabeledContent("Autopilot", value: model.vehicle.autopilot)
                            LabeledContent("Type", value: model.vehicle.vehicleType)
                            LabeledContent("System", value: "\(model.vehicle.systemId) / \(model.vehicle.componentId)")
                            LabeledContent("State", value: model.vehicle.systemStatus)
                        }
                    }
                }
            }
            .navigationTitle("Connection")
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

    private var explanation: String {
        switch (model.form.type, model.form.udpMode) {
        case (.udp, .listen):
            return "Waits on this port for whatever sends to this phone: a simulator, MAVProxy, or a radio set to send here."
        case (.udp, .connect):
            return "Speaks first, then listens for the answer. For WiFi bridges that wait to hear from the ground station, such as mLRS (192.168.4.55, port 14550)."
        case (.tcp, _):
            return "Connects to a TCP server, such as a simulator on port 5760."
        }
    }
}
