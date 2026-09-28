//
//  DownloadJob.swift
//  Downloady
//
//  One queued piece of work: a download, and the text file that follows it.
//  The queue is a plain array of these on `DownloadModel`; this file is the
//  part with no host and no process in it, so the tests pin the rules.
//

import Foundation

/// One download the user started, from the moment it is queued until its
/// file (and its transcript) are on disk.
public struct DownloadJob: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Waiting for the download lane, or a Recording for the Recording Lane.
        case waiting
        /// A Scheduled recording: holds no Lane until its broadcast is due.
        case scheduled(Date)
        case downloading(fraction: Double, speed: String?, eta: String?)
        /// A Recording under way since yt-dlp started, with the size of what
        /// it has written, once there is any.
        case recording(since: Date, bytes: Int64?)
        /// yt-dlp is merging, remuxing or extracting.
        case postProcessing
        /// The media is on disk; waiting for the transcription lane.
        case waitingForTranscript
        /// macOS is fetching the speech model for the language.
        case preparingTranscript
        case transcribing(fraction: Double)
        case finished
        case failed(String)
    }

    public let id: UUID
    public let url: URL
    /// What the queue row shows: the media's title, else the page's host.
    public let title: String
    public let options: DownloadOptions
    /// The language yt-dlp was asked for, when the job writes subtitles.
    public let subtitleLanguage: String
    /// The media's length, for the transcription progress.
    public let duration: Double?
    /// Whether this Job is a Recording: made from a Live stream, it runs in
    /// the Recording Lane and ends with Stop.
    public let isRecording: Bool
    /// The folder checked when the job was queued; `nil` is the current setting.
    public let folder: URL?
    public var state: State
    /// The media file, once yt-dlp reported it.
    public var file: URL?
    /// The `.srt`, once the subtitles were written or the transcript ran.
    public var transcript: URL?

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        options: DownloadOptions,
        subtitleLanguage: String = "en",
        duration: Double? = nil,
        isRecording: Bool = false,
        folder: URL? = nil,
        state: State = .waiting,
        file: URL? = nil,
        transcript: URL? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.options = options
        self.subtitleLanguage = subtitleLanguage
        self.duration = duration
        self.isRecording = isRecording
        self.folder = folder
        self.state = state
        self.file = file
        self.transcript = transcript
    }

    /// Whether Downloady is still working on this job.
    public var isActive: Bool {
        switch state {
        case .finished, .failed: false
        default: true
        }
    }

    /// Whether the download itself is still running.
    public var isDownloading: Bool {
        switch state {
        case .waiting, .downloading, .postProcessing: true
        default: false
        }
    }

    /// Whether the Job has written nothing yet: waiting for its Lane, or a
    /// Scheduled recording.
    /// A Recording that was Stopped and is finishing its file, a few
    /// seconds. It cannot be cancelled: yt-dlp keeps the file whatever
    /// happens, so a Cancel would only lose the row.
    public var isStopping: Bool { isRecording && state == .postProcessing }

    public var isWaiting: Bool {
        switch state {
        case .waiting, .scheduled: true
        default: false
        }
    }

    /// Whether the transcription lane owns this job.
    public var isTranscribing: Bool {
        switch state {
        case .waitingForTranscript, .preparingTranscript, .transcribing: true
        default: false
        }
    }

    /// How far along the whole job is, or `nil` when there is nothing to
    /// measure yet.
    public var fraction: Double? {
        switch state {
        case .waiting, .scheduled, .recording, .waitingForTranscript, .preparingTranscript: nil
        case .downloading(let fraction, _, _): fraction
        case .postProcessing: 1
        case .transcribing(let fraction): fraction
        case .finished: 1
        case .failed: nil
        }
    }

    /// The line under the title in the queue.
    public var statusText: String {
        switch state {
        case .waiting:
            "Waiting"
        case .scheduled(let start):
            DownloadJob.startsIn(start.timeIntervalSinceNow)
        case .downloading(let fraction, let speed, let eta):
            DownloadJob.progressDetail(fraction: fraction, speed: speed, eta: eta)
        case .recording(_, let bytes):
            // The elapsed time is drawn beside it, by a view that ticks.
            bytes.map { "Recording · \($0.formatted(.byteCount(style: .file)))" } ?? "Recording"
        case .postProcessing:
            "Finishing…"
        case .waitingForTranscript:
            options.transcript.transcribesLocally ? "Waiting to transcribe" : "Waiting"
        case .preparingTranscript:
            "Getting the speech model…"
        case .transcribing(let fraction):
            "Transcribing · \(fraction.formatted(.percent.precision(.fractionLength(0))))"
        case .finished:
            transcript == nil ? "Saved" : "Saved, with \(options.transcript == .transcribe ? "a transcript" : "subtitles")"
        case .failed(let message):
            message
        }
    }

    /// The glyph the queue row and the live activity use.
    public var systemImage: String {
        switch state {
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .waitingForTranscript, .preparingTranscript, .transcribing: "text.quote"
        default: isRecording ? "dot.radiowaves.left.and.right" : "arrow.down"
        }
    }

    /// Whether a progress tick is worth publishing over the state on screen.
    ///
    /// yt-dlp prints a progress line for every block it writes, dozens a
    /// second on a fast link, and every published change redraws the widget,
    /// the takeover and the notch row on Droppy's main thread. A tick is
    /// published when the stage changes, when the whole percentage moves (at
    /// most `minimumInterval` apart), or once `refreshInterval` has passed so
    /// the speed and time left stay fresh.
    public static func shouldPublish(
        _ new: State,
        over old: State,
        elapsed: TimeInterval,
        minimumInterval: TimeInterval = 0.25,
        refreshInterval: TimeInterval = 1
    ) -> Bool {
        let percents: (Double, Double)
        switch (old, new) {
        case let (.downloading(a, _, _), .downloading(b, _, _)): percents = (a, b)
        case let (.transcribing(a), .transcribing(b)): percents = (a, b)
        default: return old != new
        }
        if elapsed >= refreshInterval { return old != new }
        let wholePercent = { (fraction: Double) in Int((fraction * 100).rounded(.down)) }
        return elapsed >= minimumInterval && wholePercent(percents.0) != wholePercent(percents.1)
    }

    /// One Job per entry of `playlist`, in playlist order, all saved in
    /// `folder`. An entry `PlaylistEntry.unavailableReason` rules out is
    /// queued already failed, so the user sees why it is missing; an entry
    /// with no web URL is left out.
    public static func jobs(
        for playlist: MediaInfo,
        options: DownloadOptions,
        subtitleLanguage: String,
        folder: URL
    ) -> [DownloadJob] {
        (playlist.entries ?? []).compactMap { entry in
            guard let url = entry.webURL else { return nil }
            return DownloadJob(
                url: url,
                title: entry.title ?? url.absoluteString,
                options: options,
                subtitleLanguage: subtitleLanguage,
                duration: entry.duration,
                folder: folder,
                state: entry.unavailableReason.map(State.failed) ?? .waiting
            )
        }
    }

    /// The subfolder of `parent` a Playlist's Jobs are saved in, named after
    /// the Playlist with what the file system refuses taken out.
    public static func playlistFolder(named title: String, in parent: URL) -> URL {
        let name = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return parent.appendingPathComponent(name.isEmpty ? "Playlist" : String(name.prefix(200)), isDirectory: true)
    }

    /// Where a Recording starts: a Scheduled recording until `start`, then
    /// (or at once, with no `start`) waiting for the Recording Lane, where
    /// yt-dlp waits for a broadcast that is late.
    public static func recordingState(start: Date?, now: Date = Date()) -> State {
        if let start, start > now { return .scheduled(start) }
        return .waiting
    }

    /// Whether a Recording in `state` may take the Recording Lane at `now`.
    public static func isDue(_ state: State, at now: Date) -> Bool {
        switch state {
        case .waiting: true
        case .scheduled(let start): start <= now
        default: false
        }
    }

    /// "Starts in 2 h 10 min", or "Waiting" once the start has passed.
    public static func startsIn(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "Waiting" }
        let minutes = Int((interval / 60).rounded(.up))
        let (days, hours, rest) = (minutes / 1440, minutes / 60 % 24, minutes % 60)
        if days > 0 { return "Starts in \(days) d \(hours) h" }
        return hours > 0 ? "Starts in \(hours) h \(rest) min" : "Starts in \(rest) min"
    }

    public static func progressDetail(fraction: Double, speed: String?, eta: String?) -> String {
        var parts = [fraction.formatted(.percent.precision(.fractionLength(0)))]
        if let speed { parts.append(speed) }
        if let eta { parts.append("\(eta) left") }
        return parts.joined(separator: " · ")
    }
}

