#if os(visionOS)
  import Observation
  import RealityKit
  import Spatial
  import SwiftUI

  @MainActor
  @Observable
  final class SpatialRadialMenuModel {
    private(set) var navigation = SpatialRadialNavigationState()
    private(set) var hierarchy = NavigationHierarchy.application(
      availability: .resolve(
        profile: .current,
        allowsCustomScenes: AppModel.allowCustomScenes,
        includesGestureEditing: true
      )
    )
    private(set) var pendingActivationID: String?
    private(set) var gestureMap: SpatialGestureMapSnapshot?
    private(set) var presentationMode: SpatialRadialPresentationMode = .navigation
    private(set) var statusMessage: String?
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

    var canGoBack: Bool {
      isShowingQuickControls || isShowingGestureMap || navigation.canGoBack
    }

    var guidance: String {
      if isShowingQuickControls {
        return "Pinch a tile to toggle · center to go back"
      }
      if isShowingGestureMap {
        return "Pinch a shortcut to follow it · center to go back"
      }
      if navigation.canGoBack {
        return "Pinch a section · center to go back"
      }
      return "Pinch a section · center to close"
    }

    func configureHierarchy() {
      hierarchy = NavigationHierarchy.application(
        availability: .resolve(
          profile: .current,
          allowsCustomScenes: AppModel.allowCustomScenes,
          includesGestureEditing: true
        )
      )
    }

    func prepare(
      focusing nodeID: String?,
      gestureMap: SpatialGestureMapSnapshot? = nil
    ) {
      configureHierarchy()
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
      self.gestureMap = gestureMap
      statusMessage = nil
      rotation = 0
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
        schedulePendingActivationDelivery()
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
      rotation = SpatialRadialGeometry.constrainedRotation(newValue)
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
          nodeID: NavigationHierarchy.rootID(for: .quality),
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

    func installActivationHandler(owner: UUID, _ handler: @escaping (String) -> Void) {
      activationOwner = owner
      activationHandler = handler
      schedulePendingActivationDelivery()
    }

    func removeActivationHandler(owner: UUID) {
      guard activationOwner == owner else { return }
      activationOwner = nil
      activationHandler = nil
    }

    func installPresentationHandlers(reveal: @escaping () -> Void, dismiss: @escaping () -> Void) {
      revealControlsHandler = reveal
      dismissHandler = dismiss
    }

    func dismiss() {
      dismissHandler?()
    }

    /// Activation handlers are installed from SwiftUI lifecycle callbacks. Deliver
    /// pending navigation after that update transaction has completed so route
    /// mutation never occurs while SwiftUI is evaluating the menu window.
    private func schedulePendingActivationDelivery() {
      Task { @MainActor [weak self] in
        await Task.yield()
        self?.deliverPendingActivationIfPossible()
      }
    }

    private func deliverPendingActivationIfPossible() {
      guard let pendingActivationID, let activationHandler else { return }
      self.pendingActivationID = nil
      activationHandler(pendingActivationID)
    }
  }

  /// RealityView construction/update callbacks may mutate RealityKit objects, but
  /// must not write SwiftUI `@State`. These values are runtime bookkeeping only;
  /// storing them behind a stable, non-observable reference keeps those mutations
  /// outside SwiftUI's state graph.
  @MainActor
  private final class SpatialRadialRuntimeState {
    var handAnchorSubscription: EventSubscription?
    var rotationGestureStart: Float?
  }

  struct SpatialRadialMenuView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SpatialRadialMenuModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var handAnchor = AnchorEntity(
      .hand(.right, location: .aboveHand),
      trackingMode: .predicted,
      physicsSimulation: .none
    )
    @State private var rootEntity = Entity()
    @State private var runtime = SpatialRadialRuntimeState()
    @State private var quickControlRevision = 0

    private var spatialQuickControls: [ToggleDescriptor] {
      let store = appModel.controlStateStore
      let key = ControlCatalogProjectionKey(
        profile: appModel.platformProfile,
        route: nil,
        presentation: .spatialRadial,
        fractalType: store.fractalType,
        catalogRevision: 1,
        transformRevision: store.spaceWarpStructureRevision,
        featureFlags: 0
      )
      return appModel.controlProjectionCache.sections(for: key).flatMap { section in
        section.controlIDs.compactMap { id -> ToggleDescriptor? in
          guard case .toggle(let descriptor) = ParameterCatalog.semanticByID[id],
                descriptor.isAvailable(store) else { return nil }
          return descriptor
        }
      }
    }

    private enum AttachmentID {
      static let header = "spatial-radial.header"
      static let hub = "spatial-radial.hub"
      static let rail = "spatial-radial.rail"
      static func node(_ id: String) -> String { "spatial-radial.node.\(id)" }
      static func quickControl(_ id: String) -> String { "spatial-radial.quick.\(id)" }
      static func gestureShortcut(_ id: String) -> String { "spatial-radial.gesture.\(id)" }
    }

    var body: some View {
      RealityView { content, attachments in
        handAnchor.name = "SpatialRadialMenuHandAnchor"
        rootEntity.name = "SpatialRadialMenuRoot"
        configureHandAnchor()
        handAnchor.addChild(rootEntity)
        content.add(handAnchor)
        runtime.handAnchorSubscription?.cancel()
        runtime.handAnchorSubscription = content.subscribe(
          to: SceneEvents.AnchoredStateChanged.self,
          on: handAnchor
        ) { event in
          Task { @MainActor in
            updateTrackedContentVisibility(handIsAnchored: event.isAnchored)
          }
        }
        synchronizeEntities(attachments)
      } update: { _, attachments in
        configureHandAnchor()
        synchronizeEntities(attachments)
      } attachments: {
        Attachment(id: AttachmentID.header) {
          header
        }
        Attachment(id: AttachmentID.hub) {
          hub
        }
        Attachment(id: AttachmentID.rail) {
          spatialRail
        }
        ForEach(model.visibleNodes) { node in
          Attachment(id: AttachmentID.node(node.id)) {
            nodeButton(node)
          }
        }
        if model.isShowingQuickControls {
          ForEach(spatialQuickControls) { control in
            Attachment(id: AttachmentID.quickControl(control.controlID.rawValue)) {
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
      .allowsHitTesting(appModel.isSpatialMenuVisible)
      .onDisappear {
        runtime.rotationGestureStart = nil
        runtime.handAnchorSubscription?.cancel()
        runtime.handAnchorSubscription = nil
        rootEntity.isEnabled = false
        handAnchor.isEnabled = false
      }
      .accessibilityLabel("Spatial radial controls")
    }

    private var rotationGesture: some Gesture {
      RotateGesture3D(constrainedToAxis: .z, minimumAngleDelta: .degrees(0.5))
        .onChanged { value in
          guard appModel.isSpatialMenuVisible, rootEntity.isEnabled else { return }
          let axisSign: Double = value.rotation.axis.z < 0 ? -1 : 1
          let delta = Float(value.rotation.angle.radians * axisSign)
          if runtime.rotationGestureStart == nil {
            runtime.rotationGestureStart = model.rotation
          }
          model.setRotation((runtime.rotationGestureStart ?? 0) + delta)
        }
        .onEnded { _ in
          runtime.rotationGestureStart = nil
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

    private var spatialRail: some View {
      Capsule()
        .fill(Color.cyan.opacity(0.24))
        .overlay(
          Capsule()
            .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
        )
        .frame(width: CGFloat(SpatialRadialGeometry.railLength * 1_000), height: 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
        .frame(width: 60, height: 60)
        .background(Color.black.opacity(0.30), in: Circle())
        .overlay(Circle().strokeBorder(Color.cyan.opacity(0.55), lineWidth: 1.5))
      }
      .buttonStyle(.plain)
      .hoverEffect(.highlight)
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
        .frame(width: 102, height: 60)
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
      .hoverEffect(.highlight)
      .accessibilityLabel("\(node.title), \(actionLabel.lowercased())")
    }

    private func quickControlButton(_ control: ToggleDescriptor) -> some View {
      _ = quickControlRevision
      let access = appModel.controlAccessService
      let isEnabled = access.readToggle(control.controlID) ?? false
      return Button {
        access.writeToggle(!isEnabled, to: control.controlID)
        quickControlRevision &+= 1
        model.reportQuickControlChange(
          title: control.name,
          isEnabled: access.readToggle(control.controlID) ?? false
        )
      } label: {
        VStack(spacing: 5) {
          Image(systemName: control.icon)
            .font(.title3.weight(.semibold))
          Text(control.name)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
          Text(isEnabled ? "On" : "Off")
            .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(isEnabled ? Color.white : Color.secondary)
        .frame(width: 102, height: 60)
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
      .hoverEffect(.highlight)
      .accessibilityLabel("\(control.name), \(isEnabled ? "on" : "off")")
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
        .frame(width: 106, height: 62)
        .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
          RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Color.cyan.opacity(0.55), lineWidth: 1.25)
        )
      }
      .buttonStyle(.plain)
      .hoverEffect(.highlight)
      .disabled(!mapIsEnabled)
      .opacity(mapIsEnabled ? 1 : 0.45)
      .accessibilityLabel(
        "\(shortcut.hand.rawValue) \(shortcut.fingerName), \(shortcut.action.displayName)"
      )
      .accessibilityHint("Follows the same destination as this hand shortcut")
    }

    private func synchronizeEntities(_ attachments: RealityViewAttachments) {
      let nodes = model.visibleNodes
      let quickControls = model.isShowingQuickControls ? spatialQuickControls : []
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
        rotation: model.rotation,
        isLeftHanded: appModel.renderSettings.leftHandedMode
      )
      var liveNames = Set<String>()

      for (node, placement) in zip(nodes, placements) {
        let name = AttachmentID.node(node.id)
        liveNames.insert(name)
        guard let entity = attachments.entity(for: name) else { continue }
        entity.name = name
        setPositionIfNeeded(placement.position, on: entity)
        setOrientationIfNeeded(
          SpatialRadialGeometry.itemOrientation(
            angle: placement.angle,
            isLeftHanded: appModel.renderSettings.leftHandedMode
          ),
          on: entity
        )
        if entity.parent !== rootEntity { rootEntity.addChild(entity) }
      }

      for (control, placement) in zip(quickControls, placements) {
        let name = AttachmentID.quickControl(control.controlID.rawValue)
        liveNames.insert(name)
        guard let entity = attachments.entity(for: name) else { continue }
        entity.name = name
        setPositionIfNeeded(placement.position, on: entity)
        setOrientationIfNeeded(
          SpatialRadialGeometry.itemOrientation(
            angle: placement.angle,
            isLeftHanded: appModel.renderSettings.leftHandedMode
          ),
          on: entity
        )
        if entity.parent !== rootEntity { rootEntity.addChild(entity) }
      }

      for (shortcut, placement) in zip(gestureShortcuts, placements) {
        let name = AttachmentID.gestureShortcut(shortcut.id)
        liveNames.insert(name)
        guard let entity = attachments.entity(for: name) else { continue }
        entity.name = name
        setPositionIfNeeded(placement.position, on: entity)
        setOrientationIfNeeded(
          SpatialRadialGeometry.itemOrientation(
            angle: placement.angle,
            isLeftHanded: appModel.renderSettings.leftHandedMode
          ),
          on: entity
        )
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
      if let rail = attachments.entity(for: AttachmentID.rail) {
        rail.name = AttachmentID.rail
        setPositionIfNeeded(
          SpatialRadialGeometry.railPosition(
            depth: model.navigation.depth,
            rotation: model.rotation,
            isLeftHanded: appModel.renderSettings.leftHandedMode
          ),
          on: rail
        )
        setOrientationIfNeeded(
          SpatialRadialGeometry.railOrientation(rotation: model.rotation),
          on: rail
        )
        if rail.parent !== rootEntity { rootEntity.addChild(rail) }
      }
      if let header = attachments.entity(for: AttachmentID.header) {
        header.name = AttachmentID.header
        setPositionIfNeeded(
          SpatialRadialGeometry.headerPosition(
            isLeftHanded: appModel.renderSettings.leftHandedMode
          ),
          on: header
        )
        if header.parent !== rootEntity { rootEntity.addChild(header) }
      }
    }

    private func configureHandAnchor() {
      let chirality: AnchoringComponent.Target.Chirality =
        appModel.renderSettings.leftHandedMode ? .left : .right
      let target = AnchoringComponent.Target.hand(chirality, location: .aboveHand)
      if handAnchor.anchoring.target != target {
        handAnchor.anchoring = AnchoringComponent(
          target,
          trackingMode: .predicted,
          physicsSimulation: .none
        )
      }

      handAnchor.isEnabled = appModel.isSpatialMenuVisible
      updateTrackedContentVisibility(handIsAnchored: handAnchor.isAnchored)
      setPositionIfNeeded(SpatialRadialGeometry.handRelativeOffset, on: rootEntity)
      let desiredOrientation = SpatialRadialGeometry.anchorToFacingOrientation
      if abs(simd_dot(rootEntity.orientation.vector, desiredOrientation.vector)) < 0.999_999 {
        rootEntity.orientation = desiredOrientation
      }
    }

    private func updateTrackedContentVisibility(handIsAnchored: Bool) {
      let shouldShow = SpatialRadialGeometry.shouldShowContent(
        menuRequested: appModel.isSpatialMenuVisible,
        handIsAnchored: handIsAnchored
      )
      rootEntity.isEnabled = shouldShow
      if !shouldShow { runtime.rotationGestureStart = nil }
    }

    /// Attachment content may invalidate independently of spatial layout (for
    /// example an on/off label changing). Avoid writing identical RealityKit
    /// transforms in those updates so they do not fan out through the scene graph.
    private func setPositionIfNeeded(_ position: SIMD3<Float>, on entity: Entity) {
      guard simd_distance_squared(entity.position, position) > 0.000_000_01 else { return }
      entity.position = position
    }

    private func setOrientationIfNeeded(_ orientation: simd_quatf, on entity: Entity) {
      guard abs(simd_dot(entity.orientation.vector, orientation.vector)) < 0.999_999 else {
        return
      }
      entity.orientation = orientation
    }
  }
#endif
