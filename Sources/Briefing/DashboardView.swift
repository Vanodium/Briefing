import AppKit
import SwiftUI

/// The 12-column grid of the Index layout, designed at 1512×982 (14" MacBook) and scaled to any screen.
/// Margins grow to keep everything that matters clear of the Dock, wherever it sits.
struct DashGrid {
    let w: CGFloat
    let h: CGFloat
    let s: CGFloat
    let marginL: CGFloat
    let marginR: CGFloat
    /// From the bottom edge of the screen to the bottom of the hint row.
    let hintBottom: CGFloat

    /// Breathing room between the Dock and the nearest piece of content.
    static let dockClearance: CGFloat = 40

    init(_ size: CGSize, dock: EdgeInsets) {
        w = size.width
        h = size.height
        s = max(0.6, min(size.width / 1512, size.height / 982))
        let clear = Self.dockClearance * s
        marginL = max(64 * s, dock.leading > 0 ? dock.leading + clear : 0)
        marginR = max(64 * s, dock.trailing > 0 ? dock.trailing + clear : 0)
        // The hint buttons carry 14 pt of padding below their text, so the text itself sits even higher.
        hintBottom = max(44 * s, dock.bottom > 0 ? dock.bottom + clear - 14 * s : 0)
    }

    var gap: CGFloat { 24 * s }
    var col: CGFloat { (w - marginL - marginR - 11 * gap) / 12 }
    /// Left edge of column `i` (0-based).
    func x(_ i: Int) -> CGFloat { marginL + CGFloat(i) * (col + gap) }
    func span(_ n: Int) -> CGFloat { CGFloat(n) * col + CGFloat(n - 1) * gap }
    /// From the bottom edge of the screen to the bottom of the three columns.
    var columnsBottom: CGFloat { hintBottom + 66 * s }
}

/// When each piece of the lower half arrives once the day opens. Spacing adapts to how much there is,
/// and the blocks arrive left to right in whatever order the person put them.
struct Cascade {
    private var labels: [BlockID: Double] = [:]
    private var starts: [BlockID: Double] = [:]
    private var steps: [BlockID: Double] = [:]
    private var ends: [BlockID: Double] = [:]
    private(set) var hint: Double = 1.2

    init(order: [BlockID], principles: Int, rows: Int, months: Int) {
        var t = 1.15
        for b in order {
            let n: Int
            let step: Double
            let lead: Double
            let tail: Double
            switch b {
            case .principles:
                n = principles; step = min(0.12, 0.7 / Double(max(principles, 1))); lead = 0.15; tail = 0.15
            case .today:
                n = rows; step = min(0.10, 0.6 / Double(max(rows, 1))); lead = 0.12; tail = 0.18
            case .month:
                n = months; step = 0.12; lead = 0.13; tail = 0.23
            }
            labels[b] = t
            starts[b] = t + lead
            steps[b] = step
            t += lead + Double(max(n, 1)) * step + tail
            ends[b] = t
        }
        hint = t + 0.05
    }

    var principlesLabel: Double { labels[.principles] ?? 0 }
    var todayLabel: Double { labels[.today] ?? 0 }
    var monthLabel: Double { labels[.month] ?? 0 }
    /// The month block's closing line (next month's status on the last day).
    var quote: Double { ends[.month] ?? hint }

    func principle(_ i: Int) -> Double { item(.principles, i) }
    func row(_ i: Int) -> Double { item(.today, i) }
    func month(_ i: Int) -> Double { item(.month, i) }

    private func item(_ b: BlockID, _ i: Int) -> Double {
        (starts[b] ?? 0) + Double(i) * (steps[b] ?? 0.1)
    }
}

/// Where a block stands on the 12-column grid.
struct BlockSlot: Equatable {
    let block: BlockID
    /// 1, 2, 3 — printed as 001, 002, 003 in the order the blocks stand.
    let number: Int
    let startColumn: Int
    let span: Int
    var isFirst: Bool { startColumn == 0 }

