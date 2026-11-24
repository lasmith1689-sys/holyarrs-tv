import AVKit
import SwiftUI

// Offline: a film or game shrunk on the PC (1080p HEVC, ~2 GB an hour, stereo; HDR turned to SDR) and kept on
// the iPhone to watch with no connection. The PC makes the copy (GET /offline/make, /offline/status), the phone
// downloads it (/offline/file/<id>.mp4) over the home network. Apple TV has no offline use, so it shows nothing.

struct OfflineItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let duration: Double
    var bytes: Int64
    let savedAt: Date
    var hasPoster: Bool
}

@MainActor
final class OfflineStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = OfflineStore()
    static let sessionID = "tv.holyarrs.offline"

    enum Phase: Equatable {
        case preparing(Double), downloading(Double), failed(String)
    }

    /// One download, carried in the task's description so it survives the app being closed (background session).
    struct Job: Codable, Hashable {
        let id: String
        let title: String
        let subtitle: String?
        let duration: Double
        var poster: String? = nil
    }

    @Published private(set) var items: [OfflineItem] = []
    @Published private(set) var phases: [String: Phase] = [:]
    /// Set by the app delegate when iOS wakes the app for finished background downloads; called once handled.
    var backgroundDone: (() -> Void)?

    private let folder: URL
    private var session: URLSession!
    private var preparing: Set<String> = []

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("Offline", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Not backed up to iCloud: these are copies the PC can make again.
        var f = folder
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? f.setResourceValues(rv)
        #if os(iOS)
        // A background session: the download carries on with the phone locked or the app closed, and iOS wakes
        // the app when it's done (2026-11-22; before, leaving the app mid-download lost a multi-GB download).
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        #else
        let c = URLSessionConfiguration.default
        #endif
        c.timeoutIntervalForResource = 6 * 3600
        session = URLSession(configuration: c, delegate: self, delegateQueue: .main)
        load()
        // Downloads still running from before the app was last closed: show their progress again.
        session.getAllTasks { tasks in
            let running = tasks.compactMap { t in Self.job(t).map { ($0.id, t.progress.fractionCompleted) } }
            Task { @MainActor in for (id, p) in running { OfflineStore.shared.phases[id] = .downloading(p) } }
        }
    }

    func file(_ id: String) -> URL { folder.appendingPathComponent("\(id).mp4") }
    func poster(_ id: String) -> URL { folder.appendingPathComponent("\(id).jpg") }
    private func resumeData(_ id: String) -> URL { folder.appendingPathComponent("\(id).resume") }
    private var index: URL { folder.appendingPathComponent("index.json") }

    func has(_ id: String) -> Bool { items.contains { $0.id == id } }

    private func load() {
        guard let d = try? Data(contentsOf: index), let list = try? JSONDecoder().decode([OfflineItem].self, from: d) else { return }
        items = list.filter { FileManager.default.fileExists(atPath: file($0.id).path) }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: index, options: .atomic) }
    }

    // Asked-for downloads not finished yet. Kept across launches: the PC goes on making a copy while the app is
    // closed, and the download starts (or picks up where it stopped) the next time the app is open at home.
    private var wanted: [Job] {
        get { (UserDefaults.standard.data(forKey: "offline.wanted")).flatMap { try? JSONDecoder().decode([Job].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "offline.wanted") }
    }

    private func forget(_ id: String) { wanted = wanted.filter { $0.id != id } }

    /// Asks the PC for the copy, waits while it is made, then downloads it.
    func download(_ film: RTXFilm, title: String, subtitle: String?, rtx: URL?) async {
        let job = Job(id: film.id, title: title, subtitle: subtitle, duration: film.duration, poster: film.poster)
        wanted = wanted.filter { $0.id != job.id } + [job]
        await fetch(job, rtx: rtx)
    }

    /// Picks up every asked-for download that isn't running (app opened again, back on the home network).
    func resumeWanted(rtx: URL?) async {
        guard rtx != nil else { return }
        for job in wanted where !has(job.id) {
            if case .downloading = phases[job.id] { continue }
            await fetch(job, rtx: rtx)
        }
    }

    private func fetch(_ job: Job, rtx: URL?) async {
        guard let rtx, !has(job.id), !preparing.contains(job.id) else { return }
        if case .downloading = phases[job.id] { return }
        preparing.insert(job.id)
        defer { preparing.remove(job.id) }
        // A download that stopped part-way (network dropped): carry on from where it was.
        if let data = try? Data(contentsOf: resumeData(job.id)) {
            try? FileManager.default.removeItem(at: resumeData(job.id))
            let task = session.downloadTask(withResumeData: data)
            task.taskDescription = Self.describe(job)
            phases[job.id] = .downloading(0)
            task.resume()
            return
        }
        phases[job.id] = .preparing(0)
        let api = RTXAPI(base: rtx)
        do {
            var st = try await api.get("offline/make", [URLQueryItem(name: "id", value: job.id)])
            while st["state"].string != "ready" {
                if st["state"].string == "failed" { throw OfflineError(st["error"].string ?? "The PC couldn't make the copy.") }
                if st["state"].string == "none" { throw OfflineError("The PC dropped the copy. Try again.") }
                phases[job.id] = .preparing(st["progress"].double ?? 0)
                try await Task.sleep(nanoseconds: 3_000_000_000)
                st = try await api.get("offline/status", [URLQueryItem(name: "id", value: job.id)])
            }
            if let p = job.poster, let u = URL(string: p, relativeTo: rtx), let r = try? await URLSession.shared.data(from: u) {
                try? r.0.write(to: poster(job.id))
            }
            phases[job.id] = .downloading(0)
            let task = session.downloadTask(with: rtx.appendingPathComponent("offline/file/\(job.id).mp4"))
            task.taskDescription = Self.describe(job)
            task.resume()
        } catch is CancellationError {
            phases[job.id] = nil  // the app went away while the PC was making it: carries on next time
        } catch {
            phases[job.id] = .failed((error as? OfflineError)?.text ?? "Couldn't reach the PC: \(error.localizedDescription)")
        }
    }

    func isFailed(_ id: String) -> Bool { if case .failed = phases[id] { return true }; return false }

    func remove(_ id: String) {
        session.getAllTasks { tasks in tasks.filter { Self.job($0)?.id == id }.forEach { $0.cancel() } }
        try? FileManager.default.removeItem(at: file(id))
        try? FileManager.default.removeItem(at: poster(id))
        try? FileManager.default.removeItem(at: resumeData(id))
        items.removeAll { $0.id == id }
        phases[id] = nil
        forget(id)
        save()
    }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    nonisolated private static func describe(_ job: Job) -> String {
        String(data: (try? JSONEncoder().encode(job)) ?? Data(), encoding: .utf8) ?? ""
    }

    nonisolated private static func job(_ task: URLSessionTask) -> Job? {
        task.taskDescription.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Job.self, from: $0) }
    }

    // MARK: URLSessionDownloadDelegate (delegate queue is main)

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let p = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        guard let job = Self.job(downloadTask) else { return }
        MainActor.assumeIsolated { phases[job.id] = .downloading(p) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file goes away when this returns: move it first.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try? FileManager.default.moveItem(at: location, to: tmp)
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard let job = Self.job(downloadTask) else { try? FileManager.default.removeItem(at: tmp); return }
        MainActor.assumeIsolated {
            guard code == 200 || code == 206 else {
                try? FileManager.default.removeItem(at: tmp)
                phases[job.id] = .failed("The PC answered \(code).")
                return
            }
            let dest = file(job.id)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                items.removeAll { $0.id == job.id }
                items.insert(OfflineItem(id: job.id, title: job.title, subtitle: job.subtitle, duration: job.duration, bytes: size,
                                         savedAt: Date(), hasPoster: FileManager.default.fileExists(atPath: poster(job.id).path)), at: 0)
                phases[job.id] = nil
                forget(job.id)
                save()
            } catch {
                phases[job.id] = .failed("Couldn't save it: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let job = Self.job(task) else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = (error as NSError).code == NSURLErrorCancelled && resume == nil
        MainActor.assumeIsolated {
            if cancelled { return }  // removed by Luke
            if let resume {
                try? resume.write(to: resumeData(job.id))
                phases[job.id] = .failed("Paused part-way. It carries on by itself next time the app is open at home.")
            } else {
                phases[job.id] = .failed("The download stopped: \(error.localizedDescription). Try again on the home network.")
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundDone?()
            backgroundDone = nil
        }
    }
}

struct OfflineError: Error {
    let text: String
    init(_ t: String) { text = t }
}

func sizeLabel(_ bytes: Int64) -> String {
    bytes >= 1 << 30 ? String(format: "%.1f GB", Double(bytes) / Double(1 << 30)) : String(format: "%.0f MB", Double(bytes) / Double(1 << 20))
}

/// "Download" on a movie or game page (iPhone only), with its progress, or "Downloaded".
struct OfflineButton: View {
    let film: RTXFilm
    let title: String
    var subtitle: String? = nil
    @EnvironmentObject private var rtx: RTXServer
    @ObservedObject private var store = OfflineStore.shared
    @State private var confirmRemove = false

    var body: some View {
        if !Device.isTV {
            VStack(alignment: .leading, spacing: 4) {
                if store.has(film.id) {
                    Button { confirmRemove = true } label: { Label("Downloaded", systemImage: "checkmark.circle.fill") }
                        .confirmationDialog("Remove the download?", isPresented: $confirmRemove) {
                            Button("Remove from this iPhone", role: .destructive) { store.remove(film.id) }
                        }
                } else {
                    switch store.phases[film.id] {
                    case let .preparing(p):
                        Label("PC is preparing it, \(Int(p * 100))%", systemImage: "hourglass")
                    case let .downloading(p):
                        Label("Downloading, \(Int(p * 100))%", systemImage: "arrow.down.circle")
                    case let .failed(why):
                        Button { Task { await store.download(film, title: title, subtitle: subtitle, rtx: rtx.base) } } label: {
                            Label("Download again", systemImage: "arrow.down.circle")
                        }
                        Text(why).font(.caption).foregroundStyle(Theme.dim)
                    case nil:
                        Button { Task { await store.download(film, title: title, subtitle: subtitle, rtx: rtx.base) } } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                        Text("For watching with no connection: about \(estimate) on this iPhone.").font(.caption).foregroundStyle(Theme.dim)
                    }
                }
            }
            .font(.system(size: F(28), weight: .semibold))
        }
    }

    /// 4.5 Mbps video + 160 kbps audio, about 2 GB an hour.
    private var estimate: String { sizeLabel(Int64(film.duration * 4_660_000 / 8)) }
}

extension View {
    /// iPhone list rows with two buttons: each keeps its own tap (a plain list row fires every button in it).
    @ViewBuilder func phoneBorderless() -> some View {
        #if os(iOS)
        buttonStyle(.borderless)
        #else
        self
        #endif
    }
}

/// An episode row's download control (iPhone): an arrow to start, the PC's and the phone's progress while it
/// comes, a check once it's here (press again to remove). Same copies as OfflineButton.
struct OfflineIcon: View {
    let film: RTXFilm
    let title: String
    var subtitle: String? = nil
    @EnvironmentObject private var rtx: RTXServer
    @ObservedObject private var store = OfflineStore.shared
    @State private var confirmRemove = false

    var body: some View {
        if !Device.isTV {
            Group {
                if store.has(film.id) {
                    Button { confirmRemove = true } label: { Image(systemName: "checkmark.circle.fill") }
                        .accessibilityLabel("Downloaded: \(title)")
                        .confirmationDialog("Remove the download?", isPresented: $confirmRemove) {
                            Button("Remove from this iPhone", role: .destructive) { store.remove(film.id) }
                        }
                } else {
                    switch store.phases[film.id] {
                    case let .preparing(p), let .downloading(p):
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.2), lineWidth: 3)
                            Circle().trim(from: 0, to: max(0.05, p)).stroke(Theme.accent, lineWidth: 3).rotationEffect(.degrees(-90))
                        }
                        .frame(width: 22, height: 22)
                        .accessibilityLabel("Downloading \(title), \(Int(p * 100))%")
                    default:
                        Button { Task { await store.download(film, title: title, subtitle: subtitle, rtx: rtx.base) } } label: {
                            Image(systemName: "arrow.down.circle")
                        }
                        .accessibilityLabel("Download \(title)")
                    }
                }
            }
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .buttonStyle(.borderless)  // its own tap inside a list row that plays
            .frame(width: 44, height: 44)
        }
    }
}

