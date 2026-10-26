import AppKit
import SwiftUI

/// First-launch onboarding, built on the dashboard's grid (1512×982, scaled) and motion.
///
/// 1. Splash: "BRIEFING" fills the window, holds, then glides up and away.
/// 2. Seven steps, one question each. The question lands first, its controls a beat later.
///    A step change reads as a scroll: the old page leaves upward, the next rises from below.
/// 3. Header, hairlines, the progress line and the buttons never move between steps.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @State private var pointer = Pointer()

    private var shown: Bool { model.phase == .shown }
    /// The controls follow the paragraph straight away, in the order the eye reads them.
    private static let controlsDelay = 0.2
    /// Steps move at about half the dashboard's pace.
    private static let pace = 0.55

    var body: some View {
        GeometryReader { geo in
            // The window already stops at the Dock, so no extra Dock margin is needed.
            let g = DashGrid(geo.size, dock: EdgeInsets())
            ZStack(alignment: .topLeading) {
                Backdrop(sunVisible: model.lightOn,
                         sunStrength: SettingsStore.shared.settings.sun,
                         palette: model.palette)

                chrome(g)

                page(g)
                    .offset(y: model.pageOffset * g.h)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)

                buttons(g)

                if model.splash != .none {
                    splash(g)
                        .offset(y: model.splash == .gone ? -g.h : 0)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .tracksPointer(pointer)
        }
        .ignoresSafeArea()
        .preferredColorScheme(model.palette.isLight ? .light : .dark)
        .tint(Theme.ink)
        .environment(\.locale, Theme.locale)
    }

    // MARK: - Splash

    private func splash(_ g: DashGrid) -> some View {
        let up = model.splash != .pre
        let available = g.w - g.marginL - g.marginR
        let size = min(312 * g.s, available / 4.9)

        return VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            HStack(alignment: .bottom) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 168 * g.s, height: 168 * g.s)
                    .padding(.leading, -16 * g.s)
                    .padding(.bottom, -14 * g.s)
                    .accessibilityLabel("Briefing app icon")
                Spacer()
                VStack(alignment: .trailing, spacing: 6 * g.s) {
                    Text("YOUR WAKE UP DASHBOARD").foregroundStyle(Theme.ink)
                    Text("FOR MACOS").foregroundStyle(Theme.soft)
                }
                .font(Theme.font(12 * g.s))
                .tracking(1 * g.s)
            }
            .rise(up, 0.5, 14 * g.s)
            .padding(.bottom, 40 * g.s)

            Text("BRIEFING")
                .font(Theme.font(size))
                .tracking(-size / 28)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .fixedSize()
                .offset(y: up ? 0 : size)
                .opacity(up ? 1 : 0)
                .animation(Curves.settle(1.9).delay(0.1), value: up)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .padding(.leading, -6 * g.s)
                .accessibilityAddTraits(.isHeader)

            Hair(color: Theme.rule)
                .scaleEffect(x: up ? 1 : 0.001, y: 1, anchor: .leading)
                .animation(Curves.settle(1.8).delay(0.5), value: up)
                .padding(.horizontal, -g.marginL)

            HStack {
                Text("EVERY MORNING, ONE SCREEN")
                Spacer()
                Text("SETUP \u{00B7} 7 STEPS")
            }
            .font(Theme.font(12 * g.s))
            .tracking(1 * g.s)
            .foregroundStyle(Theme.soft)
            .padding(.top, 22 * g.s)
            .rise(up, 0.9, 14 * g.s)
        }
        .padding(.leading, g.marginL)
        .padding(.trailing, g.marginR)
        .padding(.bottom, 110 * g.s)
        .frame(width: g.w, height: g.h, alignment: .bottomLeading)
    }

    // MARK: - Chrome: progress line, header, hairlines. Never moves.

    private func chrome(_ g: DashGrid) -> some View {
        let on = model.chromeOn
        let top = 104 * g.s
        let n = model.progressIndex + 1

        return ZStack(alignment: .topLeading) {
            Color.clear

            // Full-width line at the very top; the filled part glides to each new step.
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.row).frame(width: g.w, height: 2)
                Rectangle().fill(Theme.accent).frame(width: g.w * model.progress, height: 2)
            }
            .accessibilityElement()
            .accessibilityLabel("Setup progress")
            .accessibilityValue("Step \(n) of \(OnboardingStep.allCases.count)")

            HStack {
                Text("BRIEFING") + Text(" \u{00B7} YOUR WAKE UP DASHBOARD").foregroundColor(Theme.soft)
                Spacer()
                Text("SETUP") + Text(" \u{00B7} STEP \(n) OF \(OnboardingStep.allCases.count)").foregroundColor(Theme.soft)
            }
            .font(Theme.font(12 * g.s))
            .tracking(1 * g.s)
            .foregroundStyle(Theme.ink)
            .frame(width: g.w - g.marginL - g.marginR)
            .offset(x: g.marginL, y: 46 * g.s)

            Hair(color: Theme.rule)
                .frame(width: g.w)
                .scaleEffect(x: on ? 1 : 0.001, y: 1, anchor: .leading)
                .animation(on ? Curves.settle(1.8).delay(0.4) : nil, value: on)
                .offset(y: top)

            Hair(color: Theme.rule, vertical: true)
                .frame(height: max(0, g.h - top))
                .scaleEffect(x: 1, y: on ? 1 : 0.001, anchor: .top)
                .animation(on ? Curves.settle(1.7).delay(0.7) : nil, value: on)
                .offset(x: g.x(5), y: top)
        }
        .frame(width: g.w, height: g.h, alignment: .topLeading)
        .opacity(on ? 1 : 0)
        .animation(on ? Curves.fade(1.2).delay(0.5) : nil, value: on)
        .allowsHitTesting(false)
    }

    // MARK: - Page: the question on the left, its controls on the right

    private func page(_ g: DashGrid) -> some View {
        let vrX = g.x(5)
        let top = 168 * g.s
        let leftW = max(200, vrX - 40 * g.s - g.marginL)
        let rightX = vrX + 40 * g.s
        let rightW = max(200, g.w - rightX - g.marginR)
        let rightH = max(0, g.h - top - g.hintBottom - 52 * g.s - 40 * g.s)

        return ZStack(alignment: .topLeading) {
            Color.clear
            question(g)
                .frame(width: leftW, alignment: .leading)
                .offset(x: g.marginL, y: top)
            controls(g)
                .frame(width: rightW, height: rightH, alignment: .topLeading)
                .offset(x: rightX, y: top)
        }
        .frame(width: g.w, height: g.h, alignment: .topLeading)
    }

    private func question(_ g: DashGrid) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14 * g.s) {
                Text(model.step.number).foregroundStyle(Theme.accent).monospacedDigit()
                Rectangle().fill(Theme.ink).frame(width: 56 * g.s, height: 1)
                Text(model.step.title.uppercased(with: Theme.locale))
            }
            .font(Theme.font(12 * g.s))
            .tracking(1 * g.s)
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .rise(shown, 0, 16 * g.s, pace: Self.pace)

            Text(model.step.question)
                .font(Theme.font(72 * g.s))
                .tracking(-2.2 * g.s)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 36 * g.s)
                .rise(shown, 0.06, 16 * g.s, pace: Self.pace)
                .accessibilityAddTraits(.isHeader)

            Text(paragraph)
                .font(Theme.font(20 * g.s, .regular))
                .lineSpacing(4 * g.s)
                .foregroundStyle(Theme.soft)
                .frame(maxWidth: 460 * g.s, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 28 * g.s)
                .rise(shown, 0.12, 16 * g.s, pace: Self.pace)
        }
    }

    private var paragraph: String {
        switch model.step {
        case .welcome: return "About two minutes. Everything can be changed later."
        case .theme: return model.palette.summary
        case .access: return model.showToday
            ? "Read only. Briefing never changes your calendar or reminders."
            : "No calendar, no problem: the Today block stays hidden. You can bring it back in Settings."
        case .principles: return "Three to five lines, one breath each. You will read them every morning."
        case .challenge: return "One or two rules. Small enough to keep every single day. Resets on the first."
        case .wake: return "Fullscreen on the first wake of the day. The rest of the day it stays out of the way."
        case .ready: return "Close this window. Tomorrow morning, it will be waiting."
        }
    }

    @ViewBuilder
    private func controls(_ g: DashGrid) -> some View {
        switch model.step {
        case .welcome: welcomeList(g)
        case .theme: themeGrid(g)
        case .access: accessList(g)
        case .principles: principleFields(g)
        case .challenge: challengeFields(g)
        case .wake: wakeRows(g)
        case .ready: whatsNext(g)
        }
    }

    private func delay(_ i: Int, step: Double = 0.06) -> Double {
        Self.controlsDelay + Double(i) * step
    }

    // MARK: 001 Welcome

    private static let promises = [
        "The day, the time, the weather.",
        "Your calendar and reminders.",
        "The principles you live by.",
        "One challenge for the month.",
        "Then you sign, and begin.",
    ]

    private func welcomeList(_ g: DashGrid) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.promises.enumerated()), id: \.offset) { i, line in
                HStack(alignment: .firstTextBaseline, spacing: 24 * g.s) {
                    Text(String(format: "%02d", i + 1))
                        .font(Theme.font(12 * g.s)).tracking(1 * g.s)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 32 * g.s, alignment: .leading)
                    Text(line)
                        .font(Theme.font(36 * g.s)).tracking(-0.5 * g.s)
                        .foregroundStyle(Theme.ink)
                }
                .padding(.vertical, 16 * g.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .rule(bottom: i == Self.promises.count - 1)
                .rise(shown, delay(i), 16 * g.s, pace: Self.pace)
            }
        }
    }

    // MARK: 002 Theme — dark grounds first, then light ones

    private func themeGrid(_ g: DashGrid) -> some View {
        let dark = Palette.all.filter { !$0.isLight }
        let light = Palette.all.filter { $0.isLight }
        return VStack(alignment: .leading, spacing: 34 * g.s) {
            themeGroup("Dark grounds", dark, first: 0, g)
            themeGroup("Light grounds", light, first: dark.count, g)
        }
    }

    private func themeGroup(_ title: String, _ palettes: [Palette], first: Int, _ g: DashGrid) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 18 * g.s, alignment: .top), count: 5)
        return VStack(alignment: .leading, spacing: 18 * g.s) {
            Text(title.uppercased(with: Theme.locale))
            .font(Theme.font(12 * g.s))
            .tracking(1 * g.s)
            .foregroundStyle(Theme.soft)
            .padding(.bottom, 10 * g.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Hair() }
            .rise(shown, delay(first == 0 ? 0 : first + 1, step: 0.035), 16 * g.s, pace: Self.pace)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 26 * g.s) {
                ForEach(Array(palettes.enumerated()), id: \.element.id) { i, p in
                    let n = first + i
                    ThemeTile(palette: p, number: n + 1, selected: p.id == model.themeID, s: g.s) {
                        model.pick(p.id)
                    }
                    .rise(shown, delay(n + (first == 0 ? 1 : 2), step: 0.035), 16 * g.s, pace: Self.pace)
                }
            }
        }
    }

    // MARK: 003 Access

    private func accessList(_ g: DashGrid) -> some View {
        let cloud = CloudProvider.configured
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                accessRow("Calendar", "Today\u{2019}s events.", model.calendar, g, 0) { model.allowCalendar() }
                accessRow("Reminders", "What is due.", model.reminders, g, 1) { model.allowReminders() }
                ForEach(Array(cloud.enumerated()), id: \.element) { i, provider in
                    accessRow(provider.name, "Straight from your \(provider.accountName) account.", model.cloud(provider), g, 2 + i,
                              labels: ("Connect", "Connected")) { model.connect(provider) }
                }
            }
            .opacity(model.showToday ? 1 : 0.3)
            .allowsHitTesting(model.showToday)

            HStack(alignment: .center, spacing: 24 * g.s) {
                VStack(alignment: .leading, spacing: 6 * g.s) {
                    Text("City").font(Theme.font(36 * g.s)).tracking(-0.5 * g.s).foregroundStyle(Theme.ink)
                    Text(cityNote)
                        .font(Theme.font(16 * g.s, .regular))
                        .foregroundStyle(model.cityStatus == .notFound ? Theme.ink : Theme.soft)
                        .lineLimit(1)
                        .id(cityNote)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                // Enter in the city: with both permissions already given, nothing is left on this step — move on.
                CityField(text: $model.city, s: g.s) {
                    if model.calendar == .granted && model.reminders == .granted { model.next() }
                }
            }
            .padding(.vertical, 18 * g.s)
            .rule(bottom: true)
            .rise(shown, delay(2 + cloud.count), 16 * g.s, pace: Self.pace)

            QuietButton(title: model.showToday ? "I don\u{2019}t use a calendar \u{2014} hide Today"
                                               : "Show Today after all", s: g.s) { model.toggleToday() }
                .padding(.top, 18 * g.s)
                .rise(shown, delay(3 + cloud.count), 16 * g.s, pace: Self.pace)
        }
    }

    private var cityNote: String {
        switch model.cityStatus {
        case .idle: return "For the weather. In any language."
        case .looking: return "Looking it up\u{2026}"
        case .found(let place): return "Weather for \(place)."
        case .notFound: return "Not found. Try adding the country."
        }
    }

    private func accessRow(_ name: String, _ why: String, _ state: PermissionState, _ g: DashGrid, _ i: Int,
                           labels: (ask: String, granted: String) = ("Allow", "Allowed"),
                           action: @escaping () -> Void) -> some View {
        let label: String
        let color: Color
        switch state {
        case .ask: label = labels.ask; color = Theme.ink
        case .granted: label = labels.granted; color = Theme.accent
        case .denied: label = "Open Settings"; color = Theme.dim
        }
        return HStack(alignment: .center, spacing: 24 * g.s) {
            VStack(alignment: .leading, spacing: 6 * g.s) {
                Text(name).font(Theme.font(36 * g.s)).tracking(-0.5 * g.s).foregroundStyle(Theme.ink)
                Text(why).font(Theme.font(16 * g.s, .regular)).foregroundStyle(Theme.soft)
            }
            Spacer(minLength: 0)
            Button(action: action) {
                Text(label.uppercased(with: Theme.locale))
                    .font(Theme.font(12 * g.s)).tracking(1 * g.s)
                    .foregroundStyle(color)
                    // Something to press is underlined; a permission already given is just a word.
                    .underlined(color.opacity(state == .granted ? 0 : 0.6), offset: 2 * g.s)
                    .padding(.vertical, 14 * g.s)
                    .padding(.leading, 24 * g.s)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
            .onHover { Cursor.hover($0 && state != .granted) }
            .disabled(state == .granted)
            .accessibilityLabel("\(label) \(name)")
        }
        .padding(.vertical, 18 * g.s)
        .rule()
        .rise(shown, delay(i), 16 * g.s, pace: Self.pace)
    }

    // MARK: 004 Principles

    private static let principleExamples = [
        "Keep my word.", "Do the hard thing first.", "No excuses. Only decisions.",
        "Respect the body.", "Finish what I start.",
    ]

    private func principleFields(_ g: DashGrid) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<model.principles.count, id: \.self) { i in
                numberedField(i, label: "Principle \(i + 1)",
                              placeholder: Self.principleExamples[i % Self.principleExamples.count],
                              text: $model.principles[i], limit: TextLimit.principle, g)
            }
        }
    }

    // MARK: 005 Challenge

    private static let challengeExamples = ["Three liters of water a day.", "No phone in the first hour."]

    private func challengeFields(_ g: DashGrid) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<model.challenges.count, id: \.self) { i in
                numberedField(i, label: "Rule \(i + 1)",
                              placeholder: Self.challengeExamples[i % Self.challengeExamples.count],
                              text: $model.challenges[i], g)
            }
            MonthTrack(on: shown, s: g.s)
                .padding(.top, 56 * g.s)
                .rise(shown, delay(2), 16 * g.s, pace: Self.pace)
        }
    }

    private func numberedField(_ i: Int, label: String, placeholder: String, text: Binding<String>,
                               limit: Int? = nil, _ g: DashGrid) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24 * g.s) {
            Text(String(format: "%02d", i + 1))
                .font(Theme.font(12 * g.s)).tracking(1 * g.s)
                .foregroundStyle(Theme.accent)
                .frame(width: 32 * g.s, alignment: .leading)
                .accessibilityHidden(true)
            LineField(label: label, placeholder: placeholder, text: text, size: 36 * g.s, s: g.s, limit: limit)
        }
        .rise(shown, delay(i), 16 * g.s, pace: Self.pace)
    }

    // MARK: 006 Wake routine

    private func wakeRows(_ g: DashGrid) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            toggleRow("Open on first wake", model.autoOpen, g, 0) {
                withAnimation(Curves.fade(0.4)) { model.autoOpen.toggle() }
            }

            HStack(alignment: .center, spacing: 24 * g.s) {
                Text("Not before").font(Theme.font(36 * g.s)).tracking(-0.5 * g.s).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                TimeStepper(text: model.notBeforeText, s: g.s,
                            earlier: { model.shiftTime(-15) }, later: { model.shiftTime(15) })
            }
            .padding(.vertical, 18 * g.s)
            .rule()
            .rise(shown, delay(1), 16 * g.s, pace: Self.pace)

            toggleRow("Open at login", model.openAtLogin, g, 2, last: true) {
                withAnimation(Curves.fade(0.4)) { model.openAtLogin.toggle() }
            }
        }
    }

    private func toggleRow(_ title: String, _ on: Bool, _ g: DashGrid, _ i: Int, last: Bool = false,
                           action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 24 * g.s) {
            Text(title).font(Theme.font(36 * g.s)).tracking(-0.5 * g.s).foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
            Button(action: action) {
                Text(on ? "ON" : "OFF")
                    .font(Theme.font(12 * g.s)).tracking(1 * g.s)
                    .foregroundStyle(on ? Theme.accent : Theme.dim)
                    .underlined((on ? Theme.accent : Theme.dim).opacity(0.6), offset: 2 * g.s)
                    .padding(.vertical, 14 * g.s)
                    .padding(.leading, 24 * g.s)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
            .onHover { Cursor.hover($0) }
            .accessibilityLabel(title)
            .accessibilityValue(on ? "On" : "Off")
        }
        .padding(.vertical, 18 * g.s)
        .rule(bottom: last)
        .rise(shown, delay(i), 16 * g.s, pace: Self.pace)
    }

    // MARK: 007 Ready — what happens next

    private func whatsNext(_ g: DashGrid) -> some View {
        let first: (String, String) = model.autoOpen
            ? ("Tomorrow", "It opens by itself on the first wake after \(model.notBeforeText).")
            : ("Any morning", "Open it from the grid icon in the menu bar.")
        let keys = SettingsStore.shared.settings
        let rows: [(String, String)] = [
            first,
            (keys.keyLabel(.advance), "Sign, and it is gone until tomorrow."),
            (keys.keyLabel(.amend), "Amend principles and challenges, any morning."),
            (keys.keyLabel(.toggle), "Brings it back any time, from anywhere."),
            (keys.keyLabel(.settings), "Themes, blocks, calendars and keys: all in Settings."),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(alignment: .firstTextBaseline, spacing: 24 * g.s) {
                    Text(row.0.uppercased(with: Theme.locale))
                        .font(Theme.font(12 * g.s)).tracking(1 * g.s)
                        .foregroundStyle(i == 0 ? Theme.accent : Theme.dim)
                        .frame(width: 130 * g.s, alignment: .leading)
                    Text(row.1)
                        .font(Theme.font(i == 0 ? Theme.Size.subheading * g.s : Theme.Size.body * g.s))
                        .tracking(-0.4 * g.s)
                        .foregroundStyle(i == 0 ? Theme.ink : Theme.soft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, (i == 0 ? 20 : 14) * g.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .rule(bottom: i == rows.count - 1)
                .rise(shown, delay(i), 16 * g.s, pace: Self.pace)
            }
        }
    }

    // MARK: - Buttons, bottom right. Never move; only the label changes.

    private var cta: String {
        switch model.step {
        case .welcome: return "Begin setup"
        case .theme: return "Use \(model.palette.name)"
        case .access: return (model.anyAccess || !model.showToday) ? "Continue" : "Skip for now"
        case .principles: return model.filledPrinciples.isEmpty ? "Later" : "Continue"
        case .challenge: return model.filledChallenges.isEmpty ? "Later" : "Continue"
        case .wake: return "Continue"
        case .ready: return "Sign & begin"
        }
    }

    private func buttons(_ g: DashGrid) -> some View {
        let on = model.chromeOn
        return HStack(spacing: 32 * g.s) {
            if model.step != .welcome {
                Button { model.previous() } label: {
                    Text("BACK")
                        .font(Theme.font(12 * g.s)).tracking(1 * g.s)
                        .foregroundStyle(Theme.soft)
                        .underlined(Theme.soft.opacity(0.6), offset: 2 * g.s)
                        .padding(.vertical, 14 * g.s)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressDim())
                .onHover { Cursor.hover($0) }
                .keyboardShortcut(.cancelAction)
            }

            Button { model.next() } label: {
                HStack(spacing: 14 * g.s) {
                    Text(cta.uppercased(with: Theme.locale))
                    Arrow()
                        .stroke(model.palette.swatchColor, style: StrokeStyle(lineWidth: 1.2, lineCap: .square))
                        .frame(width: 16 * g.s, height: 9 * g.s)
                        .accessibilityHidden(true)
                }
                .font(Theme.font(12 * g.s))
                .tracking(1 * g.s)
                .foregroundStyle(model.palette.swatchColor)
                .padding(.horizontal, 26 * g.s)
                .frame(height: 52 * g.s)
                .background(Theme.ink)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(model.finishing)
        }
        .frame(width: g.w - g.marginL - g.marginR, height: 52 * g.s, alignment: .trailing)
        .offset(x: g.marginL, y: g.h - g.hintBottom - 52 * g.s)
        .opacity(on ? 1 : 0)
        .animation(on ? Curves.fade(1.2).delay(0.5) : nil, value: on)
        .allowsHitTesting(on)
    }
}

// MARK: - Pieces

/// A one-pixel rule at any display scale (0.5 pt vanished on some lines and screens).
private extension View {
    /// The dashboard's row rule: a line above, and optionally below.
    func rule(bottom: Bool = false) -> some View {
        overlay(alignment: .top) { Hair() }
            .overlay(alignment: .bottom) {
                if bottom { Hair() }
            }
    }
}

/// A borderless text field on a hairline, like the dashboard's edit mode.
private struct LineField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let size: CGFloat
    let s: CGFloat
    /// The most characters the line may hold; longer typing or pasting is cut there.
    var limit: Int? = nil

    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Theme.faint))
            .textFieldStyle(.plain)
            .font(Theme.font(size))
            .foregroundStyle(Theme.ink)
            .focused($focused)
            .padding(.vertical, 14 * s)
            .overlay(alignment: .bottom) {
                Hair(color: focused ? Theme.ink.opacity(0.7) : Theme.row)
            }
            .overlay(alignment: .bottomTrailing) {
                if let limit {
                    LengthNote(count: text.count, limit: limit, s: s)
                        .offset(y: 18 * s)
                }
            }
            .onChange(of: text) { _, new in
                if let limit, new.count > limit { text = String(new.prefix(limit)) }
            }
            .animation(Curves.fade(0.3), value: focused)
            .accessibilityLabel(label)
    }
}