    /// Principles keep the wide column, Today the next widest; the month takes what is left.
    ///   three blocks: 5 / 4 / 3 · Principles + Today: 7 / 5 · Principles + Month: 8 / 4 ·
    ///   Today + Month: 7 / 5 · one alone: 8, 7 or 6.
    static func layout(_ blocks: [BlockID]) -> [BlockSlot] {
        let spans: [Int]
        switch blocks.count {
        case 0: spans = []
        case 1: spans = [blocks[0].isWide ? 8 : (blocks[0] == .today ? 7 : 6)]
        case 2:
            let wide: BlockID = blocks.contains(where: \.isWide) ? .principles : .today
            let split = blocks.contains(.principles) && blocks.contains(.month) ? 8 : 7
            spans = blocks.map { $0 == wide ? split : 12 - split }
        default: spans = blocks.map { $0.isWide ? 5 : ($0 == .today ? 4 : 3) }
        }
        var column = 0
        var result: [BlockSlot] = []
        for (i, b) in blocks.prefix(spans.count).enumerated() {
            result.append(BlockSlot(block: b, number: i + 1, startColumn: column, span: spans[i]))
            column += spans[i]
        }
        return result
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    let onClose: () -> Void
    var onSettings: (SettingsTab) -> Void = { _ in }
    @State private var pointer = Pointer()

    private var shown: Bool { model.stage != .pre }
    private var isFull: Bool { model.stage == .full }
    private var maxRows: Int { 7 }
    private var blocks: [BlockID] { model.settings.visibleBlocks }
    private var slots: [BlockSlot] { BlockSlot.layout(blocks) }

    /// How much lower the upper block stands before the day opens — near the optical centre.
    private static let rest: CGFloat = 389
    /// Once the day opens: the time's baseline, and the rule across the screen under it.
    private static let clockBaseline: CGFloat = 236
    private static let ruleTop: CGFloat = 281

    /// The date stands on the second column's rule when that rule is at column 5, else at 6.
    private var dateColumn: Int { slots.dropFirst().contains(where: { $0.startColumn == 5 }) ? 5 : 6 }

    private var cascade: Cascade {
        Cascade(order: blocks,
                principles: model.principles.count,
                rows: min(model.agenda.count, maxRows),
                months: model.currentChallenges.count)
    }

    var body: some View {
        GeometryReader { geo in
            let g = DashGrid(geo.size, dock: model.dock)
            ZStack(alignment: .topLeading) {
                Backdrop(sunVisible: shown, sunStrength: model.settings.sun)

                // The upper block starts lower, near the optical centre, then glides up into place.
                header(g)
                    .offset(y: isFull ? 0 : Self.rest * g.s)
                    .animation(Curves.glide, value: isFull)
                    .receded(model.editing)

                rules(g)
                columns(g)
                hints(g)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .tracksPointer(pointer)
        }
        .ignoresSafeArea()
        .preferredColorScheme(Palette.current.isLight ? .light : .dark)
        .tint(Theme.ink)
    }

    // MARK: - Upper block: day, time, date, weather

    private func header(_ g: DashGrid) -> some View {
        TimelineView(.everyMinute) { ctx in
            let date = ctx.date
            ZStack(alignment: .topLeading) {
                Color.clear

                dayWord(date, g)

                HStack(alignment: .firstTextBaseline, spacing: 14 * g.s) {
                    RollingClock(text: Fmt.clock(date), size: 168 * g.s, tracking: -6 * g.s)
                        .foregroundStyle(Theme.ink)
                    // On a 12-hour Mac: AM / PM in small capitals on the clock's baseline.
                    if let period = Fmt.period(date) {
                        Text(period)
                            .font(Theme.font(12 * g.s))
                            .tracking(1 * g.s)
                            .foregroundStyle(Theme.soft)
                    }
                }
                    .fixedSize()
                    .offset(x: g.marginL - 4 * g.s, y: Self.clockBaseline * g.s - Theme.ascent(168 * g.s))
                    .rise(shown, 0.55, 14 * g.s)

                // Once the big weekday has gone, the date line carries the name of the day.
                meta(first: Fmt.string(date, "d MMM yyyy"), opened: Fmt.string(date, "EEEE, d MMM yyyy"),
                     second: dayOfYear(date), trailing: false, g)
                    .frame(width: g.span(3), alignment: .leading)
                    .offset(x: g.x(dateColumn), y: metaTop(g))
                    .rise(shown, 0.9, 14 * g.s)

                if model.settings.showWeather {
                    meta(first: weatherFirst, second: weatherSecond, trailing: true, g)
                        .frame(width: g.span(3), alignment: .trailing)
                        .offset(x: g.x(9), y: metaTop(g))
                        .rise(shown, 1.05, 14 * g.s)
                        .transition(.opacity)
                }
            }
            .animation(Curves.fade(0.5), value: model.settings.showWeather)
            .frame(width: g.w, height: g.h, alignment: .topLeading)
        }
    }

    /// The weekday, rising out of a mask as if from behind a line. Once the day opens it is never
    /// left half-cropped by the screen edge: it carries on upward and leaves through the top of the
    /// same mask it came in by, while the block glides up and the date line takes the name of the day over.
    private func dayWord(_ date: Date, _ g: DashGrid) -> some View {
        let size = 300 * g.s
        let maskHeight = 262 * g.s
        let baseline = 231 * g.s
        // Where the baseline stands before the day opens: the arrangement this screen is built around.
        let opening = Theme.nsFont(size).capHeight * 2 / 3 + 260 * g.s
        let word = Fmt.string(date, "EEEE").uppercased(with: Theme.locale)
        let tracking = -10 * g.s
        // The longest names (WEDNESDAY) would run past the right edge at full size: they scale down to fit.
        let fit = min(1, (g.w - g.marginL - g.marginR) / Self.width(of: word, size: size, tracking: tracking))
        return ZStack(alignment: .topLeading) {
            Color.clear
            Text(word)
                .font(Theme.font(size * fit))
                .tracking(tracking * fit)
                .foregroundStyle(Theme.ink)
                .fixedSize()
                .offset(y: baseline - Theme.ascent(size * fit))
                .offset(y: shown ? 0 : maskHeight)
                .animation(Curves.settle(1.9).delay(0.15), value: shown)
                // Scoped, not `value:` animations: those would also take over the block's glide,
                // and whatever they hold would trail behind the rest of the type.
                .animation(Curves.leave(1.3)) { $0.offset(y: isFull ? -maskHeight : 0) }
                .opacity(shown ? 1 : 0)
                .animation(Curves.fade(1.2).delay(0.15), value: shown)
                .animation(Curves.fade(0.9).delay(isFull ? 0.35 : 0)) { $0.opacity(isFull ? 0 : 1) }
        }
        .frame(width: g.w - g.marginL + 4 * g.s, height: maskHeight, alignment: .topLeading)
        .clipped()
        .offset(x: g.marginL - 4 * g.s, y: opening - Self.rest * g.s - baseline)
        .accessibilityHidden(true)
    }

    private static func width(of text: String, size: CGFloat, tracking: CGFloat) -> CGFloat {
        let plain = (text as NSString).size(withAttributes: [.font: Theme.nsFont(size)]).width
        return max(1, plain + tracking * CGFloat(text.count))
    }

    /// Two lines in small capitals. `opened`, when given, replaces the first line once the day opens.
    private func meta(first: String, opened: String? = nil, second: String, trailing: Bool, _ g: DashGrid) -> some View {
        let swap = opened != nil && isFull
        return VStack(alignment: trailing ? .trailing : .leading, spacing: 6 * g.s) {
            ZStack(alignment: trailing ? .trailing : .leading) {
                // Only the opacity takes these delays (scoped animations): a `value:` animation would
                // also hold back the line's glide, and the date would trail behind the time.
                Text(first.uppercased(with: Theme.locale))
                    .animation(Curves.fade(0.7).delay(swap ? 1.0 : 0)) { $0.opacity(swap ? 0 : 1) }
                    .accessibilityHidden(swap)
                if let opened {
                    Text(opened.uppercased(with: Theme.locale))
                        .animation(Curves.fade(0.9).delay(swap ? 1.3 : 0)) { $0.opacity(swap ? 1 : 0) }
                        .accessibilityHidden(!swap)
                }
            }
            .foregroundStyle(Theme.ink)
            Text(second.uppercased(with: Theme.locale)).foregroundStyle(Theme.soft)
        }
        .font(Theme.font(12 * g.s))
        .tracking(1 * g.s)
        .multilineTextAlignment(trailing ? .trailing : .leading)
        .lineLimit(1)
    }

    /// Two 12 pt lines whose last baseline sits on the same line as the time's baseline.
    private func metaTop(_ g: DashGrid) -> CGFloat {
        let f = Theme.nsFont(12 * g.s)
        let lineHeight = f.ascender - f.descender + f.leading
        return (Self.clockBaseline + 1) * g.s - (lineHeight + 6 * g.s + f.ascender)
    }

    private func dayOfYear(_ date: Date) -> String {
        let cal = Calendar.current
        let day = cal.ordinality(of: .day, in: .year, for: date) ?? 1
        let total = cal.range(of: .day, in: .year, for: date)?.count ?? 365
        return "Day \(day) / \(total)"
    }

    private var weatherFirst: String {
        guard model.settings.hasCity else { return "Weather" }
        guard let w = model.weather else { return model.settings.city }
        return "\(model.settings.city) \(WeatherSnapshot.format(w.temperature))"
    }

    private var weatherSecond: String {
        guard model.settings.hasCity else { return "No city set" }
        guard let w = model.weather else { return "Weather unavailable" }
        if model.weatherIsStale {
            let sameDay = Calendar.current.isDate(w.fetchedAt, inSameDayAs: Date())
            return "Offline · " + (sameDay ? Fmt.time(w.fetchedAt) : Fmt.string(w.fetchedAt, "MMM d"))
        }
        guard w.day == DayKey.day(Date()) else { return w.conditions }
        return "\(w.conditions) · \(WeatherSnapshot.format(w.minimum)) / \(WeatherSnapshot.format(w.maximum))"
    }

    // MARK: - Rules: one across the screen, two down to the bottom edge

    private func rules(_ g: DashGrid) -> some View {
        let top = Self.ruleTop * g.s
        return ZStack(alignment: .topLeading) {
            Color.clear

            Hair(color: Theme.rule)
                .frame(width: g.w)
                .scaleEffect(x: isFull ? 1 : 0.001, y: 1, anchor: .leading)
                .animation(Curves.settle(1.8).delay(0.55), value: isFull)
                .opacity(isFull ? 1 : 0)
                .animation(Curves.fade(0.4).delay(isFull ? 0.55 : 0), value: isFull)
                .offset(y: top)

            // One rule between each pair of neighbouring blocks.
            ForEach(Array(slots.dropFirst().enumerated()), id: \.element.block) { i, slot in
                verticalRule(x: g.x(slot.startColumn), top: top, g, delay: 0.95 + Double(i) * 0.15)
                    .transition(.opacity)
            }
        }
        .frame(width: g.w, height: g.h, alignment: .topLeading)
        .animation(Curves.fade(0.5), value: blocks)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func verticalRule(x: CGFloat, top: CGFloat, _ g: DashGrid, delay: Double) -> some View {
        Hair(color: Theme.rule, vertical: true)
            .frame(height: g.h - top)
            .scaleEffect(x: 1, y: isFull ? 1 : 0.001, anchor: .top)
            .animation(Curves.settle(1.7).delay(delay), value: isFull)
            .opacity(isFull ? 1 : 0)
            .animation(Curves.fade(0.4).delay(isFull ? delay : 0), value: isFull)
            .offset(x: x, y: top)
    }

    // MARK: - Lower half: 001 Principles, 002 Today, 003 Month

    private func columns(_ g: DashGrid) -> some View {
        let top = (Self.ruleTop + 30) * g.s
        let height = max(0, g.h - top - g.columnsBottom)
        let c = cascade
        return ZStack(alignment: .topLeading) {
            Color.clear

            ForEach(slots, id: \.block) { slot in
                let width = g.span(slot.span) - (slot.isFirst ? 40 : 24) * g.s
                // What the list under the index label has to fit in, clear of the fading bottom edge.
                let room = CGSize(width: width, height: max(0, height - (44 + 12) * g.s))
                block(slot, g, c, room: room)
                    .frame(width: width, height: height, alignment: .topLeading)
                    .mask(alignment: .top) { columnMask(g) }
                    .offset(x: slot.isFirst ? g.marginL : g.x(slot.startColumn) + 24 * g.s, y: top)
                    .transition(.opacity)
            }
        }
        .frame(width: g.w, height: g.h, alignment: .topLeading)
        .animation(Curves.fade(0.5), value: model.editing)
        .animation(Curves.settle(0.9), value: slots)
    }

    /// A long list stops at the bottom of its column instead of running into the hints, and ends in a short
    /// fade rather than a line cut in half. The sides and top stay open for the blur of rising type.
    private func columnMask(_ g: DashGrid) -> some View {
        VStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 36 * g.s)
        }
        .padding(.horizontal, -60 * g.s)
        .padding(.top, -60 * g.s)
    }

    @ViewBuilder
    private func block(_ slot: BlockSlot, _ g: DashGrid, _ c: Cascade, room: CGSize) -> some View {
        switch slot.block {
        case .principles: principlesColumn(g, c, number: slot.number, room: room)
        case .today: todayColumn(g, c, number: slot.number).receded(model.editing)
        case .month: monthColumn(g, c, number: slot.number, room: room)
        }
    }

    /// The largest of `sizes` at which every line, wrapped to the column's width, fits its height.
    /// Past the smallest, the column's faded bottom edge takes what does not fit.
    private static func fittingSize(_ texts: [String], sizes: [CGFloat], weight: Theme.Weight, tracking: CGFloat,
                                    spacing: CGFloat, in room: CGSize, s: CGFloat) -> CGFloat {
        for size in sizes where textHeight(texts, size: size * s, weight: weight, tracking: tracking,
                                           spacing: spacing, width: room.width) <= room.height {
            return size * s
        }
        return (sizes.last ?? Theme.Size.text) * s
    }

    private static func textHeight(_ texts: [String], size: CGFloat, weight: Theme.Weight, tracking: CGFloat,
                                   spacing: CGFloat, width: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.nsFont(size, weight), .kern: tracking]
        let bound = CGSize(width: max(1, width - 2), height: .greatestFiniteMagnitude)
        let lines = texts.reduce(CGFloat(0)) { total, text in
            total + ceil((text as NSString).boundingRect(with: bound, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                          attributes: attributes).height)
        }
        return lines + spacing * CGFloat(max(texts.count - 1, 0))
    }

