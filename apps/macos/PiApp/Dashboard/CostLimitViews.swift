import SwiftUI

// The cost limit on screen: a chat's spend against its limit, the editor for
// the chat's own limit (in its usage popover, Session info and the stop
// notice's Raise limit… popover), and the Settings default.

enum CostLimitText {
    /// What a limit does, under every editor.
    static let explanation = "A chat stops before its next model request once the spend the gateway reported for it reaches the limit; a request already running always finishes. Title and name suggestions run as separate small tasks and don't count toward a chat's spend."
    /// A preset's chip: "$5", "$25".
    static func preset(_ amount: Double) -> String { amount.rounded() == amount ? "$\(Int(amount))" : CostLimit.dollars(amount) }
}

/// "$4.12 of $25.00", the share of the limit and a thin meter, in warning ink
/// from 80% of the limit on. Requests that reported no cost are named: their
/// spend cannot be counted.
struct CostLimitMeter: View {
    let reading: SessionCostReading
    var body: some View {
        let warning = reading.warning
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: PiSpacing.sm) {
                Text(headline).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(warning ? Color.piWarning : Color.piInk)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityIdentifier("cost-limit-figure")
                Spacer(minLength: PiSpacing.sm)
                if let fraction = reading.fraction {
                    Text(Self.percent(fraction))
                        .font(PiFont.caption.weight(.medium)).monospacedDigit()
                        .foregroundStyle(warning ? Color.piWarning : Color.piInkSecondary)
                }
            }
            if let fraction = reading.fraction {
                CostLimitBar(fraction: fraction, warning: warning)
            }
            if let note = reading.unreportedNote {
                Label(note + "; their cost can't be counted.", systemImage: "exclamationmark.circle")
                    .font(PiFont.micro).foregroundStyle(Color.piWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cost-limit-unreported")
            }
        }
        .accessibilityElement(children: .combine)
    }
    /// The share of the limit spent, past 100% too: a limit lowered below the spend reads as over it.
    nonisolated static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        return value > 0 && value < 1 ? "<1%" : "\(Int(value.rounded()))%"
    }
    private var headline: String {
        if let figure = reading.figure { return figure }
        return reading.limit.usd == nil ? "No limit" : "Limit " + reading.limit.label
    }
}

/// The spend's share of the limit: a track, and the part used.
private struct CostLimitBar: View {
    let fraction: Double
    let warning: Bool
    var body: some View {
        Canvas { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2, style: .continuous)
            context.fill(track, with: .color(Color.piFillStrong))
            let used = max(0, min(1, fraction)) * size.width
            guard used > 0 else { return }
            context.clip(to: track)
            context.fill(Path(CGRect(x: 0, y: 0, width: max(size.height, used), height: size.height)),
                         with: .color(warning ? Color.piWarning : Color.piBrandOrange))
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// One choice among the limits: a capsule that reads as selected with the
/// accent wash and a check.
private struct CostLimitChipStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            configuration.label
        }
        .font(.system(size: 12, weight: .medium)).monospacedDigit()
        .foregroundStyle(selected ? Color.piAccent : Color.piInk)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(selected ? Color.piAccentSoft : hovering ? Color.piFill : Color.piSurface, in: Capsule())
        .overlay(Capsule().stroke(selected ? Color.piAccent.opacity(0.55) : Color.piHairlineStrong, lineWidth: 1))
        .opacity(configuration.isPressed ? 0.75 : 1)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .piAnimation(PiMotion.quick, value: hovering)
        .piPointer()
    }
}

/// The limits to choose from — the default (in a chat's editor), No limit,
/// the presets and a custom amount — as one row of chips that wraps.
struct CostLimitChoices: View {
    /// The choice shown as selected; nil is the default.
    let selection: CostLimit?
    /// Offer "Default ($25.00)" first: a chat's editor does, Settings does not.
    var defaultLimit: CostLimit? = nil
    let choose: (CostLimit?) -> Void
    var identifier = "cost-limit"
    @State private var customOpen = false
    @State private var custom = ""
    @State private var invalid = false

