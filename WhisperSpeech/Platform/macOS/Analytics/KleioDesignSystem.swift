import SwiftUI
import AppKit

// MARK: - Palette

/// Shared semantic color tokens for the Kleio macOS dashboard surfaces.
///
/// Base tokens are carried over from `RefMacPalette` (MacReferenceDashboardPages.swift)
/// so existing reference surfaces stay visually coherent. Accent tokens are semantic —
/// each one has exactly ONE meaning across the dashboard. Do not repurpose an accent for
/// a use it wasn't documented for (e.g. don't use `live` for a chart series).
enum KleioPalette {
    // MARK: Base

    static let page = Color(red: 0.975, green: 0.966, blue: 0.944)
    static let card = Color.white.opacity(0.96)
    /// Primary text color.
    static let ink = Color(red: 0.07, green: 0.08, blue: 0.08)
    static let secondary = Color(red: 0.34, green: 0.36, blue: 0.36)
    static let stroke = Color(red: 0.84, green: 0.82, blue: 0.76).opacity(0.72)
    static let selection = Color(red: 0.89, green: 0.92, blue: 0.90)

    // MARK: Semantic accents

    /// Interactive: primary CTAs, active nav, links — never data or status.
    static let action = Color(red: 0.11, green: 0.36, blue: 0.28)
    /// Recording/live-now indicators only (matches the dictation pill's ember).
    static let live = Color(red: 0.85, green: 0.42, blue: 0.15)
    /// Primary chart series.
    static let data = Color(red: 0.18, green: 0.34, blue: 0.38)
    /// Secondary chart series.
    static let dataSecondary = Color(red: 0.79, green: 0.58, blue: 0.23)
    /// Third chart series (multi-line charts only).
    static let dataTertiary = Color(red: 0.47, green: 0.34, blue: 0.51)
    /// Fourth chart series (multi-line charts only).
    static let dataQuaternary = Color(red: 0.72, green: 0.42, blue: 0.26)
    /// Good status/deltas.
    static let positive = Color(red: 0.24, green: 0.47, blue: 0.33)
    /// Caution status.
    static let attention = Color(red: 0.72, green: 0.52, blue: 0.16)
    /// Errors, destructive actions, negative deltas.
    static let danger = Color(red: 0.72, green: 0.28, blue: 0.12)
    /// Brass — logo/brand flourish only.
    static let brand = Color(red: 0.58, green: 0.45, blue: 0.25)

    /// Used by the `DictationOutputPreset.kleioColor` mapping (the "default" preset).
    static let sage = Color(red: 0.62, green: 0.70, blue: 0.62)
}

// MARK: - Output preset mapping

/// Categorical identity colors for styles (donut slices, style dots). They mark
/// *which style*, nothing else — never reuse them for status, data series, or actions.
extension DictationOutputPreset {
    var kleioColor: Color {
        switch self {
        case .default: return KleioPalette.sage
        case .professional: return Color(red: 0.25, green: 0.45, blue: 0.38)
        case .email: return Color(red: 0.79, green: 0.58, blue: 0.23)
        case .casual: return Color(red: 0.77, green: 0.32, blue: 0.12)
        case .veryCasual: return Color(red: 0.38, green: 0.54, blue: 0.57)
        case .excited: return Color(red: 0.92, green: 0.68, blue: 0.28)
        }
    }

    var kleioIcon: String {
        switch self {
        case .default: return "text.alignleft"
        case .professional: return "briefcase"
        case .email: return "envelope"
        case .casual: return "message"
        case .veryCasual: return "face.smiling"
        case .excited: return "sparkles"
        }
    }
}

// MARK: - Card chrome

/// Standard card chrome: 8pt continuous radius, hairline stroke, soft shadow.
struct KleioCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .foregroundStyle(KleioPalette.ink)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(KleioPalette.card)
                    .shadow(color: Color.black.opacity(0.045), radius: 10, y: 4)
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(KleioPalette.stroke, lineWidth: 1))
    }
}