/// What the live activity, the queue button and the HUD read: the queue, boiled down.
public struct QueueSummary: Equatable, Sendable {
    /// Jobs still being worked on.
    public let activeCount: Int
    /// The job the notch is about: the running download, else the running
    /// transcription, else the running Recording.
    public let leading: DownloadJob?
    /// Whether a Recording is running, beside whatever leads.
    public let isRecording: Bool

    public init(activeCount: Int, leading: DownloadJob?, isRecording: Bool = false) {
        self.activeCount = activeCount
        self.leading = leading
        self.isRecording = isRecording
    }

    public var isActive: Bool { activeCount > 0 }

    public var fraction: Double { leading?.fraction ?? 0 }

    /// The trailing wing of the live activity: a percentage, or "Text" while
    /// a transcript has none yet.
    ///
    /// A notch wing leaves about 37pt for this label at 12pt: "100 %" is
    /// 35pt, while "Finishing" (51pt), "Queued" (45pt) and a job count
    /// ("62 % · 3") are cut short. So the stages without a number show the
    /// one they amount to, and the ring's glyph says which stage it is. The
    /// queue has the count.
    public var activityLabel: String {
        guard let leading else { return "" }
        let percent = { (fraction: Double) in fraction.formatted(.percent.precision(.fractionLength(0))) }
        switch leading.state {
        case .downloading(let fraction, _, _):
            return percent(fraction)
        case .postProcessing:
            // The bytes are all here; ffmpeg is merging them.
            return percent(1)
        case .preparingTranscript, .waitingForTranscript:
            return "Text"
        case .transcribing(let fraction):
            return fraction > 0 ? percent(fraction) : "Text"
        case .waiting:
            return percent(0)
        case .scheduled, .recording, .finished, .failed:
            // A Recording has no percentage: the wing shows the record circle.
            return ""
        }
    }

