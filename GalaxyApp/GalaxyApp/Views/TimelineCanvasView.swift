import SwiftUI

// MARK: - Content Canvas (bars + dots, no ruler)

/// Renders bars, dots, and lane separators for a segment.
/// The hash rail is handled separately by TimelineRulerSegment.
struct TimelineContentCanvas: View {
    let segment: LayoutSegment
    let activeLanes: [TimelineResource]
    let availableWidth: CGFloat
    let originHash: Date
    let laneMaxSubColumns: [Int]
    let dotDiameter: CGFloat = 10.0

    // Shared crosshair state (owned by TimelineView)
    @Binding var hoverSegmentId: UUID?
    @Binding var hoverRow: Int?
    @Binding var hoverColX: CGFloat?

    // Item tooltip state (owned by TimelineView)
    @Binding var hoveredItem: HoveredTimelineItem?
    @Binding var hoveredItemPoint: CGPoint?

    // Cross-segment highlight (duration ID or event
    // ID of the currently hovered item).
    var highlightId: String? = nil

    private let subColPitch: CGFloat = 25.0

    private var lanePadding: CGFloat {
        subColPitch - dotDiameter
    }

    private var laneInset: CGFloat {
        lanePadding + dotDiameter / 2.0
    }

    private var minLaneWidth: CGFloat {
        2.0 * subColPitch + lanePadding
    }

    private var laneWidths: [CGFloat] {
        activeLanes.indices.map {
            max(
                minLaneWidth,
                CGFloat(laneMaxSubColumns[$0])
                    * subColPitch + lanePadding
            )
        }
    }

    /// Lane X offsets starting at 0 (no hash rail offset).
    private var laneXOffsets: [CGFloat] {
        var offsets: [CGFloat] = []
        var x: CGFloat = 0
        for w in laneWidths {
            offsets.append(x)
            x += w
        }
        return offsets
    }

