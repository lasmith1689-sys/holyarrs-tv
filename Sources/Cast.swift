import SwiftUI

// Chromecast and Google TV: the PC finds the Cast TVs on the network (GET /cast/devices) and tells the chosen one to
// play its own stream (rtx-upscale-stream src/cast.py), so nothing is installed on the TV and the IPTV login stays on
// the PC. Live channels: /tv/cast; On Demand: /tv/ondemand/cast; each answers once the TV reports playing, or why not.

struct CastDevice: Identifiable, Hashable {
    let name: String
    let model: String
    var id: String { name }
}

/// What to cast: the query for the PC (path and items, the chosen device added on the way).
struct CastTarget {
    let title: String
    let path: String
    let query: [URLQueryItem]
}

/// Lists the Cast TVs the PC can see; picking one starts it there and reports what the TV said.
struct CastSheet: View {
    let target: CastTarget
    /// Called once the TV is playing (the caller closes its own player).
    var started: () -> Void = {}
    @EnvironmentObject private var rtx: RTXServer
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [CastDevice] = []
    @State private var looking = true
    @State private var note: String?
    @State private var playingOn: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                if let playingOn {
                    Section {
                        Label("Playing on \(playingOn)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Stop on \(playingOn)", role: .destructive) {
                            Task {
                                if let base = rtx.base { _ = try? await RTXAPI(base: base).get("cast/stop") }
                                dismiss()
                            }
                        }
                    }
                } else {
                    Section {
                        if looking {
                            HStack { ProgressView(); Text("Looking for Chromecasts and Google TVs...") }
                        } else if devices.isEmpty {
                            Text("No Chromecast or Google TV found. Turn it on (on the home Wi-Fi) and look again.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(devices) { d in
                            Button { Task { await cast(to: d) } } label: {
                                HStack {
                                    Image(systemName: "tv")
                                    VStack(alignment: .leading) {
                                        Text(d.name)
                                        if !d.model.isEmpty { Text(d.model).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            .disabled(busy)
                        }
                    } header: {
                        Text("Cast \(target.title)")
                    } footer: {
                        Text("The PC tells the TV to play its own stream, so nothing needs installing on the TV.")
                    }
                    if busy { HStack { ProgressView(); Text("Starting it (it can take half a minute)...") } }
                    if let note { Text(note).foregroundStyle(.red) }
                    Button("Look again") { Task { await load(fresh: true) } }.disabled(busy || looking)
                }
            }
            .navigationTitle("Cast")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task { await load(fresh: false) }
    }

    private func load(fresh: Bool) async {
        looking = true
        defer { looking = false }
        guard let base = rtx.base else { note = "The PC's address isn't set. Open Settings."; return }
        do {
            let j = try await RTXAPI(base: base).get("cast/devices", fresh ? [URLQueryItem(name: "fresh", value: "1")] : [])
            devices = j["devices"].array.compactMap { d in
                guard let name = d["name"].string else { return nil }
                return CastDevice(name: name, model: d["model"].string ?? "")
            }
            note = nil
        } catch {
            note = "Couldn't reach the PC."
        }
    }

    private func cast(to device: CastDevice) async {
        guard let base = rtx.base else { return }
        busy = true
        note = nil
        defer { busy = false }
        do {
            _ = try await RTXAPI(base: base).get(target.path, target.query + [URLQueryItem(name: "device", value: device.name)])
            playingOn = device.name
            started()
        } catch APIError.server(_, let body) {
            let j = (try? JSON.parse(Data(body.utf8))) ?? .null
            note = "\(device.name) didn't start: " + (j["error"].string ?? j["status"]["error"].string ?? "no answer from the TV.")
        } catch {
            note = "Couldn't reach the PC."
        }
    }
}