    private static func index(_ n: Int) -> String { String(format: "%03d", n) }

    private func indexLabel(_ number: String, _ title: String, line: CGFloat, extra: String? = nil, _ g: DashGrid) -> some View {
        HStack(spacing: 14 * g.s) {
            Text(number).foregroundStyle(Theme.accent)
            Rectangle().fill(Theme.ink).frame(width: line * g.s, height: 1)
            Text(title.uppercased(with: Theme.locale))
            if let extra {
                Text(extra.uppercased(with: Theme.locale)).foregroundStyle(Theme.dim)
            }
        }
        .font(Theme.font(12 * g.s))
        .tracking(1 * g.s)
        .foregroundStyle(Theme.ink)
        .lineLimit(1)
    }

    // 001
    private func principlesColumn(_ g: DashGrid, _ c: Cascade, number: Int, room: CGSize) -> some View {
        // 36 pt for a short list, 28 for a longer one, stepping down further when long lines would overflow.
        let sizes: [CGFloat] = model.principles.count <= 5 ? [36, 32, 28, 24, 20] : [28, 24, 20]
        let size = Self.fittingSize(model.principles.map(\.text), sizes: sizes, weight: .medium,
                                    tracking: -0.5 * g.s, spacing: 6 * g.s, in: room, s: g.s)

        return VStack(alignment: .leading, spacing: 0) {
            indexLabel(Self.index(number), "Principles", line: 56, g)
                .rise(isFull, c.principlesLabel, 20 * g.s)

            if model.editing {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        EditableList(items: $model.principles, size: Theme.Size.subheading * g.s, weight: .medium,
                                     placeholder: "New principle", addTitle: "Add principle",
                                     s: g.s, limit: TextLimit.principle, onChange: { model.persist() })
                    }
                    .padding(.top, 30 * g.s)
                    .padding(.bottom, 24 * g.s)
                }
                .scrollIndicators(.never)
                .transition(.opacity)
            } else if model.principles.isEmpty {
                VStack(alignment: .leading, spacing: 14 * g.s) {
                    Text("No principles written yet.")
                        .font(Theme.font(36 * g.s))
                        .tracking(-0.5 * g.s)
                        .foregroundStyle(Theme.soft)
                    QuietButton(title: "\(amendKey) — Write them", s: g.s) { model.beginEditing() }
                }
                .padding(.top, 30 * g.s)
                .rise(isFull, c.principle(0), 20 * g.s)
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 6 * g.s) {
                    ForEach(Array(model.principles.enumerated()), id: \.element.id) { i, item in
                        Text(item.text)
                            .font(Theme.font(size))
                            .tracking(-0.5 * g.s)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .rise(isFull, c.principle(i), 20 * g.s)
                    }
                }
                .padding(.top, 30 * g.s)
                .transition(.opacity)
            }
        }
    }

    // 002
    private func todayColumn(_ g: DashGrid, _ c: Cascade, number: Int) -> some View {
        let items = model.agenda
        let shownItems = Array(items.prefix(maxRows))
        let now = model.now
        let nextID = shownItems.first(where: { item in
            if item.allDay { return false }
            if let end = item.end { return end > now }
            if let start = item.start { return start >= now }
            return false
        })?.id

        return VStack(alignment: .leading, spacing: 0) {
            indexLabel(Self.index(number), "Today", line: 32, g)
                .rise(isFull, c.todayLabel, 20 * g.s)

            Group {
                if let blocked = model.agendaBlocked {
                    VStack(alignment: .leading, spacing: 4 * g.s) {
                        Text(blocked)
                            .font(Theme.font(16 * g.s, .regular)).foregroundStyle(Theme.soft)
                        HintButton(title: "Open Settings", color: Theme.ink, s: g.s, underline: true) {
                            onSettings(.calendars)
                        }
                    }
                    .rise(isFull, c.row(0), 20 * g.s)
                } else if shownItems.isEmpty {
                    Text("Nothing scheduled.")
                        .font(Theme.font(Theme.Size.body * g.s, .regular))
                        .foregroundStyle(Theme.soft)
                        .padding(.vertical, 11 * g.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { Hair() }
                        .overlay(alignment: .bottom) { Hair() }
                        .rise(isFull, c.row(0), 20 * g.s)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shownItems.enumerated()), id: \.element.id) { i, item in
                            AgendaRow(item: item, now: now, isNext: item.id == nextID,
                                      isLast: i == shownItems.count - 1, s: g.s)
                                .rise(isFull, c.row(i), 20 * g.s)
                        }
                        if items.count > shownItems.count {
                            Text("AND \(items.count - shownItems.count) MORE")
                                .font(Theme.font(12 * g.s)).tracking(1 * g.s)
                                .foregroundStyle(Theme.dim)
                                .padding(.top, 14 * g.s)
                                .rise(isFull, c.row(shownItems.count), 20 * g.s)
                        }
                    }
                }
            }
            .padding(.top, 30 * g.s)
        }
    }

    // 003
    private func monthColumn(_ g: DashGrid, _ c: Cascade, number: Int, room: CGSize) -> some View {
        let cur = model.currentMonthKey
        let next = model.nextMonthKey
        let day = Calendar.current.component(.day, from: model.now)
        let days = Calendar.current.range(of: .day, in: .month, for: model.now)?.count ?? 30
        // Long challenges step down from 20 pt rather than run off the bottom; the closing line keeps its place.
        let closing: CGFloat = DayKey.isLastDayOfMonth(model.now) ? 40 * g.s : 0
        let size = Self.fittingSize(model.currentChallenges.map(\.text), sizes: [20, 18, 16], weight: .regular,
                                    tracking: 0, spacing: 14 * g.s,
                                    in: CGSize(width: room.width, height: room.height - closing), s: g.s)

        return VStack(alignment: .leading, spacing: 0) {
            if model.editing {
                HStack(spacing: 22 * g.s) {
                    monthTab(DashboardModel.monthName(cur), selected: !model.editingNextMonth, g) { model.editingNextMonth = false }
                    monthTab(DashboardModel.monthName(next), selected: model.editingNextMonth, g) { model.editingNextMonth = true }
                }
                ScrollView(.vertical) {
                    EditableList(items: model.editingNextMonth ? $model.nextChallenges : $model.currentChallenges,
                                 size: 20 * g.s, weight: .regular,
                                 placeholder: "Challenge", addTitle: "Add",
                                 s: g.s, onChange: { model.persist() })
                        .padding(.top, 30 * g.s)
                        .padding(.bottom, 24 * g.s)
                }
                .scrollIndicators(.never)
                .transition(.opacity)
            } else {
                indexLabel(Self.index(number), DashboardModel.monthName(cur), line: 32, extra: "\(day)/\(days)", g)
                    .rise(isFull, c.monthLabel, 20 * g.s)

                VStack(alignment: .leading, spacing: 14 * g.s) {
                    if model.currentChallenges.isEmpty {
                        Text("No challenge set for \(DashboardModel.monthName(cur)).")
                            .font(Theme.font(20 * g.s, .regular))
                            .foregroundStyle(Theme.soft)
                            .rise(isFull, c.month(0), 20 * g.s)
                        QuietButton(title: "\(amendKey) — Set one", s: g.s) { model.beginEditing() }
                            .rise(isFull, c.month(1), 20 * g.s)
                    } else {
                        ForEach(Array(model.currentChallenges.enumerated()), id: \.element.id) { i, item in
                            Text(item.text)
                                .font(Theme.font(size, .regular))
                                .foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .rise(isFull, c.month(i), 20 * g.s)
                        }
                    }

                    // Last day of the month — time to set the next one.
                    if DayKey.isLastDayOfMonth(model.now) {
                        let ready = model.nextChallenges.count
                        Text((DashboardModel.monthName(next) + (ready > 0 ? " — \(ready) set" : " — not set · \(amendKey)")).uppercased(with: Theme.locale))
                            .font(Theme.font(12 * g.s)).tracking(1 * g.s)
                            .foregroundStyle(ready > 0 ? Theme.dim : Theme.soft)
                            .padding(.top, 8 * g.s)
                            .rise(isFull, c.quote, 20 * g.s)
                    }
                }
                .padding(.top, 30 * g.s)
                .transition(.opacity)
            }
        }
    }

    /// The tab being edited carries a solid underline, the other a quiet one — both read as switches.
    private func monthTab(_ title: String, selected: Bool, _ g: DashGrid, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased(with: Theme.locale))
                .font(Theme.font(12 * g.s)).tracking(1 * g.s)
                .foregroundStyle(selected ? Theme.ink : Theme.dim)
                .underlined(selected ? Theme.ink : Theme.dim.opacity(0.6), offset: 2 * g.s)
                .padding(.vertical, 4 * g.s)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .onHover { Cursor.hover($0) }
        .animation(Curves.fade(0.4), value: selected)
    }

    private var amendKey: String { model.settings.keyLabel(.amend) }

    // MARK: - Hints, bottom right

    private func hints(_ g: DashGrid) -> some View {
        let fullIdle = isFull && !model.editing
        // After the first cascade, the hints come back quickly (e.g. when leaving edit mode).
        let fullDelay = Date().timeIntervalSince(model.fullSince) > 4 ? 0.2 : cascade.hint

        return ZStack(alignment: .trailing) {
            // Quiet on purpose: small, faint, one line. They are there when looked for, not before.
            HStack(spacing: 20 * g.s) {
                HintButton(title: "\(model.settings.keyLabel(.settings)) — Settings", color: Theme.faint.opacity(0.6),
                           s: g.s, size: 10) {
                    onSettings(.general)
                }
                if model.canEdit {
                    HintButton(title: "\(amendKey) — Amend", color: Theme.faint.opacity(0.6), s: g.s, size: 10) {
                        model.beginEditing()
                    }
                }
                HintButton(title: "\(model.settings.keyLabel(.advance)) — Sign & begin", color: Theme.faint,
                           s: g.s, size: 10) { onClose() }
            }
            .fixedSize()
            .rise(fullIdle, fullDelay, 8 * g.s)
            .allowsHitTesting(fullIdle)

            HintButton(title: "Esc — Done", color: Theme.dim, s: g.s, size: 10) { model.endEditing() }
                .fixedSize()
                .rise(model.editing, 0.15, 8 * g.s)
                .allowsHitTesting(model.editing)
        }
        .frame(width: g.w - g.marginL - g.marginR, height: 44 * g.s, alignment: .trailing)
        .offset(x: g.marginL, y: g.h - g.hintBottom - 44 * g.s)
    }
}