/// "07:30" in the accent colour on a hairline, with quiet − and + either side (15-minute steps).
private struct TimeStepper: View {
    let text: String
    let s: CGFloat
    let earlier: () -> Void
    let later: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18 * s) {
            stepButton("\u{2212}", "Earlier", earlier)
            Text(text)
                .font(Theme.font(28 * s))
                .monospacedDigit()
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 6 * s)
                .overlay(alignment: .bottom) { Hair(color: Theme.rule) }
                .accessibilityLabel("Not before \(text)")
            stepButton("+", "Later", later)
        }
    }

    private func stepButton(_ glyph: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(Theme.font(20 * s, .regular))
                .foregroundStyle(Theme.soft)
                .frame(width: 32 * s, height: 44 * s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The city, right-aligned in the accent colour on a hairline: the same shape as the wake time.
/// The field and its line are exactly as wide as what is written (or the placeholder), and follow it as you type.
private struct CityField: View {
    @Binding var text: String
    let s: CGFloat
    var onSubmit: () -> Void = {}

    @State private var focused = false
    private static let placeholder = "Your city"

    private var font: NSFont { Theme.nsFont(28 * s) }
    private var lineHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font)) }

    private var width: CGFloat {
        func measure(_ t: String) -> CGFloat {
            ceil((t as NSString).size(withAttributes: [.font: font]).width)
        }
        // A little room for the caret, so the last letter is never clipped while typing.
        let content = measure(text.isEmpty ? Self.placeholder : text) + 6 * s
        return min(content, 420 * s)
    }

    var body: some View {
        StableTextField(text: $text, focused: $focused, placeholder: Self.placeholder, font: font,
                        color: NSColor(Theme.accent), placeholderColor: NSColor(Theme.faint), onSubmit: onSubmit)
            .frame(width: width, height: lineHeight)
            .padding(.bottom, 6 * s)
            .overlay(alignment: .bottom) {
                Hair(color: focused ? Theme.ink.opacity(0.7) : Theme.rule)
            }
            .animation(Curves.fade(0.3), value: focused)
            .accessibilityLabel("City")
    }
}

