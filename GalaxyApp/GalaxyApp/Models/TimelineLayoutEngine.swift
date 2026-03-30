import Foundation

/// Pure function: [TimelineEvent] -> TimelineLayout.
/// No SwiftUI, no side effects. Testable and view-layer independent.
enum TimelineLayoutEngine {
    /// Height of one hash row in points.
    static let hashHeight: CGFloat = 20.0
    /// Seconds per hash tick.
    static let hashGranularity: TimeInterval = 5.0
    /// Number of consecutive empty hashes that triggers a break (13 = 65s).
    static let breakThreshold = 13
    /// Maximum segment height in points before forced sub-chunking.
    static let maxSegmentHeight: CGFloat = 4000.0

    // MARK: - Public API

    /// Phase 1: Compute time-axis layout (width-independent).
    /// Call once per data fetch.
    static func computeTimeAxis(
        events: [TimelineEvent]
    ) -> TimeAxisResult? {
        // 1. Filter to registered event types
        let registered = events.compactMap { event -> (TimelineEvent, EventRegistration)? in
            guard let reg = timelineEventRegistry[event.eventType] else { return nil }
            return (event, reg)
        }
        guard !registered.isEmpty else { return nil }

        // 2. Sort by occurred_at (defensive re-sort)
        let sorted = registered.sorted { $0.0.occurredAt < $1.0.occurredAt }

        // 3. Determine active lanes
        let activeResources = Set(sorted.map { $0.1.resource })
        let activeLanes = TimelineResource.allCases.filter { activeResources.contains($0) }
        guard !activeLanes.isEmpty else { return nil }

        // 4. Pair duration events
        let durations = pairDurations(sorted: sorted)

        // 5. Snap to hashes and compute hash range
        // Extend to "now" so trailing inactivity is
        // visible as either empty hashes or a break.
        let firstTime = sorted.first!.0.occurredAt
        let lastTime = max(
            sorted.last!.0.occurredAt, Date()
        )
        let originHash = snapToHash(firstTime)
        let endHash = snapToHash(lastTime)
        let totalHashes = max(
            1,
            hashIndex(
                for: endHash, origin: originHash
            ) + 1
        )

        // 6. Build hash -> events mapping for point events
        var pointsByHash: [Int: [(TimelineEvent, EventRegistration)]] = [:]
        for (event, reg) in sorted where reg.mode == .point {
            let h = hashIndex(for: snapToHash(event.occurredAt), origin: originHash)
            pointsByHash[h, default: []].append((event, reg))
        }

        // 7. Detect breaks
        let segments = detectBreaks(
            totalHashes: totalHashes,
            originHash: originHash,
            durations: durations,
            pointsByHash: pointsByHash,
            activeLanes: activeLanes
        )

        return TimeAxisResult(
            activeLanes: activeLanes,
            segments: segments,
            durations: durations,
            pointsByHash: pointsByHash,
            originHash: originHash,
            totalHashes: totalHashes
        )
    }

