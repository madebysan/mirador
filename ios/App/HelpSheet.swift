import SwiftUI

/// "How Mirador works" for the iPhone: which role this phone plays, the controls, connections, problems and privacy.
struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    var body: some View {
        ZStack {
            Hardware.enclosure.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        EngravedLabel(text: "HOW MIRADOR WORKS")
                        Spacer()
                        Button { dismiss() } label: {
                            Text("Done").font(.callout.weight(.semibold)).padding(.horizontal, 18).frame(minHeight: 36)
                        }
                        .buttonStyle(HardwareKeyStyle(radius: 18))
                            .accessibilityIdentifier("helpDoneButton")
                    }
                    role
                    section("Watching", [
                        "Tap Rear or Front to see that camera. Tap the lit key again to turn video off.",
                        "Listen plays the Android microphone. Stop turns everything off.",
                        "Pinch the picture to zoom in, drag to look around, and tap the zoom number to see all of it again.",
                        "The flashlight key turns on the Android phone’s light for dark rooms. It works with the rear camera and turns off when you switch cameras or stop.",
                        "Red lights show what is live right now.",
                    ])
                    section("Connections", [
                        "Mirador tries your home Wi-Fi and Tailscale first, then the internet. Any one is enough.",
                        "The display shows which one is in use: WI-FI, TAILSCALE or INTERNET.",
                    ])
                    section("If something is wrong", [
                        "OFFLINE: the Android phone can’t be reached. Check that Mirador shows Ready on it and that it has Wi-Fi or mobile data.",
                        "Enable Mirador on Android: open Mirador on the Android phone and tap Enable. It needs this after every restart or update.",
                        "Reconnect: the connection dropped, often after switching networks. Tap it to bring back the same camera and listening.",
                    ])
                    section("Privacy", [
                        "Nothing is recorded or saved on either phone.",
                        "Leaving this app stops the Android camera and microphone right away.",
                        "On the internet route, everything is encrypted between your two phones. The relay in the middle can’t see or hear anything.",
                    ])
                    section("Pairing", [
                        "To pair again or forget the Android phone, use the ••• key.",
                        "Pairing works on any network: scan the code from Pair a Receiver on the Android phone.",
                    ])
                    Text("Mirador \(version)").font(.caption).foregroundStyle(Hardware.label.opacity(0.5))
                        .frame(maxWidth: .infinity).padding(.top, 4)
                }
                .padding(16)
            }
        }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var role: some View {
        VStack(alignment: .leading, spacing: 6) {
            LCDBadge(text: "RX")
            Text("This iPhone is the receiver.").font(.title2.weight(.semibold))
            Text("It shows and plays what Mirador on your Android phone, the transmitter, sends.").font(.subheadline)
        }
        .foregroundStyle(Hardware.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(LCDGlass())
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Hardware.bezel))
        .accessibilityElement(children: .combine)
    }

    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(0.6)
                .foregroundStyle(Hardware.label.opacity(0.85)).shadow(color: Hardware.engraveShadow, radius: 0, y: 1)
                .accessibilityAddTraits(.isHeader)
            ForEach(lines, id: \.self) { line in
                Text(line).font(.callout).foregroundStyle(Hardware.label).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Plate(radius: 20))
    }
}