/// A one-line AppKit text view. Unlike a text field it draws its text the same way whether or not
/// it is being edited, so nothing jumps or gets clipped when you click into it.
private struct StableTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let font: NSFont
    let color: NSColor
    let placeholderColor: NSColor
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> LineTextView {
        let view = LineTextView()
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.maximumNumberOfLines = 1
        view.textContainer?.lineBreakMode = .byClipping
        view.textContainer?.widthTracksTextView = true
        view.alignment = .right
        view.focusRingType = .none
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: LineTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text { view.string = text }
        view.font = font
        view.textColor = color
        view.insertionPointColor = color
        view.selectedTextAttributes = [.backgroundColor: color.withAlphaComponent(0.16)]
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        view.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        view.placeholder = NSAttributedString(string: placeholder, attributes: [
            .font: font, .foregroundColor: placeholderColor, .paragraphStyle: paragraph,
        ])
        view.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: StableTextField
        init(_ parent: StableTextField) { self.parent = parent }

        func textDidBeginEditing(_ note: Notification) { parent.focused = true }
        func textDidEndEditing(_ note: Notification) { parent.focused = false }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            // One line only: a pasted line break becomes a space.
            if view.string.contains(where: \.isNewline) {
                view.string = view.string.replacingOccurrences(of: "\r\n", with: " ")
                    .components(separatedBy: .newlines).joined(separator: " ")
            }
            parent.text = view.string
            view.needsDisplay = true
        }

        /// Enter finishes typing (and submits), Esc just finishes; Tab moves on, as in a field.
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                view.window?.makeFirstResponder(nil)
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                view.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.insertTab(_:)):
                view.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                view.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }
    }

    /// Draws the placeholder in the exact spot the text will take.
    final class LineTextView: NSTextView {
        var placeholder: NSAttributedString?

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if string.isEmpty, let placeholder {
                placeholder.draw(in: bounds)
            }
        }
    }
}

