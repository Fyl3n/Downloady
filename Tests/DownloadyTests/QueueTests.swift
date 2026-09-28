//
//  QueueTests.swift
//  DownloadyTests
//
//  The queue's rules: which job each lane takes next, and what the notch
//  shows while they run.
//

import Foundation
import Testing

@testable import Downloady

@Suite struct QueueLaneTests {
    private func job(_ state: DownloadJob.State, title: String = "A") -> DownloadJob {
        DownloadJob(
            url: URL(string: "https://youtu.be/\(title)")!,
            title: title,
            options: DownloadOptions(),
            state: state
        )
    }

    /// A narrow row cuts the words around the percentage, never the number.
    @Test func theStatusLineSplitsAroundItsPercentage() {
        let transcribing = job(.transcribing(fraction: 0.42)).statusSegments
        #expect(transcribing?.head == "Transcribing")
        #expect(transcribing?.percent.hasSuffix("%") == true)
        #expect(transcribing?.tail == "")
        let downloading = job(.downloading(fraction: 0.1, speed: "2 MB/s", eta: "1:00")).statusSegments
        #expect(downloading?.head == "")
        #expect(downloading?.tail == "2 MB/s · 1:00 left")
        #expect(job(.waiting).statusSegments == nil)
    }

    /// Only a finished Job whose file is gone loses it.
    @Test func aFinishedJobLosesAFileThatIsGone() {
        var finished = job(.finished)
        finished.file = URL(fileURLWithPath: "/nowhere/a.mp4")
        #expect(finished.hasLostFile(exists: { _ in false }))
        #expect(!finished.hasLostFile(exists: { _ in true }))
        var running = finished
        running.state = .postProcessing
        #expect(!running.hasLostFile(exists: { _ in false }))
    }

    @Test func theDownloadLaneTakesOneJobAtATime() {
        #expect([job(.waiting), job(.waiting)].nextToDownload?.title == "A")
        let running = [job(.downloading(fraction: 0.2, speed: nil, eta: nil)), job(.waiting, title: "B")]
        #expect(running.nextToDownload == nil)
        #expect([job(.postProcessing), job(.waiting, title: "B")].nextToDownload == nil)
    }

    /// A transcript runs beside the next download, not behind it.
    @Test func theTranscriptLaneRunsWhileADownloadDoes() {
        let jobs = [job(.waitingForTranscript), job(.downloading(fraction: 0.5, speed: nil, eta: nil), title: "B")]
        #expect(jobs.nextToTranscribe?.title == "A")
        #expect(jobs.nextToDownload == nil)
    }

    @Test func theTranscriptLaneAlsoTakesOneAtATime() {
        let jobs = [job(.transcribing(fraction: 0.1)), job(.waitingForTranscript, title: "B")]
        #expect(jobs.nextToTranscribe == nil)
    }

    private func recording(_ state: DownloadJob.State, title: String = "R") -> DownloadJob {
        DownloadJob(url: URL(string: "https://youtu.be/\(title)")!, title: title, options: DownloadOptions(), isRecording: true, state: state)
    }

    /// A Recording has its own Lane: it never blocks the download Lane.
    @Test func aRecordingDoesNotBlockTheDownloadLane() {
        let now = Date()
        let jobs = [recording(.recording(since: now, bytes: 10)), job(.waiting, title: "B")]
        #expect(jobs.nextToDownload?.title == "B")
        #expect(jobs.nextToRecord(at: now) == nil)
        // Nor does the download Lane ever take a Recording.
        #expect([recording(.waiting)].nextToDownload == nil)
        #expect([job(.downloading(fraction: 0.1, speed: nil, eta: nil)), recording(.waiting)].nextToRecord(at: now)?.title == "R")
    }

    @Test func aSecondRecordingWaitsForTheFirst() {
        let now = Date()
        let jobs = [recording(.recording(since: now, bytes: nil)), recording(.waiting, title: "S")]
        #expect(jobs.nextToRecord(at: now) == nil)
        // Being Stopped, it still holds the Lane until yt-dlp has finished.
        #expect([recording(.postProcessing), recording(.waiting, title: "S")].nextToRecord(at: now) == nil)
        #expect([recording(.finished), recording(.waiting, title: "S")].nextToRecord(at: now)?.title == "S")
    }

