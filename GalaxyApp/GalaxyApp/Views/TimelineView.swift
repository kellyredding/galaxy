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
    @State private var scrollToBottomTrigger: UUID =
        UUID()
    @State private var hScrollOffset: CGFloat = 0

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
                fetchTimelineEvents()
            }
            if sessionManager.activeTab != .timeline,
                session.id
                    == sessionManager.activeSessionId
            {
                nilAllState()
            }
        }
        .onChange(of: sessionManager.activeSessionId) {
            if session.id
                == sessionManager.activeSessionId,
                sessionManager.activeTab == .timeline
            {
                fetchTimelineEvents()
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
            Image(systemName: "chart.bar.xaxis")
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
                // header + outer vertical scroll
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: headerHeight)

                    ScrollViewReader { proxy in
                        ScrollView(
                            .vertical,
                            showsIndicators: true
                        ) {
                            VStack(spacing: 0) {
                                HStack(
                                    alignment: .top,
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

                                Color.clear
                                    .frame(height: 1)
                                    .id(
                                        "timeline-bottom"
                                    )
                            }
                        }
                        .onAppear {
                            proxy.scrollTo(
                                "timeline-bottom",
                                anchor:
                                    .bottomLeading
                            )
                        }
                        .onChange(
                            of: scrollToBottomTrigger
                        ) {
                            proxy.scrollTo(
                                "timeline-bottom",
                                anchor:
                                    .bottomLeading
                            )
                        }
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
            }
        }
    }

    // MARK: - Ruler Column

    @ViewBuilder
    private func rulerColumn(
        layout: TimelineLayout
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(
                Array(
                    layout.segments.enumerated()
                ),
                id: \.element.id
            ) { index, segment in
                TimelineRulerHeader(
                    date: dateForSegment(
                        segment,
                        origin: layout.originHash
                    ),
                    showDate:
                        shouldShowDateHeader(
                            layout: layout,
                            segmentIndex: index
                        )
                )

                TimelineRulerSegment(
                    segment: segment,
                    originHash: layout.originHash
                )

                if layout.breakAfter(segment) != nil
                {
                    TimelineRulerBreakSpacer()
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
        VStack(spacing: 0) {
            ForEach(
                Array(
                    layout.segments.enumerated()
                ),
                id: \.element.id
            ) { index, segment in
                TimelineContentHeaderSpacer(
                    continuationBars:
                        segment.placedBars
                            .filter {
                                $0.continuesFromPrevious
                            },
                    activeLanes:
                        layout.activeLanes,
                    laneMaxSubColumns:
                        layout.laneMaxSubColumns
                )

                TimelineContentCanvas(
                    segment: segment,
                    activeLanes:
                        layout.activeLanes,
                    availableWidth: width,
                    originHash:
                        layout.originHash,
                    laneMaxSubColumns:
                        layout.laneMaxSubColumns
                )

                if let brk = layout.breakAfter(
                    segment
                ) {
                    TimelineContentBreak(
                        duration:
                            brk.formattedDuration
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
                    self.scrollToBottomTrigger =
                        UUID()
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

    private func nilAllState() {
        events = nil
        timeAxis = nil
        layout = nil
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