    var body: some View {
        Canvas { context, size in
            drawCrosshair(
                context: context, size: size
            )
            drawLaneSeparators(
                context: context, size: size
            )
            drawBars(context: context, size: size)
            drawDots(context: context, size: size)
        }
        .frame(height: segment.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                updateHover(at: point)
            case .ended:
                hoverSegmentId = nil
                hoverRow = nil
                hoverColX = nil
                hoveredItem = nil
                hoveredItemPoint = nil
            @unknown default:
                hoverSegmentId = nil
                hoverRow = nil
                hoverColX = nil
                hoveredItem = nil
                hoveredItemPoint = nil
            }
        }
    }

    // MARK: - Hover

    private func updateHover(at point: CGPoint) {
        hoverSegmentId = segment.id

        let hashHeight =
            TimelineLayoutEngine.hashHeight
        let row = Int(point.y / hashHeight)
        hoverRow = (row >= 0
            && row < segment.hashCount)
            ? row : nil

        // Find lane and sub-column
        let offsets = laneXOffsets
        let widths = laneWidths
        hoverColX = nil

        for i in 0..<activeLanes.count {
            let laneStart = offsets[i]
            let laneEnd = laneStart + widths[i]
            guard point.x >= laneStart,
                point.x < laneEnd
            else { continue }

            let relX = point.x - laneStart
                - lanePadding / 2.0
            if relX >= 0 {
                let subCol = Int(
                    relX / subColPitch
                )
                if subCol >= 0,
                    subCol < laneMaxSubColumns[i]
                {
                    let centerX = offsets[i]
                        + laneInset
                        + CGFloat(subCol)
                            * subColPitch
                    hoverColX = centerX
                        - subColPitch / 2.0
                }
            }
            break
        }

        // Hit-test placed items
        hitTestItem(at: point)
    }

    private func hitTestItem(at point: CGPoint) {
        let hashHeight =
            TimelineLayoutEngine.hashHeight
        let halfDot = dotDiameter / 2.0
        let offsets = laneXOffsets

        // Check dots first (smaller targets, higher
        // priority when overlapping bars)
        for dot in segment.placedDots {
            let centerX = offsets[dot.laneIndex]
                + laneInset
                + CGFloat(dot.subColumn)
                    * subColPitch
            let centerY = CGFloat(dot.hashIndex)
                * hashHeight + hashHeight / 2.0
            let dx = point.x - centerX
            let dy = point.y - centerY
            let hitRadius = halfDot + 3.0
            if dx * dx + dy * dy
                <= hitRadius * hitRadius
            {
                hoveredItem = .dot(dot)
                hoveredItemPoint = point
                return
            }
        }

        // Check bars
        for bar in segment.placedBars {
            let barWidth = dotDiameter
            let laneCenterX =
                offsets[bar.laneIndex]
                + laneInset
                + CGFloat(bar.subColumn)
                    * subColPitch

            var topY = CGFloat(bar.startHashIndex)
                * hashHeight + hashHeight / 2.0
                - halfDot
            var bottomY = CGFloat(bar.endHashIndex)
                * hashHeight + hashHeight / 2.0
                + halfDot

            if bar.continuesFromPrevious {
                topY = 0
            }
            if bar.continuesIntoNext
                || bar.isOpenEnded
            {
                bottomY = CGFloat(
                    segment.hashCount
                ) * hashHeight
            }

            let hitPad: CGFloat = 3.0
            let rect = CGRect(
                x: laneCenterX - barWidth / 2.0
                    - hitPad,
                y: topY,
                width: barWidth + hitPad * 2.0,
                height: max(
                    dotDiameter,
                    bottomY - topY
                )
            )
            if rect.contains(point) {
                hoveredItem = .bar(bar)
                hoveredItemPoint = point
                return
            }
        }

        hoveredItem = nil
        hoveredItemPoint = nil
    }

    // MARK: - Crosshair

    private func drawCrosshair(
        context: GraphicsContext, size: CGSize
    ) {
        let hashHeight =
            TimelineLayoutEngine.hashHeight
        let highlight = Color.primary.opacity(0.06)

        // Row highlight: only in the hovered segment
        if hoverSegmentId == segment.id,
            let row = hoverRow
        {
            let y = CGFloat(row) * hashHeight
            context.fill(
                Path(CGRect(
                    x: 0, y: y,
                    width: size.width,
                    height: hashHeight
                )),
                with: .color(highlight)
            )
        }

        // Column highlight: all segments (disabled)
        // if let colX = hoverColX {
        //     context.fill(
        //         Path(CGRect(
        //             x: colX, y: 0,
        //             width: subColPitch,
        //             height: size.height
        //         )),
        //         with: .color(highlight)
        //     )
        // }
    }

    // MARK: - Drawing

    private func drawLaneSeparators(
        context: GraphicsContext, size: CGSize
    ) {
        guard !activeLanes.isEmpty else { return }
        let offsets = laneXOffsets
        let widths = laneWidths

        // Leading edge + between lanes + trailing edge
        for i in 0...activeLanes.count {
            let x: CGFloat
            if i < activeLanes.count {
                x = offsets[i]
            } else {
                x = offsets[i - 1] + widths[i - 1]
            }
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(
                to: CGPoint(x: x, y: size.height)
            )
            context.stroke(
                path,
                with: .color(
                    .secondary.opacity(0.25)
                ),
                lineWidth: 1
            )
        }
    }

    /// Whether dimming is active (something is hovered).
    private var isDimming: Bool {
        highlightId != nil
    }

    /// Opacity for non-highlighted items when dimming.
    private let dimOpacity: Double = 0.3

    /// Whether a bar matches the current highlight.
    /// Matches by startEvent.id so cross-segment splits
    /// highlight together but different bars with the
    /// same durationIdentifier highlight independently.
    private func isBarHighlighted(
        _ bar: PlacedBar
    ) -> Bool {
        guard let hid = highlightId
        else { return false }
        return "\(bar.startEvent.id)" == hid
    }

    /// Whether a dot matches the current highlight.
    private func isDotHighlighted(
        _ dot: PlacedDot
    ) -> Bool {
        guard let hid = highlightId
        else { return false }
        return "\(dot.event.id)" == hid
    }

    private func drawBars(
        context: GraphicsContext, size: CGSize
    ) {
        let hashHeight = TimelineLayoutEngine.hashHeight
        let halfDot = dotDiameter / 2.0
        let offsets = laneXOffsets

        for bar in segment.placedBars {
            let barWidth = dotDiameter
            let laneCenterX = offsets[bar.laneIndex]
                + laneInset
                + CGFloat(bar.subColumn) * subColPitch

            var topY = CGFloat(bar.startHashIndex)
                * hashHeight + hashHeight / 2.0
                - halfDot
            var bottomY = CGFloat(bar.endHashIndex)
                * hashHeight + hashHeight / 2.0
                + halfDot

            if bar.continuesFromPrevious {
                topY = 0
            }
            if bar.continuesIntoNext
                || bar.isOpenEnded
            {
                bottomY = size.height
            }

            let barHeight = max(
                dotDiameter, bottomY - topY
            )
            let cornerRadius = barWidth / 2.0

            let rect = CGRect(
                x: laneCenterX - barWidth / 2.0,
                y: topY,
                width: barWidth,
                height: barHeight
            )

            let roundTop = !bar.continuesFromPrevious
            let roundBottom = !bar.continuesIntoNext
                && !bar.isOpenEnded

            let path = barPath(
                rect: rect,
                cornerRadius: cornerRadius,
                roundTop: roundTop,
                roundBottom: roundBottom
            )

            let highlighted = isBarHighlighted(bar)
            let color = bar.resource.color
            let fillOpacity =
                isDimming && !highlighted
                ? dimOpacity : 1.0

            context.fill(
                path,
                with: .color(
                    color.opacity(fillOpacity)
                )
            )

            // Stroke on highlighted bars
            if highlighted {
                context.stroke(
                    path,
                    with: .color(
                        color.opacity(0.9)
                    ),
                    lineWidth: 2.0
                )
            }
        }
    }

    private func barPath(
        rect: CGRect,
        cornerRadius: CGFloat,
        roundTop: Bool,
        roundBottom: Bool
    ) -> Path {
        if roundTop && roundBottom {
            return Path(
                roundedRect: rect,
                cornerRadius: cornerRadius
            )
        }
        if !roundTop && !roundBottom {
            return Path(rect)
        }

        let r = cornerRadius
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        var path = Path()
        if roundTop {
            path.move(to: CGPoint(x: minX, y: maxY))
            path.addLine(
                to: CGPoint(x: minX, y: minY + r)
            )
            path.addArc(
                center: CGPoint(
                    x: minX + r, y: minY + r
                ),
                radius: r,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
            path.addLine(
                to: CGPoint(x: maxX - r, y: minY)
            )
            path.addArc(
                center: CGPoint(
                    x: maxX - r, y: minY + r
                ),
                radius: r,
                startAngle: .degrees(270),
                endAngle: .degrees(0),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: maxX, y: maxY))
            path.closeSubpath()
        } else {
            path.move(to: CGPoint(x: minX, y: minY))
            path.addLine(
                to: CGPoint(x: maxX, y: minY)
            )
            path.addLine(
                to: CGPoint(x: maxX, y: maxY - r)
            )
            path.addArc(
                center: CGPoint(
                    x: maxX - r, y: maxY - r
                ),
                radius: r,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
            path.addLine(
                to: CGPoint(x: minX + r, y: maxY)
            )
            path.addArc(
                center: CGPoint(
                    x: minX + r, y: maxY - r
                ),
                radius: r,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
            path.closeSubpath()
        }
        return path
    }

    private func drawDots(
        context: GraphicsContext, size: CGSize
    ) {
        let hashHeight = TimelineLayoutEngine.hashHeight
        let offsets = laneXOffsets

        for dot in segment.placedDots {
            let diameter = dotDiameter
            let laneCenterX = offsets[dot.laneIndex]
                + laneInset
                + CGFloat(dot.subColumn) * subColPitch

            let centerY = CGFloat(dot.hashIndex)
                * hashHeight + hashHeight / 2.0

            let highlighted = isDotHighlighted(dot)
            let color = dot.resource.color
            let fillOpacity =
                isDimming && !highlighted
                ? dimOpacity : 1.0

            let rect = CGRect(
                x: laneCenterX - diameter / 2.0,
                y: centerY - diameter / 2.0,
                width: diameter,
                height: diameter
            )
            let path = Path(ellipseIn: rect)
            context.fill(
                path,
                with: .color(
                    color.opacity(fillOpacity)
                )
            )

            // Stroke on highlighted dots
            if highlighted {
                context.stroke(
                    path,
                    with: .color(
                        color.opacity(0.9)
                    ),
                    lineWidth: 2.0
                )
            }
        }
    }
}

// MARK: - Content Header Spacer

/// Height-matched spacer for the ruler segment header.
/// Draws continuation bars at their lane positions so
/// they scroll horizontally with the content.
struct TimelineContentHeaderSpacer: View {
    static let height: CGFloat = 20.0

    var continuationBars: [PlacedBar] = []
    var activeLanes: [TimelineResource] = []
    var laneMaxSubColumns: [Int] = []
    var hoverColX: CGFloat? = nil
    var isHighlighted: Bool = false
    var segmentId: UUID? = nil
    var hoverSegmentIdBinding: Binding<UUID?>? = nil
    var hoverRowBinding: Binding<Int?>? = nil
    var hoveredItemBinding:
        Binding<HoveredTimelineItem?>? = nil
    var hoveredItemPointBinding:
        Binding<CGPoint?>? = nil
    var highlightId: String? = nil

    private let dotDiameter: CGFloat = 10.0
    private let subColPitch: CGFloat = 25.0

    private var lanePadding: CGFloat {
        subColPitch - dotDiameter
    }
    private var laneInset: CGFloat {
        lanePadding + dotDiameter / 2.0
    }
    private var minLaneWidth: CGFloat {
        2.0 * subColPitch + lanePadding
    }

    var body: some View {
        Canvas { context, size in
            // Row highlight for header
            if isHighlighted {
                context.fill(
                    Path(CGRect(
                        x: 0, y: 0,
                        width: size.width,
                        height: size.height
                    )),
                    with: .color(
                        Color.primary
                            .opacity(0.06)
                    )
                )
            }
            if !continuationBars.isEmpty {
                drawContinuationBars(
                    context: context, size: size
                )
            }
        }
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hoverSegmentIdBinding?
                    .wrappedValue = segmentId
                hoverRowBinding?
                    .wrappedValue = -1
                hitTestHeaderBar(at: point)
            case .ended:
                hoverSegmentIdBinding?
                    .wrappedValue = nil
                hoverRowBinding?
                    .wrappedValue = nil
                hoveredItemBinding?
                    .wrappedValue = nil
                hoveredItemPointBinding?
                    .wrappedValue = nil
            @unknown default:
                break
            }
        }
    }

    private func hitTestHeaderBar(
        at point: CGPoint
    ) {
        let widths = computeLaneWidths()
        var offsets: [CGFloat] = []
        var x: CGFloat = 0
        for w in widths {
            offsets.append(x)
            x += w
        }

        let hitPad: CGFloat = 3.0
        for bar in continuationBars {
            guard bar.laneIndex < offsets.count
            else { continue }

            let laneCenterX =
                offsets[bar.laneIndex]
                + laneInset
                + CGFloat(bar.subColumn)
                    * subColPitch
            let rect = CGRect(
                x: laneCenterX
                    - dotDiameter / 2.0
                    - hitPad,
                y: 0,
                width: dotDiameter
                    + hitPad * 2.0,
                height: Self.height
            )
            if rect.contains(point) {
                hoveredItemBinding?
                    .wrappedValue = .bar(bar)
                hoveredItemPointBinding?
                    .wrappedValue = point
                return
            }
        }

        hoveredItemBinding?
            .wrappedValue = nil
        hoveredItemPointBinding?
            .wrappedValue = nil
    }

    private func drawContinuationBars(
        context: GraphicsContext, size: CGSize
    ) {
        let widths = computeLaneWidths()
        var offsets: [CGFloat] = []
        var x: CGFloat = 0
        for w in widths {
            offsets.append(x)
            x += w
        }

        let isDimming = highlightId != nil
        let dimOpacity: Double = 0.3

        for bar in continuationBars {
            guard bar.laneIndex < offsets.count
            else { continue }

            let highlighted: Bool
            if let hid = highlightId {
                highlighted =
                    "\(bar.startEvent.id)" == hid
            } else {
                highlighted = false
            }

            let color = bar.resource.color
            let fillOpacity =
                isDimming && !highlighted
                ? dimOpacity : 1.0

            let laneCenterX = offsets[bar.laneIndex]
                + laneInset
                + CGFloat(bar.subColumn) * subColPitch
            let rect = CGRect(
                x: laneCenterX - dotDiameter / 2.0,
                y: 0,
                width: dotDiameter,
                height: size.height
            )
            context.fill(
                Path(rect),
                with: .color(
                    color.opacity(fillOpacity)
                )
            )

            if highlighted {
                context.stroke(
                    Path(rect),
                    with: .color(
                        color.opacity(0.9)
                    ),
                    lineWidth: 2.0
                )
            }
        }
    }

    private func computeLaneWidths() -> [CGFloat] {
        activeLanes.indices.map {
            max(
                minLaneWidth,
                CGFloat(laneMaxSubColumns[$0])
                    * subColPitch + lanePadding
            )
        }
    }
}

