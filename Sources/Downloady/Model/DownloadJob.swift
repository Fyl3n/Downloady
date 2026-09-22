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
        /// Waiting for the download lane.
        case waiting
        case downloading(fraction: Double, speed: String?, eta: String?)
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
        case .waiting, .waitingForTranscript, .preparingTranscript: nil
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
        case .downloading(let fraction, let speed, let eta):
            DownloadJob.progressDetail(fraction: fraction, speed: speed, eta: eta)
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
        default: "arrow.down"
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
    /// transcription.
    public let leading: DownloadJob?

    public init(activeCount: Int, leading: DownloadJob?) {
        self.activeCount = activeCount
        self.leading = leading
    }

    public static let idle = QueueSummary(activeCount: 0, leading: nil)

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
        case .finished, .failed:
            return ""
        }
    }

    /// Builds the summary from the queue. The running download wins the
    /// notch; a transcription only gets it when no download is running.
    public init(jobs: [DownloadJob]) {
        let active = jobs.filter(\.isActive)
        let leading = active.first(where: { if case .downloading = $0.state { return true } else { return false } })
            ?? active.first(where: \.isDownloading)
            ?? active.first
        self.init(activeCount: active.count, leading: leading)
    }
}

extension Array where Element == DownloadJob {
    /// The job the download lane should run next, if it is free.
    var nextToDownload: DownloadJob? {
        guard !contains(where: { if case .downloading = $0.state { return true }
                                 if case .postProcessing = $0.state { return true }
                                 return false }) else { return nil }
        return first { $0.state == .waiting }
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