/// The month as one line, filled up to the end of today; weeks as ticks.
/// Line, ticks and fill are drawn as one picture, so they always move together.
private struct MonthTrack: View {
    let on: Bool
    let s: CGFloat

    var body: some View {
        let now = Date()
        let cal = Calendar.current
        let days = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let today = cal.component(.day, from: now)
        let share = CGFloat(today) / CGFloat(max(days, 1))

        VStack(alignment: .leading, spacing: 14 * s) {
            HStack {
                Text(Fmt.string(now, "MMMM").uppercased(with: Theme.locale)).foregroundStyle(Theme.ink)
                Spacer()
                Text("DAY \(today) / \(days)").foregroundStyle(Theme.dim)
            }
            .font(Theme.font(12 * s)).tracking(1 * s)

            TrackBar(fill: on ? share : 0, days: days, s: s,
                     rule: Theme.rule, accent: Theme.accent)
                .frame(height: 10 * s)
                .animation(on ? Curves.settle(1.1).delay(0.45) : Curves.fade(0.3), value: on)

            HStack {
                Text("1")
                Spacer()
                Text("\(days)")
            }
            .font(Theme.font(12 * s, .regular))
            .monospacedDigit()
            .foregroundStyle(Theme.dim)
        }
        .accessibilityElement()
        .accessibilityLabel("Day \(today) of \(days)")
    }
}

