//
//  MB3DParameterMap.swift
//  Threshold
//
//  Maps Mandelbulb3D formula IDs and names to Threshold fractal types.
//

import Foundation

/// Mapping from an MB3D formula to a Threshold fractal type + param indices.
struct MB3DFormulaMapping {
    let thresholdType: String
    let parameterMap: [String: Int]  // "param0" etc → Threshold params[] index
}

enum MB3DFormulaDatabase {

    // MARK: - Builtin Name Lookup

    /// Known MB3D internal formula names by iFnr ID.
    /// These match the formula table in the MB3D `formulas` unit.
    /// Custom / external formulas (typically iFnr ≥ 20) use CustomFname instead.
    static func builtinName(for id: Int) -> String {
        switch id {
        case 0:  return "IntPower"          // Mandelbulb (integer power)
        case 1:  return "BenesiPine"
        case 2:  return "Quaternion"
        case 3:  return "Tricorn"
        case 4:  return "AmazingBox"        // MandelBox
        case 5:  return "BulBox"
        case 6:  return "MengerSponge"
        case 7:  return "Sierpinski"
        case 8:  return "IcosSierpinski"
        case 9:  return "Koch"
        case 10: return "AmazingSurf"
        case 11: return "Julia"
        case 12: return "Benesi_T1_Pine"
        case 13: return "Fold"
        case 14: return "IFS"
        case 15: return "Polyhedra"
        default: return "Formula_\(id)"
        }
    }

    // MARK: - Threshold Type Mapping

    /// Determine the corresponding Threshold fractal type.
    /// Tries formula name first (handles custom formulas), then falls back to ID.
    static func thresholdType(for formulaID: Int, name: String) -> String? {
        let n = name.lowercased()
        // Name-based matching (works for custom/extern formulas)
        if n.contains("pseudokleinian")                     { return "theliPseudoKleinian" }
        if n.contains("amazingbox") || n.contains("mandelbox") { return "mandelbox" }
        if n.contains("amazingsurf")                        { return "mandelbox" }
        if n.contains("mandelbulb") || n.contains("intpower")  { return "mandelbulb" }
        if n.contains("menger")                             { return "menger" }
        if n.contains("sierpinski")                         { return "sierpinski" }
        if n.contains("quaternion")                         { return "quaternionJulia" }
        if n.contains("octahedron")                         { return "octahedron" }
        if n.contains("icosahedron")                        { return "icosahedron" }
        if n.contains("spheresponge")                       { return "sphereSponge" }

        // ID-based fallback
        switch formulaID {
        case 0:       return "mandelbulb"
        case 4, 10:   return "mandelbox"
        case 6:       return "menger"
        case 7, 8:    return "sierpinski"
        case 2, 11:   return "quaternionJulia"
        default:      return nil
        }
    }

    // MARK: - Parameter Index Mapping

    /// Get a parameter mapping for a formula slot.
    static func mapping(for slot: MB3DFormulaSlot) -> MB3DFormulaMapping? {
        guard let threshType = thresholdType(
            for: slot.formulaID, name: slot.formulaName) else {
            return nil
        }
        // MB3D dOptionValue[0..15] → Threshold params[] indices
        // The exact semantics depend on the formula.  Below are best-effort defaults.
        switch threshType {
        case "mandelbox":
            return MB3DFormulaMapping(thresholdType: threshType, parameterMap: [
                "param0": 0,   // Scale
                "param1": 1,   // MinRadius
                "param2": 2,   // FoldLimit
                "param3": 3,   // FixedRadius
            ])
        case "mandelbulb":
            return MB3DFormulaMapping(thresholdType: threshType, parameterMap: [
                "param0": 0,   // Power
            ])
        case "theliPseudoKleinian":
            return MB3DFormulaMapping(thresholdType: threshType, parameterMap: [
                "param0": 0,   // Size
                "param1": 1, "param2": 2, "param3": 3,    // CSize.xyz
                "param4": 4, "param5": 5, "param6": 6,    // C.xyz
                "param7": 7,   // DEoffset
                "param8": 8, "param9": 9, "param10": 10,  // Offset.xyz
            ])
        case "menger":
            return MB3DFormulaMapping(thresholdType: threshType, parameterMap: [
                "param0": 0,   // Scale
                "param1": 1, "param2": 2, "param3": 3,    // Offset.xyz
            ])
        default:
            return nil
        }
    }
}
