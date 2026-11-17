// StatsPoller (Plan 4 Task 8): the Task-based poll loop that reads one raw
// report per cadence tick (1 s in production), derives a sample per report
// through StatsDeriver and keeps the call's samples for the end-of-call
// report. Production wires the reading closure over
// `CallMediaEngine.statistics` (Task 7); stop() cancels with the call.

import CallEngine
import Foundation

public actor StatsPoller {
    /// Reads the next raw statistics snapshot. Production wires it over
    /// `CallMediaEngine.statistics` (whose stream unblocks the read on task
    /// cancellation); tests hand canned reports back.
    public typealias ReportReading = @Sendable () async -> RawStatsReport?

    private let nextReport: ReportReading
    private let statsInterval: Duration
    private let deriver = StatsDeriver()
    private var previous: RawStatsReport?
    private var collected: [CallStatsSample] = []
    private var task: Task<Void, Never>?

    public init(nextReport: @escaping ReportReading, statsInterval: Duration = .seconds(1)) {
        self.nextReport = nextReport
        self.statsInterval = statsInterval
    }

    /// The samples derived so far — the coordinator folds them into the
    /// end-of-call CallReport.
    public var samples: [CallStatsSample] {
        collected
    }

    /// Starts the loop; a running poller is left untouched.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self, statsInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: statsInterval)
                guard !Task.isCancelled, let self else { return }
                await tick()
            }
        }
    }

    /// Cancels the loop with the call; the collected samples stay readable
    /// for the end-of-call report.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// One cadence step: read, derive, collect. The cancellation check after
    /// the read keeps a cancelled loop from appending anything further.
    private func tick() async {
        let report = await nextReport()
        guard !Task.isCancelled, let report else { return }
        if let sample = deriver.derive(previous: previous, current: report) {
            collected.append(sample)
        }
        previous = report
    }
}
