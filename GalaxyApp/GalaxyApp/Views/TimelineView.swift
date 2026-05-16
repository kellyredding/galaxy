import SwiftUI

/// Container that keeps a TimelineView alive per session
/// using a ZStack. Opacity + allowsHitTesting toggle
/// visibility without destroying state.
struct TimelineContainerView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        ZStack {
            ForEach(sessionManager.sessions) { session in
                TimelineView(session: session)
                    .opacity(
                        session.id
                            == sessionManager
                                .activeSessionId
                            ? 1 : 0
                    )
                    .allowsHitTesting(
                        session.id
                            == sessionManager
                                .activeSessionId
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Displays a session's timeline events as a swimlane
/// diagram with a spreadsheet-like frozen ruler column
/// and header row.
struct TimelineView: View {
    @ObservedObject var session: Session
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.chromeFontSize)
    private var chromeFontSize
    @Environment(\.colorScheme)
    private var colorScheme

    private var fontSize: ChromeFontSize {
        ChromeFontSize(chromeFontSize)
    }

    // JIT data state
    @State private var events: [TimelineEvent]? = nil
    @State private var timeAxis: TimeAxisResult? = nil
    @State private var layout: TimelineLayout? = nil
    @State private var isLoading: Bool = false
    @State private var fetchTask: Task<Void, Never>? =
        nil
    @State private var hScrollOffset: CGFloat = 0

    // Live refresh state
    @State private var refreshTask: Task<Void, Never>?
        = nil
    @State private var isAtBottom: Bool = true

    // Viewport-windowed rendering state
    @State private var vScrollOffset: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// Programmatic scroll target (Y offset).
    /// Set by marker chip clicks to bypass
    /// ScrollViewReader identity issues with
    /// viewport windowing.
    @State private var programmaticScrollY:
        CGFloat? = nil
    /// Buffer above and below the viewport in points.
    /// Segments within this range are rendered; the
    /// rest become lightweight spacers.
    private let renderBuffer: CGFloat = 3000.0

    // Crosshair hover state (shared across segments)
    @State private var hoverSegmentId: UUID? = nil
    @State private var hoverRow: Int? = nil
    @State private var hoverColX: CGFloat? = nil

    // Item tooltip state
    @State private var hoveredItem:
        HoveredTimelineItem? = nil
    @State private var hoveredItemPoint:
        CGPoint? = nil
    // Viewport-level mouse position for tooltip
    @State private var viewportMousePoint:
        CGPoint? = nil

    /// Identifier used to highlight the hovered item
    /// and all related segments (cross-break bars).
    /// Uses startEvent.id so cross-segment splits of the
    /// same bar highlight together, but different bars
    /// sharing a durationIdentifier (e.g. multiple
    /// session resume/end pairs) highlight independently.
    private var highlightId: String? {
        guard let item = hoveredItem
        else { return nil }
        switch item {
        case .bar(let b):
            return "\(b.startEvent.id)"
        case .dot(let d):
            return "\(d.event.id)"
        }
    }

    /// Height of the frozen lane header row.
    private let headerHeight: CGFloat = 28.0
    /// Width of the frozen ruler column.
    private let rulerWidth: CGFloat = 76.0

    var body: some View {
        Group {
            if isLoading && events == nil {
                loadingView
            } else if let layout = layout,
                !layout.segments.isEmpty
            {
                timelineContent(layout: layout)
            } else {
                emptyStateView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.textBackgroundColor))
        .onAppear {
            if session.id
                == sessionManager.activeSessionId,
                sessionManager.activeTab == .timeline
            {
                fetchTimelineEvents()
            }
        }
        .onChange(of: sessionManager.activeTab) {
            if sessionManager.activeTab == .timeline,
                session.id
                    == sessionManager.activeSessionId
            {
                // Resume polling; fetch only if
                // we have no data yet.
                if layout == nil {
                    fetchTimelineEvents()
                } else {
                    startPolling()
                }
            }
            if sessionManager.activeTab != .timeline,
                session.id
                    == sessionManager.activeSessionId
            {
                pauseState()
            }
        }
        .onChange(of: sessionManager.activeSessionId) {
            if session.id
                == sessionManager.activeSessionId,
                sessionManager.activeTab == .timeline
            {
                if layout == nil {
                    fetchTimelineEvents()
                } else {
                    startPolling()
                }
            } else if session.id
                != sessionManager.activeSessionId
            {
                nilAllState()
            }
        }
        .onDisappear {
            fetchTask?.cancel()
            fetchTask = nil
            TimelineQueryService.shared.cancelAll()
            nilAllState()
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(0.8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .chromeFont(size: fontSize.iconLarge)
                .foregroundColor(.secondary)
            Text("No timeline events yet")
                .chromeFont(size: fontSize.body)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Content Width

    /// Natural content width (lanes only, no ruler).
    private func contentNaturalWidth(
        layout: TimelineLayout
    ) -> CGFloat {
        let subColPitch: CGFloat = 25.0
        let dotDiameter: CGFloat = 10.0
        let lanePadding = subColPitch - dotDiameter
        let minLaneWidth =
            2.0 * subColPitch + lanePadding
        return layout.activeLanes.indices.reduce(
            CGFloat(0)
        ) { sum, i in
            sum
                + max(
                    minLaneWidth,
                    CGFloat(
                        layout.laneMaxSubColumns[i]
                    )
                        * subColPitch + lanePadding
                )
        }
    }

    // MARK: - Timeline Content

    private func timelineContent(
        layout: TimelineLayout
    ) -> some View {
        GeometryReader { geo in
            let natWidth = contentNaturalWidth(
                layout: layout
            )
            let contentViewport =
                geo.size.width - rulerWidth
            let contentScrollWidth = max(
                contentViewport, natWidth
            )

            ZStack(alignment: .topLeading) {
                // Main scroll area: spacer for
                // header + chip bar + outer vertical
                // scroll
                VStack(spacing: 0) {
                    Color.clear
                        .frame(
                            height: headerHeight
                                + chipBarHeight
                        )

                    ScrollView(
                            .vertical,
                            showsIndicators: true
                        ) {
                            VStack(spacing: 0) {
                                HStack(
                                    alignment:
                                        .top,
                                    spacing: 0
                                ) {
                                    rulerColumn(
                                        layout:
                                            layout
                                    )
                                    .frame(
                                        width:
                                            rulerWidth,
                                        alignment:
                                            .leading
                                    )
                                    .zIndex(1)

                                    ScrollView(
                                        .horizontal,
                                        showsIndicators:
                                            true
                                    ) {
                                        contentColumn(
                                            layout:
                                                layout,
                                            width:
                                                contentScrollWidth
                                        )
                                        .frame(
                                            width:
                                                contentScrollWidth
                                        )
                                        .background(
                                            HScrollOffsetReader(
                                                offset:
                                                    $hScrollOffset
                                            )
                                            .frame(
                                                width:
                                                    0,
                                                height:
                                                    0
                                            )
                                        )
                                    }
                                }
                            }
                            .background(
                                VScrollAtBottomReader(
                                    isAtBottom:
                                        $isAtBottom,
                                    scrollOffset:
                                        $vScrollOffset,
                                    viewportHeight:
                                        $viewportHeight,
                                    scrollToY:
                                        $programmaticScrollY
                                )
                                .frame(
                                    width: 0,
                                    height: 0
                                )
                            )
                        }
                    }

                // Frozen header row
                HStack(spacing: 0) {
                    // Corner cell
                    Rectangle()
                        .fill(
                            Color(
                                .textBackgroundColor
                            )
                        )
                        .frame(
                            width: rulerWidth,
                            height: headerHeight
                        )
                        .zIndex(1)

                    // Lane headers synced to
                    // horizontal scroll
                    TimelineLaneHeader(
                        activeLanes:
                            layout.activeLanes,
                        laneMaxSubColumns:
                            layout
                                .laneMaxSubColumns,
                        availableWidth:
                            contentScrollWidth
                    )
                    .offset(x: -hScrollOffset)
                    .frame(
                        width: contentViewport,
                        alignment: .leading
                    )
                    .clipped()
                }
                .frame(height: headerHeight)
                .background(
                    Color(.textBackgroundColor)
                )
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(
                            Color.primary
                                .opacity(0.08)
                        )
                        .frame(height: 1)
                }
                .zIndex(2)

                // Chip bars (frozen)
                VStack(spacing: 0) {
                    Color.clear.frame(
                        height: headerHeight
                    )
                    VStack(spacing: 0) {
                        TimelineDayChipBar(
                            transitions:
                                layout
                                    .dayTransitions(),
                            onNow: {
                                // Use CGFloat.infinity
                                // — the NSScrollView
                                // handler clamps to the
                                // actual max offset.
                                programmaticScrollY =
                                    .infinity
                            },
                            onSelect: { dt in
                                programmaticScrollY =
                                    dayScrollY(
                                        layout: layout,
                                        day: dt
                                    )
                            }
                        )

                        let markers =
                            layout
                                .markerTransitions()
                        if !markers.isEmpty {
                            Rectangle()
                                .fill(
                                    Color.primary
                                        .opacity(0.06)
                                )
                                .frame(height: 1)
                            TimelineMarkerChipBar(
                                markers: markers,
                                onSelect: { mt in
                                    let targetY =
                                        markerScrollY(
                                            layout:
                                                layout,
                                            marker: mt
                                        )
                                    programmaticScrollY =
                                        targetY
                                }
                            )
                        }
                    }
                    .background(
                        Color(
                            .textBackgroundColor
                        )
                    )
                    .overlay(
                        alignment: .bottom
                    ) {
                        Rectangle()
                            .fill(
                                Color.primary
                                    .opacity(
                                        0.08
                                    )
                            )
                            .frame(height: 1)
                    }
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .onAppear {
                                    chipBarHeight =
                                        g.size.height
                                }
                                .onChange(
                                    of: g.size.height
                                ) { newH in
                                    chipBarHeight =
                                        newH
                                }
                        }
                    )

                    Spacer()
                }
                .zIndex(2.5)

                // Item tooltip overlay — positioned
                // from the top-leading corner so
                // leading edge placement is exact.
                if let item = hoveredItem,
                    let pt = viewportMousePoint
                {
                    let pos =
                        tooltipOffset(
                            anchor: pt,
                            viewSize: geo.size
                        )
                    TimelineItemTooltip(
                        item: item
                    )
                    .fixedSize()
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: pos.alignment
                    )
                    .offset(
                        x: pos.x, y: pos.y
                    )
                    .allowsHitTesting(false)
                    .zIndex(3)
                }

            }  // ZStack
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt):
                    viewportMousePoint = pt
                case .ended:
                    viewportMousePoint = nil
                @unknown default:
                    viewportMousePoint = nil
                }
            }
        }  // GeometryReader
    }

    // MARK: - Click Handling

    /// Navigate to the reader view for a clicked timeline
    /// item. Mirrors the ordering used by
    /// NavigationCoordinator.apply(route:) — identifier
    /// set first, then tab — so the reader view opens
    /// pre-populated. Both @Published emissions land in
    /// the coordinator's 50ms debounce window and coalesce
    /// into a single history entry.
    private func handleItemTapped(
        _ item: HoveredTimelineItem
    ) {
        guard let target = item.clickTarget else { return }
        switch target {
        case .snapshot(let n):
            session.openSnapshotNumber = n
            sessionManager.activeTab = .snapshots
        case .artifact(let n):
            session.openArtifactNumber = n
            sessionManager.activeTab = .artifacts
        case .agent(let id):
            session.selectedAgentId = id
            sessionManager.activeTab = .agents
        }
    }

    // MARK: - Tooltip Positioning

    private struct TooltipPosition {
        let x: CGFloat
        let y: CGFloat
        let alignment: Alignment
    }

    /// Compute offset from the alignment corner.
    /// Uses .topLeading when placing right of cursor,
    /// .topTrailing when placing left of cursor.
    /// Flips above the cursor when near the bottom.
    private func tooltipOffset(
        anchor: CGPoint,
        viewSize: CGSize
    ) -> TooltipPosition {
        let gap: CGFloat = 12.0
        let maxW: CGFloat = 260.0
        let maxH: CGFloat = 120.0

        // Vertical: flip above cursor when tooltip
        // would extend beyond the bottom edge.
        let nearBottom =
            anchor.y + maxH > viewSize.height
        let yComponent: (CGFloat, vertical: String) =
            nearBottom
            ? (-(viewSize.height - anchor.y + gap),
                "bottom")
            : (anchor.y, "top")

        // Horizontal: try right side first, flip
        // left if it would overflow.
        let rightLeading = anchor.x + gap
        if rightLeading + maxW <= viewSize.width {
            let align: Alignment =
                yComponent.vertical == "bottom"
                ? .bottomLeading : .topLeading
            return TooltipPosition(
                x: rightLeading,
                y: yComponent.0,
                alignment: align
            )
        }

        let align: Alignment =
            yComponent.vertical == "bottom"
            ? .bottomTrailing : .topTrailing
        return TooltipPosition(
            x: -(viewSize.width - anchor.x + gap),
            y: yComponent.0,
            alignment: align
        )
    }

    // MARK: - Viewport Windowing

    /// Height of one segment slot (header + body +
    /// optional break). Used to compute cumulative
    /// offsets for viewport visibility testing.
    private func segmentSlotHeight(
        _ segment: LayoutSegment
    ) -> CGFloat {
        let header = TimelineContentHeaderSpacer.height
        let body = segment.height
        let brk: CGFloat =
            if let b = segment.breakAfter {
                b.markerTitle != nil
                    ? TimelineContentBreak.markerBreakHeight
                    : TimelineContentBreak.breakHeight
            } else {
                0
            }
        return header + body + brk
    }

    /// Determine the range of segment indices that
    /// fall within the visible viewport plus the
    /// render buffer.
    private func visibleSegmentRange(
        layout: TimelineLayout
    ) -> ClosedRange<Int> {
        let count = layout.segments.count
        guard count > 0 else { return 0...0 }

        let top = vScrollOffset - renderBuffer
        let bottom =
            vScrollOffset + viewportHeight
            + renderBuffer

        var cumY: CGFloat = 0
        var first: Int? = nil
        var last: Int = count - 1

        for i in 0..<count {
            let slotH = segmentSlotHeight(
                layout.segments[i]
            )
            let slotBottom = cumY + slotH

            if first == nil, slotBottom > top {
                first = i
            }
            if cumY > bottom {
                last = max(0, i - 1)
                break
            }
            cumY = slotBottom
        }

        let lo = first ?? 0
        return lo...min(last, count - 1)
    }

    // MARK: - Ruler Column

    @ViewBuilder
    private func rulerColumn(
        layout: TimelineLayout
    ) -> some View {
        let visible = visibleSegmentRange(
            layout: layout
        )
        VStack(spacing: 0) {
            ForEach(
                Array(
                    layout.segments.enumerated()
                ),
                id: \.element.id
            ) { index, segment in
                if visible.contains(index) {
                    TimelineRulerHeader(
                        date: dateForSegment(
                            segment,
                            origin: layout.originHash
                        ),
                        showDate:
                            shouldShowDateHeader(
                                layout: layout,
                                segmentIndex: index
                            ),
                        segmentId: segment.id,
                        isHighlighted:
                            hoverSegmentId
                                == segment.id
                                && hoverRow == -1,
                        hoverSegmentIdBinding:
                            $hoverSegmentId,
                        hoverRowBinding:
                            $hoverRow
                    )

                    TimelineRulerSegment(
                        segment: segment,
                        originHash: layout.originHash,
                        isHoveredSegment:
                            hoverSegmentId
                                == segment.id,
                        hoverRow: hoverRow,
                        hoverSegmentIdBinding:
                            $hoverSegmentId,
                        hoverRowBinding:
                            $hoverRow
                    )

                    if let brk = layout.breakAfter(
                        segment
                    ) {
                        TimelineRulerBreakSpacer(
                            isMarker:
                                brk.markerTitle != nil
                        )
                    }
                } else {
                    Color.clear.frame(
                        height: segmentSlotHeight(
                            segment
                        )
                    )
                }
            }
        }
    }

    // MARK: - Content Column

    @ViewBuilder
    private func contentColumn(
        layout: TimelineLayout,
        width: CGFloat
    ) -> some View {
        let visible = visibleSegmentRange(
            layout: layout
        )
        VStack(spacing: 0) {
            ForEach(
                Array(
                    layout.segments.enumerated()
                ),
                id: \.element.id
            ) { index, segment in
                if visible.contains(index) {
                    TimelineContentHeaderSpacer(
                        continuationBars:
                            segment.placedBars
                                .filter {
                                    $0.continuesFromPrevious
                                },
                        activeLanes:
                            layout.activeLanes,
                        laneMaxSubColumns:
                            layout.laneMaxSubColumns,
                        hoverColX: hoverColX,
                        isHighlighted:
                            hoverSegmentId
                                == segment.id
                                && hoverRow == -1,
                        segmentId: segment.id,
                        hoverSegmentIdBinding:
                            $hoverSegmentId,
                        hoverRowBinding:
                            $hoverRow,
                        hoveredItemBinding:
                            $hoveredItem,
                        hoveredItemPointBinding:
                            $hoveredItemPoint,
                        highlightId: highlightId
                    )

                    TimelineContentCanvas(
                        segment: segment,
                        activeLanes:
                            layout.activeLanes,
                        availableWidth: width,
                        originHash:
                            layout.originHash,
                        laneMaxSubColumns:
                            layout.laneMaxSubColumns,
                        hoverSegmentId:
                            $hoverSegmentId,
                        hoverRow: $hoverRow,
                        hoverColX: $hoverColX,
                        hoveredItem:
                            $hoveredItem,
                        hoveredItemPoint:
                            $hoveredItemPoint,
                        highlightId: highlightId,
                        onItemTapped: handleItemTapped
                    )

                    if let brk = layout.breakAfter(
                        segment
                    ) {
                        TimelineContentBreak(
                            duration:
                                brk.formattedDuration,
                            markerTitle:
                                brk.markerTitle,
                            hoverColX: hoverColX
                        )
                    }
                } else {
                    Color.clear.frame(
                        height: segmentSlotHeight(
                            segment
                        )
                    )
                }
            }
        }
    }

    // MARK: - Date Header Logic

    private func dateForSegment(
        _ segment: LayoutSegment, origin: Date
    ) -> Date {
        let seconds = Double(segment.startHash)
            * TimelineLayoutEngine.hashGranularity
        return origin.addingTimeInterval(seconds)
    }

    private func shouldShowDateHeader(
        layout: TimelineLayout, segmentIndex: Int
    ) -> Bool {
        if segmentIndex == 0 { return true }

        let prevSegment =
            layout.segments[segmentIndex - 1]
        let thisSegment =
            layout.segments[segmentIndex]

        let prevEndSeconds = Double(
            prevSegment.endHash
        )
            * TimelineLayoutEngine.hashGranularity
        let prevEndDate =
            layout.originHash.addingTimeInterval(
                prevEndSeconds
            )
        let thisStartDate = dateForSegment(
            thisSegment, origin: layout.originHash
        )

        let calendar = Calendar.current
        return !calendar.isDate(
            prevEndDate, inSameDayAs: thisStartDate
        )
    }

    // MARK: - Programmatic Scroll Offsets

    /// Compute the cumulative Y offset for a marker's
    /// target segment. Returns the sum of all segment
    /// slot heights before the target index.
    /// Scroll target for a marker chip. Positions the
    /// viewport so the marker pill itself is at the
    /// top. The cumulative Y up to the target segment
    /// lands just AFTER the break, so we subtract the
    /// marker break height to show the pill.
    /// Scroll target for a day chip. Positions the
    /// viewport so the day's ruler header is at the
    /// top — cumulative height of all segments before
    /// the day's first segment.
    private func dayScrollY(
        layout: TimelineLayout,
        day dt: DayTransition
    ) -> CGFloat {
        var cumY: CGFloat = 0
        for i in 0..<min(
            dt.segmentIndex, layout.segments.count
        ) {
            cumY += segmentSlotHeight(
                layout.segments[i]
            )
        }
        return cumY
    }

    private func markerScrollY(
        layout: TimelineLayout,
        marker mt: MarkerTransition
    ) -> CGFloat {
        let target = mt.segmentIndex + 1
        var cumY: CGFloat = 0
        for i in 0..<min(
            target, layout.segments.count
        ) {
            cumY += segmentSlotHeight(
                layout.segments[i]
            )
        }
        return max(
            0,
            cumY
                - TimelineContentBreak
                    .markerBreakHeight
        )
    }

    /// Measured height of the frozen chip bar area.
    @State private var chipBarHeight: CGFloat = 30.0

    // MARK: - Data Fetching

    private func fetchTimelineEvents() {
        guard let lsid = session.ledgerSessionId
        else { return }
        guard !isLoading else { return }

        fetchTask?.cancel()
        fetchTask = Task {
            isLoading = true

            do {
                let fetched =
                    try await TimelineQueryService
                    .shared.fetchEvents(
                        ledgerSessionId: lsid
                    )
                guard !Task.isCancelled
                else { return }

                await MainActor.run {
                    self.events = fetched
                    self.timeAxis =
                        TimelineLayoutEngine
                        .computeTimeAxis(
                            events: fetched
                        )
                    if let ta = self.timeAxis {
                        self.layout =
                            TimelineLayoutEngine
                            .computeSpatial(
                                timeAxis: ta,
                                availableWidth: 800
                            )
                    } else {
                        self.layout = nil
                    }
                    self.isLoading = false
                    // Initial scroll to bottom is
                    // handled by the
                    // VScrollAtBottomReader's
                    // currentScrollState() when the
                    // document view's frame grows from
                    // zero to its laid-out size. Same
                    // mechanism that handles refresh-
                    // tail, so the two paths share one
                    // animation and don't fight.
                    startPolling()
                }
            } catch {
                guard !Task.isCancelled
                else { return }
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - Live Refresh

    private func refreshTimelineEvents() {
        // Skip refresh while hovering to avoid
        // re-render flashing dimmed items.
        guard hoveredItem == nil else { return }

        guard let lsid = session.ledgerSessionId
        else { return }

        Task {
            do {
                let fetched =
                    try await TimelineQueryService
                    .shared.fetchEvents(
                        ledgerSessionId: lsid
                    )
                guard !Task.isCancelled
                else { return }

                await MainActor.run {
                    self.events = fetched
                    self.timeAxis =
                        TimelineLayoutEngine
                        .computeTimeAxis(
                            events: fetched
                        )
                    if let ta = self.timeAxis {
                        self.layout =
                            TimelineLayoutEngine
                            .computeSpatial(
                                timeAxis: ta,
                                availableWidth: 800
                            )
                    } else {
                        self.layout = nil
                    }
                    // Follow-tail handled inside the
                    // VScrollAtBottomReader's
                    // currentScrollState() — it sees the
                    // doc grow and re-snaps if the user
                    // was at bottom. Avoid setting
                    // programmaticScrollY here because
                    // doing so reads the doc height
                    // before AppKit lays out the new
                    // content and clamps to the stale
                    // bottom.
                }
            } catch {
                // Silently ignore refresh errors —
                // next tick will retry
            }
        }
    }

    private func startPolling() {
        stopPolling()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(5)
                )
                guard !Task.isCancelled
                else { break }
                refreshTimelineEvents()
            }
        }
    }

    private func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Light pause: stop polling and clear transient
    /// hover state but keep data alive so the view
    /// tree (and scroll position) is preserved.
    private func pauseState() {
        stopPolling()
        hoveredItem = nil
        hoveredItemPoint = nil
        viewportMousePoint = nil
    }

    private func nilAllState() {
        stopPolling()
        events = nil
        timeAxis = nil
        layout = nil
        hoveredItem = nil
        hoveredItemPoint = nil
        viewportMousePoint = nil
    }
}

