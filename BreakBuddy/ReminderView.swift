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

    /// Panel frame (screen coordinates, bottom-left origin) for a corner of `visibleFrame`.
    static func panelFrame(in visibleFrame: CGRect, position: ReminderPosition) -> CGRect {
        let size = panelSize
        let x: CGFloat
        switch position.column {
        case .left: x = visibleFrame.minX + screenMargin
        case .center: x = visibleFrame.midX - size.width / 2
        case .right: x = visibleFrame.maxX - size.width - screenMargin
        }
        let y: CGFloat
        switch position.row {
        case .top: y = visibleFrame.maxY - size.height - screenMargin
        case .middle: y = visibleFrame.midY - size.height / 2
        case .bottom: y = visibleFrame.minY + screenMargin
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Bubble rect in the panel's top-left-origin coordinates. The bubble sits
    /// above the character on the bottom and middle rows and below it on the top row.
    static func bubbleRect(size: CGSize, position: ReminderPosition) -> CGRect {
        let x: CGFloat
        switch position.column {
        case .left: x = trailingPadding
        case .center: x = (panelSize.width - size.width) / 2
        case .right: x = panelSize.width - trailingPadding - size.width
        }
        let y: CGFloat
        switch position.row {
        case .top: y = characterSize
        case .middle: y = (panelSize.height - characterSize - size.height) / 2
        case .bottom: y = panelSize.height - characterSize - size.height
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

// MARK: - View model

final class ReminderViewModel: ObservableObject {

    enum Pose { case idle, blink, wave }

    let reminder: Reminder

    /// Drives the slide/bounce in (true) and slide out (false).
    @Published var isPresented = false
    @Published private(set) var pose: Pose = .idle
    /// Size of the bubble + tail, measured once up front by the panel controller (not via
    /// SwiftUI preferences, which weren't reliably delivered while the view slides in).
    var bubbleSize: CGSize = .zero

    /// Updated by the panel controller's mouse tracking (not observed by the view).
    var isHovering = false

    private let idle: NSImage
    private let blink: NSImage?
    private let wave: NSImage?
    private var blinkTimer: Timer?

    let themeColor: Color
    let position: ReminderPosition

    init(reminder: Reminder, characters: CharacterStore, themeColor: Color, position: ReminderPosition = .bottomRight) {
        self.reminder = reminder
        self.themeColor = themeColor
        self.position = position
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
        return ReminderLayout.bubbleRect(size: bubbleSize, position: position)
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

// MARK: - ReminderView

struct ReminderView: View {
    @ObservedObject var model: ReminderViewModel
    let onDone: () -> Void
    let onSnooze: () -> Void

    private var position: ReminderPosition { model.position }
    private var horizontal: HorizontalAlignment {
        switch position.column {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private var vertical: VerticalAlignment {
        switch position.row {
        case .top: return .top
        case .middle: return .center
        case .bottom: return .bottom
        }
    }

    private var panelAlignment: Alignment { Alignment(horizontal: horizontal, vertical: vertical) }

    /// Off-screen offset for the slide-in: from the nearest side edge, or from the
    /// top/bottom edge for the centered columns.
    private var hiddenOffset: CGSize {
        let distance = ReminderLayout.panelSize.width + 40
        switch position.column {
        case .left: return CGSize(width: -distance, height: 0)
        case .right: return CGSize(width: distance, height: 0)
        case .center: return CGSize(width: 0, height: position.row == .top ? -distance : distance)
        }
    }

    private var edgePadding: Edge.Set {
        switch position.column {
        case .left: return .leading
        case .right: return .trailing
        case .center: return []
        }
    }

    var body: some View {
        ZStack(alignment: panelAlignment) {
            // Fully transparent backdrop the size of the panel.
            Color.clear

            VStack(alignment: horizontal, spacing: 0) {
                // Bubble above the character in bottom corners, below it in top corners.
                if position.row == .top {
                    character
                    bubbleBlock
                } else {
                    bubbleBlock
                    character
                }
            }
            .padding(edgePadding, ReminderLayout.trailingPadding)
            // Slide in from the nearest screen edge with a springy bounce; slide out smoothly.
            .offset(model.isPresented ? .zero : hiddenOffset)
            .animation(
                model.isPresented
                    ? Animation.spring(response: 0.7, dampingFraction: 0.5)
                    : Animation.easeIn(duration: 0.45),
                value: model.isPresented
            )
        }
        .frame(width: ReminderLayout.panelSize.width, height: ReminderLayout.panelSize.height)
    }

    /// The bubble alone, used to measure its size up front (see `ReminderViewModel.bubbleSize`).
    var bubbleForMeasuring: some View { bubbleBlock }

    // MARK: Speech bubble

    private var bubbleBlock: some View {
        VStack(alignment: horizontal, spacing: -1) {
            if position.row == .top { bubbleTail }

            VStack(alignment: .leading, spacing: 10) {
                Text(model.reminder.message)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.black)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Done", action: onDone)
                        .buttonStyle(CartoonButtonStyle(fill: model.themeColor, text: .white))
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

            if position.row != .top { bubbleTail }
        }
        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
        .scaleEffect(model.isPresented ? 1 : 0.4, anchor: scaleAnchor)
        .opacity(model.isPresented ? 1 : 0)
        .animation(
            model.isPresented
                ? Animation.spring(response: 0.45, dampingFraction: 0.6).delay(0.25)
                : Animation.easeIn(duration: 0.2),
            value: model.isPresented
        )
    }

    /// Tail pointing at the character: down in bottom corners, up in top corners,
    /// mirrored so it sits on the side nearest the screen edge.
    private var bubbleTail: some View {
        BubbleTail()
            .fill(Color.white)
            .frame(width: 26, height: 14)
            .scaleEffect(x: position.column == .left ? -1 : 1, y: position.row == .top ? -1 : 1)
            .padding(edgePadding, 56)
    }

    /// The bubble grows out of the corner nearest the character.
    private var scaleAnchor: UnitPoint {
        let x: CGFloat
        switch position.column {
        case .left: x = 0
        case .center: x = 0.5
        case .right: x = 1
        }
        return UnitPoint(x: x, y: position.row == .top ? 0 : 1)
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