    @Test func aScheduledRecordingTakesTheLaneWhenDue() {
        let now = Date()
        let start = now.addingTimeInterval(3600)
        let jobs = [recording(.scheduled(start))]
        #expect(jobs.nextToRecord(at: now) == nil)
        #expect(jobs.nextToRecord(at: start)?.title == "R")
        #expect(DownloadJob.isDue(.scheduled(start), at: start.addingTimeInterval(-1)) == false)
        #expect(recording(.scheduled(start)).isWaiting)
    }

    /// Without a date, or with one already past, a Recording asks for the
    /// Lane at once and yt-dlp waits for the broadcast.
    @Test func whereARecordingStarts() {
        let now = Date()
        #expect(DownloadJob.recordingState(start: nil, now: now) == .waiting)
        #expect(DownloadJob.recordingState(start: now.addingTimeInterval(-60), now: now) == .waiting)
        #expect(DownloadJob.recordingState(start: now.addingTimeInterval(60), now: now) == .scheduled(now.addingTimeInterval(60)))
    }

    @Test func aScheduledRecordingSaysWhenItStarts() {
        #expect(DownloadJob.startsIn(2 * 3600 + 10 * 60) == "Starts in 2 h 10 min")
        #expect(DownloadJob.startsIn(90) == "Starts in 2 min")
        #expect(DownloadJob.startsIn(26 * 3600) == "Starts in 1 d 2 h")
        #expect(DownloadJob.startsIn(0) == "Waiting")
    }

    @Test func finishedJobsAreNotActive() {
        #expect(!job(.finished).isActive)
        #expect(!job(.failed("nope")).isActive)
        #expect(job(.waitingForTranscript).isActive)
        #expect(job(.waitingForTranscript).isTranscribing)
        #expect(job(.postProcessing).isDownloading)
    }
}

@Suite struct QueueSummaryTests {
    private func job(_ state: DownloadJob.State, title: String = "A") -> DownloadJob {
        DownloadJob(
            url: URL(string: "https://youtu.be/\(title)")!,
            title: title,
            options: DownloadOptions(),
            state: state
        )
    }

    @Test func aQuietQueueAsksForNothing() {
        #expect(!QueueSummary(jobs: []).isActive)
        #expect(!QueueSummary(jobs: [job(.finished)]).isActive)
        #expect(QueueSummary(jobs: [job(.finished)]).activityLabel.isEmpty)
    }

    /// The running download owns the notch; a transcript only gets it when
    /// nothing is downloading.
    @Test func theDownloadLeadsTheNotch() {
        let jobs = [job(.transcribing(fraction: 0.4)), job(.downloading(fraction: 0.25, speed: nil, eta: nil), title: "B")]
        let summary = QueueSummary(jobs: jobs)
        #expect(summary.leading?.title == "B")
        #expect(summary.fraction == 0.25)
        // The percentage is written the way this Mac writes percentages, with
        // no job count: it would not fit a notch wing.
        #expect(summary.activityLabel == 0.25.formatted(.percent.precision(.fractionLength(0))))
    }

    @Test func aLoneTranscriptLeads() {
        let summary = QueueSummary(jobs: [job(.transcribing(fraction: 0.6))])
        #expect(summary.leading?.isTranscribing == true)
        #expect(summary.activityLabel == 0.6.formatted(.percent.precision(.fractionLength(0))))
    }

    @Test func stagesWithNoNumberGetAWord() {
        // Words wider than a notch wing are cut short: stages with no number
        // of their own show the one they amount to.
        #expect(QueueSummary(jobs: [job(.postProcessing)]).activityLabel == 1.0.formatted(.percent.precision(.fractionLength(0))))
        #expect(QueueSummary(jobs: [job(.preparingTranscript)]).activityLabel == "Text")
        #expect(QueueSummary(jobs: [job(.waiting)]).activityLabel == 0.0.formatted(.percent.precision(.fractionLength(0))))
    }