    /// Builds the summary from the queue. The running download wins the
    /// notch; a transcription only gets it when no download is running, and
    /// a Recording when nothing else is. A Scheduled recording is not
    /// running: it does not hold the notch for hours before its broadcast.
    public init(jobs: [DownloadJob]) {
        let active = jobs.filter { $0.isActive && !$0.isScheduled }
        let recording = active.first(where: { if case .recording = $0.state { return true } else { return false } })
        let leading = active.first(where: { if case .downloading = $0.state { return true } else { return false } })
            ?? active.first(where: { $0.isDownloading && !$0.isRecording })
            ?? active.first(where: { !$0.isRecording })
            ?? recording
            ?? active.first
        self.init(activeCount: active.count, leading: leading, isRecording: recording != nil)
    }
}

extension DownloadJob {
    var isScheduled: Bool {
        if case .scheduled = state { true } else { false }
    }

    /// Whether this Job holds the download Lane, or for a Recording the
    /// Recording Lane.
    var holdsLane: Bool {
        switch state {
        case .downloading, .recording, .postProcessing: true
        default: false
        }
    }
}

extension Array where Element == DownloadJob {
    /// The job the download lane should run next, if it is free. Recordings
    /// have their own Lane and never hold this one.
    var nextToDownload: DownloadJob? {
        guard !contains(where: { $0.holdsLane && !$0.isRecording }) else { return nil }
        return first { $0.state == .waiting && !$0.isRecording }
    }

    /// The Recording the Recording Lane should run at `now`, if it is free:
    /// the first one waiting, or Scheduled and due.
    func nextToRecord(at now: Date) -> DownloadJob? {
        guard !contains(where: { $0.holdsLane && $0.isRecording }) else { return nil }
        return first { $0.isRecording && DownloadJob.isDue($0.state, at: now) }
    }

    /// The oldest finished rows past `limit`, which the queue lets go. Failed
    /// rows stay until Clear finished, or a large Playlist's unavailable
    /// entries would go as soon as they were queued.
    func historyToTrim(limit: Int) -> Set<UUID> {
        let finished = filter { $0.state == .finished }
        return Set(finished.dropLast(limit).map(\.id))
    }

    /// The job the transcription lane should run next, if it is free.
    var nextToTranscribe: DownloadJob? {
        guard !contains(where: { if case .transcribing = $0.state { return true }
                                 if case .preparingTranscript = $0.state { return true }
                                 return false }) else { return nil }
        return first { $0.state == .waitingForTranscript }
    }

    subscript(id id: UUID) -> DownloadJob? {
        first { $0.id == id }
    }
}
