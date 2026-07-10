import Foundation
import Combine
import AVFoundation
import MediaPlayer

/// A generated audio version of an article, stored on disk under
/// Documents/ListenAudio. Metadata persists; the mp3 file lives beside it.
struct AudioTrack: Codable, Identifiable, Hashable {
    let id: UUID
    let articleSlug: String
    let title: String
    let fileName: String
    let voice: String
    let createdAt: Date
    var duration: Double?

    init(id: UUID = UUID(), articleSlug: String, title: String,
         fileName: String, voice: String, createdAt: Date = Date(), duration: Double? = nil) {
        self.id = id
        self.articleSlug = articleSlug
        self.title = title
        self.fileName = fileName
        self.voice = voice
        self.createdAt = createdAt
        self.duration = duration
    }
}

/// One line in the OpenAI TTS debug log (a request note or a response result).
struct TTSLogEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let message: String
    let isError: Bool

    init(id: UUID = UUID(), date: Date = Date(), message: String, isError: Bool) {
        self.id = id
        self.date = date
        self.message = message
        self.isError = isError
    }
}

/// Owns the Listen playlist and a simple AVAudioPlayer-backed media player, and
/// drives on-device text-to-speech synthesis through the OpenAI API.
@MainActor
final class ListenStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var tracks: [AudioTrack] = []
    @Published private(set) var currentTrackID: UUID?
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    /// A rolling record of OpenAI TTS requests/responses, surfaced in Settings
    /// for debugging (most recent first).
    @Published private(set) var debugLog: [TTSLogEntry] = []

    /// Progress of an in-flight audio generation, or `nil` when idle. Observed by
    /// the article's Listen control and the Listen pane.
    @Published private(set) var generation: GenerationProgress?

    /// Live progress for the article currently being synthesized.
    struct GenerationProgress: Equatable {
        let articleSlug: String
        let title: String
        let total: Int          // number of chunks
        var completed: Int      // chunks finished
        var fraction: Double { total > 0 ? min(Double(completed) / Double(total), 1) : 0 }
    }

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var remoteCommandsConfigured = false
    private let defaults = UserDefaults.standard
    private let tracksKey = "listenTracks"
    private let logKey = "listenDebugLog"
    private let maxLog = 200

    override init() {
        super.init()
        loadTracks()
        loadLog()
    }

    var currentTrack: AudioTrack? { tracks.first { $0.id == currentTrackID } }

    /// The most recently generated recording for a given article, if any.
    func track(forArticle slug: String) -> AudioTrack? {
        tracks.first { $0.articleSlug == slug }
    }

    // MARK: - Storage

    private var audioDir: URL {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ListenAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func url(for track: AudioTrack) -> URL { audioDir.appendingPathComponent(track.fileName) }

    private func loadTracks() {
        guard let data = defaults.data(forKey: tracksKey),
              let saved = try? JSONDecoder().decode([AudioTrack].self, from: data) else { return }
        // Drop entries whose audio file has gone missing.
        tracks = saved.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func saveTracks() {
        if let data = try? JSONEncoder().encode(tracks) {
            defaults.set(data, forKey: tracksKey)
        }
    }

    // MARK: - Debug log

    func appendLog(_ message: String, isError: Bool) {
        debugLog.insert(TTSLogEntry(message: message, isError: isError), at: 0)
        if debugLog.count > maxLog { debugLog.removeLast(debugLog.count - maxLog) }
        saveLog()
    }

    func clearLog() {
        debugLog = []
        defaults.removeObject(forKey: logKey)
    }

    private func loadLog() {
        if let data = defaults.data(forKey: logKey),
           let saved = try? JSONDecoder().decode([TTSLogEntry].self, from: data) {
            debugLog = saved
        }
    }

    private func saveLog() {
        if let data = try? JSONEncoder().encode(debugLog) {
            defaults.set(data, forKey: logKey)
        }
    }

    // MARK: - Generation

    /// Synthesize an article to speech and add it to the playlist (newest first),
    /// publishing per-chunk progress and logging each request/response. Long
    /// articles are split into several requests whose mp3 responses are stitched
    /// together; each request is retried a few times on transient failures.
    func generate(article: Article, apiKey: String, voice: TTSVoice) async throws -> AudioTrack {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            appendLog("No API key set.", isError: true)
            throw OpenAITTS.TTSError.missingKey
        }

        let text = Self.readableText(from: article)
        let chunks = OpenAITTS.chunk(text, max: OpenAITTS.maxChunk)
        let estimate = OpenAITTS.currencyString(OpenAITTS.estimatedCost(forCharacters: text.count))
        appendLog("→ “\(article.title)” · voice \(voice.rawValue) · \(text.count) chars · \(chunks.count) chunk(s) · est. \(estimate)",
                  isError: false)

        generation = GenerationProgress(articleSlug: article.slug, title: article.title,
                                        total: chunks.count, completed: 0)
        defer { generation = nil }

        var audio = Data()
        for (index, piece) in chunks.enumerated() {
            let data = try await synthesizeChunk(piece, key: key, voice: voice.rawValue,
                                                 index: index, total: chunks.count)
            audio.append(data)
            generation?.completed = index + 1
        }
        guard !audio.isEmpty else {
            appendLog("✗ Empty audio response.", isError: true)
            throw OpenAITTS.TTSError.empty
        }

        let fileName = "\(UUID().uuidString).mp3"
        let fileURL = audioDir.appendingPathComponent(fileName)
        try audio.write(to: fileURL, options: .atomic)

        var track = AudioTrack(articleSlug: article.slug, title: article.title,
                               fileName: fileName, voice: voice.label)
        track.duration = (try? AVAudioPlayer(contentsOf: fileURL))?.duration

        tracks.insert(track, at: 0)
        saveTracks()
        appendLog("✓ Saved \(Self.byteString(audio.count)) · \(chunks.count) clip(s) stitched.", isError: false)
        return track
    }

    /// One chunk, retried a few times on timeouts / 5xx / rate limits. Client
    /// errors (bad key, malformed request) fail immediately.
    private func synthesizeChunk(_ piece: String, key: String, voice: String,
                                 index: Int, total: Int) async throws -> Data {
        let maxAttempts = 3
        var lastError: Error = OpenAITTS.TTSError.empty

        for attempt in 1...maxAttempts {
            do {
                let (data, status) = try await OpenAITTS.requestSpeech(piece, apiKey: key, voice: voice)
                let note = attempt > 1 ? " (attempt \(attempt))" : ""
                appendLog("✓ Chunk \(index + 1)/\(total): HTTP \(status), \(Self.byteString(data.count))\(note)",
                          isError: false)
                return data
            } catch {
                lastError = error
                // Don't retry on client errors other than rate limiting.
                if case let OpenAITTS.TTSError.http(status, body) = error,
                   status != 429, (400..<500).contains(status) {
                    appendLog("✗ Chunk \(index + 1)/\(total): HTTP \(status) — \(body)", isError: true)
                    throw error
                }
                appendLog("⟳ Chunk \(index + 1)/\(total): \(Self.reason(for: error)) — attempt \(attempt)/\(maxAttempts)",
                          isError: true)
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)  // 1.5s, 3s backoff
                }
            }
        }
        throw lastError
    }

    private static func reason(for error: Error) -> String {
        if case let OpenAITTS.TTSError.http(status, _) = error { return "HTTP \(status)" }
        return error.localizedDescription
    }

    private static func byteString(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        return kb >= 1024 ? String(format: "%.1f MB", kb / 1024) : String(format: "%.0f KB", kb)
    }

    /// Title followed by the body, lightly cleaned for narration.
    static func readableText(from article: Article) -> String {
        let body = article.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(article.title).\n\n\(body)"
    }

    // MARK: - Playback

    func play(_ track: AudioTrack) {
        configureSession()
        configureRemoteCommandsIfNeeded()
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url(for: track))
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            player = newPlayer
            duration = newPlayer.duration
            currentTime = 0
            currentTrackID = track.id
            newPlayer.play()
            isPlaying = true
            startTimer()
            updateNowPlaying()
        } catch {
            isPlaying = false
        }
    }

    func togglePlayPause() {
        guard let player else {
            if let track = currentTrack ?? tracks.first { play(track) }
            return
        }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            configureSession()
            player.play()
            isPlaying = true
            startTimer()
        }
        updateNowPlaying()
    }

    func seek(to time: Double) {
        guard let player else { return }
        let clamped = min(max(time, 0), player.duration)
        player.currentTime = clamped
        currentTime = clamped
        updateNowPlaying()
    }

    func next() { advance(by: 1) }
    func previous() { advance(by: -1) }

    private func advance(by offset: Int) {
        guard let id = currentTrackID,
              let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard tracks.indices.contains(target) else { return }
        play(tracks[target])
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        stopTimer()
        currentTime = 0
        duration = 0
        currentTrackID = nil
        updateNowPlaying()
        deactivateSession()
    }

    // MARK: - Removal

    func remove(_ track: AudioTrack) {
        if currentTrackID == track.id { stop() }
        try? FileManager.default.removeItem(at: url(for: track))
        tracks.removeAll { $0.id == track.id }
        saveTracks()
    }

    func remove(atOffsets offsets: IndexSet) {
        for track in offsets.map({ tracks[$0] }) { remove(track) }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        if let player, player.isPlaying { currentTime = player.currentTime }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.handleFinish() }
    }

    private func handleFinish() {
        currentTime = duration
        isPlaying = false
        stopTimer()
        // Auto-advance to the next item in the playlist, if any.
        if let id = currentTrackID,
           let index = tracks.firstIndex(where: { $0.id == id }),
           tracks.indices.contains(index + 1) {
            play(tracks[index + 1])
        } else {
            updateNowPlaying()
        }
    }

    // MARK: - Session

    private func configureSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - Now Playing & remote controls (lock screen / Control Center)

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            return
        }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: "1911 Britannica · \(track.voice)",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime ?? currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        center.nowPlayingInfo = info
    }

    private func configureRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPlaying else { return }
                self.togglePlayPause()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.togglePlayPause()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }
}