    /// Phase 2: Compute spatial positions using overlap-aware
    /// sub-column packing. Items pack left; only overflow creates
    /// new columns. Call once per data fetch.
    static func computeSpatial(
        timeAxis: TimeAxisResult,
        availableWidth: CGFloat,
        hashRailWidth: CGFloat = 76.0,
        dotDiameter: CGFloat = 10.0
    ) -> TimelineLayout {
        let laneCount = timeAxis.activeLanes.count
        guard laneCount > 0 else {
            return TimelineLayout(
                segments: [], activeLanes: [],
                totalHeight: 0,
                originHash: timeAxis.originHash,
                laneMaxSubColumns: []
            )
        }

        // Track peak sub-columns per lane across all segments
        var globalMaxSubCols = [Int](
            repeating: 1, count: laneCount
        )
        var layoutSegments: [LayoutSegment] = []
        var totalHeight: CGFloat = 0

        // Sub-column history: preserves a bar's column
        // assignment across segment breaks so continuing
        // bars don't reset to column 0.
        // Key = DurationPair.startEvent.id (unique per bar).
        var barSubColHistory: [Int64: Int] = [:]

        for segmentInfo in timeAxis.segments {
            let hashCount =
                segmentInfo.endHash - segmentInfo.startHash + 1
            let segmentHeight =
                CGFloat(hashCount) * hashHeight

            // --- Collect items per lane ---

            struct BarEntry {
                let dur: DurationPair
                let laneIndex: Int
                let localStart: Int
                let localEnd: Int
                let continuesPrev: Bool
                let continuesNext: Bool
            }
            struct DotEntry {
                let event: TimelineEvent
                let resource: TimelineResource
                let laneIndex: Int
                let localHash: Int
            }

            var barEntries: [BarEntry] = []
            var dotEntries: [DotEntry] = []

            for dur in timeAxis.durations {
                let laneIndex = timeAxis.activeLanes
                    .firstIndex(of: dur.resource) ?? 0
                let barStart = dur.startHash
                let barEnd: Int
                if let eh = dur.endHash {
                    barEnd = eh
                } else if dur.resource == .session {
                    // Open-ended session: extend to end
                    barEnd = timeAxis.totalHashes - 1
                } else {
                    // Non-session open-ended (orphaned
                    // scrollback etc): short indicator
                    barEnd = min(
                        dur.startHash + 2,
                        timeAxis.totalHashes - 1
                    )
                }

                guard barStart <= segmentInfo.endHash,
                      barEnd >= segmentInfo.startHash
                else { continue }

                let localStart = max(
                    0, barStart - segmentInfo.startHash
                )
                let localEnd = min(
                    hashCount - 1,
                    barEnd - segmentInfo.startHash
                )
                // Skip degenerate bars (hash snapping
                // can invert short durations)
                guard localStart <= localEnd else { continue }
                barEntries.append(BarEntry(
                    dur: dur,
                    laneIndex: laneIndex,
                    localStart: localStart,
                    localEnd: localEnd,
                    continuesPrev:
                        barStart < segmentInfo.startHash,
                    continuesNext:
                        barEnd > segmentInfo.endHash
                ))
            }

            for hashIdx in
                segmentInfo.startHash...segmentInfo.endHash
            {
                guard let points =
                    timeAxis.pointsByHash[hashIdx]
                else { continue }
                let localHash =
                    hashIdx - segmentInfo.startHash
                for (event, reg) in points {
                    let laneIndex = timeAxis.activeLanes
                        .firstIndex(of: reg.resource) ?? 0
                    dotEntries.append(DotEntry(
                        event: event,
                        resource: reg.resource,
                        laneIndex: laneIndex,
                        localHash: localHash
                    ))
                }
            }

            // --- Overlap-aware sub-column packing ---

            var barSubCols = [Int](
                repeating: 0, count: barEntries.count
            )
            var dotSubCols = [Int](
                repeating: 0, count: dotEntries.count
            )
            var laneMaxSubCols = [Int](
                repeating: 1, count: laneCount
            )

            for lane in 0..<laneCount {
                // columns[col] = occupied hash ranges
                var columns: [[ClosedRange<Int>]] = []

                // Pack bars first (sorted by start hash)
                let laneBarIndices = barEntries.indices
                    .filter { barEntries[$0].laneIndex == lane }
                    .sorted {
                        barEntries[$0].localStart
                            < barEntries[$1].localStart
                    }

                // Phase A: Pre-place bars continuing from
                // a previous segment at their historical
                // sub-column so they don't reset to 0.
                var prePlaced = Set<Int>()
                for bi in laneBarIndices {
                    guard barEntries[bi].continuesPrev
                    else { continue }
                    let eventId =
                        barEntries[bi].dur.startEvent.id
                    guard let prevCol =
                        barSubColHistory[eventId]
                    else { continue }

                    // Expand columns array to reach prevCol
                    while columns.count <= prevCol {
                        columns.append([])
                    }
                    let lo = barEntries[bi].localStart
                    let hi = barEntries[bi].localEnd
                    guard lo <= hi else { continue }
                    columns[prevCol].append(lo...hi)
                    barSubCols[bi] = prevCol
                    prePlaced.insert(bi)
                }

                // Phase B: Pack remaining (new) bars around
                // any pre-placed entries.
                for bi in laneBarIndices
                    where !prePlaced.contains(bi)
                {
                    let lo = barEntries[bi].localStart
                    let hi = barEntries[bi].localEnd
                    guard lo <= hi else { continue }
                    let range: ClosedRange<Int> = lo...hi
                    var placed = false
                    for col in 0..<columns.count {
                        let overlaps = columns[col]
                            .contains { $0.overlaps(range) }
                        if !overlaps {
                            columns[col].append(range)
                            barSubCols[bi] = col
                            placed = true
                            break
                        }
                    }
                    if !placed {
                        columns.append([range])
                        barSubCols[bi] = columns.count - 1
                    }
                }

                // Pack dots (sorted by hash, then event id)
                let laneDotIndices = dotEntries.indices
                    .filter { dotEntries[$0].laneIndex == lane }
                    .sorted {
                        dotEntries[$0].localHash
                            < dotEntries[$1].localHash
                    }

                for di in laneDotIndices {
                    let h = dotEntries[di].localHash
                    let range = h...h
                    var placed = false
                    for col in 0..<columns.count {
                        let overlaps = columns[col]
                            .contains { $0.overlaps(range) }
                        if !overlaps {
                            columns[col].append(range)
                            dotSubCols[di] = col
                            placed = true
                            break
                        }
                    }
                    if !placed {
                        columns.append([range])
                        dotSubCols[di] = columns.count - 1
                    }
                }

                laneMaxSubCols[lane] = max(1, columns.count)
            }

            // Record sub-column assignments so
            // continuing bars keep their column in
            // subsequent segments.
            for (bi, entry) in barEntries.enumerated() {
                barSubColHistory[entry.dur.startEvent.id]
                    = barSubCols[bi]
            }

            // Update global peak
            for lane in 0..<laneCount {
                globalMaxSubCols[lane] = max(
                    globalMaxSubCols[lane],
                    laneMaxSubCols[lane]
                )
            }

            // --- Build placed items ---

            let placedBars: [PlacedBar] = barEntries
                .enumerated().map { bi, entry in
                    PlacedBar(
                        startEvent: entry.dur.startEvent,
                        endEvent: entry.dur.endEvent,
                        resource: entry.dur.resource,
                        laneIndex: entry.laneIndex,
                        subColumn: barSubCols[bi],
                        maxSubColumns:
                            laneMaxSubCols[entry.laneIndex],
                        startHashIndex: entry.localStart,
                        endHashIndex: entry.localEnd,
                        isOpenEnded:
                            entry.dur.endEvent == nil,
                        continuesFromPrevious:
                            entry.continuesPrev,
                        continuesIntoNext:
                            entry.continuesNext
                    )
                }

            let placedDots: [PlacedDot] = dotEntries
                .enumerated().map { di, entry in
                    PlacedDot(
                        event: entry.event,
                        resource: entry.resource,
                        laneIndex: entry.laneIndex,
                        subColumn: dotSubCols[di],
                        maxSubColumns:
                            laneMaxSubCols[entry.laneIndex],
                        hashIndex: entry.localHash
                    )
                }

            layoutSegments.append(LayoutSegment(
                startHash: segmentInfo.startHash,
                endHash: segmentInfo.endHash,
                hashCount: hashCount,
                height: segmentHeight,
                placedDots: placedDots,
                placedBars: placedBars,
                breakAfter: segmentInfo.breakAfter
            ))

            totalHeight += segmentHeight
            if segmentInfo.breakAfter != nil {
                totalHeight += 16
            }
        }

        // Normalize maxSubColumns to global peak so items
        // align consistently across segments
        layoutSegments = layoutSegments.map { seg in
            LayoutSegment(
                startHash: seg.startHash,
                endHash: seg.endHash,
                hashCount: seg.hashCount,
                height: seg.height,
                placedDots: seg.placedDots.map { dot in
                    PlacedDot(
                        event: dot.event,
                        resource: dot.resource,
                        laneIndex: dot.laneIndex,
                        subColumn: dot.subColumn,
                        maxSubColumns:
                            globalMaxSubCols[dot.laneIndex],
                        hashIndex: dot.hashIndex
                    )
                },
                placedBars: seg.placedBars.map { bar in
                    PlacedBar(
                        startEvent: bar.startEvent,
                        endEvent: bar.endEvent,
                        resource: bar.resource,
                        laneIndex: bar.laneIndex,
                        subColumn: bar.subColumn,
                        maxSubColumns:
                            globalMaxSubCols[bar.laneIndex],
                        startHashIndex: bar.startHashIndex,
                        endHashIndex: bar.endHashIndex,
                        isOpenEnded: bar.isOpenEnded,
                        continuesFromPrevious:
                            bar.continuesFromPrevious,
                        continuesIntoNext:
                            bar.continuesIntoNext
                    )
                },
                breakAfter: seg.breakAfter
            )
        }

        return TimelineLayout(
            segments: layoutSegments,
            activeLanes: timeAxis.activeLanes,
            totalHeight: totalHeight,
            originHash: timeAxis.originHash,
            laneMaxSubColumns: globalMaxSubCols
        )
    }