/// The hairline, week ticks and the filled part, with a softly rounded end where today stops.
private struct TrackBar: View, Animatable {
    var fill: CGFloat
    let days: Int
    let s: CGFloat
    let rule: Color
    let accent: Color
    @Environment(\.displayScale) private var scale

    var animatableData: CGFloat {
        get { fill }
        set { fill = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, mid = (size.height / 2).rounded()
            let px = 1 / max(scale, 1)
            ctx.fill(Path(CGRect(x: 0, y: mid - px / 2, width: w, height: px)), with: .color(rule))
            for d in stride(from: 1, through: days, by: 7) {
                let x = w * CGFloat(d - 1) / CGFloat(max(days, 1))
                ctx.fill(Path(CGRect(x: x - px / 2, y: mid - 3.5 * s, width: px, height: 7 * s)), with: .color(rule))
            }
            let bar: CGFloat = 2
            let length = w * max(0, min(1, fill))
            if length > 0 {
                let rect = CGRect(x: 0, y: mid - bar / 2, width: length, height: bar)
                let r = min(bar / 2, length / 2)
                // Square where the month starts, rounded where today ends.
                let shape = UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 0,
                                                                      bottomTrailing: r, topTrailing: r))
                ctx.fill(shape.path(in: rect), with: .color(accent))
            }
        }
    }
}