// MARK: - Content Break

/// Dashed line with duration label between content segments.
struct TimelineContentBreak: View {
    let duration: String
    var hoverColX: CGFloat? = nil
    @Environment(\.chromeFontSize)
    private var chromeFontSize

    private var fontSize: ChromeFontSize {
        ChromeFontSize(chromeFontSize)
    }

    private let subColPitch: CGFloat = 25.0

    static let breakHeight: CGFloat = 16.0

    var body: some View {
        HStack(spacing: 8) {
            dashedLine
            Text(duration)
                .chromeFont(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            dashedLine
        }
        .padding(.horizontal, 12)
        .frame(height: Self.breakHeight)
        // Column highlight background (disabled)
        // .background {
        //     if let colX = hoverColX {
        //         Canvas { context, size in
        //             context.fill(
        //                 Path(CGRect(
        //                     x: colX, y: 0,
        //                     width: subColPitch,
        //                     height: size.height
        //                 )),
        //                 with: .color(
        //                     Color.primary
        //                         .opacity(0.06)
        //                 )
        //             )
        //         }
        //     }
        // }
    }

    private var dashedLine: some View {
        GeometryReader { geo in
            Path { path in
                path.move(
                    to: CGPoint(
                        x: 0,
                        y: geo.size.height / 2
                    )
                )
                path.addLine(
                    to: CGPoint(
                        x: geo.size.width,
                        y: geo.size.height / 2
                    )
                )
            }
            .stroke(
                style: StrokeStyle(
                    lineWidth: 1, dash: [4, 4]
                )
            )
            .foregroundColor(.secondary.opacity(0.4))
        }
    }
}

// MARK: - Ruler Segment

/// Hash ticks, time labels, and rail edge line for a segment.
/// Hover over any 5-second slot to see the full date/time.
struct TimelineRulerSegment: View {
    let segment: LayoutSegment
    let originHash: Date
    var isHoveredSegment: Bool = false
    var hoverRow: Int? = nil