// MARK: - Pointer

extension View {
    /// Pointing-hand cursor over a clickable element. Uses the system pointer style
    /// instead of NSCursor push/pop, which leaked the cursor stack when a hovered
    /// view disappeared mid-hover.
    func kleioPointer(_ enabled: Bool = true) -> some View {
        pointerStyle(enabled ? .link : nil)
    }
}

// MARK: - Typography

struct KleioSectionTitle: View {
    let text: String
    var color: Color = KleioPalette.ink

    init(_ text: String, color: Color = KleioPalette.ink) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(color)
    }
}

// MARK: - Buttons

struct KleioSecondaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(KleioPalette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? KleioPalette.selection : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(KleioPalette.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .kleioPointer()
    }
}

// MARK: - Chips & badges

struct KleioStatusChip: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Toggle

/// High-contrast switch style. Unlike the native `.switch` style, the OFF state uses a
/// clearly visible neutral-gray track with a hairline border so it never washes out
/// against `KleioPalette.card`'s near-white background. Built as a `ToggleStyle` so the
/// row title is the accessible label and VoiceOver/keyboard toggling work.
struct KleioSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? KleioPalette.action : Color(white: 0.82))
                    .overlay(Capsule().stroke(KleioPalette.stroke, lineWidth: configuration.isOn ? 0 : 1))
                Circle()
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.15), radius: 1, y: 0.5)
                    .frame(width: 16, height: 16)
                    .padding(2)
            }
            .frame(width: 36, height: 20)
            .contentShape(Rectangle())
            .onTapGesture { configuration.isOn.toggle() }
            .kleioPointer()
            .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

// MARK: - Source app icon

struct KleioSourceAppIcon: View {
    let entry: DictationHistoryEntry
    let size: CGFloat

    var body: some View {
        Group {
            if let image = KleioSourceAppIconCache.image(for: entry) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(KleioPalette.selection)
                    .overlay {
                        Text(monogram)
                            .font(.system(size: size * 0.42, weight: .semibold, design: .serif))
                            .foregroundStyle(KleioPalette.ink)
                    }
            }
        }
        .frame(width: size, height: size)
    }

    private var monogram: String {
        guard let name = entry.sourceAppName, let first = name.first else { return "K" }
        return String(first).uppercased()
    }
}

/// Decoding the stored PNG on every row render was a per-frame cost; icons are cached
/// per source app (the same app's icon repeats across many rows).
@MainActor
enum KleioSourceAppIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for entry: DictationHistoryEntry) -> NSImage? {
        let key = (entry.sourceAppBundleIdentifier ?? entry.sourceAppName ?? "") as NSString
        if key.length > 0, let cached = cache.object(forKey: key) {
            return cached
        }
        guard let data = entry.sourceAppIconPNGData, let image = NSImage(data: data) else { return nil }
        if key.length > 0 { cache.setObject(image, forKey: key) }
        return image
    }
}

// MARK: - Avatar

struct KleioAvatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(KleioPalette.selection)
            .overlay(Circle().stroke(KleioPalette.stroke, lineWidth: 1))
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.36, weight: .semibold, design: .serif))
                    .foregroundStyle(KleioPalette.ink)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "K" : String(letters).uppercased()
    }
}

// MARK: - Flow layout

/// Wraps children onto new lines, for chip lists of unpredictable width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Donut

