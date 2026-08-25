//
//  SceneNavigationFeedbackOverlay.swift
//  Threshold
//
//  Transient scene information shown after a successful manual switch.
//

import SwiftUI

enum SceneNavigationFeedbackSettings {
    static let defaultsKey = "ContentView.showSceneNavigationFeedback"
    static let defaultValue = true
}

private struct SceneNavigationFeedbackDismissalID: Equatable {
    let feedbackID: UUID?
    let interactionGeneration: UInt64
    let isInteracting: Bool
    let isEnabled: Bool
}

private struct SceneNavigationFeedbackCard: View {
    private enum NavigationButtonFocus: Hashable {
        case previous
        case next
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focusedNavigationButton: NavigationButtonFocus?
    @GestureState private var dragTranslation: CGSize?

    let feedback: SceneNavigationFeedback
    let instruction: String
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onInteractionChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            navigationButton(
                systemImage: "chevron.left",
                accessibilityLabel: "Previous scene",
                focus: .previous,
                action: onPrevious
            )

            VStack(spacing: 2) {
                Text(feedback.sceneName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(instruction)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(cardDragGesture)
            .accessibilityHidden(true)

            navigationButton(
                systemImage: "chevron.right",
                accessibilityLabel: "Next scene",
                focus: .next,
                action: onNext
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: 480)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.orange.opacity(0.42), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 12, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .offset(x: cardDragOffset)
        .animation(
            reduceMotion ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.82),
            value: cardDragOffset
        )
        .onChange(of: isActivelyInteracting) { _, isInteracting in
            onInteractionChanged(isInteracting)
        }
        .onDisappear { onInteractionChanged(false) }
    }

    private var cardDragOffset: CGFloat {
        guard !reduceMotion, let dragTranslation else { return 0 }
        return min(max(dragTranslation.width * 0.22, -28), 28)
    }

    private var isActivelyInteracting: Bool {
        dragTranslation != nil || focusedNavigationButton != nil
    }

    private var cardDragGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                switch SceneSwipeGesturePolicy.sceneStep(
                    for: SIMD2(Float(value.translation.width), Float(value.translation.height))
                ) {
                case -1: onPrevious()
                case 1: onNext()
                default: break
                }
            }
    }

    private func navigationButton(
        systemImage: String,
        accessibilityLabel: String,
        focus: NavigationButtonFocus,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.bold))
                .foregroundStyle(.orange)
                .frame(width: 44, height: 44)
                .background(Color.orange.opacity(0.16), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityFocused($focusedNavigationButton, equals: focus)
    }
}

private struct SceneNavigationFeedbackOverlayModifier: ViewModifier {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AppStorage(SceneNavigationFeedbackSettings.defaultsKey)
    private var isEnabled = SceneNavigationFeedbackSettings.defaultValue

    let isObscured: Bool
    let instruction: String
    let bottomPadding: CGFloat

    @State private var presentedFeedback: SceneNavigationFeedback?
    @State private var interactionGeneration: UInt64 = 0
    @State private var isInteracting = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isEnabled, !isObscured, let feedback = presentedFeedback {
                    SceneNavigationFeedbackCard(
                        feedback: feedback,
                        instruction: instruction,
                        onPrevious: { navigate(forward: false) },
                        onNext: { navigate(forward: true) },
                        onInteractionChanged: { isInteracting = $0 }
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, bottomPadding)
                    .transition(transition(for: feedback))
                    .zIndex(8)
                }
            }
            .onChange(of: appModel.sceneNavigationFeedback) { _, feedback in
                guard isEnabled, let feedback else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.84)) {
                    presentedFeedback = feedback
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                guard !enabled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    presentedFeedback = nil
                }
            }
            .task(id: SceneNavigationFeedbackDismissalID(
                feedbackID: presentedFeedback?.id,
                interactionGeneration: interactionGeneration,
                isInteracting: isInteracting,
                isEnabled: isEnabled
            )) {
                guard isEnabled, !isInteracting, let feedbackID = presentedFeedback?.id else { return }
                do {
                    try await Task.sleep(for: .milliseconds(voiceOverEnabled ? 8_000 : 2_800))
                } catch {
                    return
                }
                guard presentedFeedback?.id == feedbackID else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    presentedFeedback = nil
                }
            }
            .task(id: appModel.sceneNavigationFeedback?.id) {
                guard let feedback = appModel.sceneNavigationFeedback else { return }
                do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
                guard appModel.sceneNavigationFeedback?.id == feedback.id else { return }
                PlatformAccessibilityAdapter.announce("Scene loaded: \(feedback.sceneName)")
            }
    }

    private func transition(for feedback: SceneNavigationFeedback) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let edge: Edge = feedback.direction == .next ? .trailing : .leading
        return .move(edge: edge).combined(with: .opacity)
    }

    private func navigate(forward: Bool) {
        interactionGeneration &+= 1
        appModel.cycleConfiguredSceneGroupOrStaticScene(forward: forward)
    }
}

extension View {
    func sceneNavigationFeedbackOverlay(
        isObscured: Bool,
        instruction: String,
        bottomPadding: CGFloat
    ) -> some View {
        modifier(SceneNavigationFeedbackOverlayModifier(
            isObscured: isObscured,
            instruction: instruction,
            bottomPadding: bottomPadding
        ))
    }
}