    // MARK: - Duration Pairing

    private static func pairDurations(
        sorted: [(TimelineEvent, EventRegistration)]
    ) -> [DurationPair] {
        let origin = snapToHash(sorted.first!.0.occurredAt)

        // Group by (resource, duration_identifier)
        struct GroupKey: Hashable {
            let resource: TimelineResource
            let durationId: String?
        }

        var startGroups: [GroupKey: [(TimelineEvent, EventRegistration)]] = [:]
        var endGroups: [GroupKey: [(TimelineEvent, EventRegistration)]] = [:]

        for (event, reg) in sorted {
            let key = GroupKey(
                resource: reg.resource,
                durationId: event.durationIdentifier
            )
            switch reg.mode {
            case .durationStart:
                startGroups[key, default: []]
                    .append((event, reg))
            case .durationEnd:
                endGroups[key, default: []]
                    .append((event, reg))
            case .point:
                break
            }
        }

        var results: [DurationPair] = []
        // Track orphans for cross-group matching
        var orphanedStarts:
            [TimelineResource: [(TimelineEvent, EventRegistration)]] = [:]
        var orphanedEnds:
            [TimelineResource: [(TimelineEvent, EventRegistration)]] = [:]

        // Phase 1: Chronological stack pairing within
        // each (resource, dur_id) group.
        let allKeys = Set(startGroups.keys)
            .union(endGroups.keys)
        for key in allKeys {
            let starts = startGroups[key] ?? []
            let ends = endGroups[key] ?? []

            // Merge into chronological stream
            let tagged: [(event: TimelineEvent,
                          reg: EventRegistration,
                          isStart: Bool)] =
                starts.map { ($0.0, $0.1, true) }
                + ends.map { ($0.0, $0.1, false) }
            let merged = tagged.sorted {
                $0.event.occurredAt < $1.event.occurredAt
            }

            var stack: [(TimelineEvent, EventRegistration)]
                = []
            for item in merged {
                if item.isStart {
                    stack.append((item.event, item.reg))
                } else if let start = stack.popLast() {
                    results.append(makePair(
                        start: start.0,
                        end: item.event,
                        resource: key.resource,
                        origin: origin
                    ))
                } else {
                    // Orphaned end — save for Phase 2
                    orphanedEnds[key.resource, default: []]
                        .append((item.event, item.reg))
                }
            }
            // Remaining unpaired starts
            for s in stack {
                orphanedStarts[key.resource, default: []]
                    .append(s)
            }
        }

        // Phase 2: Cross-group orphan matching.
        // Pairs orphaned starts (e.g. dur_id=nil) with
        // orphaned ends (e.g. dur_id=ledger-session...)
        // of the same resource, chronologically.
        for resource in Set(orphanedStarts.keys)
            .union(orphanedEnds.keys)
        {
            var starts = (orphanedStarts[resource] ?? [])
                .sorted {
                    $0.0.occurredAt < $1.0.occurredAt
                }
            let ends = (orphanedEnds[resource] ?? [])
                .sorted {
                    $0.0.occurredAt < $1.0.occurredAt
                }

            for (endEvent, _) in ends {
                // Find latest start before this end
                if let idx = starts.lastIndex(where: {
                    $0.0.occurredAt <= endEvent.occurredAt
                }) {
                    let start = starts.remove(at: idx)
                    results.append(makePair(
                        start: start.0,
                        end: endEvent,
                        resource: resource,
                        origin: origin
                    ))
                }
                // else: truly orphaned end, discard
            }

            // Remaining starts become open-ended
            for (startEvent, _) in starts {
                results.append(DurationPair(
                    startEvent: startEvent,
                    endEvent: nil,
                    resource: resource,
                    startHash: hashIndex(
                        for: snapToHash(startEvent.occurredAt),
                        origin: origin
                    ),
                    endHash: nil
                ))
            }
        }

        return results.sorted {
            $0.startHash < $1.startHash
        }
    }

