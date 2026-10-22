import Foundation
import Observation
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/** A film or episode saved on the device, or on its way. */
struct DownloadItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case film, episode }
    enum State: String, Codable { case queued, downloading, paused, done, failed }

    /** The provider's id and the item's progress key: "2aaa825fbcf4|movie/123.mkv". */
    var id: String
    var providerId: String
    /** The stream's address. It carries the login, so it never leaves the device. */
    var url: String
    /** The film's or episode's own id, for playing it from Downloads. */
    var itemId: String?
    var kind: Kind
    var title: String
    /** The series, for an episode. */
    var show: String?
    var seriesId: String?
    var art: String?
    var state: State = .queued
    var received: Int64 = 0
    var total: Int64 = 0
    /** Why it failed, readable. */
    var message: String?
    var added: Double

    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    /** The file it's saved in, inside the downloads folder: the id with only safe characters. */
    var fileName: String {
        let ext = URL(string: url)?.pathExtension.lowercased() ?? ""
        let safe = id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return String(safe) + (ext.isEmpty ? "" : ".\(ext)")
    }
}

/** When downloads run. Overnight by default, so they never compete with watching. */
struct DownloadSettings: Codable, Equatable {
    var overnight = true
    var startHour = 1
    var endHour = 7
    var wifiOnly = true
    var deleteWatched = false
}

/**
 * Downloads, for watching without a connection: one at a time, through a background URL session
 * that carries on while telly is closed (iPad) or in the background (Mac).
 *
 * - **When:** straight away, or only in the overnight window. On iPad, iOS is asked to wake telly in
 *   the window (it chooses the exact time, usually on Wi-Fi, often while charging); once a download
 *   is handed to iOS it finishes even with the iPad locked, and each finished one wakes telly to
 *   start the next. On a Mac, telly has to be running, and keeps the Mac awake while downloading.
 * - **Never while watching:** playing anything pauses the download, and leaving the player resumes it,
 *   so the two never compete for the provider's connection (many allow only one).
 * - **Files** stay in telly's own folder, out of backups (iCloud included), readable once the iPad
 *   has been unlocked since starting (so they can be written while it's locked overnight).
 */
@MainActor
@Observable
final class Downloads {
    static let shared = Downloads()
    static let sessionId = "io.github.tellyteam.telly.downloads"
    static let wakeTaskId = "io.github.tellyteam.telly.downloads.overnight"

    private(set) var items: [DownloadItem] = []
    var settings = DownloadSettings() { didSet { guard started else { return }; saveSettings(); reschedule(); pump() } }
    /** "Start now": downloads run outside the window until the queue is empty. */
    private(set) var startedNow = false
    /** Set while something plays; downloads wait. */
    var watching = false { didSet { guard started else { return }; watching ? pauseCurrent(to: .queued) : pump() } }

    @ObservationIgnored private var session: URLSession!
    /** Set once [init] is done. (@Observable runs didSet even in init, before the session exists,
     *  and on iPad before the overnight task is registered, which iOS treats as a crash.) */
    @ObservationIgnored private var started = false
    @ObservationIgnored private let delegate = SessionDelegate()
    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var awake: NSObjectProtocol?
    /** iOS's completion handler for background session events, called once they're handled. */
    @ObservationIgnored var backgroundEventsDone: (() -> Void)?

    nonisolated static var folder: URL {
        let dir = Device.dataDirectory.appendingPathComponent("downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = dir
            try? url.setResourceValues(values)
            #if os(iOS)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
            #endif
        }
        return dir
    }