    // Shared crosshair bindings for ruler-initiated
    // hover (sets same state as content hover).
    var hoverSegmentIdBinding: Binding<UUID?>? = nil
    var hoverRowBinding: Binding<Int?>? = nil

    @State private var hoveredHashIndex: Int? = nil

    private let railWidth: CGFloat = 76.0

    private static let minuteFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        fmt.timeZone = .current
        return fmt
    }()

    private static let weekdayMonthFormatter:
        DateFormatter =
    {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE MMM"
        fmt.timeZone = .current
        return fmt
    }()

    private static let yearFormatter:
        DateFormatter =
    {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy"
        fmt.timeZone = .current
        return fmt
    }()

    private static let hoverTimeFormatter:
        DateFormatter =
    {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm:ss a"
        fmt.timeZone = .current
        return fmt
    }()

    var body: some View {
        Canvas { context, size in
            drawRowHighlight(
                context: context, size: size
            )
            drawHashRail(context: context, size: size)
        }
        .frame(height: segment.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let hashHeight =
                    TimelineLayoutEngine.hashHeight
                let idx = Int(point.y / hashHeight)
                if idx >= 0,
                    idx < segment.hashCount
                {
                    hoveredHashIndex = idx
                    hoverSegmentIdBinding?
                        .wrappedValue = segment.id
                    hoverRowBinding?
                        .wrappedValue = idx
                } else {
                    hoveredHashIndex = nil
                    hoverSegmentIdBinding?
                        .wrappedValue = nil
                    hoverRowBinding?
                        .wrappedValue = nil
                }
            case .ended:
                hoveredHashIndex = nil
                hoverSegmentIdBinding?
                    .wrappedValue = nil
                hoverRowBinding?
                    .wrappedValue = nil
            @unknown default:
                hoveredHashIndex = nil
                hoverSegmentIdBinding?
                    .wrappedValue = nil
                hoverRowBinding?
                    .wrappedValue = nil
            }
        }
        .overlay(alignment: .topLeading) {
            if let idx = hoveredHashIndex {
                hashTooltip(localIndex: idx)
            }
        }
    }

    // MARK: - Hover Tooltip

    private func hashTooltip(
        localIndex: Int
    ) -> some View {
        let hashHeight =
            TimelineLayoutEngine.hashHeight
        let topY = CGFloat(localIndex) * hashHeight
        let date = dateForHash(localIndex)

        return VStack {
            Spacer()
                .frame(height: topY)
            Text(formatFullDateTime(date))
                .font(.system(
                    size: 10.0,
                    weight: .bold,
                    design: .monospaced
                ))
                .foregroundColor(
                    Color.primary.opacity(0.85)
                )
                .fixedSize(
                    horizontal: true,
                    vertical: false
                )
                .shadow(
                    color: Color(
                        .textBackgroundColor
                    ),
                    radius: 3, x: 0, y: 0
                )
                .shadow(
                    color: Color(
                        .textBackgroundColor
                    ),
                    radius: 3, x: 0, y: 0
                )
                .padding(.horizontal, 2)
                .background(
                    Color(.textBackgroundColor)
                        .opacity(0.3),
                    in: Capsule()
                )
                .frame(height: hashHeight)
                .padding(.leading, 4)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func dateForHash(
        _ localIndex: Int
    ) -> Date {
        let globalHash =
            segment.startHash + localIndex
        let seconds = Double(globalHash)
            * TimelineLayoutEngine.hashGranularity
        return originHash.addingTimeInterval(seconds)
    }

    private func formatFullDateTime(
        _ date: Date
    ) -> String {
        let calendar = Calendar.current
        let day = calendar.component(
            .day, from: date
        )
        let prefix =
            Self.weekdayMonthFormatter.string(
                from: date
            )
        let year = Self.yearFormatter.string(
            from: date
        )
        let time = Self.hoverTimeFormatter.string(
            from: date
        )
        return "\(prefix) \(day)"
            + "\(ordinalSuffix(day))"
            + " \(year) — \(time)"
    }

    private func ordinalSuffix(
        _ day: Int
    ) -> String {
        switch day {
        case 11, 12, 13: return "th"
        default:
            switch day % 10 {
            case 1: return "st"
            case 2: return "nd"
            case 3: return "rd"
            default: return "th"
            }
        }
    }

    private func drawRowHighlight(
        context: GraphicsContext, size: CGSize
    ) {
        guard isHoveredSegment,
            let row = hoverRow,
            row >= 0, row < segment.hashCount
        else { return }

        let hashHeight =
            TimelineLayoutEngine.hashHeight
        let y = CGFloat(row) * hashHeight
        context.fill(
            Path(CGRect(
                x: 0, y: y,
                width: size.width,
                height: hashHeight
            )),
            with: .color(
                Color.primary.opacity(0.06)
            )
        )
    }

    private func drawHashRail(
        context: GraphicsContext, size: CGSize
    ) {
        let hashHeight = TimelineLayoutEngine.hashHeight
        let railEdgeX = railWidth - 1.0
        let tickShort: CGFloat = 8.0
        let tickMedium: CGFloat = 16.0
        let tickLong: CGFloat = 16.0

        // Vertical rail edge line
        var railPath = Path()
        railPath.move(to: CGPoint(x: railEdgeX, y: 0))
        railPath.addLine(
            to: CGPoint(x: railEdgeX, y: size.height)
        )
        context.stroke(
            railPath,
            with: .color(.secondary.opacity(0.25)),
            lineWidth: 1
        )

        let calendar = Calendar.current
        for h in 0..<segment.hashCount {
            let y = CGFloat(h) * hashHeight
                + hashHeight / 2.0
            let globalHash = segment.startHash + h
            let absoluteSeconds = Double(globalHash)
                * TimelineLayoutEngine.hashGranularity
            let absoluteTime =
                originHash.addingTimeInterval(
                    absoluteSeconds
                )

            let second = calendar.component(
                .second, from: absoluteTime
            )

            let tickLength: CGFloat
            let tickOpacity: Double
            let label: String?

            if second == 0 {
                tickLength = tickLong
                tickOpacity = 0.5
                label = Self.minuteFormatter.string(
                    from: absoluteTime
                )
            } else if second == 30 {
                tickLength = tickMedium
                tickOpacity = 0.35
                label = ":30"
            } else {
                tickLength = tickShort
                tickOpacity = 0.15
                label = nil
            }

            var tickPath = Path()
            tickPath.move(
                to: CGPoint(x: railEdgeX, y: y)
            )
            tickPath.addLine(
                to: CGPoint(
                    x: railEdgeX - tickLength, y: y
                )
            )
            context.stroke(
                tickPath,
                with: .color(
                    .secondary.opacity(tickOpacity)
                ),
                lineWidth: 1
            )

            if let label = label {
                let text = Text(label)
                    .font(.system(
                        size: 9.0,
                        weight: .bold,
                        design: .monospaced
                    ))
                    .foregroundColor(
                        Color.primary.opacity(0.7)
                    )

                let resolved = context.resolve(text)
                let textSize = resolved.measure(
                    in: CGSize(
                        width: railWidth
                            - tickLength - 6,
                        height: hashHeight
                    )
                )

                let textX = railEdgeX - tickLength
                    - 4 - textSize.width
                let textY = y - textSize.height / 2.0

                context.draw(
                    resolved,
                    in: CGRect(
                        x: textX, y: textY,
                        width: textSize.width,
                        height: textSize.height
                    )
                )
            }
        }
    }
}

// MARK: - Ruler Segment Header

/// Date/time text for a segment boundary. Positioned in
/// the ruler column but overflows right into the content
/// area via fixedSize + no clipping on the parent.
struct TimelineRulerHeader: View {
    let date: Date
    let showDate: Bool
    var segmentId: UUID? = nil
    var isHighlighted: Bool = false
    var hoverSegmentIdBinding: Binding<UUID?>? = nil
    var hoverRowBinding: Binding<Int?>? = nil

    private static let weekdayMonthFormatter:
        DateFormatter =
    {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE MMM"
        fmt.timeZone = .current
        return fmt
    }()

    private static let yearFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy"
        fmt.timeZone = .current
        return fmt
    }()

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        fmt.timeZone = .current
        return fmt
    }()

    private var friendlyDate: String {
        let calendar = Calendar.current
        let day = calendar.component(.day, from: date)
        let prefix = Self.weekdayMonthFormatter.string(
            from: date
        )
        let year = Self.yearFormatter.string(from: date)
        return "\(prefix) \(day)\(ordinalSuffix(day))"
            + " \(year)"
    }

    private var friendlyTime: String {
        Self.timeFormatter.string(from: date)
    }

    private func ordinalSuffix(_ day: Int) -> String {
        switch day {
        case 11, 12, 13: return "th"
        default:
            switch day % 10 {
            case 1: return "st"
            case 2: return "nd"
            case 3: return "rd"
            default: return "th"
            }
        }
    }

    private var headerText: String {
        if showDate {
            return "\(friendlyDate) — \(friendlyTime)"
        } else {
            return friendlyTime
        }
    }

    var body: some View {
        // Layout footprint: 76pt wide, fixed height.
        // The actual text is rendered as an overlay
        // with fixedSize so it overflows right without
        // inflating the VStack's intrinsic width.
        (isHighlighted
            ? Color.primary.opacity(0.06)
            : Color.clear)
            .frame(
                height: TimelineContentHeaderSpacer
                    .height
            )
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    hoverSegmentIdBinding?
                        .wrappedValue = segmentId
                    hoverRowBinding?
                        .wrappedValue = -1
                case .ended:
                    hoverSegmentIdBinding?
                        .wrappedValue = nil
                    hoverRowBinding?
                        .wrappedValue = nil
                @unknown default:
                    break
                }
            }
            .overlay(alignment: .leading) {
                Text(headerText)
                    .font(.system(
                        size: 10.0,
                        weight: .bold,
                        design: .monospaced
                    ))
                    .foregroundColor(
                        Color.primary.opacity(0.6)
                    )
                    .fixedSize(
                        horizontal: true,
                        vertical: false
                    )
                    .shadow(
                        color: Color(
                            .textBackgroundColor
                        ),
                        radius: 3, x: 0, y: 0
                    )
                    .shadow(
                        color: Color(
                            .textBackgroundColor
                        ),
                        radius: 3, x: 0, y: 0
                    )
                    .padding(.horizontal, 2)
                    .background(
                        Color(.textBackgroundColor)
                            .opacity(0.3),
                        in: Capsule()
                    )
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
            }
    }
}

