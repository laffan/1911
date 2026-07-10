import SwiftUI

/// The Listen pane: a playlist of generated article recordings above a simple
/// media player pinned to the bottom while a track is loaded.
struct ListenTab: View {
    @EnvironmentObject var listen: ListenStore

    var body: some View {
        NavigationStack {
            Group {
                if listen.tracks.isEmpty && listen.generation == nil {
                    ContentPlaceholder(
                        icon: "headphones",
                        title: "Nothing to listen to yet",
                        message: "Open an article and tap Listen to create an audio version."
                    )
                } else {
                    playlist
                }
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .safeAreaInset(edge: .top, spacing: 0) {
                if let progress = listen.generation { GeneratingBanner(progress: progress) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if listen.currentTrack != nil { NowPlayingBar() }
            }
        }
    }

    private var playlist: some View {
        List {
            ForEach(listen.tracks) { track in
                Button {
                    if listen.currentTrackID == track.id {
                        listen.togglePlayPause()
                    } else {
                        listen.play(track)
                    }
                } label: {
                    trackRow(track)
                }
                .buttonStyle(.plain)
            }
            .onDelete { listen.remove(atOffsets: $0) }
        }
    }

    private func trackRow(_ track: AudioTrack) -> some View {
        let isCurrent = listen.currentTrackID == track.id
        return HStack(spacing: 12) {
            Image(systemName: isCurrent && listen.isPlaying ? "waveform.circle.fill" : "play.circle")
                .font(.title2)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                Text(subtitle(track))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func subtitle(_ track: AudioTrack) -> String {
        var parts = [track.voice]
        if let duration = track.duration, duration > 0 {
            parts.append(TimeFormat.string(from: duration))
        }
        parts.append(track.createdAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }
}

/// A top banner shown while an article is being synthesized to audio.
struct GeneratingBanner: View {
    let progress: ListenStore.GenerationProgress

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generating “\(progress.title)”")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(progress.total > 1 ? "Clip \(min(progress.completed + 1, progress.total)) of \(progress.total)" : "Processing…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(progress.fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fraction)
                .tint(Color.accentColor)
            Divider()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(.bar)
    }
}

/// The transport controls + scrubber for the currently loaded track.
struct NowPlayingBar: View {
    @EnvironmentObject var listen: ListenStore
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            Divider()
            if let track = listen.currentTrack {
                Text(track.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Text(TimeFormat.string(from: scrubbing ? scrubValue : listen.currentTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Slider(value: sliderBinding, in: 0...max(listen.duration, 0.1)) { editing in
                    if editing { scrubValue = listen.currentTime }
                    scrubbing = editing
                    if !editing { listen.seek(to: scrubValue) }
                }

                Text(TimeFormat.string(from: listen.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 36) {
                Button { listen.previous() } label: {
                    Image(systemName: "backward.fill")
                }
                Button { listen.togglePlayPause() } label: {
                    Image(systemName: listen.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                }
                Button { listen.next() } label: {
                    Image(systemName: "forward.fill")
                }
            }
            .font(.title3)
            .foregroundStyle(Color.accentColor)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(.bar)
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { scrubbing ? scrubValue : listen.currentTime },
            set: { scrubValue = $0 }
        )
    }
}

/// Formats a duration in seconds as m:ss (or h:mm:ss).
enum TimeFormat {
    static func string(from seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