    private var customSelected: Bool {
        guard let amount = selection?.usd else { return false }
        return !CostLimit.presets.contains(amount)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            PiFlow(spacing: 6, rowSpacing: 6) {
                if let defaultLimit {
                    Button("Default (\(defaultLimit.label))") { customOpen = false; choose(nil) }
                        .buttonStyle(CostLimitChipStyle(selected: selection == nil))
                        .accessibilityIdentifier(identifier + "-default")
                }
                Button("No limit") { customOpen = false; choose(.unlimited) }
                    .buttonStyle(CostLimitChipStyle(selected: selection == .unlimited))
                    .accessibilityIdentifier(identifier + "-none")
                ForEach(CostLimit.presets, id: \.self) { amount in
                    Button(CostLimitText.preset(amount)) { customOpen = false; choose(.usd(amount)) }
                        .buttonStyle(CostLimitChipStyle(selected: selection == .usd(amount)))
                        .accessibilityIdentifier(identifier + "-\(Int(amount))")
                }
                Button(customSelected ? "Custom · " + (selection?.label ?? "") : "Custom…") {
                    customOpen.toggle()
                    if customOpen, custom.isEmpty, let amount = selection?.usd { custom = String(format: amount >= 0.01 ? "%.2f" : "%g", amount) }
                }
                .buttonStyle(CostLimitChipStyle(selected: customSelected || customOpen))
                .accessibilityIdentifier(identifier + "-custom")
            }
            if customOpen {
                HStack(spacing: PiSpacing.sm) {
                    PiTextField(placeholder: "Amount in US dollars", text: $custom, icon: "dollarsign", onSubmit: applyCustom)
                        .frame(maxWidth: 200)
                        .accessibilityIdentifier(identifier + "-custom-amount")
                    Button("Set Limit", action: applyCustom).buttonStyle(.piSecondaryCompact)
                        .disabled(CostLimit.parse(custom) == nil)
                        .accessibilityIdentifier(identifier + "-custom-set")
                    Spacer(minLength: 0)
                }
                if invalid {
                    Text("Enter an amount above $0, up to $1,000,000.").font(PiFont.micro).foregroundStyle(Color.piDanger)
                }
            }
        }
        .onChange(of: custom) { _, _ in invalid = false }
    }
    private func applyCustom() {
        guard let limit = CostLimit.parse(custom) else { invalid = true; return }
        invalid = false; customOpen = false; choose(limit)
    }
}

/// A chat's own limit: where it stands, the choices, and what a limit does.
/// Choosing saves at once; the chat's next model request is checked against it.
struct CostLimitEditor: View {
    let reading: SessionCostReading
    var title = "Cost limit"
    /// Saves a choice; nil follows the Settings default.
    let choose: @MainActor (CostLimit?) async throws -> Void
    @State private var failure: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: PiSpacing.md) {
            HStack(alignment: .center, spacing: PiSpacing.sm) {
                Image(systemName: "dollarsign.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.piInkTertiary)
                Text(title).font(PiFont.caption.weight(.semibold)).foregroundStyle(Color.piInk)
                Spacer(minLength: PiSpacing.sm)
                if saving { ProgressView().controlSize(.mini) }
                PiBadge(text: reading.source, tone: reading.override == nil ? .neutral : .accent)
                    .accessibilityIdentifier("cost-limit-source")
            }
            CostLimitMeter(reading: reading)
            CostLimitChoices(selection: reading.override, defaultLimit: reading.defaultLimit, choose: { limit in
                failure = nil; saving = true
                Task { @MainActor in
                    defer { saving = false }
                    do { try await choose(limit) } catch { failure = error.localizedDescription }
                }
            })
            if let failure { Text(failure).font(PiFont.micro).foregroundStyle(Color.piDanger).fixedSize(horizontal: false, vertical: true) }
            Text(CostLimitText.explanation).font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cost-limit-editor")
    }
}

/// The editor over a chat's live reading: its figures move as requests settle.
struct CostLimitLiveEditor: View {
    @ObservedObject var footer: SessionMetrics
    var title = "Cost limit"
    let choose: @MainActor (CostLimit?) async throws -> Void
    var body: some View { CostLimitEditor(reading: footer.cost, title: title, choose: choose) }
}
