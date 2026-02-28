//
//  FingerGestureAction.swift
//  Threshold
//
//  Configurable mapping of two-hand finger pinches to actions.
//  Each finger pair (index, middle, ring, pinky) can be assigned one action.
//

import Foundation

/// Actions that can be assigned to a two-hand finger-pinch pair.
enum FingerGestureAction: Int32, CaseIterable, Codable {
    case none         = 0   // Finger pair is unassigned
    case grab         = 1   // Two-point grab: scale + rotate + translate world
    case minDistance   = 2   // Mandelbox minRadius² (sphere fold cutoff)
    case foldingLimit  = 3   // Mandelbox box fold boundary
    case sphereRadius  = 4   // Mandelbox sphere inversion radius
    case fractalScale  = 5   // Mandelbox overall scale factor

    var displayName: String {
        switch self {
        case .none:         return "None"
        case .grab:         return "Grab (Scale/Rotate)"
        case .minDistance:   return "Min Distance"
        case .foldingLimit:  return "Folding Limit"
        case .sphereRadius:  return "Sphere Radius"
        case .fractalScale:  return "Fractal Scale"
        }
    }

    var icon: String {
        switch self {
        case .none:         return "xmark.circle"
        case .grab:         return "hand.pinch"
        case .minDistance:   return "circle.dashed"
        case .foldingLimit:  return "square.dashed"
        case .sphereRadius:  return "circle.circle"
        case .fractalScale:  return "arrow.up.left.and.arrow.down.right"
        }
    }
}

/// Which finger pair (both hands must pinch the same finger).
enum FingerPair: Int, CaseIterable {
    case index  = 1
    case middle = 2
    case ring   = 3
    case pinky  = 4

    var displayName: String {
        switch self {
        case .index:  return "Index"
        case .middle: return "Middle"
        case .ring:   return "Ring"
        case .pinky:  return "Pinky"
        }
    }

    var icon: String {
        switch self {
        case .index:  return "1.circle.fill"
        case .middle: return "2.circle.fill"
        case .ring:   return "3.circle.fill"
        case .pinky:  return "4.circle.fill"
        }
    }
}