// MARK: - Edit mode

/// How long a line may be typed. A principle is read in one breath: about two lines in the wide column at 36 pt,
/// so five of them still fit without the type stepping down.
enum TextLimit {
    static let principle = 60
}

/// "52 / 60" under a field, once the text comes within ten characters of its limit; nothing before that.
struct LengthNote: View {
    let count: Int
    let limit: Int
    let s: CGFloat

    var body: some View {
        let near = count >= limit - 10
        Text("\(count) / \(limit)")
            .font(Theme.font(11 * s, .regular))
            .monospacedDigit()
            .foregroundStyle(count >= limit ? Theme.soft : Theme.dim)
            .opacity(near ? 1 : 0)
            .animation(Curves.fade(0.3), value: near)
            .accessibilityHidden(!near)
    }
}

private extension View {
    /// While editing, what cannot be edited steps back, so the eye goes to what can.
    func receded(_ on: Bool) -> some View {
        opacity(on ? 0.18 : 1)
            .saturation(on ? 0 : 1)
            .allowsHitTesting(!on)
            .animation(Curves.fade(0.6), value: on)
    }
}

// MARK: - Plan row

/// The big clock. Each minute only the digits that change roll over: the old one lifts away, the new one rises in.
/// Not `.contentTransition(.numericText)`: its last frame was drawn without the ancestors' offsets,
/// so the time jumped up over the weekday for a moment whenever a minute turned before the day opened.
private struct RollingClock: View {
    let text: String
    let size: CGFloat
    let tracking: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, char in
                ZStack {
                    Text(String(char))
                        .font(Theme.font(size))
                        .tracking(tracking)
                        .monospacedDigit()
                        .id(char)
                        .transition(.asymmetric(insertion: roll(from: 0.45), removal: roll(from: -0.45)))
                }
            }
        }
        .animation(Curves.settle(1.1), value: text)
    }

    /// Slide in from (or out to) a share of the type size, fading and blurring on the way.
    private func roll(from share: CGFloat) -> AnyTransition {
        .modifier(active: Roll(y: share * size, blur: size * 0.04, opacity: 0),
                  identity: Roll(y: 0, blur: 0, opacity: 1))
    }

    private struct Roll: ViewModifier {
        let y: CGFloat
        let blur: CGFloat
        let opacity: Double

        func body(content: Content) -> some View {
            content.offset(y: y).blur(radius: blur).opacity(opacity)
        }
    }
}

