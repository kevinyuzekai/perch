import AppKit

/// 暂存区实现：把文件物理复制到
/// ~/Library/Application Support/Perch/Staging/<uuid>/<原文件名>，
/// 到期由 1 秒定时器清理并通知 UI。
public final class StagingStore: StagingService {
    private let settings: SettingsStoreProtocol
    private let rootURL: URL
    private let lock = NSLock()
    private var items: [StagedFile] = []
    private var timer: Timer?
    private var tickCount: UInt64 = 0

    public var onChange: (() -> Void)?

    public init(settings: SettingsStoreProtocol, rootURL: URL? = nil) {
        self.settings = settings
        let root = rootURL ?? Self.defaultRootURL()
        self.rootURL = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        purgeLeftovers()
        startTimer()
    }

    deinit {
        timer?.invalidate()
    }

    public static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Perch", isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
    }

    public var files: [StagedFile] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    // MARK: - StagingService

    @discardableResult
    public func stage(_ urls: [URL]) throws -> [StagedFile] {
        guard !urls.isEmpty else { return [] }
        let ttl = max(30, settings.stagingTTL)
        let now = Date()
        let expiry = now.addingTimeInterval(ttl)
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var created: [StagedFile] = []
        for source in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { continue }
            let id = UUID()
            let dir = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = Self.uniqueDestination(in: dir, name: source.lastPathComponent)
            do {
                try fm.copyItem(at: source, to: destination)
            } catch {
                try? fm.removeItem(at: dir)
                throw error
            }
            created.append(StagedFile(id: id, url: destination, originalURL: source, addedAt: now, expiresAt: expiry))
        }

        guard !created.isEmpty else { return [] }
        lock.lock()
        items.append(contentsOf: created)
        items.sort { $0.addedAt < $1.addedAt }
        lock.unlock()
        notify()
        return created
    }

    public func remove(id: UUID) throws {
        lock.lock()
        let item = items.first(where: { $0.id == id })
        lock.unlock()
        guard let item else { return }
        let dir = item.url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        lock.lock()
        items.removeAll { $0.id == id }
        lock.unlock()
        notify()
    }

    public func clear() throws {
        lock.lock()
        let snapshot = items
        items.removeAll()
        lock.unlock()
        let fm = FileManager.default
        for item in snapshot {
            let dir = item.url.deletingLastPathComponent()
            if fm.fileExists(atPath: dir.path) { try? fm.removeItem(at: dir) }
        }
        purgeLeftovers()
        notify()
    }

    public func itemProvider(for id: UUID) -> NSItemProvider? {
        guard let item = files.first(where: { $0.id == id }) else { return nil }
        guard FileManager.default.fileExists(atPath: item.url.path) else { return nil }
        return NSItemProvider(contentsOf: item.url)
    }

    public func revealInFinder(id: UUID) {
        guard let item = files.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - Lifecycle

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        tickCount &+= 1
        let now = Date()
        var expired = false
        lock.lock()
        let dead = items.filter { $0.expiresAt <= now }
        if !dead.isEmpty {
            items.removeAll { $0.expiresAt <= now }
            expired = true
        }
        var current: [StagedFile] = []
        if !expired && tickCount % 1 == 0 { current = items }
        lock.unlock()

        if expired {
            let fm = FileManager.default
            for item in dead {
                let dir = item.url.deletingLastPathComponent()
                if fm.fileExists(atPath: dir.path) { try? fm.removeItem(at: dir) }
            }
        }
        if expired || !current.isEmpty { notify() }
    }

    private func notify() {
        if Thread.isMainThread {
            onChange?()
        } else {
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
    }

    private func purgeLeftovers() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
    }

    private static func uniqueDestination(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }

        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var index = 2
        while true {
            let fileName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = dir.appendingPathComponent(fileName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