// MARK: - Ruler Break Spacer

/// Matches the height of the content break view.
/// Draws the rail edge line through the break gap
/// so the ruler column line stays continuous.
struct TimelineRulerBreakSpacer: View {
    private let railWidth: CGFloat = 76.0

    var body: some View {
        Canvas { context, size in
            let railEdgeX = railWidth - 1.0
            var path = Path()
            path.move(
                to: CGPoint(x: railEdgeX, y: 0)
            )
            path.addLine(
                to: CGPoint(
                    x: railEdgeX, y: size.height
                )
            )
            context.stroke(
                path,
                with: .color(
                    .secondary.opacity(0.25)
                ),
                lineWidth: 1
            )
        }
        .frame(height: TimelineContentBreak.breakHeight)
    }
}

// MARK: - Lane Header Cell

/// Individual lane header cell with hover-to-expand.
/// Truncates normally; on hover, overlays the full name
/// with a matching background extending past the column.
private struct TimelineLaneHeaderCell: View {
    let name: String
    let color: Color
    let fontSize: ChromeFontSize
    let cellWidth: CGFloat

    @State private var isHovered = false

    var body: some View {
        Text(name)
            .chromeFont(size: fontSize.caption2)
            .fontWeight(.bold)
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .frame(
                width: cellWidth,
                alignment: .leading
            )
            .clipped()
            .opacity(isHovered ? 0 : 1)
            .overlay(alignment: .leading) {
                if isHovered {
                    Text(name)
                        .chromeFont(
                            size: fontSize.caption2
                        )
                        .fontWeight(.bold)
                        .foregroundColor(color)
                        .lineLimit(1)
                        .fixedSize(
                            horizontal: true,
                            vertical: false
                        )
                        .padding(.horizontal, 6)
                        .background(
                            Color(
                                .textBackgroundColor
                            )
                        )
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

// MARK: - Lane Header Row

/// Column headers aligned to lane geometry. No hash rail
/// spacer — the caller positions this to the right of
/// the corner cell.
struct TimelineLaneHeader: View {
    let activeLanes: [TimelineResource]
    let laneMaxSubColumns: [Int]
    let availableWidth: CGFloat

    @Environment(\.chromeFontSize)
    private var chromeFontSize

    private var fontSize: ChromeFontSize {
        ChromeFontSize(chromeFontSize)
    }

    private let subColPitch: CGFloat = 25.0
    private let dotDiameter: CGFloat = 10.0

    private var lanePadding: CGFloat {
        subColPitch - dotDiameter
    }

    private var minLaneWidth: CGFloat {
        2.0 * subColPitch + lanePadding
    }

    private var laneWidths: [CGFloat] {
        let pad = lanePadding
        let natural = activeLanes.indices.map {
            max(
                minLaneWidth,
                CGFloat(laneMaxSubColumns[$0])
                    * subColPitch + pad
            )
        }
        return natural
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(
                Array(activeLanes.enumerated()),
                id: \.element
            ) { index, resource in
                TimelineLaneHeaderCell(
                    name: resource.displayName,
                    color: resource.color,
                    fontSize: fontSize,
                    cellWidth: laneWidths.indices
                        .contains(index)
                        ? laneWidths[index]
                        : minLaneWidth
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Item Tooltip

/// Compact tooltip shown when hovering a placed dot or
/// bar. Displays event type, timestamp, and parsed
/// detail_data summary.
struct TimelineItemTooltip: View {
    let item: HoveredTimelineItem

    private static let timeFormatter:
        DateFormatter =
    {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm:ss a"
        fmt.timeZone = .current
        return fmt
    }()

    private static let dateTimeFormatter:
        DateFormatter =
    {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy  h:mm:ss a"
        fmt.timeZone = .current
        return fmt
    }()

    var body: some View {
        VStack(
            alignment: .leading, spacing: 3
        ) {
            // Header: colored dot + event label
            // For completed bars, show combined label
            // (e.g., "Turn Initiated → Completed").
            HStack(spacing: 6) {
                Circle()
                    .fill(item.resource.color)
                    .frame(width: 8, height: 8)
                Text(tooltipLabel)
                .font(.system(
                    size: 11, weight: .semibold
                ))
                .foregroundColor(.primary)
            }

            // Timestamp
            Text(
                Self.dateTimeFormatter.string(
                    from: item.event.occurredAt
                )
            )
            .font(.system(
                size: 10, design: .monospaced
            ))
            .foregroundColor(
                .secondary
            )

            // Duration end time (for bars)
            if let endEvt = item.endEvent {
                Text(
                    "→ "
                        + Self.timeFormatter
                            .string(
                                from: endEvt
                                    .occurredAt
                            )
                )
                .font(.system(
                    size: 10,
                    design: .monospaced
                ))
                .foregroundColor(
                    .secondary
                )
            } else if case .bar(let b) = item,
                b.isOpenEnded
            {
                Text("→ ongoing")
                    .font(.system(
                        size: 10,
                        design: .monospaced
                    ))
                    .foregroundColor(
                        .secondary.opacity(0.7)
                    )
            }

            // Detail lines — for bars with an end event,
            // show start lines then end lines.
            let details = tooltipDetails
            if !details.isEmpty {
                Divider()
                    .padding(.vertical, 1)
                ForEach(
                    details, id: \.self
                ) { line in
                    Text(line)
                        .font(.system(
                            size: 10,
                            design: .monospaced
                        ))
                        .foregroundColor(
                            .primary.opacity(0.8)
                        )
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(
            minWidth: 140,
            maxWidth: 260,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    Color(.windowBackgroundColor)
                )
                .shadow(
                    color: Color.black
                        .opacity(0.2),
                    radius: 4, x: 0, y: 2
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    Color.primary.opacity(0.1),
                    lineWidth: 0.5
                )
        )
    }

    // MARK: - Computed Helpers

    /// Combined label for bars with end events:
    /// "Session Started → Ended". For dots and
    /// open-ended bars, just the start label.
    private var tooltipLabel: String {
        let startLabel =
            TimelineTooltipFormatter.label(
                for: item.event.eventType
            )
        guard let endEvt = item.endEvent else {
            return startLabel
        }
        let endLabel =
            TimelineTooltipFormatter.label(
                for: endEvt.eventType
            )
        // Extract the short suffix after the
        // resource prefix (e.g., "Turn Completed"
        // → "Completed").
        let startPrefix = startLabel.split(
            separator: " "
        ).first.map(String.init) ?? ""
        let endSuffix: String
        if endLabel.hasPrefix(startPrefix) {
            endSuffix = String(
                endLabel.dropFirst(
                    startPrefix.count
                )
            ).trimmingCharacters(
                in: .whitespaces
            )
        } else {
            endSuffix = endLabel
        }
        return "\(startLabel) → \(endSuffix)"
    }

    /// Detail lines from both start and end events.
    /// For dots: just the event's detail lines.
    /// For bars: start lines + end lines concatenated.
    private var tooltipDetails: [String] {
        var lines = TimelineTooltipFormatter
            .detailLines(
                for: item.event.eventType,
                detailData: item.event.detailData
            )
        if let endEvt = item.endEvent {
            lines += TimelineTooltipFormatter
                .detailLines(
                    for: endEvt.eventType,
                    detailData: endEvt.detailData
                )
        }
        return lines
    }
}
