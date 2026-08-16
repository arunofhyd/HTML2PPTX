import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

// MARK: - App Constants
let appVersion = "1.0.0"
let updateCheckURL = "https://raw.githubusercontent.com/arunofhyd/HTML2PPTX/main/version.json"
let githubRepoURL = "https://github.com/arunofhyd/HTML2PPTX"

// MARK: - App Delegate & Entry Point
@main
struct HTMLToPPTXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = ConverterViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 650, maxWidth: 720, minHeight: 560, maxHeight: 640)
                .background(VisualEffectBackground())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open HTML Presentation…") { model.selectFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !urls.isEmpty {
            NotificationCenter.default.post(name: NSNotification.Name("OpenFilesNotification"), object: urls)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Hardware Inspection & Adaptive Concurrency
struct HardwareProfile {
    static func determineOptimalConcurrency() -> (concurrency: Int, description: String) {
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let ramBytes = ProcessInfo.processInfo.physicalMemory
        let ramGB = Double(ramBytes) / (1024 * 1024 * 1024)
        let thermalState = ProcessInfo.processInfo.thermalState

        if thermalState == .critical {
            return (1, "1 engine (Critical Thermal Protection Active)")
        }

        if ramGB < 8.0 || cpuCount <= 4 {
            return (1, "Single engine mode (\(cpuCount) cores, \(Int(ramGB))GB RAM)")
        } else if ramGB <= 16.0 || cpuCount <= 8 {
            return (2, "Dual parallel engines (\(cpuCount) cores, \(Int(ramGB))GB RAM)")
        } else {
            return (3, "3 parallel engines (\(cpuCount) cores, \(Int(ramGB))GB RAM)")
        }
    }
}

// MARK: - Format Helpers
func formatFileSize(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / (1024 * 1024)
    if mb >= 1.0 {
        return String(format: "%.1f MB", mb)
    } else {
        let kb = Double(bytes) / 1024
        return String(format: "%.0f KB", kb)
    }
}

func formatElapsedTime(_ interval: TimeInterval) -> String {
    let totalSecs = Int(interval)
    if totalSecs < 60 {
        return "\(totalSecs)s"
    } else {
        let mins = totalSecs / 60
        let secs = totalSecs % 60
        return "\(mins)m \(secs)s"
    }
}

