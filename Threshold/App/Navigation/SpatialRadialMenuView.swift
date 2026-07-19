#if os(visionOS)
  import Observation
  import RealityKit
  import Spatial
  import SwiftUI

  @MainActor
  @Observable
  final class SpatialRadialMenuModel {
    static let windowID = "SpatialRadialMenu"

    private(set) var navigation = SpatialRadialNavigationState()
    private(set) var hierarchy = NavigationHierarchy.application(
      availability: .current(
        allowsCustomScenes: AppModel.allowCustomScenes,
        includesGestureEditing: true
      )
    )
    private(set) var isPresented = false
    private(set) var pendingActivationID: String?
    private(set) var mathLens: SpatialMathLensSnapshot?
    private(set) var gestureMap: SpatialGestureMapSnapshot?
    private(set) var presentationMode: SpatialRadialPresentationMode = .navigation
    private(set) var statusMessage: String?
    private(set) var mathLensPageIndex = 0
    private(set) var presentationRequestID = UUID()
    var rotation: Float = 0

    var isShowingQuickControls: Bool { presentationMode == .quickControls }
    var isShowingGestureMap: Bool { presentationMode == .gestureMap }

    @ObservationIgnored private var activationHandler: ((String) -> Void)?
    @ObservationIgnored private var activationOwner: UUID?
    @ObservationIgnored private var revealControlsHandler: (() -> Void)?
    @ObservationIgnored private var dismissHandler: (() -> Void)?

    var visibleNodes: [NavigationHierarchy.Node] {
      isShowingQuickControls || isShowingGestureMap
        ? []
        : navigation.visibleNodes(in: hierarchy)
    }

    var currentTitle: String {
      if isShowingQuickControls { return "Quick Toggles" }
      if isShowingGestureMap { return "Gesture Map" }
      return navigation.currentBranch(in: hierarchy)?.title ?? "Spatial Controls"
    }

    var contextualNode: NavigationHierarchy.Node? {
      if isShowingQuickControls { return hierarchy.node(withID: "utility.quickToggles") }
      if isShowingGestureMap { return hierarchy.node(withID: "utility.gestures") }
      return navigation.currentBranch(in: hierarchy)
        ?? navigation.highlightedNodeID.flatMap { hierarchy.node(withID: $0) }
    }

    var canGoBack: Bool {
      isShowingQuickControls || isShowingGestureMap || navigation.canGoBack
    }

    var currentMathLensPage: SpatialMathLensSnapshot.Page? {
      guard let pages = mathLens?.pages, !pages.isEmpty else { return nil }
      return pages[mathLensPageIndex % pages.count]
    }

    var guidance: String {
      if isShowingQuickControls {
        return "Pinch a tile to toggle · rotate the ring · center to go back"
      }
      if isShowingGestureMap {
        return "Pinch a shortcut to follow it · rotate the map · center to go back"
      }
      if navigation.canGoBack {
        return "Pinch a section · rotate the ring · center to go back"
      }
      return "Pinch a section · rotate with both hands · center to close"
    }

    func configureHierarchy() {
      hierarchy = NavigationHierarchy.application(
        availability: .current(
          allowsCustomScenes: AppModel.allowCustomScenes,
          includesGestureEditing: true
        )
      )
    }

    func prepare(
      focusing nodeID: String?,
      mathLens: SpatialMathLensSnapshot? = nil,
      gestureMap: SpatialGestureMapSnapshot? = nil
    ) -> UUID {
      configureHierarchy()
      presentationRequestID = UUID()
      if nodeID == "utility.quickToggles" {
        presentationMode = .quickControls
      } else if nodeID == "utility.gestures", gestureMap != nil {
        presentationMode = .gestureMap
      } else {
        presentationMode = .navigation
      }
      if isShowingQuickControls || isShowingGestureMap {
        navigation.reset()
      } else {
        navigation.focus(nodeID: nodeID, in: hierarchy)
      }
      self.mathLens = mathLens
      self.gestureMap = gestureMap
      mathLensPageIndex = 0
      statusMessage = nil
      rotation = 0
      return presentationRequestID
    }

    func select(_ node: NavigationHierarchy.Node) {
      if node.id == "utility.quickToggles" {
        navigation.reset()
        presentationMode = .quickControls
        statusMessage = nil
        rotation = 0
        return
      }
      if node.id == "utility.gestures", gestureMap != nil {
        navigation.reset()
        presentationMode = .gestureMap
        statusMessage = nil
        rotation = 0
        return
      }
      switch navigation.select(nodeID: node.id, in: hierarchy) {
      case .navigated:
        rotation = 0
      case .activate(let nodeID):
        pendingActivationID = nodeID
        revealControlsHandler?()
        deliverPendingActivationIfPossible()
        dismiss()
      case .ignored:
        break
      }
    }

    func goBackOrDismiss() {
      if isShowingQuickControls {
        presentationMode = .navigation
        navigation.reset()
        statusMessage = nil
        rotation = 0
        return
      }
      if isShowingGestureMap {
        presentationMode = .navigation
        navigation.reset()
        statusMessage = nil
        rotation = 0
        return
      }
      if navigation.canGoBack {
        navigation.goBack()
        rotation = 0
      } else {
        dismiss()
      }
    }

    func setRotation(_ newValue: Float) {
      guard newValue.isFinite, abs(newValue - rotation) > 0.0005 else { return }
      rotation = newValue.remainder(dividingBy: 2 * .pi)
    }

    func reportQuickControlChange(title: String, isEnabled: Bool) {
      statusMessage = "\(title) turned \(isEnabled ? "on" : "off")"
    }

    func followGestureShortcut(_ action: PerFingerTapAction) -> Bool {
      presentationMode = .navigation
      statusMessage = nil
      rotation = 0
      switch action {
      case .openShapeMenu:
        navigation.focus(
          nodeID: NavigationHierarchy.rootID(for: .shape),
          in: hierarchy
        )
        return true
      case .openRenderMenu:
        navigation.focus(
          nodeID: NavigationHierarchy.rootID(for: .performance),
          in: hierarchy
        )
        return true
      case .openQuickToggles:
        navigation.reset()
        presentationMode = .quickControls
        return true
      case .none, .toggleMenu, .toggleAnimationPlayer:
        presentationMode = .gestureMap
        return false
      }
    }

    func reportStatus(_ message: String) {
      statusMessage = message
    }

    func advanceMathLens() {
      guard let count = mathLens?.pages.count, count > 1 else { return }
      mathLensPageIndex = (mathLensPageIndex + 1) % count
    }

    func installActivationHandler(owner: UUID, _ handler: @escaping (String) -> Void) {
      activationOwner = owner
      activationHandler = handler
      deliverPendingActivationIfPossible()
    }

    func removeActivationHandler(owner: UUID) {
      guard activationOwner == owner else { return }
      activationOwner = nil
      activationHandler = nil
    }

    func installWindowHandlers(reveal: @escaping () -> Void, dismiss: @escaping () -> Void) {
      revealControlsHandler = reveal
      dismissHandler = dismiss
    }

    func markPresented(_ presented: Bool) {
      isPresented = presented
      if !presented {
        navigation.reset()
        mathLens = nil
        gestureMap = nil
        presentationMode = .navigation
        statusMessage = nil
        mathLensPageIndex = 0
      }
    }

    func dismiss() {
      dismissHandler?()
    }

    private func deliverPendingActivationIfPossible() {
      guard let pendingActivationID, let activationHandler else { return }
      self.pendingActivationID = nil
      activationHandler(pendingActivationID)
    }
  }

  struct SpatialRadialMenuView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SpatialRadialMenuModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var rootEntity = Entity()
    @State private var rotationGestureStart: Float?
    @State private var quickControlRevision = 0

    private enum SpatialQuickControl: String, CaseIterable, Identifiable {
      case boundingShape
      case surroundings
      case shadows
      case smartAdvance
      case audioReactive

      var id: String { rawValue }

      var title: String {
        switch self {
        case .boundingShape: return "Bounding Shape"
        case .surroundings: return "Surroundings"
        case .shadows: return "Self-Shadows"
        case .smartAdvance: return "Smart Advance"
        case .audioReactive: return "Audio Reactive"
        }
      }

      var icon: String {
        switch self {
        case .boundingShape: return "circle.dashed"
        case .surroundings: return "square.3.layers.3d"
        case .shadows: return "moon"
        case .smartAdvance: return "bolt"
        case .audioReactive: return "waveform"
        }
      }

      func isEnabled(in settings: RenderSettings) -> Bool {
        switch self {
        case .boundingShape: return settings.boundingSphereSkipEnabled
        case .surroundings: return settings.envScrunchEnabled
        case .shadows: return settings.shadowsEnabled
        case .smartAdvance: return settings.smartAdvanceEnabled
        case .audioReactive: return settings.fractalAudioReactiveEnabled
        }
      }

      func toggle(in settings: RenderSettings) {
        switch self {
        case .boundingShape:
          settings.boundingSphereSkipEnabled.toggle()
        case .surroundings:
          settings.envScrunchEnabled.toggle()
          if settings.envScrunchEnabled && settings.envScrunchContain == 0 {
            settings.envScrunchContain = 2
          }
        case .shadows:
          settings.shadowsEnabled.toggle()
        case .smartAdvance:
          settings.smartAdvanceEnabled.toggle()
        case .audioReactive:
          settings.fractalAudioReactiveEnabled.toggle()
        }
      }
    }

    private enum AttachmentID {
      static let header = "spatial-radial.header"
      static let hub = "spatial-radial.hub"
      static let mathLens = "spatial-radial.math-lens"
      static func node(_ id: String) -> String { "spatial-radial.node.\(id)" }
      static func quickControl(_ id: String) -> String { "spatial-radial.quick.\(id)" }
      static func gestureShortcut(_ id: String) -> String { "spatial-radial.gesture.\(id)" }
    }

    var body: some View {
      RealityView { content, attachments in
        rootEntity.name = "SpatialRadialMenuRoot"
        content.add(rootEntity)
        synchronizeEntities(attachments)
      } update: { _, attachments in
        synchronizeEntities(attachments)
      } attachments: {
        Attachment(id: AttachmentID.header) {
          header
        }
        Attachment(id: AttachmentID.hub) {
          hub
        }
        if let snapshot = model.mathLens {
          Attachment(id: AttachmentID.mathLens) {
            spatialMathLens(snapshot)
          }
        }
        ForEach(model.visibleNodes) { node in
          Attachment(id: AttachmentID.node(node.id)) {
            nodeButton(node)
          }
        }
        if model.isShowingQuickControls {
          ForEach(SpatialQuickControl.allCases) { control in
            Attachment(id: AttachmentID.quickControl(control.id)) {
              quickControlButton(control)
            }
          }
        }
        if model.isShowingGestureMap, let gestureMap = model.gestureMap {
          ForEach(gestureMap.shortcuts) { shortcut in
            Attachment(id: AttachmentID.gestureShortcut(shortcut.id)) {
              gestureShortcutButton(shortcut, mapIsEnabled: gestureMap.isEnabled)
            }
          }
        }
      }
      .simultaneousGesture(rotationGesture)
      .onAppear {
        model.markPresented(true)
        appModel.setSpatialMenuVisible(true)
      }
      .onDisappear {
        rotationGestureStart = nil
        model.markPresented(false)
        appModel.setSpatialMenuVisible(false)
      }
      .accessibilityLabel("Spatial radial controls")
    }

    private var rotationGesture: some Gesture {
      RotateGesture3D(constrainedToAxis: .z, minimumAngleDelta: .degrees(0.5))
        .onChanged { value in
          let axisSign: Double = value.rotation.axis.z < 0 ? -1 : 1
          let delta = Float(value.rotation.angle.radians * axisSign)
          if rotationGestureStart == nil {
            rotationGestureStart = model.rotation
          }
          model.setRotation((rotationGestureStart ?? 0) + delta)
        }
        .onEnded { _ in
          rotationGestureStart = nil
        }
    }

    private var header: some View {
      VStack(spacing: 3) {
        Text("SPATIAL RADIAL · DEPTH \(model.navigation.depth)")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.cyan)
        Text(model.currentTitle)
          .font(.headline)
        Text(model.guidance)
          .font(.caption2)
          .foregroundStyle(.secondary)
        if model.isShowingGestureMap, let gestureMap = model.gestureMap {
          Label(
            gestureMap.menuGestureIsEnabled
              ? "OPEN MENU · \(gestureMap.menuGestureName)"
              : "MENU GESTURE · OFF",
            systemImage: gestureMap.menuGestureIcon
          )
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(gestureMap.menuGestureIsEnabled ? .cyan : .orange)
          if !gestureMap.isEnabled {
            Text("Per-finger shortcuts are disabled")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.orange)
          } else if gestureMap.shortcuts.isEmpty {
            Text("No per-finger shortcuts are assigned")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.secondary)
          }
        }
        if let statusMessage = model.statusMessage {
          Label(statusMessage, systemImage: "checkmark.circle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
            .transition(.opacity)
        }
      }
      .multilineTextAlignment(.center)
      .padding(.horizontal, 18)
      .padding(.vertical, 10)
      .glassBackgroundEffect(in: .rect(cornerRadius: 18))
      .accessibilityElement(children: .combine)
    }

    private var hub: some View {
      Button {
        withAnimation(accessibilityReduceMotion ? nil : .snappy(duration: 0.2)) {
          model.goBackOrDismiss()
        }
      } label: {
        VStack(spacing: 4) {
          Image(systemName: model.canGoBack ? "arrow.uturn.backward" : "xmark")
            .font(.title2.weight(.bold))
          Text(model.canGoBack ? "Back" : "Close")
            .font(.caption2.weight(.semibold))
        }
        .frame(width: 72, height: 72)
        .background(Color.black.opacity(0.30), in: Circle())
        .overlay(Circle().strokeBorder(Color.cyan.opacity(0.55), lineWidth: 1.5))
      }
      .buttonStyle(.plain)
      .hoverEffect(.lift)
      .accessibilityHint(
        model.canGoBack ? "Returns to the previous radial ring" : "Closes spatial controls")
    }

    private func nodeButton(_ node: NavigationHierarchy.Node) -> some View {
      let highlighted = model.navigation.highlightedNodeID == node.id
      let actionLabel: String
      switch node.id {
      case "utility.quickToggles": actionLabel = "Open toggles"
      case "utility.gestures": actionLabel = "Open map"
      default: actionLabel = node.isBranch ? "Open ring" : "Open controls"
      }
      return Button {
        withAnimation(accessibilityReduceMotion ? nil : .snappy(duration: 0.22)) {
          model.select(node)
        }
      } label: {
        VStack(spacing: 5) {
          Image(systemName: node.systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(highlighted ? .orange : node.isBranch ? .cyan : .primary)
          Text(node.title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
          Text(actionLabel)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .frame(width: 118, height: 68)
        .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
          RoundedRectangle(cornerRadius: 16)
            .strokeBorder(
              highlighted
                ? Color.orange
                : node.isBranch ? Color.cyan.opacity(0.55) : Color.white.opacity(0.16),
              lineWidth: highlighted ? 2 : 1
            )
        )
      }
      .buttonStyle(.plain)
      .hoverEffect(.lift)
      .accessibilityLabel("\(node.title), \(actionLabel.lowercased())")
    }

    private func quickControlButton(_ control: SpatialQuickControl) -> some View {
      _ = quickControlRevision
      let isEnabled = control.isEnabled(in: appModel.renderSettings)
      return Button {
        control.toggle(in: appModel.renderSettings)
        quickControlRevision &+= 1
        model.reportQuickControlChange(
          title: control.title,
          isEnabled: control.isEnabled(in: appModel.renderSettings)
        )
        NotificationCenter.default.post(
          name: AppModel.fractalSettingsDidChangeNotification,
          object: nil
        )
      } label: {
        VStack(spacing: 5) {
          Image(systemName: control.icon)
            .font(.title3.weight(.semibold))
          Text(control.title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
          Text(isEnabled ? "On" : "Off")
            .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(isEnabled ? Color.white : Color.secondary)
        .frame(width: 118, height: 68)
        .background(
          isEnabled ? Color.cyan.opacity(0.55) : Color.black.opacity(0.34),
          in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 16)
            .strokeBorder(
              isEnabled ? Color.white.opacity(0.7) : Color.white.opacity(0.16), lineWidth: 1.25)
        )
      }
      .buttonStyle(.plain)
      .hoverEffect(.lift)
      .accessibilityLabel("\(control.title), \(isEnabled ? "on" : "off")")
      .accessibilityValue(isEnabled ? "On" : "Off")
      .accessibilityHint("Toggles the setting directly in the immersive scene")
    }

    private func gestureShortcutButton(
      _ shortcut: SpatialGestureShortcut,
      mapIsEnabled: Bool
    ) -> some View {
      Button {
        if model.followGestureShortcut(shortcut.action) { return }
        switch shortcut.action {
        case .toggleMenu:
          model.dismiss()
        case .toggleAnimationPlayer:
          appModel.toggleAnimationPlayback()
          model.reportStatus("Animation playback toggled")
        case .none, .openShapeMenu, .openRenderMenu, .openQuickToggles:
          break
        }
      } label: {
        VStack(spacing: 4) {
          HStack(spacing: 5) {
            Image(systemName: shortcut.fingerIcon)
            Text("\(shortcut.hand.rawValue) · \(shortcut.fingerName)")
          }
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.cyan)
          Image(systemName: shortcut.action.icon)
            .font(.title3.weight(.semibold))
          Text(shortcut.action.displayName)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .frame(width: 128, height: 72)
        .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
          RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Color.cyan.opacity(0.55), lineWidth: 1.25)
        )
      }
      .buttonStyle(.plain)
      .hoverEffect(.lift)
      .disabled(!mapIsEnabled)
      .opacity(mapIsEnabled ? 1 : 0.45)
      .accessibilityLabel(
        "\(shortcut.hand.rawValue) \(shortcut.fingerName), \(shortcut.action.displayName)"
      )
      .accessibilityHint("Follows the same destination as this hand shortcut")
    }

    private func spatialMathLens(_ snapshot: SpatialMathLensSnapshot) -> some View {
      let page = model.currentMathLensPage ?? snapshot.pages[0]
      return Button {
        withAnimation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.18)) {
          model.advanceMathLens()
        }
      } label: {
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(
              "MATH LENS · \(model.mathLensPageIndex + 1)/\(snapshot.pages.count)",
              systemImage: "function"
            )
            .font(.caption2.weight(.bold))
            .foregroundStyle(.cyan)
            Text(page.field.uppercased())
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(snapshot.pages.count > 1 ? "PINCH NEXT" : "LIVE FORMULA")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(.orange)
          }
          Text(page.title)
            .font(.caption.weight(.bold))
          Text(snapshot.constructionRoute)
            .font(.system(.caption2, design: .monospaced, weight: .semibold))
            .foregroundStyle(.cyan)
            .lineLimit(1)
          Text(page.formal)
            .font(.system(size: 10, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          Text(page.notice)
            .font(.system(size: 9))
            .foregroundStyle(.primary.opacity(0.84))
            .lineLimit(2)
          Text(snapshot.crossReference(for: model.contextualNode))
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .frame(width: 350, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassBackgroundEffect(in: .rect(cornerRadius: 16))
      }
      .buttonStyle(.plain)
      .hoverEffect(.highlight)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        "Math Lens concept \(model.mathLensPageIndex + 1) of \(snapshot.pages.count). "
          + "\(page.title). \(page.formal). \(page.notice). \(snapshot.constructionRoute). "
          + snapshot.crossReference(for: model.contextualNode)
      )
      .accessibilityHint(
        snapshot.pages.count > 1
          ? "Shows the next concept in construction order" : "Shows the live formula")
    }

    private func synchronizeEntities(_ attachments: RealityViewAttachments) {
      let nodes = model.visibleNodes
      let quickControls = model.isShowingQuickControls ? SpatialQuickControl.allCases : []
      let gestureShortcuts =
        model.isShowingGestureMap
        ? model.gestureMap?.shortcuts ?? []
        : []
      let itemCount: Int
      if model.isShowingQuickControls {
        itemCount = quickControls.count
      } else if model.isShowingGestureMap {
        itemCount = gestureShortcuts.count
      } else {
        itemCount = nodes.count
      }
      let placements = SpatialRadialGeometry.placements(
        count: itemCount,
        depth: model.navigation.depth,
        rotation: model.rotation
      )
      var liveNames = Set<String>()

      for (node, placement) in zip(nodes, placements) {
        let name = AttachmentID.node(node.id)
        liveNames.insert(name)
        guard let entity = attachments.entity(for: name) else { continue }
        entity.name = name
        setPositionIfNeeded(placement.position, on: entity)
        if entity.parent !== rootEntity { rootEntity.addChild(entity) }
      }

      for (control, placement) in zip(quickControls, placements) {
        let name = AttachmentID.quickControl(control.id)
        liveNames.insert(name)
        guard let entity = attachments.entity(for: name) else { continue }
        entity.name = name
        setPositionIfNeeded(placement.position, on: entity)
        if entity.parent !== rootEntity { rootEntity.addChild(entity) }
      }

      for (shortcut, placement) in zip(gestureShortcuts, placements) {
        let name = AttachmentID.gestureShortcut(shortcut.id)
        liveNames.insert(name)
        guard let entity = attachments.entity(for: name) else { continue }
        entity.name = name
        setPositionIfNeeded(placement.position, on: entity)
        if entity.parent !== rootEntity { rootEntity.addChild(entity) }
      }

      for child in rootEntity.children
      where
        (child.name.hasPrefix("spatial-radial.node.")
        || child.name.hasPrefix("spatial-radial.quick.")
        || child.name.hasPrefix("spatial-radial.gesture."))
        && !liveNames.contains(child.name)
      {
        child.removeFromParent()
      }

      if let hub = attachments.entity(for: AttachmentID.hub) {
        hub.name = AttachmentID.hub
        setPositionIfNeeded(SpatialRadialGeometry.hubPosition, on: hub)
        if hub.parent !== rootEntity { rootEntity.addChild(hub) }
      }
      if let header = attachments.entity(for: AttachmentID.header) {
        header.name = AttachmentID.header
        setPositionIfNeeded(SpatialRadialGeometry.headerPosition, on: header)
        if header.parent !== rootEntity { rootEntity.addChild(header) }
      }
      if let mathLens = attachments.entity(for: AttachmentID.mathLens) {
        mathLens.name = AttachmentID.mathLens
        // A distinct rear plane makes the explanation feel spatial while
        // keeping it outside the main gaze/pinch target ring.
        setPositionIfNeeded(SpatialRadialGeometry.mathLensPosition, on: mathLens)
        if mathLens.parent !== rootEntity { rootEntity.addChild(mathLens) }
      } else {
        rootEntity.children.first(where: { $0.name == AttachmentID.mathLens })?
          .removeFromParent()
      }
    }

    /// Attachment content may invalidate independently of spatial layout (for
    /// example an on/off label changing). Avoid writing identical RealityKit
    /// transforms in those updates so they do not fan out through the scene graph.
    private func setPositionIfNeeded(_ position: SIMD3<Float>, on entity: Entity) {
      guard simd_distance_squared(entity.position, position) > 0.000_000_01 else { return }
      entity.position = position
    }
  }
#endif