    private func recording(_ state: DownloadJob.State) -> DownloadJob {
        DownloadJob(url: URL(string: "https://youtu.be/R")!, title: "R", options: DownloadOptions(), isRecording: true, state: state)
    }

    /// A Recording alone leads, with no percentage: the wing shows the
    /// record circle.
    @Test func aLoneRecordingLeads() {
        let summary = QueueSummary(jobs: [recording(.recording(since: Date(), bytes: 1_000))])
        #expect(summary.isActive)
        #expect(summary.isRecording)
        #expect(summary.leading?.title == "R")
        #expect(summary.fraction == 0)
        #expect(summary.activityLabel.isEmpty)
    }

    /// A download beside it keeps the ring; the record circle stays.
    @Test func aDownloadBesideARecordingLeads() {
        let jobs = [recording(.recording(since: Date(), bytes: nil)), job(.downloading(fraction: 0.4, speed: nil, eta: nil), title: "B")]
        let summary = QueueSummary(jobs: jobs)
        #expect(summary.leading?.title == "B")
        #expect(summary.isRecording)
        #expect(summary.activeCount == 2)
    }

    /// A Scheduled recording is not running: it does not hold the notch.
    @Test func aScheduledRecordingAsksForNothing() {
        let summary = QueueSummary(jobs: [recording(.scheduled(Date(timeIntervalSinceNow: 3600)))])
        #expect(!summary.isActive)
        #expect(!summary.isRecording)
    }
}

@MainActor
@Suite struct QueueModelTests {
    @Test func theFormFollowsTheJobStartedFromItsLink() {
        let model = DownloadModel()
        #expect(model.currentJob == nil)
    }

    @Test func aTranscriptLandsBesideTheMediaItWasMadeFrom() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloady-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let media = folder.appendingPathComponent("Clip [abc].mp4")
        try Data().write(to: media)
        #expect(DownloadModel.subtitleFile(beside: media) == nil)

        let subtitles = folder.appendingPathComponent("Clip [abc].en.srt")
        try Data().write(to: subtitles)
        // Another video's subtitles in the same folder are not this one's.
        try Data().write(to: folder.appendingPathComponent("Other [xyz].en.srt"))
        #expect(DownloadModel.subtitleFile(beside: media) == subtitles)
    }
}

@Suite struct ProgressThrottleTests {
    private func downloading(_ fraction: Double, speed: String? = "1MiB/s") -> DownloadJob.State {
        .downloading(fraction: fraction, speed: speed, eta: "00:10")
    }

    @Test func aTickInsideTheSamePercentWaits() {
        #expect(!DownloadJob.shouldPublish(downloading(0.421), over: downloading(0.420), elapsed: 0.5))
    }

    @Test func aNewPercentPublishesOnceTheIntervalPassed() {
        #expect(!DownloadJob.shouldPublish(downloading(0.43), over: downloading(0.42), elapsed: 0.05))
        #expect(DownloadJob.shouldPublish(downloading(0.43), over: downloading(0.42), elapsed: 0.3))
    }

    @Test func theSpeedRefreshesEverySecond() {
        #expect(DownloadJob.shouldPublish(downloading(0.42, speed: "2MiB/s"), over: downloading(0.42), elapsed: 1.2))
    }

    @Test func aNewStageAlwaysPublishes() {
        #expect(DownloadJob.shouldPublish(.postProcessing, over: downloading(0.99), elapsed: 0))
        #expect(DownloadJob.shouldPublish(.transcribing(fraction: 0.01), over: .preparingTranscript, elapsed: 0))
    }
}

@Suite struct PlaylistQueueTests {
    private let folder = URL(fileURLWithPath: "/tmp/Downloads/The Universe", isDirectory: true)