// MARK: - Vertical Scroll At-Bottom Reader

/// NSViewRepresentable that tracks whether the
/// enclosing vertical NSScrollView is scrolled to
/// the bottom. Mirrors the HScrollOffsetReader
/// pattern but reports a boolean instead of an offset.
struct VScrollAtBottomReader: NSViewRepresentable {
    @Binding var isAtBottom: Bool
    @Binding var scrollOffset: CGFloat
    @Binding var viewportHeight: CGFloat
    @Binding var scrollToY: CGFloat?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(
        context: Context
    ) -> AtBottomTrackingNSView {
        let view = AtBottomTrackingNSView()
        view.coordinator = context.coordinator
        context.coordinator.updateBinding = {
            [weak view] in
            guard let state =
                view?.currentScrollState()
            else { return }
            self.isAtBottom = state.isAtBottom
            self.scrollOffset = state.scrollOffset
            self.viewportHeight =
                state.viewportHeight
        }
        return view
    }

    func updateNSView(
        _ nsView: AtBottomTrackingNSView,
        context: Context
    ) {
        context.coordinator.updateBinding = {
            [weak nsView] in
            guard let state =
                nsView?.currentScrollState()
            else { return }
            self.isAtBottom = state.isAtBottom
            self.scrollOffset = state.scrollOffset
            self.viewportHeight =
                state.viewportHeight
        }

        // Handle programmatic scroll requests
        if let targetY = scrollToY {
            guard let scrollView =
                nsView.enclosingScrollView
            else { return }
            let clip = scrollView.contentView
            let docHeight =
                scrollView.documentView?
                .frame.height ?? 0

            // Content not laid out yet — leave the
            // request pending so the next
            // updateNSView (triggered by layout
            // completing) retries automatically.
            if docHeight < 1 { return }

            let maxY = max(
                0, docHeight - clip.bounds.height
            )
            let clampedY = min(targetY, maxY)

            NSAnimationContext.runAnimationGroup {
                ctx in
                ctx.duration = 0.3
                ctx.timingFunction =
                    CAMediaTimingFunction(
                        name: .easeInEaseOut
                    )
                clip.animator().setBoundsOrigin(
                    NSPoint(x: 0, y: clampedY)
                )
            }

            DispatchQueue.main.async {
                self.scrollToY = nil
            }
        }
    }

