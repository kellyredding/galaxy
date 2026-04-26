import AppKit
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

        // 2. Sort by occurred_at, then by event id as a stable
        // tiebreaker. Without the id tiebreaker, events that share
        // the same occurredAt can switch relative order across
        // re-renders depending on source-data fetch order, which
        // bleeds into nondeterministic sub-column placement
        // downstream.
        let sorted = registered.sorted { lhs, rhs in
            if lhs.0.occurredAt != rhs.0.occurredAt {
                return lhs.0.occurredAt < rhs.0.occurredAt
            }
            return lhs.0.id < rhs.0.id
        }

        // 3. Determine active lanes
        let activeResources = Set(sorted.map { $0.1.resource })
        let activeLanes = Array(TimelineResource.allCases)
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

        // 6b. Build hash -> events mapping for marker
        // events (separate from dots, but their hashes
        // still count as "active" for break detection)
        var markersByHash: [Int: [(
            TimelineEvent, EventRegistration
        )]] = [:]
        for (event, reg) in sorted
            where reg.mode == .marker
        {
            let h = hashIndex(
                for: snapToHash(event.occurredAt),
                origin: originHash
            )
            markersByHash[h, default: []]
                .append((event, reg))
        }

        // 7. Detect breaks
        let segments = detectBreaks(
            totalHashes: totalHashes,
            originHash: originHash,
            durations: durations,
            pointsByHash: pointsByHash,
            markersByHash: markersByHash,
            activeLanes: activeLanes
        )

        return TimeAxisResult(
            activeLanes: activeLanes,
            segments: segments,
            durations: durations,
            pointsByHash: pointsByHash,
            markersByHash: markersByHash,
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

            // Collect markers for this segment (no
            // lane packing — they span full width)
            var markerEntries: [(
                TimelineEvent, Int
            )] = []  // (event, localHash)
            let mStart = segmentInfo.startHash
            let mEnd = segmentInfo.endHash
            for hashIdx in mStart...mEnd {
                guard let markers =
                    timeAxis.markersByHash[hashIdx]
                else { continue }
                let localHash =
                    hashIdx - segmentInfo.startHash
                for (event, _) in markers {
                    markerEntries.append(
                        (event, localHash)
                    )
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

                // Pack bars first (sorted by start hash, then
                // by start-event id as a deterministic tiebreaker
                // for bars that share the same starting slot).
                // Lower id sorts first → gets the leftmost free
                // sub-column, so bar placement within a slot is
                // stable across re-renders.
                let laneBarIndices = barEntries.indices
                    .filter { barEntries[$0].laneIndex == lane }
                    .sorted { lhs, rhs in
                        let a = barEntries[lhs]
                        let b = barEntries[rhs]
                        if a.localStart != b.localStart {
                            return a.localStart < b.localStart
                        }
                        return a.dur.startEvent.id
                            < b.dur.startEvent.id
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
                    let hi = barEntries[bi].dur.endEvent
                        == nil
                        ? max(
                            barEntries[bi].localEnd,
                            hashCount - 1
                        )
                        : barEntries[bi].localEnd
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
                    // Open-ended bars render to the full
                    // segment height, so claim the entire
                    // segment for packing to prevent dots
                    // from being placed behind the bar.
                    let hi = barEntries[bi].dur.endEvent
                        == nil
                        ? max(
                            barEntries[bi].localEnd,
                            hashCount - 1
                        )
                        : barEntries[bi].localEnd
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

                // Pack dots (sorted by hash, then by event id as
                // a deterministic tiebreaker for dots sharing the
                // same hash bucket — multiple point events at the
                // same instant). Lower id → leftmost sub-column.
                let laneDotIndices = dotEntries.indices
                    .filter { dotEntries[$0].laneIndex == lane }
                    .sorted { lhs, rhs in
                        let a = dotEntries[lhs]
                        let b = dotEntries[rhs]
                        if a.localHash != b.localHash {
                            return a.localHash < b.localHash
                        }
                        return a.event.id < b.event.id
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

            let placedMarkers: [PlacedMarker] =
                markerEntries
                    .map { event, localHash in
                        let title =
                            extractMarkerTitle(
                                from: event.detailData
                            )
                        let width =
                            measureMarkerTitle(title)
                        return PlacedMarker(
                            event: event,
                            title: title,
                            titleWidth: width,
                            hashIndex: localHash
                        )
                    }

            layoutSegments.append(LayoutSegment(
                startHash: segmentInfo.startHash,
                endHash: segmentInfo.endHash,
                hashCount: hashCount,
                height: segmentHeight,
                placedDots: placedDots,
                placedBars: placedBars,
                placedMarkers: placedMarkers,
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
                placedMarkers: seg.placedMarkers,
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
            case .point, .marker:
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
        markersByHash: [Int: [(TimelineEvent, EventRegistration)]],
        activeLanes: [TimelineResource]
    ) -> [SegmentInfo] {
        guard totalHashes > 0 else { return [] }

        // Build set of "active" hashes — hashes that have content
        var activeHashes = Set<Int>()

        // Point events make their hash active
        for h in pointsByHash.keys {
            activeHashes.insert(h)
        }

        // Marker events also make their hash active
        // (ends inactivity gaps)
        for h in markersByHash.keys {
            activeHashes.insert(h)
        }

        // All duration bars are breakable — they don't
        // prevent breaks in inactive gaps. Only their
        // start/end hashes are anchored (below).

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
        let markerHashes = Set(markersByHash.keys)
        var segments: [SegmentInfo] = []
        var segStart = sortedActive.first!

        for i in 0..<(sortedActive.count - 1) {
            let current = sortedActive[i]
            let next = sortedActive[i + 1]
            let gap = next - current - 1

            if gap >= breakThreshold {
                // Insert inactivity break
                let gapSeconds =
                    Double(gap) * hashGranularity
                segments.append(SegmentInfo(
                    startHash: segStart,
                    endHash: current,
                    breakAfter: LayoutBreak(
                        duration: gapSeconds,
                        formattedDuration:
                            formatBreakDuration(
                                gapSeconds
                            )
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

        // Post-process: split segments at marker
        // boundaries. The marker hash is excluded from
        // all segments — it becomes a marker break
        // between the segment before and after. Duration
        // bars split with continuation caps at the
        // marker, just like inactivity breaks.
        guard !markerHashes.isEmpty else {
            return segments
        }
        var result: [SegmentInfo] = []
        for seg in segments {
            let markers = markerHashes
                .filter {
                    $0 >= seg.startHash
                        && $0 <= seg.endHash
                }
                .sorted()
            if markers.isEmpty {
                result.append(seg)
                continue
            }
            var cursor = seg.startHash
            for mh in markers {
                let title = extractMarkerTitle(
                    from: markersByHash[mh]?
                        .first?.0.detailData
                )
                // Segment before this marker
                if mh > cursor {
                    result.append(SegmentInfo(
                        startHash: cursor,
                        endHash: mh - 1,
                        breakAfter: LayoutBreak(
                            duration: 0,
                            formattedDuration: "",
                            markerTitle: title
                        )
                    ))
                } else if let prev = result.last {
                    // Marker is at segment start —
                    // attach to previous segment's
                    // break. Replace the existing
                    // breakAfter with the marker
                    // break.
                    result[result.count - 1] =
                        SegmentInfo(
                            startHash: prev.startHash,
                            endHash: prev.endHash,
                            breakAfter: LayoutBreak(
                                duration:
                                    prev.breakAfter?
                                    .duration ?? 0,
                                formattedDuration:
                                    prev.breakAfter?
                                    .formattedDuration
                                    ?? "",
                                markerTitle: title
                            )
                        )
                }
                cursor = mh + 1
            }
            // Remaining hashes after last marker
            if cursor <= seg.endHash {
                result.append(SegmentInfo(
                    startHash: cursor,
                    endHash: seg.endHash,
                    breakAfter: seg.breakAfter
                ))
            } else {
                // Marker was at or past segment end
                // — preserve the original breakAfter
                // on the last result segment if it
                // doesn't already have one.
                if seg.breakAfter != nil,
                    let last = result.last,
                    last.breakAfter?.markerTitle != nil
                {
                    // Already has marker break —
                    // the original breakAfter (e.g.
                    // inactivity) is superseded.
                }
            }
        }
        return result
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

    // MARK: - Marker Helpers

    /// Maximum display characters for marker titles.
    /// Titles longer than this are truncated with "…".
    /// Keeps pre-computed text width stable regardless
    /// of canvas width — the trailing dash line adapts
    /// to fill remaining space at any window size.
    private static let markerTitleMaxChars = 80

    /// Extract title from marker detail_data JSON.
    /// Truncates to `markerTitleMaxChars` with ellipsis
    /// so the pre-computed width is bounded.
    private static func extractMarkerTitle(
        from detailData: String?
    ) -> String {
        guard let data = detailData,
            let jsonData = data.data(using: .utf8),
            let dict = try? JSONSerialization
                .jsonObject(with: jsonData)
                as? [String: Any],
            let title = dict["title"] as? String
        else { return "Marker" }
        if title.count > markerTitleMaxChars {
            return String(
                title.prefix(
                    markerTitleMaxChars - 1
                )
            ) + "…"
        }
        return title
    }

    /// Font used for marker title rendering. Defined
    /// once so layout measurement and canvas drawing
    /// use the same metrics.
    static let markerTitleFont: NSFont =
        NSFont.monospacedSystemFont(
            ofSize: 10.0, weight: .bold
        )

    /// Pre-compute marker title text width using
    /// NSAttributedString so the canvas only does
    /// path strokes and resolved text draws — no
    /// measurement per frame.
    private static func measureMarkerTitle(
        _ title: String
    ) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: markerTitleFont,
        ]
        let size = (title as NSString)
            .size(withAttributes: attrs)
        return ceil(size.width)
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
    let markersByHash: [Int: [(TimelineEvent, EventRegistration)]]
    let originHash: Date
    let totalHashes: Int
}