    /// Helper to build a DurationPair from matched events.
    private static func makePair(
        start: TimelineEvent,
        end: TimelineEvent,
        resource: TimelineResource,
        origin: Date
    ) -> DurationPair {
        DurationPair(
            startEvent: start,
            endEvent: end,
            resource: resource,
            startHash: hashIndex(
                for: snapToHash(start.occurredAt),
                origin: origin
            ),
            endHash: hashIndex(
                for: snapToHash(end.occurredAt),
                origin: origin
            )
        )
    }

    // MARK: - Break Detection

    private static func detectBreaks(
        totalHashes: Int,
        originHash: Date,
        durations: [DurationPair],
        pointsByHash: [Int: [(TimelineEvent, EventRegistration)]],
        activeLanes: [TimelineResource]
    ) -> [SegmentInfo] {
        guard totalHashes > 0 else { return [] }

        // Build set of "active" hashes — hashes that have content
        var activeHashes = Set<Int>()

        // Point events make their hash active
        for h in pointsByHash.keys {
            activeHashes.insert(h)
        }

        // Non-breakable duration bars make all their hashes active.
        // Session and scrollback bars are breakable — they don't count.
        for dur in durations {
            let isBreakable = dur.resource == .session || dur.resource == .scrollback
            if !isBreakable {
                let end = dur.endHash ?? (totalHashes - 1)
                for h in dur.startHash...end {
                    activeHashes.insert(h)
                }
            }
        }

        // Also mark start/end hashes of ALL durations as active
        // (even breakable ones) to anchor segments
        for dur in durations {
            activeHashes.insert(dur.startHash)
            if let end = dur.endHash {
                activeHashes.insert(end)
            }
        }

        // Mark the final hash (now) as active so
        // trailing inactivity produces either empty
        // hashes or a collapsed break at the bottom.
        activeHashes.insert(totalHashes - 1)

        // Walk hashes and detect gaps
        guard !activeHashes.isEmpty else {
            return [SegmentInfo(
                startHash: 0, endHash: totalHashes - 1, breakAfter: nil
            )]
        }

        let sortedActive = activeHashes.sorted()
        var segments: [SegmentInfo] = []
        var segStart = sortedActive.first!

        for i in 0..<(sortedActive.count - 1) {
            let current = sortedActive[i]
            let next = sortedActive[i + 1]
            let gap = next - current - 1

            if gap >= breakThreshold {
                // Insert break
                let gapSeconds = Double(gap) * hashGranularity
                segments.append(SegmentInfo(
                    startHash: segStart,
                    endHash: current,
                    breakAfter: LayoutBreak(
                        duration: gapSeconds,
                        formattedDuration: formatBreakDuration(gapSeconds)
                    )
                ))
                segStart = next
            }
        }

        // Final segment
        segments.append(SegmentInfo(
            startHash: segStart,
            endHash: sortedActive.last!,
            breakAfter: nil
        ))

        return segments
    }

