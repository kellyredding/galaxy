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
            drawLaneSeparators(
                context: context, size: size
            )
            drawBars(context: context, size: size)
            drawDots(context: context, size: size)
        }
        .frame(height: segment.height)
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
            context.fill(
                path,
                with: .color(bar.resource.color)
            )
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

            let rect = CGRect(
                x: laneCenterX - diameter / 2.0,
                y: centerY - diameter / 2.0,
                width: diameter,
                height: diameter
            )
            let path = Path(ellipseIn: rect)
            context.fill(
                path,
                with: .color(dot.resource.color)
            )
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
        if !continuationBars.isEmpty {
            Canvas { context, size in
                drawContinuationBars(
                    context: context, size: size
                )
            }
            .frame(height: Self.height)
        } else {
            Color.clear.frame(height: Self.height)
        }
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

        for bar in continuationBars {
            guard bar.laneIndex < offsets.count
            else { continue }

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
                with: .color(bar.resource.color)
            )
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
    @Environment(\.chromeFontSize)
    private var chromeFontSize

    private var fontSize: ChromeFontSize {
        ChromeFontSize(chromeFontSize)
    }

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
                } else {
                    hoveredHashIndex = nil
                }
            case .ended:
                hoveredHashIndex = nil
            @unknown default:
                hoveredHashIndex = nil
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
        let centerY = CGFloat(localIndex)
            * hashHeight + hashHeight / 2.0
        let date = dateForHash(localIndex)

        return Text(formatFullDateTime(date))
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
                color: Color(.textBackgroundColor),
                radius: 3, x: 0, y: 0
            )
            .shadow(
                color: Color(.textBackgroundColor),
                radius: 3, x: 0, y: 0
            )
            .padding(.horizontal, 2)
            .background(
                Color(.textBackgroundColor)
                    .opacity(0.3),
                in: Capsule()
            )
            .offset(
                x: 4,
                y: centerY - 10
            )
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
        Color.clear
            .frame(
                height: TimelineContentHeaderSpacer
                    .height
            )
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