/// Share donut with a centered caption. Slices are drawn by their own fractions, so
/// the ring always agrees with the legend beside it.
struct KleioDonut: View {
    let slices: [ShareSlice]
    let centerValue: String
    let centerCaption: String
    var lineWidth: CGFloat = 16

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - lineWidth / 2
                var start = Angle.degrees(-90)
                for slice in slices {
                    let end = start + .degrees(360 * slice.fraction)
                    var path = Path()
                    path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                    context.stroke(path, with: .color(slice.color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    start = end
                }
            }
            VStack(spacing: 1) {
                Text(centerValue)
                    .font(.system(size: 16, weight: .regular, design: .serif))
                    .foregroundStyle(KleioPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(centerCaption)
                    .font(.system(size: 10))
                    .foregroundStyle(KleioPalette.secondary)
            }
            .padding(lineWidth + 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slices.map { "\($0.name) \(KleioFormat.percent($0.fraction))" }.joined(separator: ", "))
    }
}

/// Legend rows for a share breakdown: dot, name, percentage.
struct KleioShareLegend: View {
    let slices: [ShareSlice]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(slices) { slice in
                HStack(spacing: 8) {
                    Circle().fill(slice.color).frame(width: 8, height: 8)
                    Text(slice.name)
                        .foregroundStyle(KleioPalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(KleioFormat.percent(slice.fraction))
                        .foregroundStyle(KleioPalette.secondary)
                        .monospacedDigit()
                }
                .font(.system(size: 12))
            }
        }
    }
}

// MARK: - Empty note

/// Honest empty state for cards with nothing real to show.
struct KleioEmptyNote: View {
    let text: String
    var minHeight: CGFloat = 120

    init(_ text: String, minHeight: CGFloat = 120) {
        self.text = text
        self.minHeight = minHeight
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(KleioPalette.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
    }
}

// MARK: - Formatting

enum KleioFormat {
    static func int(_ n: Int) -> String {
        n.formatted(.number)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded()))
        if wholeSeconds < 60 {
            return "\(wholeSeconds)s"
        }
        if wholeSeconds < 3600 {
            let minutes = wholeSeconds / 60
            let remainder = wholeSeconds % 60
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
        }
        let hours = wholeSeconds / 3600
        let remainderMinutes = (wholeSeconds % 3600) / 60
        return remainderMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainderMinutes)m"
    }

    static func wpm(_ value: Double) -> String {
        "\(Int(value.rounded())) WPM"
    }

    static func percent(_ fraction: Double) -> String {
        if fraction > 0 && fraction < 0.01 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    static func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }

    /// "+12% vs previous 7 days", or nil when there's nothing to compare against.
    static func delta(_ percent: Double?, _ comparison: String) -> String? {
        guard let percent else { return nil }
        let rounded = Int(percent.rounded())
        return "\(rounded > 0 ? "+" : "")\(rounded)% \(comparison)"
    }
}

// MARK: - Multi-series trend chart

/// One line on a `KleioTrendChart`.
///
/// `values` holds one entry per x-slot; `nil` means "no data that day" and renders
/// as a gap rather than a fabricated zero. `display` provides the REAL formatted
/// value for the hover tooltip — series are drawn on independent relative scales
/// (each normalized to its own range) so differently-sized metrics share one plot,
/// and the tooltip is where the honest numbers live.
struct KleioTrendSeries: Identifiable {
    let id: String
    let name: String
    let color: Color
    let values: [Double?]
    let display: [String?]
    /// Shown next to the series name in the legend (e.g. the weekly total).
    let summary: String
}

/// Smooth multi-series trend chart in the reference language: Catmull-Rom curves,
/// soft gradient fills, dashed gridlines, hover hairline + tooltip, no y-axis
/// (series use independent relative scales — see `KleioTrendSeries`).
struct KleioTrendChart: View {
    let series: [KleioTrendSeries]
    let xLabels: [String]
    /// Longer per-slot labels for the hover tooltip (e.g. "Tue, Oct 7"); defaults to `xLabels`.
    var tooltipLabels: [String]? = nil
    var plotHeight: CGFloat = 210

    @State private var hoveredIndex: Int?