/// One theme, reduced to its essentials: the ground and its light, the index number in its ink,
/// one hairline in its rule colour. Hover lifts the name a little; the pick frames the swatch in ink
/// and lights its name up fully, letter by letter.
private struct ThemeTile: View {
    let palette: Palette
    let number: Int
    let selected: Bool
    let s: CGFloat
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12 * s) {
                swatch
                    .aspectRatio(1512 / 982, contentMode: .fit)
                    .overlay(Rectangle().strokeBorder(selected ? Theme.ink : (hover ? Theme.soft : Theme.row),
                                                      lineWidth: 1))
                name
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Curves.fade(0.3), value: selected)
        .animation(Curves.fade(0.3), value: hover)
        .accessibilityLabel(palette.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Each letter is its own Text so it can light up on its own beat; going dark again happens all at once.
    private var name: some View {
        let letters = Array(palette.name.uppercased(with: Theme.locale))
        return HStack(spacing: 0) {
            ForEach(Array(letters.enumerated()), id: \.offset) { i, ch in
                Text(String(ch))
                    .tracking(1 * s)
                    .foregroundStyle(selected ? Theme.ink : (hover ? Theme.soft : Theme.dim))
                    .animation(selected ? Curves.fade(0.18).delay(Double(i) * 0.035) : Curves.fade(0.3),
                               value: selected)
            }
        }
        .font(Theme.font(12 * s))
        .lineLimit(1)
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var swatch: some View {
        ThemeSwatch(palette: palette, number: number, s: s)
    }
}

/// A thin arrow pointing right, drawn in the button's own stroke (no symbol font).
private struct Arrow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.move(to: CGPoint(x: r.maxX - r.height / 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX - r.height / 2, y: r.maxY))
        return p
    }
}