    // MARK: - Hash Arithmetic

    /// Snap a date to the nearest 5-second hash boundary.
    static func snapToHash(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        let snapped = (seconds / hashGranularity).rounded() * hashGranularity
        return Date(timeIntervalSinceReferenceDate: snapped)
    }

    /// Compute hash index relative to an origin date.
    static func hashIndex(for date: Date, origin: Date) -> Int {
        let delta = date.timeIntervalSince(origin)
        return max(0, Int((delta / hashGranularity).rounded()))
    }

    // MARK: - Duration Formatting

    static func formatBreakDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)

        if totalSeconds < 60 {
            return "\(totalSeconds) sec"
        } else if totalSeconds < 3600 {
            let min = totalSeconds / 60
            let sec = totalSeconds % 60
            if sec == 0 {
                return "\(min) min"
            }
            return "\(min) min \(sec) sec"
        } else if totalSeconds < 86400 {
            let hr = totalSeconds / 3600
            let min = (totalSeconds % 3600) / 60
            if min == 0 {
                return "\(hr) hr"
            }
            return "\(hr) hr \(min) min"
        } else {
            let day = totalSeconds / 86400
            let hr = (totalSeconds % 86400) / 3600
            if hr == 0 {
                return "\(day) day\(day == 1 ? "" : "s")"
            }
            return "\(day) day\(day == 1 ? "" : "s") \(hr) hr"
        }
    }

    /// Compute the absolute timestamp for a hash index relative to origin.
    static func timestampForHash(
        _ hashIdx: Int, segmentStartHash: Int, originHash: Date
    ) -> Date {
        let globalHash = segmentStartHash + hashIdx
        let seconds = Double(globalHash) * hashGranularity
        return originHash.addingTimeInterval(seconds)
    }
}

// MARK: - Internal Types

/// Intermediate duration pairing result.
struct DurationPair {
    let startEvent: TimelineEvent
    let endEvent: TimelineEvent?
    let resource: TimelineResource
    let startHash: Int
    let endHash: Int?  // nil = open-ended
}

/// Intermediate segment info before spatial layout.
struct SegmentInfo {
    let startHash: Int
    let endHash: Int
    let breakAfter: LayoutBreak?
}

/// Width-independent time-axis computation result.
/// Reused across resize events without recomputation.
struct TimeAxisResult {
    let activeLanes: [TimelineResource]
    let segments: [SegmentInfo]
    let durations: [DurationPair]
    let pointsByHash: [Int: [(TimelineEvent, EventRegistration)]]
    let originHash: Date
    let totalHashes: Int
}