    @Test func everyEntryBecomesAJobInPlaylistOrder() throws {
        var info = try FormatAvailabilityTests.decode(PlaylistLookupTests.playlistJSON)
        info = MediaInfo(
            id: info.id, title: info.title, extractorKey: info.extractorKey, formats: nil, type: info.type,
            entries: (info.entries ?? []) + [
                PlaylistEntry(url: "https://www.youtube.com/watch?v=live", title: "Launch", liveStatus: "is_live"),
                PlaylistEntry(url: nil, title: "No link"),
                PlaylistEntry(url: "abc123", title: "A bare ID"),
            ]
        )
        let options = DownloadOptions(quality: .audioOnly)
        let jobs = DownloadJob.jobs(for: info, options: options, subtitleLanguage: "fr", folder: folder)

        #expect(jobs.map(\.title) == [
            "Three Ways to Destroy the Universe",
            "[Private video]",
            "Space Elevator – Science Fiction or the Future of Mankind?",
            "Launch",
        ])
        #expect(jobs[0].url.absoluteString == "https://www.youtube.com/watch?v=4_aOIA-vyBo")
        #expect(jobs[0].duration == 377)
        #expect(jobs.allSatisfy { $0.folder == folder && $0.options == options && $0.subtitleLanguage == "fr" })
        #expect(jobs.map(\.state) == [
            .waiting,
            .failed("Private video"),
            .waiting,
            .failed("Live stream: open it on its own to record it"),
        ])
        // The failed ones never reach the download Lane.
        #expect(jobs.nextToDownload?.title == "Three Ways to Destroy the Universe")
    }

    /// A channel's page lists its tabs, which are playlists with no link:
    /// the Lookup says so instead of offering "Download 0 videos".
    @Test func aChannelPageOfTabsSaysWhatToOpen() {
        let tabs = MediaInfo(
            id: "UC", title: "NASA", extractorKey: "YoutubeTab", formats: nil, type: "playlist",
            entries: [
                PlaylistEntry(url: nil, title: "NASA - Videos", type: "playlist"),
                PlaylistEntry(url: nil, title: "NASA - Live", type: "playlist"),
            ]
        )
        #expect(tabs.downloadableCount == 0)
        #expect(tabs.nestedPlaylistReason != nil)

        let videos = MediaInfo(
            id: "PL", title: "Mix", extractorKey: "YoutubeTab", formats: nil, type: "playlist",
            entries: [PlaylistEntry(url: "https://www.youtube.com/watch?v=a", title: "A")]
        )
        #expect(videos.nestedPlaylistReason == nil)
    }

    /// A stopped Recording finishing its file shows no Cancel, and refuses one.
    @Test func aStoppedRecordingCannotBeCancelled() {
        func job(_ state: DownloadJob.State, recording: Bool) -> DownloadJob {
            DownloadJob(url: URL(string: "https://youtu.be/a")!, title: "A", options: DownloadOptions(), isRecording: recording, state: state)
        }
        #expect(job(.postProcessing, recording: true).isStopping)
        #expect(!job(.postProcessing, recording: false).isStopping)
        #expect(!job(.recording(since: Date(), bytes: 1), recording: true).isStopping)
    }

    @Test func thePlaylistFolderIsSafeForTheFileSystem() {
        let parent = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
        #expect(DownloadJob.playlistFolder(named: "Space: 2026/27", in: parent).lastPathComponent == "Space- 2026-27")
        #expect(DownloadJob.playlistFolder(named: "..hidden. ", in: parent).lastPathComponent == "hidden")
        #expect(DownloadJob.playlistFolder(named: " / ", in: parent).lastPathComponent == "-")
        #expect(DownloadJob.playlistFolder(named: "...", in: parent).lastPathComponent == "Playlist")
        #expect(DownloadJob.playlistFolder(named: "Mix", in: parent).deletingLastPathComponent().path == parent.path)
    }

    /// A large Playlist's unavailable entries stay until Clear finished.
    @Test func historyTrimsFinishedRowsOnly() {
        func job(_ state: DownloadJob.State) -> DownloadJob {
            DownloadJob(url: URL(string: "https://youtu.be/a")!, title: "A", options: DownloadOptions(), state: state)
        }
        let failed = (0..<10).map { _ in job(.failed("Private video")) }
        let finished = (0..<4).map { _ in job(.finished) }
        let jobs = failed + finished + [job(.waiting)]
        #expect(jobs.historyToTrim(limit: 6).isEmpty)
        #expect(jobs.historyToTrim(limit: 3) == [finished[0].id])
        #expect(jobs.historyToTrim(limit: 0) == Set(finished.map(\.id)))
    }
}
