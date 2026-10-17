import SwiftUI

/// Fixed palette for the viewer's hardware look: a dark graphite enclosure, a near-black display bezel and a lit
/// blue-grey LCD. The Android camera uses the same design in light, so the two phones are easy to tell apart.
enum Hardware {
    static let enclosure = LinearGradient(colors: [Color(white: 0.17), Color(white: 0.10)], startPoint: .top, endPoint: .bottom)
    static let plate = Color(white: 0.21)
    static let bezel = Color(white: 0.06)
    static let lcdTop = Color(red: 0.73, green: 0.84, blue: 0.89)
    static let lcdBottom = Color(red: 0.64, green: 0.77, blue: 0.83)
    static let ink = Color(red: 0.10, green: 0.15, blue: 0.18)
    /// Engraving on the enclosure and keys.
    static let label = Color(white: 0.86)
    /// The shadow that makes engraving read as cut into the surface.
    static let engraveShadow = Color.black.opacity(0.7)
    static let tally = Color(red: 0.86, green: 0.05, blue: 0.10)
}

/// A raised panel that holds the display or the controls.
struct Plate: View {
    var radius: CGFloat = 28
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(Hardware.plate)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
    }
}

/// The recessed well that keys sit in.
struct KeyHousing<Content: View>: View {
    var radius: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.padding(5).background(
            shape.fill(Color(white: 0.11).shadow(.inner(color: .black.opacity(0.7), radius: 2.5, y: 1.5)))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.clear, .white.opacity(0.10)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        )
    }
}

/// `standard` keys match the enclosure; `accent` keys stand out for the action that needs attention.
enum KeyTone { case standard, accent }

/// The face of a physical key. `down` is a latched or pressed key; `deep` is a key being pressed right now.
struct KeyFace: View {
    var radius: CGFloat
    var tone: KeyTone = .standard
    var down = false
    var deep = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let colors: [Color] = switch (tone, down) {
        case (.standard, false): [Color(white: 0.33), Color(white: 0.23)]
        case (.standard, true): [Color(white: 0.19), Color(white: 0.24)]
        case (.accent, false): [Color(white: 0.97), Color(white: 0.84)]
        case (.accent, true): [Color(white: 0.80), Color(white: 0.88)]
        }
        shape.fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(tone == .accent ? 1 : 0.22), .black.opacity(0.5)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(deep ? 0.25 : down ? 0.4 : 0.6), radius: deep ? 0.5 : down ? 1.5 : 3, y: deep ? 0.5 : down ? 1 : 2.5)
    }
}

/// A physical key with a pressed travel, a light haptic click and dimmed engraving when disabled.
struct HardwareKeyStyle: ButtonStyle {
    var radius: CGFloat = 14
    var tone: KeyTone = .standard
    /// Draws the key held down, for toggles that are currently on.
    var latched = false
    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration, radius: radius, tone: tone, latched: latched)
    }
    private struct KeyBody: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        let tone: KeyTone
        let latched: Bool
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .foregroundStyle((tone == .standard ? Hardware.label : Hardware.ink).opacity(isEnabled ? 1 : 0.3))
                .background(KeyFace(radius: radius, tone: tone, down: pressed || latched, deep: pressed))
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .offset(y: pressed ? 1 : 0)
                .animation(.easeOut(duration: 0.08), value: pressed)
                .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: pressed) { _, isDown in isDown }
        }
    }
}

/// A small indicator lamp. Red marks an Android sensor that is live.
struct LED: View {
    var on: Bool
    var color = Hardware.tally
    var body: some View {
        Circle().fill(on ? color : Color(white: 0.34))
            .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
            .frame(width: 7, height: 7)
            .shadow(color: on ? color.opacity(0.85) : .clear, radius: on ? 4 : 0)
            .accessibilityHidden(true)
    }
}

/// Uppercase text printed on the enclosure below a key.
struct EngravedLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).tracking(0.6)
            .foregroundStyle(Hardware.label.opacity(0.85))
            .shadow(color: Hardware.engraveShadow, radius: 0, y: 1)
            .lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityHidden(true)
    }
}

/// The LCD glass: a blue-grey gradient with an inner shadow and a faint top reflection.
struct LCDGlass: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        shape.fill(LinearGradient(colors: [Hardware.lcdTop, Hardware.lcdBottom], startPoint: .top, endPoint: .bottom)
            .shadow(.inner(color: .black.opacity(0.35), radius: 3, y: 1.5)))
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)))
    }
}