#if os(iOS)
/// What's on this iPhone to watch with no connection.
struct OfflineView: View {
    var offlineBanner = false
    var retry: (() -> Void)? = nil
    @ObservedObject private var store = OfflineStore.shared
    @State private var playing: PlayRequest?

    var body: some View {
        List {
            if offlineBanner {
                Section {
                    Text("Can't reach home right now. Here's what's downloaded on this iPhone.")
                    if let retry { Button("Try again", action: retry) }
                }
            }
            if store.items.isEmpty {
                Text("Nothing downloaded yet. On a movie or game page at home, tap Download.").foregroundStyle(.secondary)
            }
            ForEach(store.items) { item in
                Button { playing = PlayRequest(local: store.file(item.id), item: item) } label: {
                    HStack(spacing: 14) {
                        Group {
                            if item.hasPoster, let img = UIImage(contentsOfFile: store.poster(item.id).path) {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                Color.white.opacity(0.1).overlay(Image(systemName: "film"))
                            }
                        }
                        .frame(width: 60, height: 90).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            Text([item.subtitle, sizeLabel(item.bytes), Resume.position(item.id).map { "left at \(Resume.label($0))" }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions { Button("Remove", role: .destructive) { store.remove(item.id) } }
            }
            if !store.items.isEmpty {
                Text("\(sizeLabel(store.totalBytes)) on this iPhone. Swipe left to remove one.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Downloaded")
        .fullScreenCover(item: $playing) { PlayerScreen(request: $0) }
    }
}
#endif
