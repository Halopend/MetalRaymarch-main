//
//  AppIcons.swift
//  MetalProject
//
//  Centralized SF Symbol names and icon sizing scale for the Threshold UI.
//  Created during the icon-standardization audit (2026-06-24) to replace the
//  ~124 inline `Image(systemName: "...")` string literals scattered across the
//  app with a single source of truth. Reference symbols as `AppIcons.close`,
//  sizes as `IconSize.medium`.
//
//  Conventions (use the semantic aliases at the bottom for shared concepts so
//  the same action looks identical everywhere):
//    - close   -> xmark.circle.fill
//    - add     -> plus.circle.fill
//    - confirm -> checkmark.circle.fill
//    - reset   -> arrow.counterclockwise   (undo = arrow.uturn.backward)
//

import SwiftUI

/// Canonical SF Symbol names. One constant per distinct glyph used in the UI.
enum AppIcons {
    static let appleLogo = "apple.logo"
    static let arrowClockwise = "arrow.clockwise"
    static let arrowCounterclockwise = "arrow.counterclockwise"
    static let arrowDownCircle = "arrow.down.circle"
    static let arrowDownToLineCompact = "arrow.down.to.line.compact"
    static let arrowLeft = "arrow.left"
    static let arrowLeftAndRight = "arrow.left.and.right"
    static let arrowTriangle2Circlepath = "arrow.triangle.2.circlepath"
    static let arrowTriangleheadCounterclockwiseRotate90 = "arrow.trianglehead.counterclockwise.rotate.90"
    static let arrowUpRightSquare = "arrow.up.right.square"
    static let arrowUpToLineCompact = "arrow.up.to.line.compact"
    static let arrowUturnBackward = "arrow.uturn.backward"
    static let atom = "atom"
    static let backwardFill = "backward.fill"
    static let boltFill = "bolt.fill"
    static let boltSlash = "bolt.slash"
    static let boltTrianglebadgeExclamationmarkFill = "bolt.trianglebadge.exclamationmark.fill"
    static let cameraFill = "camera.fill"
    static let cameraFilters = "camera.filters"
    static let characterCursorIbeam = "character.cursor.ibeam"
    static let chartBarFill = "chart.bar.fill"
    static let checkmark = "checkmark"
    static let checkmarkCircle = "checkmark.circle"
    static let checkmarkCircleFill = "checkmark.circle.fill"
    static let chevronDown = "chevron.down"
    static let chevronLeft = "chevron.left"
    static let chevronLeftForwardslashChevronRight = "chevron.left.forwardslash.chevron.right"
    static let chevronRight = "chevron.right"
    static let chevronUp = "chevron.up"
    static let chevronUpChevronDown = "chevron.up.chevron.down"
    static let circle = "circle"
    static let circleDashed = "circle.dashed"
    static let circleDashedInsetFilled = "circle.dashed.inset.filled"
    static let circleHexagongridFill = "circle.hexagongrid.fill"
    static let clock = "clock"
    static let curveBezier = "curve.bezier"
    static let docBadgeArrowUp = "doc.badge.arrow.up"
    static let docText = "doc.text"
    static let ellipsisCircle = "ellipsis.circle"
    static let exclamationmarkTriangle = "exclamationmark.triangle"
    static let eye = "eye"
    static let eyeSlash = "eye.slash"
    static let filmFill = "film.fill"
    static let filmStack = "film.stack"
    static let flaskFill = "flask.fill"
    static let folder = "folder"
    static let forwardFill = "forward.fill"
    static let function = "function"
    static let gauge = "gauge"
    static let gaugeWithDotsNeedle50percent = "gauge.with.dots.needle.50percent"
    static let gaugeWithDotsNeedle67percent = "gauge.with.dots.needle.67percent"
    static let gearshape = "gearshape"
    static let globeAsiaAustralia = "globe.asia.australia"
    static let handDraw = "hand.draw"
    static let handDrawFill = "hand.draw.fill"
    static let handPointUpLeftAndText = "hand.point.up.left.and.text"
    static let handPointUpLeftFill = "hand.point.up.left.fill"
    static let handRaisedFill = "hand.raised.fill"
    static let handRaisedFingersSpread = "hand.raised.fingers.spread"
    static let handRaisedFingersSpreadFill = "hand.raised.fingers.spread.fill"
    static let handTapFill = "hand.tap.fill"
    static let handsSparkles = "hands.sparkles"
    static let icloud = "icloud"
    static let infoCircle = "info.circle"
    static let lightbulbMax = "lightbulb.max"
    static let linkBadgePlus = "link.badge.plus"
    static let magnifyingglass = "magnifyingglass"
    static let menucard = "menucard"
    static let micFill = "mic.fill"
    static let micSlashFill = "mic.slash.fill"
    static let move3d = "move.3d"
    static let musicNote = "music.note"
    static let musicNoteList = "music.note.list"
    static let paintbrushFill = "paintbrush.fill"
    static let paintpaletteFill = "paintpalette.fill"
    static let pauseCircleFill = "pause.circle.fill"
    static let pauseFill = "pause.fill"
    static let pencil = "pencil"
    static let pencilAndListClipboard = "pencil.and.list.clipboard"
    static let person3Fill = "person.3.fill"
    static let personSlash = "person.slash"
    static let photo = "photo"
    static let photoBadgePlus = "photo.badge.plus"
    static let photoOnRectangleAngled = "photo.on.rectangle.angled"
    static let pin = "pin"
    static let pinFill = "pin.fill"
    static let playCircleFill = "play.circle.fill"
    static let playFill = "play.fill"
    static let plus = "plus"
    static let plusCircle = "plus.circle"
    static let plusCircleFill = "plus.circle.fill"
    static let plusSquareOnSquare = "plus.square.on.square"
    static let questionmarkCircle = "questionmark.circle"
    static let recordCircle = "record.circle"
    static let rectangleDashed = "rectangle.dashed"
    static let repeatIcon = "repeat"
    static let rotate3d = "rotate.3d"
    static let shieldLefthalfFilled = "shield.lefthalf.filled"
    static let shuffle = "shuffle"
    static let sliderHorizontal3 = "slider.horizontal.3"
    static let sliderHorizontalBelowRectangle = "slider.horizontal.below.rectangle"
    static let sparkles = "sparkles"
    static let sparklesRectangleStack = "sparkles.rectangle.stack"
    static let speakerWave2Fill = "speaker.wave.2.fill"
    static let squareAndArrowDown = "square.and.arrow.down"
    static let squareAndArrowUp = "square.and.arrow.up"
    static let squareStack = "square.stack"
    static let squareStack3dUp = "square.stack.3d.up"
    static let stopCircle = "stop.circle"
    static let stopCircleFill = "stop.circle.fill"
    static let stopFill = "stop.fill"
    static let target = "target"
    static let timer = "timer"
    static let trash = "trash"
    static let viewfinder = "viewfinder"
    static let waveform = "waveform"
    static let waveformCircle = "waveform.circle"
    static let waveformCircleFill = "waveform.circle.fill"
    static let waveformPath = "waveform.path"
    static let waveformPathEcg = "waveform.path.ecg"
    static let wrenchAndScrewdriver = "wrench.and.screwdriver"
    static let xmark = "xmark"
    static let xmarkCircle = "xmark.circle"
    static let xmarkCircleFill = "xmark.circle.fill"