// MARK: - View Model
@MainActor
class ConverterViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case processing
        case completed(outputURLs: [URL], totalSlides: Int, elapsedTime: TimeInterval, totalSizeBytes: UInt64)
        case error(message: String)
    }

    @Published var state: State = .idle
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = "Drag & drop an HTML presentation file or folder"
    @Published var subStatus: String = "Ready to convert into crisp 4K PowerPoint"
    @Published var logs: [String] = []
    @Published var isHoveringDropZone: Bool = false
    @Published var currentFileName: String = ""
    @Published var elapsedTime: TimeInterval = 0
    @Published var completedFileCount: Int = 0
    @Published var totalFileCount: Int = 0

    // Update Checker State
    @Published var updateStatus: String? = nil
    @Published var isCheckingForUpdates: Bool = false
    @Published var newerVersionAvailable: Bool = false
    @Published var latestVersionNumber: String? = nil
    @Published var latestChangelog: String = ""
    @Published var latestDownloadURL: String = githubRepoURL

    private var timerTask: Task<Void, Never>?

    init() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OpenFilesNotification"), object: nil, queue: .main) { [weak self] notif in
            if let urls = notif.object as? [URL], !urls.isEmpty {
                Task { @MainActor in
                    self?.startBatchConversion(for: urls)
                }
            }
        }
    }

    func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.html, UTType.folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Convert to PPTX"
        panel.message = "Choose HTML presentation file(s) or folder(s) to convert:"

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            startBatchConversion(for: panel.urls)
        }
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        var droppedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    droppedURLs.append(url)
                } else if let url = item as? URL {
                    droppedURLs.append(url)
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            if !droppedURLs.isEmpty {
                self?.startBatchConversion(for: droppedURLs)
            }
        }
        return true
    }

    func startBatchConversion(for inputURLs: [URL]) {
        guard state != .processing else { return }

        var allHTMLTargets: [URL] = []
        var seenPaths: Set<String> = []

        for url in inputURLs {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                    let htmlFiles = contents.filter { $0.pathExtension.lowercased() == "html" || $0.pathExtension.lowercased() == "htm" }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    for f in htmlFiles {
                        if seenPaths.insert(f.path).inserted { allHTMLTargets.append(f) }
                    }
                } else if url.pathExtension.lowercased() == "html" || url.pathExtension.lowercased() == "htm" {
                    if seenPaths.insert(url.path).inserted { allHTMLTargets.append(url) }
                }
            }
        }

        guard !allHTMLTargets.isEmpty else {
            self.state = .error(message: "No HTML presentation files found in the dropped item(s).")
            return
        }

        self.state = .processing
        self.progress = 0.02
        self.logs.removeAll()
        self.completedFileCount = 0
        self.totalFileCount = allHTMLTargets.count
        self.elapsedTime = 0
        self.addLog("🚀 Found \(allHTMLTargets.count) HTML presentation file(s) to convert.")

        // Start elapsed time ticker
        let startDate = Date()
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self = self else { return }
                await MainActor.run {
                    self.elapsedTime = Date().timeIntervalSince(startDate)
                }
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processAllFiles(targets: allHTMLTargets, startDate: startDate)
        }
    }

    private func addLog(_ line: String) {
        logs.append(line)
    }

    private func sendNativeNotification(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = UNNotificationSound.default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func processAllFiles(targets: [URL], startDate: Date) async {
        let totalFiles = targets.count
        var createdPPTXURLs: [URL] = []
        var grandTotalSlides = 0

        let pythonBin = "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3"
        let fallbackPython = "/usr/bin/python3"
        let chosenPython = FileManager.default.fileExists(atPath: pythonBin) ? pythonBin : fallbackPython

        var scriptPath: String?
        if let bundlePath = Bundle.main.path(forResource: "converter_core", ofType: "py") {
            scriptPath = bundlePath
        } else {
            let candidate = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/converter_core.py").path
            if FileManager.default.fileExists(atPath: candidate) {
                scriptPath = candidate
            }
        }

        guard let script = scriptPath, FileManager.default.fileExists(atPath: script) else {
            await MainActor.run {
                self.state = .error(message: "Converter engine script not found inside app bundle.")
                self.addLog("❌ Error: converter_core.py not found.")
                self.timerTask?.cancel()
            }
            return
        }

        let hw = HardwareProfile.determineOptimalConcurrency()
        let maxConcurrent = min(hw.concurrency, totalFiles)

        await MainActor.run {
            if totalFiles > 1 {
                self.statusMessage = maxConcurrent > 1 ? "Converting \(totalFiles) presentations (\(maxConcurrent) in parallel)..." : "Converting \(totalFiles) presentations..."
            } else {
                self.statusMessage = "Converting \(targets[0].lastPathComponent)..."
            }
            self.subStatus = hw.description
            self.addLog("💻 \(hw.description)")
            self.addLog("⚡ Launching \(maxConcurrent) simultaneous 4K worker(s)...")
        }

        let results: [(URL, URL?, Int)] = await withTaskGroup(of: (URL, URL?, Int).self, returning: [(URL, URL?, Int)].self) { group in
            var fileIterator = targets.makeIterator()
            var runningCount = 0

            while runningCount < maxConcurrent, let nextURL = fileIterator.next() {
                runningCount += 1
                group.addTask {
                    await self.convertSingleFile(targetURL: nextURL, chosenPython: chosenPython, scriptPath: script, totalFiles: totalFiles)
                }
            }

            var collectedResults: [(URL, URL?, Int)] = []

            for await result in group {
                collectedResults.append(result)

                await MainActor.run {
                    self.completedFileCount += 1
                    self.progress = max(0.05, min(0.95, Double(self.completedFileCount) / Double(totalFiles)))
                    if totalFiles > 1 {
                        self.subStatus = "Completed \(self.completedFileCount)/\(totalFiles) presentations"
                    }
                }

                if let nextURL = fileIterator.next() {
                    group.addTask {
                        await self.convertSingleFile(targetURL: nextURL, chosenPython: chosenPython, scriptPath: script, totalFiles: totalFiles)
                    }
                }
            }

            return collectedResults
        }

        timerTask?.cancel()
        let finalElapsed = Date().timeIntervalSince(startDate)

        for (_, outputURL, slideCount) in results {
            grandTotalSlides += slideCount
            if let out = outputURL {
                createdPPTXURLs.append(out)
            }
        }

        var totalSizeBytes: UInt64 = 0
        for url in createdPPTXURLs {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64 {
                totalSizeBytes += size
            }
        }

        await MainActor.run {
            self.elapsedTime = finalElapsed
            if !createdPPTXURLs.isEmpty {
                self.progress = 1.0
                self.state = .completed(outputURLs: createdPPTXURLs, totalSlides: grandTotalSlides, elapsedTime: finalElapsed, totalSizeBytes: totalSizeBytes)
                self.statusMessage = totalFiles > 1 ? "All \(createdPPTXURLs.count) Presentations Created!" : "PowerPoint Ready!"
                self.subStatus = createdPPTXURLs.map { $0.lastPathComponent }.joined(separator: ", ")
                self.addLog("\n🎉 All parallel conversions finished! Created \(createdPPTXURLs.count) PPTX deck(s) (\(grandTotalSlides) slides, \(formatFileSize(totalSizeBytes))) in \(formatElapsedTime(finalElapsed)).")

                let notifBody = totalFiles > 1
                    ? "\(createdPPTXURLs.count) presentations (\(grandTotalSlides) slides) in \(formatElapsedTime(finalElapsed))"
                    : "\(createdPPTXURLs[0].lastPathComponent) (\(grandTotalSlides) slides) in \(formatElapsedTime(finalElapsed))"
                self.sendNativeNotification(title: "HTML to PPTX Converter", message: notifBody)
                NSSound(named: "Glass")?.play()
            } else {
                self.state = .error(message: "Failed to create presentations. Check logs.")
                self.statusMessage = "Conversion Failed"
                self.subStatus = "Check logs below"
            }
        }
    }

    private func convertSingleFile(targetURL: URL, chosenPython: String, scriptPath: String, totalFiles: Int) async -> (URL, URL?, Int) {
        let fileName = targetURL.lastPathComponent

        await MainActor.run {
            self.addLog("\n📄 [Start] \(fileName)")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: chosenPython)
        p.arguments = [scriptPath, targetURL.path]

        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            NSHomeDirectory() + "/.nvm/versions/node/v24.18.0/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        env["PATH"] = extraPaths.joined(separator: ":") + ":" + (env["PATH"] ?? "")
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        var fileSlides = 0
        var outputPPTXPath: String?

        do {
            try p.run()

            let reader = pipe.fileHandleForReading
            for try await line in reader.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                await MainActor.run {
                    self.addLog("  [\(fileName)] \(trimmed)")

                    if trimmed.contains("Capturing") && trimmed.contains("slides") {
                        if let match = trimmed.range(of: #"\d+"#, options: .regularExpression) {
                            fileSlides = Int(trimmed[match]) ?? 0
                        }
                    } else if trimmed.contains("Slide") && trimmed.contains("captured") {
                        if let match = trimmed.range(of: #"Slide (\d+)/(\d+)"#, options: .regularExpression) {
                            let parts = String(trimmed[match]).replacingOccurrences(of: "Slide ", with: "").split(separator: "/")
                            if parts.count == 2, let current = Int(parts[0]), let total = Int(parts[1]) {
                                if totalFiles > 1 {
                                    self.statusMessage = "[\(self.completedFileCount + 1)/\(totalFiles)] \(fileName)"
                                } else {
                                    self.statusMessage = "Slide \(current) of \(total)..."
                                }
                                self.subStatus = "Capturing slide \(current)/\(total) in 4K"
                            }
                        }
                    } else if trimmed.contains(".pptx (") {
                        let pathPart = trimmed.replacingOccurrences(of: "📂 ", with: "").components(separatedBy: " (").first?.trimmingCharacters(in: .whitespaces)
                        if let pathPart = pathPart {
                            outputPPTXPath = pathPart
                        }
                    }
                }
            }

            p.waitUntilExit()

            if p.terminationStatus == 0 {
                let finalURL = outputPPTXPath != nil ? URL(fileURLWithPath: outputPPTXPath!) : targetURL.deletingPathExtension().appendingPathExtension("pptx")
                var sizeStr = ""
                if let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
                   let size = attrs[.size] as? UInt64 {
                    sizeStr = " (\(formatFileSize(size)))"
                }

                await MainActor.run {
                    self.addLog("  ✅ [Done] \(fileName) -> \(finalURL.lastPathComponent)\(sizeStr)")
                }
                return (targetURL, finalURL, fileSlides)
            } else {
                await MainActor.run {
                    self.addLog("  ❌ [Failed] \(fileName) with exit code \(p.terminationStatus)")
                }
                return (targetURL, nil, 0)
            }
        } catch {
            await MainActor.run {
                self.addLog("  ❌ [Exception] \(fileName): \(error.localizedDescription)")
            }
            return (targetURL, nil, 0)
        }
    }

    func checkForUpdates() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        updateStatus = "Checking for updates..."

        guard let url = URL(string: "\(updateCheckURL)?t=\(Int(Date().timeIntervalSince1970))") else {
            isCheckingForUpdates = false
            updateStatus = "Invalid update URL."
            return
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self = self else { return }
                self.isCheckingForUpdates = false

                if error != nil {
                    self.updateStatus = "✓ You are running the latest version (v\(appVersion))."
                    return
                }

                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let remoteVersion = json["version"] as? String else {
                    self.updateStatus = "✓ You are running the latest version (v\(appVersion))."
                    return
                }

                self.latestVersionNumber = remoteVersion
                self.latestDownloadURL = (json["downloadURL"] as? String) ?? githubRepoURL

                if let changelog = json["changelog"] as? [[String: Any]],
                   let first = changelog.first,
                   let changes = first["changes"] as? [String] {
                    self.latestChangelog = changes.map { "• \($0)" }.joined(separator: "\n")
                }

                if self.isVersion(remoteVersion, newerThan: appVersion) {
                    self.newerVersionAvailable = true
                    self.updateStatus = "New version v\(remoteVersion) is available!"
                } else {
                    self.newerVersionAvailable = false
                    self.updateStatus = "You are on the latest version (v\(appVersion))."
                }
            }
        }.resume()
    }

    private func isVersion(_ remote: String, newerThan current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }

    func reset() {
        state = .idle
        progress = 0.0
        statusMessage = "Drag & drop an HTML presentation file or folder"
        subStatus = "Ready to convert into crisp 4K PowerPoint"
        logs.removeAll()
        elapsedTime = 0
        completedFileCount = 0
        totalFileCount = 0
        timerTask?.cancel()
    }
}

