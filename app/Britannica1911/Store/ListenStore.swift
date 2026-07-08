import Foundation
import Combine
import AVFoundation

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

/// Owns the Listen playlist and a simple AVAudioPlayer-backed media player, and
/// drives on-device text-to-speech synthesis through the OpenAI API.
@MainActor
final class ListenStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var tracks: [AudioTrack] = []
    @Published private(set) var currentTrackID: UUID?
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    private let tracksKey = "listenTracks"

    override init() {
        super.init()
        loadTracks()
    }

    var currentTrack: AudioTrack? { tracks.first { $0.id == currentTrackID } }

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

    // MARK: - Generation

    /// Synthesize an article to speech and add it to the playlist (newest first).
    func generate(article: Article, apiKey: String, voice: TTSVoice) async throws -> AudioTrack {
        let text = Self.readableText(from: article)
        let data = try await OpenAITTS.synthesize(text: text, apiKey: apiKey, voice: voice.rawValue)

        let fileName = "\(UUID().uuidString).mp3"
        let fileURL = audioDir.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)

        var track = AudioTrack(articleSlug: article.slug, title: article.title,
                               fileName: fileName, voice: voice.label)
        track.duration = (try? AVAudioPlayer(contentsOf: fileURL))?.duration

        tracks.insert(track, at: 0)
        saveTracks()
        return track
    }

    /// Title followed by the body, lightly cleaned for narration.
    static func readableText(from article: Article) -> String {
        let body = article.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(article.title).\n\n\(body)"
    }

    // MARK: - Playback

    func play(_ track: AudioTrack) {
        configureSession()
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
    }

    func seek(to time: Double) {
        guard let player else { return }
        let clamped = min(max(time, 0), player.duration)
        player.currentTime = clamped
        currentTime = clamped
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
        }
    }

    private func configureSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}

/// Minimal client for OpenAI's text-to-speech endpoint. Long articles exceed the
/// per-request character limit, so the text is chunked and the mp3 responses are
/// concatenated (mp3 frames play back seamlessly when joined).
enum OpenAITTS {
    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
    private static let model = "tts-1"
    private static let maxChunk = 3800   // safely under the 4096-char API limit

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

    static func synthesize(text: String, apiKey: String, voice: String) async throws -> Data {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TTSError.missingKey }

        var audio = Data()
        for piece in chunk(text, max: maxChunk) {
            audio.append(try await request(piece, apiKey: key, voice: voice))
        }
        guard !audio.isEmpty else { throw TTSError.empty }
        return audio
    }

    private static func request(_ input: String, apiKey: String, voice: String) async throws -> Data {
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

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw TTSError.empty }
        guard (200..<300).contains(http.statusCode) else {
            throw TTSError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Pull `error.message` out of an OpenAI JSON error body, if present.
    private static func friendlyMessage(from body: String) -> String {
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