    // MARK: - Semantic aliases (prefer these for shared concepts)
    /// Close / dismiss an overlay, sheet, or banner.
    static let close = xmarkCircleFill
    /// Add a new item (keyframe, stop, scene, …).
    static let add = plusCircleFill
    /// Confirm / selected / checked state.
    static let confirm = checkmarkCircleFill
    /// Reset a value back to its default.
    static let reset = arrowCounterclockwise
    /// Undo the last edit.
    static let undo = arrowUturnBackward
    /// Refresh / reload from source.
    static let refresh = arrowClockwise
    /// Marks a control as audio-reactive.
    static let audioReactive = waveformCircleFill
}

/// Standard icon point sizes. Snap icon `.font(.system(size:))` values to these
/// tiers so glyph hierarchy stays consistent across the app.
enum IconSize {
    /// 9pt - micro badges, axis glyphs, captions.
    static let micro: CGFloat = 9
    /// 11pt - dense inline controls.
    static let small: CGFloat = 11
    /// 15pt - default body/toolbar icon.
    static let medium: CGFloat = 15
    /// 18pt - prominent toolbar / section icon.
    static let large: CGFloat = 18
    /// 28pt - large affordances.
    static let xlarge: CGFloat = 28
    /// 40pt - hero / transport / empty-state art.
    static let hero: CGFloat = 40
}
