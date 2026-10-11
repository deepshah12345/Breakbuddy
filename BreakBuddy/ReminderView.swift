//
//  ReminderView.swift
//  BreakBuddy
//
//  SwiftUI content of the popup: the character, a speech bubble with the
//  message, and the Done / Snooze buttons. Also holds the view model that
//  drives the pose (idle / blink / wave) and the slide in/out state.
//

import SwiftUI
import AppKit

// MARK: - Layout constants shared with the panel controller

enum ReminderLayout {
    /// Fixed size of the transparent panel. The character and bubble live inside it.
    static let panelSize = CGSize(width: 380, height: 380)
    static let screenMargin: CGFloat = 12
    static let characterSize: CGFloat = 150
    static let bubbleWidth: CGFloat = 260
    static let trailingPadding: CGFloat = 8
}

// MARK: - View model

final class ReminderViewModel: ObservableObject {

    enum Pose { case idle, blink, wave }

    let reminder: Reminder

    /// Drives the slide/bounce in (true) and slide out (false).
    @Published var isPresented = false
    @Published private(set) var pose: Pose = .idle
    /// Size of the bubble + tail, reported by the view; used to compute the clickable area.
    @Published var bubbleSize: CGSize = .zero

    /// Updated by the panel controller's mouse tracking (not observed by the view).
    var isHovering = false

    private let idle: NSImage
    private let blink: NSImage?
    private let wave: NSImage?
    private var blinkTimer: Timer?

    init(reminder: Reminder, characters: CharacterStore) {
        self.reminder = reminder
        self.idle = characters.idleImage()
        self.blink = characters.image(for: .blink)
        self.wave = characters.image(for: .wave)
    }

    deinit { blinkTimer?.invalidate() }

    /// The image for the current pose, falling back to idle when a pose has no image.
    var currentImage: NSImage {
        switch pose {
        case .idle: return idle
        case .blink: return blink ?? idle
        case .wave: return wave ?? idle
        }
    }

    /// The interactive area (bubble) in the panel's top-left-origin coordinates.
    var interactiveRect: CGRect {
        guard bubbleSize != .zero else { return .zero }
        let panel = ReminderLayout.panelSize
        return CGRect(
            x: panel.width - ReminderLayout.trailingPadding - bubbleSize.width,
            y: panel.height - ReminderLayout.characterSize - bubbleSize.height,
            width: bubbleSize.width,
            height: bubbleSize.height
        )
    }

    /// Triggers the entrance animation and starts the idle behaviours.
    func start() {
        isPresented = true
        if wave != nil {
            pose = .wave
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                if self?.pose == .wave { self?.pose = .idle }
            }
        }
        scheduleBlink()
    }

    /// Triggers the exit animation.
    func stop() {
        isPresented = false
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    /// Blink at random intervals by briefly swapping to the blink image.
    private func scheduleBlink() {
        guard blink != nil else { return }
        blinkTimer?.invalidate()
        let delay = Double.random(in: 2.5...5.0)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.pose == .idle { self.pose = .blink }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                if self?.pose == .blink { self?.pose = .idle }
            }
            self.scheduleBlink()
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }
}

// MARK: - Preference key to measure the bubble

private struct BubbleSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - ReminderView

struct ReminderView: View {
    @ObservedObject var model: ReminderViewModel
    let onDone: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Fully transparent backdrop the size of the panel.
            Color.clear

            VStack(alignment: .trailing, spacing: 0) {
                bubbleBlock
                character
            }
            .padding(.trailing, ReminderLayout.trailingPadding)
            // Slide in from the right edge with a springy bounce; slide out smoothly.
            .offset(x: model.isPresented ? 0 : ReminderLayout.panelSize.width + 40)
            .animation(
                model.isPresented
                    ? Animation.spring(response: 0.7, dampingFraction: 0.5)
                    : Animation.easeIn(duration: 0.45),
                value: model.isPresented
            )
        }
        .frame(width: ReminderLayout.panelSize.width, height: ReminderLayout.panelSize.height)
        .onPreferenceChange(BubbleSizeKey.self) { size in
            // Deferred so we never publish a change in the middle of a view update.
            DispatchQueue.main.async { model.bubbleSize = size }
        }
    }

    // MARK: Speech bubble

    private var bubbleBlock: some View {
        VStack(alignment: .trailing, spacing: -1) {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.reminder.message)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.black)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Done", action: onDone)
                        .buttonStyle(CartoonButtonStyle(fill: Color(red: 0.30, green: 0.69, blue: 0.40),
                                                        text: .white))
                    Button("Snooze \(AppSettings.snoozeMinutes) min", action: onSnooze)
                        .buttonStyle(CartoonButtonStyle(fill: Color(white: 0.88), text: .black))
                }
            }
            .padding(14)
            .frame(width: ReminderLayout.bubbleWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.12), lineWidth: 1)
            )

            BubbleTail()
                .fill(Color.white)
                .frame(width: 26, height: 14)
                .padding(.trailing, 56)
        }
        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
        // Measure the layout size (not affected by the scale animation below).
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: BubbleSizeKey.self, value: proxy.size)
            }
        )
        .scaleEffect(model.isPresented ? 1 : 0.4, anchor: .bottomTrailing)
        .opacity(model.isPresented ? 1 : 0)
        .animation(
            model.isPresented
                ? Animation.spring(response: 0.45, dampingFraction: 0.6).delay(0.25)
                : Animation.easeIn(duration: 0.2),
            value: model.isPresented
        )
    }

    // MARK: Character

    private var character: some View {
        // TimelineView redraws every frame, giving a gentle floating/bobbing motion.
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Image(nsImage: model.currentImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: ReminderLayout.characterSize, height: ReminderLayout.characterSize)
                .offset(y: CGFloat(sin(t * 2.2)) * 5)
                .rotationEffect(.degrees(sin(t * 1.1) * 2.5), anchor: .bottom)
        }
        .frame(width: ReminderLayout.characterSize, height: ReminderLayout.characterSize)
        .accessibilityHidden(true)
    }
}

// MARK: - Bubble tail shape

/// Small downward-pointing triangle that connects the bubble to the character.
private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX * 0.85, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Button style

/// Chunky pill button matching the cartoon look.
private struct CartoonButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundColor(text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.7 : 1)))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}