    class Coordinator {
        var updateBinding: (() -> Void)?
    }

    class AtBottomTrackingNSView: NSView {
        weak var coordinator: Coordinator?
        private var boundsObs: Any?
        private var frameObs: Any?
        /// Last observed document height. Used to detect
        /// "doc grew while user was at bottom" so the
        /// follow-tail re-snap fires independently of the
        /// polling-based programmaticScrollY channel.
        private var lastDocHeight: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, boundsObs == nil {
                setupObservation()
            }
        }

        private func setupObservation() {
            guard let scrollView =
                enclosingScrollView
            else { return }

            // Use legacy scrollers so the
            // scrollbar has a dedicated track
            // outside the content — always
            // visible and reliably draggable.
            scrollView.scrollerStyle = .legacy
            scrollView.hasVerticalScroller = true

            // Observe clip view bounds changes
            // (user scrolling, programmatic scroll)
            scrollView.contentView
                .postsBoundsChangedNotifications =
                true
            boundsObs =
                NotificationCenter.default
                .addObserver(
                    forName: NSView
                        .boundsDidChangeNotification,
                    object:
                        scrollView.contentView,
                    queue: .main
                ) { [weak self] _ in
                    self?.coordinator?
                        .updateBinding?()
                }

            // Observe document view frame changes
            // (content laid out, height grows from
            // 0). This triggers updateNSView so
            // pending scroll requests are retried
            // once content is available.
            if let docView =
                scrollView.documentView
            {
                docView
                    .postsFrameChangedNotifications =
                    true
                frameObs =
                    NotificationCenter.default
                    .addObserver(
                        forName: NSView
                            .frameDidChangeNotification,
                        object: docView,
                        queue: .main
                    ) { [weak self] _ in
                        self?.coordinator?
                            .updateBinding?()
                    }
            }
        }