    private init() {
        items = Store.read("downloads", as: [DownloadItem].self) ?? []
        settings = Store.read("download-settings", as: DownloadSettings.self) ?? DownloadSettings()
        // A download that was running when telly last stopped carries on from where iOS has it.
        for i in items.indices where items[i].state == .downloading { items[i].state = .queued }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 1
        delegate.owner = self
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        // Reconnect to a download the system kept going while telly wasn't running.
        session.getAllTasks { tasks in
            Task { @MainActor in self.adopt(tasks.compactMap { $0 as? URLSessionDownloadTask }) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { Downloads.shared.tick() }
        }
        started = true
    }

    // MARK: What's downloaded

    func item(_ providerId: String?, _ url: String) -> DownloadItem? {
        guard let providerId else { return nil }
        let id = "\(providerId)|\(Playback.progressKey(url))"
        return items.first { $0.id == id }
    }

    func items(for providerId: String?) -> [DownloadItem] { items.filter { $0.providerId == providerId } }

    /** The saved file for [url], if it's fully downloaded. */
    func localURL(_ providerId: String?, _ url: String) -> URL? {
        guard let item = item(providerId, url), item.state == .done else { return nil }
        let file = Self.folder.appendingPathComponent(item.fileName)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /** Only files can be downloaded: HLS streams are made of many small pieces. */
    static func canDownload(_ url: String) -> Bool {
        guard let u = URL(string: url), u.scheme == "http" || u.scheme == "https" else { return false }
        return !["m3u8", "m3u"].contains(u.pathExtension.lowercased())
    }

    var usedBytes: Int64 {
        items.filter { $0.state == .done }.reduce(0) { $0 + $1.total }
    }

    var freeBytes: Int64? {
        let values = try? Self.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Changing the queue

    func add(providerId: String, _ c: Channel, kind: DownloadItem.Kind, show: String? = nil, seriesId: String? = nil, art: String? = nil) {
        guard Self.canDownload(c.url), item(providerId, c.url) == nil else { return }
        items.append(DownloadItem(id: "\(providerId)|\(Playback.progressKey(c.url))", providerId: providerId, url: c.url, itemId: c.id, kind: kind,
                                  title: c.name, show: show, seriesId: seriesId, art: c.logo ?? art,
                                  added: (Date().timeIntervalSince1970 * 1000).rounded()))
        save()
        reschedule()
        pump()
    }

    func remove(_ id: String) {
        if task?.taskDescription == id { task?.cancel(); task = nil }
        if let item = items.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(item.fileName))
        }
        try? FileManager.default.removeItem(at: resumeFile(id))
        items.removeAll { $0.id == id }
        save()
        pump()
    }

    /** Everything for a provider that's been removed. */
    func removeAll(providerId: String) {
        for item in items where item.providerId == providerId { remove(item.id) }
    }

    func pause(_ id: String) {
        if task?.taskDescription == id { pauseCurrent(to: .paused) } else { set(id) { $0.state = .paused } }
    }

    func resume(_ id: String) {
        set(id) { $0.state = .queued; $0.message = nil }
        pump()
    }

    /** Starts the queue outside the overnight window, until it's empty. */
    func startNow() {
        startedNow = true
        pump()
    }

    /** Once watched to the end, an episode's download goes (if that's what the user chose). */
    func watched(_ providerId: String?, _ url: String) {
        guard settings.deleteWatched, let item = item(providerId, url), item.kind == .episode, item.state == .done else { return }
        remove(item.id)
    }

    // MARK: Running

    /** Whether it's download time: always, or in the overnight window, or "Start now". */
    func inWindow(_ date: Date = Date()) -> Bool {
        if !settings.overnight || startedNow { return true }
        let hour = Calendar.current.component(.hour, from: date)
        let (start, end) = (settings.startHour, settings.endHour)
        return start <= end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }

    /** Starts the next download if it's time and nothing else is running. */
    func pump() {
        guard task == nil, !watching, inWindow() else { return }
        guard let next = items.first(where: { $0.state == .queued }), let url = URL(string: next.url) else {
            if startedNow && !items.contains(where: { $0.state == .queued }) { startedNow = false }
            keepAwake(false)
            return
        }
        let t: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeFile(next.id)) {
            t = session.downloadTask(withResumeData: data)
            try? FileManager.default.removeItem(at: resumeFile(next.id))
        } else {
            var r = URLRequest(url: url)
            r.setValue("\(Device.userAgent)/1", forHTTPHeaderField: "User-Agent")
            r.allowsCellularAccess = !settings.wifiOnly
            r.allowsExpensiveNetworkAccess = !settings.wifiOnly
            t = session.downloadTask(with: r)
        }
        t.taskDescription = next.id
        task = t
        set(next.id) { $0.state = .downloading; $0.message = nil }
        keepAwake(true)
        t.resume()
    }

    /** Stops the running download, keeping what's been received to carry on later. */
    private func pauseCurrent(to state: DownloadItem.State) {
        guard let t = task, let id = t.taskDescription else { return }
        task = nil
        set(id) { $0.state = state }
        t.cancel { [resume = resumeFile(id)] data in
            if let data { try? data.write(to: resume) }
        }
        keepAwake(false)
    }