private struct AgendaRow: View {
    let item: AgendaItem
    let now: Date
    let isNext: Bool
    let isLast: Bool
    let s: CGFloat

    private var isPast: Bool {
        if let end = item.end { return end <= now }
        return false
    }

    private var timeLabel: String {
        if item.allDay { return "All day" }
        if let start = item.start { return Fmt.time(start) }
        return "—"
    }

    private var color: Color {
        if isNext { return Theme.ink }
        if isPast { return Theme.dim }
        return Theme.soft
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20 * s) {
            Text(timeLabel)
                .monospacedDigit()
                .frame(width: (Fmt.uses24Hour ? 72 : 100) * s, alignment: .leading)
            VStack(alignment: .leading, spacing: 3 * s) {
                Text(item.title)
                    .lineLimit(2)
                if let since = item.overdueSince {
                    Text("from " + Fmt.string(since, "MMM d"))
                        .font(Theme.font(13 * s, .regular))
                        .foregroundStyle(Theme.dim)
                }
            }
        }
        .font(Theme.font(Theme.Size.body * s, isNext ? .bold : .regular))
        .foregroundStyle(color)
        .padding(.vertical, 11 * s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hair() }
        .overlay(alignment: .bottom) {
            if isLast { Hair() }
        }
    }
}

// MARK: - Editable list