        /// Snapshot the current scroll state and, if the
        /// document just grew while the user was at (or
        /// within slop of) the previous bottom, re-snap
        /// the clip view to the new bottom. Returns the
        /// values the SwiftUI bindings should be updated
        /// to, or nil if the scroll view isn't ready.
        ///
        /// Decouples follow-tail from the polling-based
        /// scrollToY channel so a stale doc-height read
        /// can't strand the viewport above new content.
        func currentScrollState() -> (
            isAtBottom: Bool,
            scrollOffset: CGFloat,
            viewportHeight: CGFloat
        )? {
            guard let scrollView = enclosingScrollView
            else { return nil }
            let clip = scrollView.contentView
            let docHeight =
                scrollView.documentView?
                .frame.height ?? 0
            let visibleMax =
                clip.bounds.origin.y
                + clip.bounds.height

            // "Was the user at (or within slop of) the
            // previous bottom?" On the first call
            // lastDocHeight is 0 — treat that as yes so
            // the initial layout pass animates to bottom.
            let wasAtBottom =
                lastDocHeight > 0
                ? (visibleMax >= lastDocHeight - 20)
                : true
            let docGrew =
                docHeight > lastDocHeight + 0.5

            let newAtBottom =
                visibleMax >= docHeight - 20

            if docGrew && wasAtBottom && !newAtBottom {
                let maxY = max(
                    0,
                    docHeight - clip.bounds.height
                )
                // Animate, don't snap. The animator
                // emits intermediate bounds-change
                // notifications across its duration; each
                // re-runs currentScrollState and writes
                // the binding through to vScrollOffset,
                // so the viewport-windowed segments re-
                // render at the new clip position. An
                // instant setBoundsOrigin moves the clip
                // before SwiftUI can update vScrollOffset
                // and leaves the viewport rendering
                // spacers instead of real content.
                NSAnimationContext.runAnimationGroup {
                    ctx in
                    ctx.duration = 0.2
                    ctx.timingFunction =
                        CAMediaTimingFunction(
                            name: .easeOut
                        )
                    clip.animator().setBoundsOrigin(
                        NSPoint(x: 0, y: maxY)
                    )
                }
            }

            lastDocHeight = docHeight

            return (
                isAtBottom: newAtBottom,
                scrollOffset: clip.bounds.origin.y,
                viewportHeight: clip.bounds.height
            )
        }