    /** Once a minute: start at the window's opening, pause at its close. */
    private func tick() {
        if inWindow() { pump() } else if task != nil { pauseCurrent(to: .queued) }
    }

    /** A download the system kept going while telly was closed. */
    private func adopt(_ tasks: [URLSessionDownloadTask]) {
        for t in tasks {
            guard let id = t.taskDescription, items.contains(where: { $0.id == id }), task == nil, t.state == .running else { t.cancel(); continue }
            task = t
            set(id) { $0.state = .downloading }
        }
        pump()
    }

    // MARK: From the session

    fileprivate func progressed(_ id: String, received: Int64, total: Int64) {
        set(id) { $0.received = received; if total > 0 { $0.total = total } }
    }

    fileprivate func finished(_ id: String, error: String?, status: Int?) {
        if task?.taskDescription == id { task = nil }
        if let status, !(200..<300).contains(status) {
            set(id) { $0.state = .failed; $0.message = PlayerController.explain(status) }
        } else if let error {
            // A pause keeps its state (paused or queued for later); anything else failed.
            set(id) { if $0.state == .downloading { $0.state = .failed; $0.message = error } }
        } else {
            set(id) { $0.state = .done; $0.received = max($0.received, $0.total); if $0.total == 0 { $0.total = $0.received } }
        }
        reschedule()
        pump()
    }

    fileprivate func eventsHandled() {
        backgroundEventsDone?()
        backgroundEventsDone = nil
    }

    // MARK: Waking overnight (iPad)

    /** Asks iOS to wake telly in the next overnight window while anything is waiting. */
    func reschedule() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.wakeTaskId)
        guard settings.overnight, items.contains(where: { $0.state == .queued }) else { return }
        let request = BGProcessingTaskRequest(identifier: Self.wakeTaskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = nextWindowStart()
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    /** The next time the overnight window opens (now, if it's open). */
    func nextWindowStart(after now: Date = Date()) -> Date {
        if inWindow(now) { return now }
        let cal = Calendar.current
        var start = cal.date(bySettingHour: settings.startHour, minute: 0, second: 0, of: now) ?? now
        if start <= now { start = cal.date(byAdding: .day, value: 1, to: start) ?? start }
        return start
    }

    #if os(iOS)
    /** Registered at launch: iOS's overnight wake starts the queue and hands it to the system. */
    static func registerWake() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: wakeTaskId, using: nil) { task in
            Task { @MainActor in
                Downloads.shared.pump()
                Downloads.shared.reschedule()
                // The download itself carries on in iOS's own process.
                task.setTaskCompleted(success: true)
            }
        }
    }
    #endif

    // MARK: Small things

    private func set(_ id: String, _ change: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        save()
    }

    private func save() { Store.write("downloads", items) }
    private func saveSettings() { Store.write("download-settings", settings) }
    private func resumeFile(_ id: String) -> URL { Self.folder.appendingPathComponent(".resume-" + String(id.map { $0.isLetter || $0.isNumber ? $0 : "_" })) }

    /** On a Mac, the Mac stays awake while a download runs (iOS handles its own). */
    private func keepAwake(_ on: Bool) {
        #if os(macOS)
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Downloading")
        } else if !on, let token = awake {
            ProcessInfo.processInfo.endActivity(token)
            awake = nil
        }
        #endif
    }
}

/** URLSession's callbacks, which arrive off the main thread. */
private final class SessionDelegate: NSObject, URLSessionDownloadDelegate {
    weak var owner: Downloads?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in self.owner?.progressed(id, received: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns, so it's moved now, before hopping to the main thread.
        guard let id = downloadTask.taskDescription,
              let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return }
        let items = Store.read("downloads", as: [DownloadItem].self) ?? []
        guard let item = items.first(where: { $0.id == id }) else { return }
        let target = Downloads.folder.appendingPathComponent(item.fileName)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: location, to: target)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let message: String? = error.map { e in
            (e as NSError).code == NSURLErrorCancelled ? "Paused" : "The download stopped: \(e.localizedDescription)"
        }
        if let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            let resume = Downloads.folder.appendingPathComponent(".resume-" + String(id.map { $0.isLetter || $0.isNumber ? $0 : "_" }))
            try? data.write(to: resume)
        }
        Task { @MainActor in self.owner?.finished(id, error: message, status: error == nil ? status : nil) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.owner?.eventsHandled() }
    }
}