// MARK: - UI Views
struct ContentView: View {
    @ObservedObject var model: ConverterViewModel
    @State private var showLogs: Bool = false
    @State private var showAbout: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor).opacity(0.96),
                    Color(nsColor: .windowBackgroundColor).opacity(0.88),
                    Color.orange.opacity(0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 20) {
                HeaderView(model: model, showAbout: $showAbout)

                DropZoneView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.state == .processing {
                    ProgressBarView(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                FooterActionView(model: model, showLogs: $showLogs)
            }
            .padding(28)
        }
        .sheet(isPresented: $showLogs) {
            LogsSheetView(logs: model.logs, isPresented: $showLogs)
        }
        .sheet(isPresented: $showAbout) {
            AboutSheetView(model: model, isPresented: $showAbout)
        }
    }
}

struct HeaderView: View {
    @ObservedObject var model: ConverterViewModel
    @Binding var showAbout: Bool

    private var logoImage: NSImage? {
        if let path = Bundle.main.path(forResource: "AppLogo", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            img.size = NSSize(width: 44, height: 44)
            return img
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 14) {
            if let logo = logoImage {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.orange, Color.red],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 42, height: 42)

                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("HTML to PPTX Converter")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)

                Text("Ultra 4K Parallel Slide Engine")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Info (i) button
            Button(action: { showAbout = true }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("About HTML to PPTX Converter & Updates")

            // Status Pill with Timer
            statusPill
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch model.state {
        case .processing:
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                Text(formatElapsedTime(model.elapsedTime))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.orange.opacity(0.12))
            .clipShape(Capsule())

        case .completed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.green)
                Text("Done")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.green.opacity(0.12))
            .clipShape(Capsule())

        case .error:
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                Text("Error")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.red.opacity(0.12))
            .clipShape(Capsule())

        default:
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text("Ready")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
        }
    }
}