private struct EditableList: View {
    @Binding var items: [EditableItem]
    let size: CGFloat
    let weight: Theme.Weight
    let placeholder: String
    let addTitle: String
    let s: CGFloat
    /// The most characters a line may hold; longer typing or pasting is cut there.
    var limit: Int? = nil
    let onChange: () -> Void

    @FocusState private var focused: UUID?
    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * s) {
            ForEach($items) { $item in
                let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
                HStack(alignment: .firstTextBaseline, spacing: 16 * s) {
                    TextField("", text: $item.text,
                              prompt: Text(placeholder).foregroundColor(Theme.faint),
                              axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.font(size, weight))
                        .foregroundStyle(Theme.ink)
                        .focused($focused, equals: item.id)
                        .padding(.bottom, 6 * s)
                        .overlay(alignment: .bottom) {
                            Hair(color: focused == item.id ? Theme.ink.opacity(0.7) : Theme.row)
                                .animation(Curves.fade(0.3), value: focused)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if let limit {
                                LengthNote(count: item.text.count, limit: limit, s: s)
                                    .offset(y: 16 * s)
                            }
                        }
                        .onChange(of: item.text) { _, new in
                            if let limit, new.count > limit { item.text = String(new.prefix(limit)) }
                        }
                    // Quiet until you reach for the row: only the text, until hover or focus.
                    let active = hovered == item.id || focused == item.id
                    HStack(alignment: .firstTextBaseline, spacing: 16 * s) {
                        QuietButton(title: "Up", s: s) { move(item.id, by: -1) }
                            .opacity(index == 0 ? 0.3 : 1)
                            .disabled(index == 0)
                        QuietButton(title: "Down", s: s) { move(item.id, by: 1) }
                            .opacity(index == items.count - 1 ? 0.3 : 1)
                            .disabled(index == items.count - 1)
                        QuietButton(title: "Delete", s: s) { remove(item.id) }
                    }
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .animation(Curves.fade(0.3), value: active)
                }
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
                }
                .transition(.opacity)
            }
            QuietButton(title: addTitle, s: s) {
                let new = EditableItem("")
                withAnimation(Curves.fade(0.4)) { items.append(new) }
                DispatchQueue.main.async { focused = new.id }
            }
            .padding(.top, 2 * s)
        }
        .onChange(of: items) { _, _ in onChange() }
    }

    private func move(_ id: UUID, by delta: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard items.indices.contains(j) else { return }
        withAnimation(Curves.settle(0.6)) { items.swapAt(i, j) }
    }

    private func remove(_ id: UUID) {
        withAnimation(Curves.fade(0.4)) { items.removeAll { $0.id == id } }
    }
}

// Buttons (QuietButton, HintButton) live in Controls.swift.

// MARK: - Formatting

enum Fmt {
    private static var formatters: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    /// Formatters are costly to make and these run on every redraw, so each format is made once.
    static func string(_ date: Date, _ format: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let f = formatters[format] ?? {
            let f = DateFormatter()
            f.locale = Theme.locale
            f.dateFormat = format
            formatters[format] = f
            return f
        }()
        f.timeZone = .autoupdatingCurrent
        return f.string(from: date)
    }

    /// The Mac's own clock setting (System Settings → General → Date & Time → 24-hour time).
    static var uses24Hour: Bool {
        let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .autoupdatingCurrent) ?? "H"
        return !pattern.contains("a")
    }

    /// The big clock: "07:42" or "7:42".
    static func clock(_ date: Date) -> String { string(date, uses24Hour ? "HH:mm" : "h:mm") }

    /// "AM" / "PM" on a 12-hour Mac, nothing on a 24-hour one.
    static func period(_ date: Date) -> String? { uses24Hour ? nil : string(date, "a") }

    /// A time in running text: "07:42" or "7:42 AM".
    static func time(_ date: Date) -> String { string(date, uses24Hour ? "HH:mm" : "h:mm a") }
}