/// A segment printed on the LCD, filled or outlined.
struct LCDBadge: View {
    let text: String
    var dot: Color?
    var outlined = false
    var body: some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(text)
        }
        .font(.caption.weight(.bold)).tracking(0.5).lineLimit(1)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .foregroundStyle(outlined ? Hardware.ink : Hardware.lcdTop)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(outlined ? Color.clear : Hardware.ink))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Hardware.ink, lineWidth: outlined ? 1.2 : 0))
    }
}

/// Elapsed live time in the recorder style, for example 0h12m34s. Unlit segments show when nothing is live.
struct LCDClock: View {
    let seconds: Int
    let lit: Bool
    var body: some View {
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        Text("\(digits(String(hours)))\(unit("h"))\(digits(String(format: "%02d", minutes)))\(unit("m"))\(digits(String(format: "%02d", rest)))\(unit("s"))")
            .lineLimit(1).minimumScaleFactor(0.5)
            .opacity(lit ? 1 : 0.28)
            .accessibilityLabel(lit ? "Live for \(hours) hours \(minutes) minutes \(rest) seconds" : "Not live")
    }
    private func digits(_ value: String) -> Text { Text(value).font(.system(size: 42, weight: .medium, design: .rounded).monospacedDigit()) }
    private func unit(_ value: String) -> Text { Text(value).font(.system(size: 21, weight: .medium, design: .rounded)) }
}

/// Analog VU meter for the Android microphone. 0 VU is aligned to -18 dBFS.
struct VUMeter: View {
    var active: Bool
    var level: () -> Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { _ in
            VUFace(position: active ? Self.position(level()) : 0, animated: !reduceMotion)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
    /// Maps a linear peak (0...1) to the needle's travel (0...1) across -20 VU to +3 VU.
    static func position(_ peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        let vu = 20 * log10(Double(peak)) + 18
        return min(max((vu + 20) / 23, 0), 1)
    }
}

private struct VUFace: View {
    let position: Double
    let animated: Bool
    private static let marks: [(vu: Double, label: String?)] = [(-20, "20"), (-10, "10"), (-7, nil), (-5, "5"), (-3, nil), (0, "0"), (3, "3")]
    private static let redZone = 20.0 / 23
    private static func angle(_ travel: Double) -> Angle { .degrees(-36 + 72 * travel) }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let pivot = CGPoint(x: size / 2, y: size * 0.80)
            let radius = size * 0.44
            ZStack {
                Circle().fill(Hardware.bezel)
                Circle().fill(LinearGradient(colors: [Hardware.lcdTop, Hardware.lcdBottom], startPoint: .top, endPoint: .bottom)
                    .shadow(.inner(color: .black.opacity(0.4), radius: 3, y: 2))).padding(size * 0.06)
                Canvas { context, _ in
                    func point(_ travel: Double, _ distance: CGFloat) -> CGPoint {
                        let radians = Self.angle(travel).radians
                        return CGPoint(x: pivot.x + distance * sin(radians), y: pivot.y - distance * cos(radians))
                    }
                    func arc(from start: Double, to end: Double) -> Path {
                        var path = Path(); path.move(to: point(start, radius))
                        for step in 1...40 { path.addLine(to: point(start + (end - start) * Double(step) / 40, radius)) }
                        return path
                    }
                    context.stroke(arc(from: 0, to: Self.redZone), with: .color(Hardware.ink), lineWidth: max(1, size * 0.012))
                    context.stroke(arc(from: Self.redZone, to: 1), with: .color(Hardware.tally), lineWidth: max(2, size * 0.035))
                    for mark in Self.marks {
                        let travel = (mark.vu + 20) / 23
                        let color = travel >= Self.redZone && mark.vu > 0 ? Hardware.tally : Hardware.ink
                        var tick = Path()
                        tick.move(to: point(travel, radius))
                        tick.addLine(to: point(travel, radius + size * (mark.label == nil ? 0.035 : 0.06)))
                        context.stroke(tick, with: .color(color), lineWidth: max(1, size * 0.012))
                        if let label = mark.label {
                            context.draw(Text(label).font(.system(size: size * 0.085, weight: .semibold, design: .rounded)).foregroundStyle(color),
                                         at: point(travel, radius + size * 0.115))
                        }
                    }
                }
                Capsule().fill(Hardware.ink)
                    .frame(width: max(1.2, size * 0.014), height: radius + size * 0.03)
                    .rotationEffect(Self.angle(position), anchor: .bottom)
                    .position(x: pivot.x, y: pivot.y - (radius + size * 0.03) / 2)
                    .animation(animated ? .easeOut(duration: 0.14) : nil, value: position)
                Rectangle().fill(Hardware.bezel)
                    .frame(height: size * 0.27)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Text("MIC").font(.system(size: size * 0.1, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(.white.opacity(0.9))
                    .position(x: size / 2, y: size * 0.86)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .black.opacity(0.3)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        }
    }
}