struct DropZoneView: View {
    @ObservedObject var model: ConverterViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(model.isHoveringDropZone ? 0.07 : 0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            model.isHoveringDropZone ?
                                AnyShapeStyle(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing)) :
                                AnyShapeStyle(Color.primary.opacity(0.12)),
                            style: StrokeStyle(lineWidth: model.isHoveringDropZone ? 2.5 : 1.5, dash: model.isHoveringDropZone ? [] : [6, 6])
                        )
                )
                .animation(.spring(response: 0.3), value: model.isHoveringDropZone)

            VStack(spacing: 16) {
                switch model.state {
                case .idle:
                    Image(systemName: model.isHoveringDropZone ? "arrow.down.doc.fill" : "doc.badge.arrow.up")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: model.isHoveringDropZone ? [.orange, .red] : [.secondary, .secondary.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .scaleEffect(model.isHoveringDropZone ? 1.12 : 1.0)
                        .animation(.spring(response: 0.3), value: model.isHoveringDropZone)

                    VStack(spacing: 6) {
                        Text(model.statusMessage)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)

                        Text("Drop HTML files or an entire folder to batch convert simultaneously")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button(action: { model.selectFile() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                Text("Browse HTML File or Folder...")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text("⌘O")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                case .processing:
                    ProgressView()
                        .scaleEffect(1.3)
                        .padding(.bottom, 6)

                    VStack(spacing: 6) {
                        Text(model.statusMessage)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primary)

                        Text(model.subStatus)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.orange)
                    }

                case .completed(let outputURLs, let totalSlides, let elapsed, let totalSize):
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: 64, height: 64)

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.green)
                    }

                    VStack(spacing: 6) {
                        Text(outputURLs.count > 1 ? "\(outputURLs.count) Presentations Created!" : "PowerPoint Successfully Created!")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primary)

                        Text(outputURLs.map { $0.lastPathComponent }.joined(separator: ", "))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)

                        HStack(spacing: 16) {
                            Label("\(totalSlides) slides", systemImage: "rectangle.stack")
                            Label(formatFileSize(totalSize), systemImage: "doc.zipper")
                            Label(formatElapsedTime(elapsed), systemImage: "clock")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    }

                    HStack(spacing: 12) {
                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting(outputURLs)
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                Text("Reveal in Finder")
                            }
                            .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        if let firstURL = outputURLs.first {
                            Button(action: {
                                NSWorkspace.shared.open(firstURL)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "play.circle.fill")
                                    Text(outputURLs.count > 1 ? "Open First PPTX" : "Open PPTX")
                                }
                                .font(.system(size: 13, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                        }

                        Button(action: { model.reset() }) {
                            Text("Convert Another")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)

                case .error(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.red)

                    VStack(spacing: 6) {
                        Text("Conversion Error")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.red)

                        Text(message)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }

                    Button(action: { model.reset() }) {
                        Text("Try Again")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            .padding(20)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $model.isHoveringDropZone) { providers in
            model.handleDrop(providers: providers)
        }
    }
}