        deinit {
            if let obs = boundsObs {
                NotificationCenter.default
                    .removeObserver(obs)
            }
            if let obs = frameObs {
                NotificationCenter.default
                    .removeObserver(obs)
            }
        }
    }
}

// MARK: - Horizontal Scroll Offset Reader

/// NSViewRepresentable that hooks into the enclosing
/// NSScrollView to track horizontal scroll offset
/// with frame-accurate precision.
struct HScrollOffsetReader: NSViewRepresentable {
    @Binding var offset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(
        context: Context
    ) -> OffsetTrackingNSView {
        let view = OffsetTrackingNSView()
        view.coordinator = context.coordinator
        context.coordinator.updateBinding = {
            [weak view] in
            guard let view = view,
                let scrollView =
                    view.enclosingScrollView
            else { return }
            self.offset =
                scrollView.contentView.bounds
                .origin.x
        }
        return view
    }

    func updateNSView(
        _ nsView: OffsetTrackingNSView,
        context: Context
    ) {
        context.coordinator.updateBinding = {
            [weak nsView] in
            guard let nsView = nsView,
                let scrollView =
                    nsView.enclosingScrollView
            else { return }
            self.offset =
                scrollView.contentView.bounds
                .origin.x
        }
    }

    class Coordinator {
        var updateBinding: (() -> Void)?
    }

    class OffsetTrackingNSView: NSView {
        weak var coordinator: Coordinator?
        private var observation: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, observation == nil {
                setupObservation()
            }
        }

        private func setupObservation() {
            guard let scrollView =
                enclosingScrollView
            else { return }
            scrollView.contentView
                .postsBoundsChangedNotifications =
                true
            observation =
                NotificationCenter.default
                .addObserver(
                    forName: NSView
                        .boundsDidChangeNotification,
                    object:
                        scrollView.contentView,
                    queue: .main
                ) { [weak self] _ in
                    self?.coordinator?
                        .updateBinding?()
                }
        }

        deinit {
            if let obs = observation {
                NotificationCenter.default
                    .removeObserver(obs)
            }
        }
    }
}