/// Minimal client for OpenAI's text-to-speech endpoint. Long articles exceed the
/// per-request character limit, so the text is chunked and the mp3 responses are
/// concatenated (mp3 frames play back seamlessly when joined).
enum OpenAITTS {
    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
    static let model = "tts-1"
    // Smaller chunks keep each request well under the request timeout and give
    // finer-grained progress; the limit is 4096 characters.
    static let maxChunk = 2400
    /// OpenAI `tts-1` list price, USD per 1,000,000 input characters.
    static let pricePerMillionCharacters = 15.0

    /// A session with generous timeouts — TTS of a full chunk can take a while,
    /// and the default 60s request timeout trips on longer inputs.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    /// Estimated USD cost of synthesizing `count` characters with `tts-1`.
    static func estimatedCost(forCharacters count: Int) -> Double {
        Double(count) / 1_000_000 * pricePerMillionCharacters
    }

    /// Format a USD amount, keeping extra precision for sub-cent estimates.
    static func currencyString(_ value: Double) -> String {
        value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }

    enum TTSError: LocalizedError {
        case missingKey
        case http(Int, String)
        case empty

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "No OpenAI API key set. Add one in Settings › Listen."
            case .empty:
                return "OpenAI returned an empty audio response."
            case .http(let code, let message):
                let detail = OpenAITTS.friendlyMessage(from: message)
                return "OpenAI request failed (\(code))." + (detail.isEmpty ? "" : " \(detail)")
            }
        }
    }

    /// One request for a single chunk of text. Returns the mp3 data and the HTTP
    /// status code; throws `TTSError.http` with the response body on failure.
    static func requestSpeech(_ input: String, apiKey: String, voice: String) async throws -> (data: Data, status: Int) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": input,
            "voice": voice,
            "response_format": "mp3",
        ])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw TTSError.empty }
        guard (200..<300).contains(http.statusCode) else {
            throw TTSError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http.statusCode)
    }

    /// Pull `error.message` out of an OpenAI JSON error body, if present.
    static func friendlyMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return String(body.prefix(140))
        }
        return message
    }

    // MARK: - Chunking

    /// Split text into pieces no longer than `max` characters, preferring to
    /// break on sentence and paragraph boundaries.
    static func chunk(_ text: String, max: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > max else { return [trimmed] }

        var chunks: [String] = []
        var current = ""

        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            current = ""
        }

        for unit in sentenceUnits(trimmed) {
            if unit.count > max {
                // A single sentence longer than the limit: hard-split it.
                flush()
                var start = unit.startIndex
                while start < unit.endIndex {
                    let end = unit.index(start, offsetBy: max, limitedBy: unit.endIndex) ?? unit.endIndex
                    chunks.append(String(unit[start..<end]))
                    start = end
                }
            } else if current.count + unit.count + 1 > max {
                flush()
                current = unit
            } else {
                current += current.isEmpty ? unit : " " + unit
            }
        }
        flush()
        return chunks
    }

    private static func sentenceUnits(_ text: String) -> [String] {
        var units: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let unit = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !unit.isEmpty { units.append(unit) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { units.append(tail) }
        return units
    }
}