struct ProgressBarView: View {
    @ObservedObject var model: ConverterViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                if model.totalFileCount > 1 {
                    Text("Rendering \(model.totalFileCount) presentations in 4K")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                } else {
                    Text("Rendering 4K Retina Slides")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if model.totalFileCount > 1 {
                    Text("\(model.completedFileCount)/\(model.totalFileCount) done")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                } else {
                    Text("\(Int(model.progress * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 8)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.orange, .red],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * CGFloat(model.progress)), height: 8)
                        .animation(.spring(response: 0.4), value: model.progress)
                }
            }
            .frame(height: 8)
        }
        .padding(.horizontal, 8)
    }
}

struct FooterActionView: View {
    @ObservedObject var model: ConverterViewModel
    @Binding var showLogs: Bool

    var body: some View {
        HStack {
            Text("Drop files/folders or press ⌘O to browse")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()

            if !model.logs.isEmpty {
                Button(action: { showLogs = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal")
                        Text("Logs (\(model.logs.count))")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - High-DPI Crisp Logs Sheet
struct LogsSheetView: View {
    let logs: [String]
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Conversion Console Output", systemImage: "terminal.fill")
                    .font(.system(size: 14, weight: .bold))

                Spacer()

                Button(action: {
                    let text = logs.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy All")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)

                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(logs.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                                .foregroundColor(logColor(for: line))
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: logs.count) { _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(logs.count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .padding(22)
        .frame(minWidth: 580, minHeight: 400)
    }

    private func logColor(for line: String) -> Color {
        if line.contains("❌") { return .red }
        if line.contains("✅") || line.contains("🎉") { return .green }
        if line.contains("⚡") || line.contains("💻") { return .orange }
        return .primary
    }
}

// MARK: - About & Info Sheet View
struct AboutSheetView: View {
    @ObservedObject var model: ConverterViewModel
    @Binding var isPresented: Bool

    private var logoImage: NSImage? {
        if let path = Bundle.main.path(forResource: "AppLogo", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            img.size = NSSize(width: 64, height: 64)
            return img
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header with App Icon & Close X
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 10) {
                    if let logo = logoImage {
                        Image(nsImage: logo)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }

                    VStack(spacing: 3) {
                        Text("HTML to PPTX Converter")
                            .font(.system(size: 18, weight: .bold, design: .rounded))

                        Text("Version \(appVersion)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)

                        Text("High-Performance HTML Presentation to 4K PowerPoint Engine")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)

                // Top Right Circular Close Button
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            Divider()

            // Info Details Card
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundColor(.orange)
                        .frame(width: 16)
                    Text("Built with ❤️ by")
                        .foregroundColor(.secondary)
                    Text("Arun Thomas")
                        .fontWeight(.semibold)
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.green)
                        .frame(width: 16)
                    Text("100% On-Device")
                        .fontWeight(.semibold)
                    Text("• Zero cloud uploads")
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "cpu.fill")
                        .foregroundColor(.blue)
                        .frame(width: 16)
                    Text("Apple Silicon Multi-Engine")
                        .fontWeight(.semibold)
                    Text("• Up to 3x parallel")
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundColor(.purple)
                        .frame(width: 16)
                    Text("Open Source")
                        .fontWeight(.semibold)
                    Link("github.com/arunofhyd/HTML2PPTX", destination: URL(string: githubRepoURL)!)
                        .foregroundColor(.orange)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Update Status if present
            if let status = model.updateStatus {
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(model.newerVersionAvailable ? .orange : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            // Bottom Action Bar
            HStack {
                Button(action: { model.checkForUpdates() }) {
                    HStack(spacing: 5) {
                        if model.isCheckingForUpdates {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(model.isCheckingForUpdates ? "Checking..." : "Check for Updates")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .disabled(model.isCheckingForUpdates)

                Spacer()

                if model.newerVersionAvailable, let url = URL(string: model.latestDownloadURL) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Download Update")
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }

                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(model.newerVersionAvailable ? .secondary : .orange)
            }
        }
        .padding(22)
        .frame(width: 440, height: 380)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