    private var slotCount: Int { xLabels.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack(alignment: .topLeading) {
                    gridlines(in: size)
                    // Reversed so the FIRST series (the primary metric) draws last,
                    // on top — correlated series otherwise bury it.
                    ForEach(Array(series.reversed())) { line in
                        seriesFill(line, in: size)
                        seriesStroke(line, in: size)
                    }
                    if let hoveredIndex {
                        hoverHairline(at: hoveredIndex, in: size)
                        hoverDots(at: hoveredIndex, in: size)
                        tooltip(at: hoveredIndex, in: size)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoveredIndex = nearestIndex(toX: point.x, width: size.width)
                    case .ended:
                        hoveredIndex = nil
                    }
                }
            }
            .frame(height: plotHeight)

            xAxisLabels
            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.map { "\($0.name): \($0.summary)" }.joined(separator: ", "))
    }

    // MARK: Geometry

    private func xPosition(_ index: Int, width: CGFloat) -> CGFloat {
        guard slotCount > 1 else { return width / 2 }
        return width * CGFloat(index) / CGFloat(slotCount - 1)
    }

    private func nearestIndex(toX x: CGFloat, width: CGFloat) -> Int {
        guard slotCount > 1 else { return 0 }
        let fraction = max(0, min(1, x / max(width, 1)))
        return Int((fraction * CGFloat(slotCount - 1)).rounded())
    }

    /// Normalizes a series to its own 0...max range, mapped into the plot with
    /// headroom so curves never kiss the card edges.
    private func points(for line: KleioTrendSeries, in size: CGSize) -> [CGPoint?] {
        let present = line.values.compactMap { $0 }
        let maxValue = max(present.max() ?? 0, 0.0001)
        let topInset: CGFloat = 12
        let bottomInset: CGFloat = 6
        let usable = size.height - topInset - bottomInset
        return line.values.enumerated().map { index, value in
            guard let value else { return nil }
            let normalized = CGFloat(value / maxValue)
            return CGPoint(
                x: xPosition(index, width: size.width),
                y: topInset + usable * (1 - normalized)
            )
        }
    }

    /// Splits a nil-gapped point list into runs of consecutive present points.
    private func runs(of points: [CGPoint?]) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        for point in points {
            if let point {
                current.append(point)
            } else if !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Catmull-Rom-through-points as cubic Béziers, with damped tangents so steep
    /// day-to-day jumps don't overshoot into implied negative values.
    private func smoothPath(through run: [CGPoint], closedTo baseline: CGFloat? = nil) -> Path {
        var path = Path()
        guard let first = run.first else { return path }
        if run.count == 1 {
            // Single-point run: no line to draw; fills skip these too.
            path.addEllipse(in: CGRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4))
            return path
        }

        if let baseline {
            path.move(to: CGPoint(x: first.x, y: baseline))
            path.addLine(to: first)
        } else {
            path.move(to: first)
        }

        let tension: CGFloat = 0.72
        for i in 0..<(run.count - 1) {
            let p0 = i > 0 ? run[i - 1] : run[i]
            let p1 = run[i]
            let p2 = run[i + 1]
            let p3 = i + 2 < run.count ? run[i + 2] : run[i + 1]
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6 * tension,
                y: p1.y + (p2.y - p0.y) / 6 * tension
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6 * tension,
                y: p2.y - (p3.y - p1.y) / 6 * tension
            )
            path.addCurve(to: p2, control1: c1, control2: c2)
        }

        if let baseline, let last = run.last {
            path.addLine(to: CGPoint(x: last.x, y: baseline))
            path.closeSubpath()
        }
        return path
    }

    // MARK: Layers

    private func gridlines(in size: CGSize) -> some View {
        Path { path in
            for step in 0...3 {
                let y = size.height * CGFloat(step) / 3
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(
            KleioPalette.stroke.opacity(0.55),
            style: StrokeStyle(lineWidth: 1, dash: [3, 5])
        )
    }

    @ViewBuilder
    private func seriesFill(_ line: KleioTrendSeries, in size: CGSize) -> some View {
        let allRuns = runs(of: points(for: line, in: size)).filter { $0.count > 1 }
        ForEach(Array(allRuns.enumerated()), id: \.offset) { _, run in
            smoothPath(through: run, closedTo: size.height)
                .fill(
                    // Quiet fills: with several series the gradients stack, and
                    // anything stronger than ~0.09 turns the midfield muddy.
                    LinearGradient(
                        colors: [line.color.opacity(0.09), line.color.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    @ViewBuilder
    private func seriesStroke(_ line: KleioTrendSeries, in size: CGSize) -> some View {
        let allRuns = runs(of: points(for: line, in: size))
        ForEach(Array(allRuns.enumerated()), id: \.offset) { _, run in
            if run.count == 1, let only = run.first {
                Circle()
                    .fill(line.color)
                    .frame(width: 5, height: 5)
                    .position(only)
            } else {
                smoothPath(through: run)
                    .stroke(
                        line.color,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
            }
        }
    }

    private func hoverHairline(at index: Int, in size: CGSize) -> some View {
        let x = xPosition(index, width: size.width)
        return Path { path in
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        .stroke(KleioPalette.secondary.opacity(0.35), lineWidth: 1)
    }

    @ViewBuilder
    private func hoverDots(at index: Int, in size: CGSize) -> some View {
        ForEach(series) { line in
            let linePoints = points(for: line, in: size)
            if linePoints.indices.contains(index), let point = linePoints[index] {
                ZStack {
                    Circle().fill(Color.white)
                    Circle().strokeBorder(line.color, lineWidth: 2)
                }
                .frame(width: 9, height: 9)
                .position(point)
            }
        }
    }

    private func tooltip(at index: Int, in size: CGSize) -> some View {
        let tooltipWidth: CGFloat = 168
        let x = min(max(xPosition(index, width: size.width), tooltipWidth / 2 + 4), size.width - tooltipWidth / 2 - 4)
        return VStack(alignment: .leading, spacing: 6) {
            Text((tooltipLabels ?? xLabels).indices.contains(index) ? (tooltipLabels ?? xLabels)[index] : "")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(KleioPalette.secondary)
            ForEach(series) { line in
                if let display = line.display.indices.contains(index) ? line.display[index] : nil {
                    HStack(spacing: 7) {
                        Circle().fill(line.color).frame(width: 7, height: 7)
                        Text(line.name)
                            .font(.system(size: 11))
                            .foregroundStyle(KleioPalette.secondary)
                        Spacer(minLength: 10)
                        Text(display)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(KleioPalette.ink)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: tooltipWidth)
        .background(Color.white.opacity(0.98), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(KleioPalette.stroke, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.10), radius: 10, y: 4)
        .position(x: x, y: 8 + tooltipHeightEstimate / 2)
        .allowsHitTesting(false)
    }

    private var tooltipHeightEstimate: CGFloat {
        26 + CGFloat(series.count) * 18
    }

    /// Labels sit exactly under their points; with many slots only every k-th label
    /// (plus the last) is drawn so they never collide.
    private var xAxisLabels: some View {
        GeometryReader { proxy in
            let stride = max(1, Int((Double(slotCount) / 8).rounded(.up)))
            ForEach(Array(xLabels.enumerated()), id: \.offset) { index, label in
                // Every stride-th label plus the last, skipping one that would crowd the last.
                if index == slotCount - 1 || (index % stride == 0 && slotCount - 1 - index >= stride) {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(KleioPalette.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .position(x: labelX(index, width: proxy.size.width), y: proxy.size.height / 2)
                }
            }
        }
        .frame(height: 14)
    }

    private func labelX(_ index: Int, width: CGFloat) -> CGFloat {
        // Keep edge labels inside the plot instead of half-clipped.
        min(max(xPosition(index, width: width), 14), width - 14)
    }

    private var legend: some View {
        HStack(spacing: 18) {
            ForEach(series) { line in
                HStack(spacing: 7) {
                    Circle().fill(line.color).frame(width: 8, height: 8)
                    Text(line.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(KleioPalette.ink)
                        .lineLimit(1)
                        .fixedSize()
                    Text(line.summary)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(KleioPalette.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
