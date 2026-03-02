//
//  ColorSchemeTypes.swift
//  Threshold
//
//  Color scheme enum with built-in presets matching ShaderTypes.h.
//  Provides palette, post-processing, neon parameters, and shader param building.
//

import Foundation
import simd

enum ColorScheme: Int32, CaseIterable, Codable {
    case classic = 0        // Original Mandelbox colors (red/gray/gold)
    case ocean = 1          // Deep blues and teals
    case fire = 2           // Warm oranges and reds
    case forest = 3         // Greens and browns
    case nebula = 4         // Purple/pink cosmic
    case mono = 5           // Grayscale with subtle tints
    case aurora = 6         // Northern lights (greens/blues/purples)
    case volcanic = 7       // Dark with lava accents
    case neonCyber = 8      // Neon cyberpunk (hot pink/cyan/purple)
    case neonSunset = 9     // Neon sunset (orange/magenta/violet)
    case neonMatrix = 10    // Neon matrix (bright greens/black)
    
    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .ocean: return "Ocean"
        case .fire: return "Fire"
        case .forest: return "Forest"
        case .nebula: return "Nebula"
        case .mono: return "Mono"
        case .aurora: return "Aurora"
        case .volcanic: return "Volcanic"
        case .neonCyber: return "Neon Cyber"
        case .neonSunset: return "Neon Sunset"
        case .neonMatrix: return "Neon Matrix"
        }
    }
    
    var icon: String {
        switch self {
        case .classic: return "paintpalette"
        case .ocean: return "water.waves"
        case .fire: return "flame"
        case .forest: return "leaf"
        case .nebula: return "sparkles"
        case .mono: return "circle.lefthalf.filled"
        case .aurora: return "rainbow"
        case .volcanic: return "mountain.2"
        case .neonCyber: return "bolt.circle.fill"
        case .neonSunset: return "sun.horizon.fill"
        case .neonMatrix: return "chevron.left.forwardslash.chevron.right"
        }
    }
    
    // Returns true if this scheme uses neon HSV mode
    var isNeonMode: Bool {
        switch self {
        case .neonCyber, .neonSunset, .neonMatrix: return true
        default: return false
        }
    }
    
    // Get the color palette for this scheme (col1, col2, col3, altColor1, altMixFactors)
    // VIBRANT palettes - high saturation primary colors for bold, colorful fractals
    var palette: (color1: SIMD3<Float>, color2: SIMD3<Float>, color3: SIMD3<Float>, 
                  altColor1: SIMD3<Float>, altMixFactors: SIMD3<Float>) {
        switch self {
        case .classic:
            // Vibrant red, electric blue, bright gold
            return (SIMD3<Float>(1.0, 0.1, 0.1),    // Bright red
                    SIMD3<Float>(0.2, 0.4, 0.9),    // Electric blue
                    SIMD3<Float>(1.0, 0.8, 0.0),    // Bright gold
                    SIMD3<Float>(0.0, 0.2, 0.8),    // Alt blue
                    SIMD3<Float>(1.0, 1.0, 0.5))    // Alt mix factors
                    
        case .ocean:
            // Electric blues, vibrant teals, bright cyan
            return (SIMD3<Float>(0.0, 0.3, 1.0),    // Electric blue
                    SIMD3<Float>(0.0, 0.9, 0.8),    // Bright teal
                    SIMD3<Float>(0.4, 1.0, 1.0),    // Bright cyan
                    SIMD3<Float>(0.1, 0.5, 1.0),    // Sky blue
                    SIMD3<Float>(0.6, 1.0, 0.3))
                    
        case .fire:
            // Intense oranges, reds, bright yellows
            return (SIMD3<Float>(1.0, 0.2, 0.0),    // Bright red-orange
                    SIMD3<Float>(1.0, 0.6, 0.0),    // Vivid orange
                    SIMD3<Float>(1.0, 1.0, 0.2),    // Bright yellow
                    SIMD3<Float>(0.9, 0.1, 0.0),    // Pure red
                    SIMD3<Float>(1.0, 0.8, 0.5))
                    
        case .forest:
            // Vibrant greens, rich browns, lime accents
            return (SIMD3<Float>(0.1, 0.8, 0.2),    // Bright green
                    SIMD3<Float>(0.6, 0.4, 0.1),    // Rich brown
                    SIMD3<Float>(0.8, 1.0, 0.2),    // Lime green
                    SIMD3<Float>(0.2, 0.6, 0.1),    // Forest green
                    SIMD3<Float>(0.8, 0.9, 0.4))
                    
        case .nebula:
            // Vivid purple, hot pink, electric blue
            return (SIMD3<Float>(0.6, 0.0, 1.0),    // Vivid purple
                    SIMD3<Float>(1.0, 0.2, 0.6),    // Hot pink
                    SIMD3<Float>(0.2, 0.6, 1.0),    // Electric blue
                    SIMD3<Float>(0.8, 0.1, 0.9),    // Magenta
                    SIMD3<Float>(1.0, 1.0, 0.5))
                    
        case .mono:
            // High contrast black and white with blue tint
            return (SIMD3<Float>(0.1, 0.1, 0.15),   // Near black (blue tint)
                    SIMD3<Float>(0.5, 0.5, 0.55),   // Mid gray
                    SIMD3<Float>(1.0, 1.0, 0.95),   // Near white (warm)
                    SIMD3<Float>(0.3, 0.35, 0.4),   // Cool gray
                    SIMD3<Float>(1.0, 1.0, 0.2))
                    
        case .aurora:
            // Neon greens, electric blues, vivid purples
            return (SIMD3<Float>(0.0, 1.0, 0.4),    // Neon green
                    SIMD3<Float>(0.0, 0.6, 1.0),    // Electric blue
                    SIMD3<Float>(0.8, 0.2, 1.0),    // Vivid purple
                    SIMD3<Float>(0.0, 0.9, 0.7),    // Bright teal
                    SIMD3<Float>(0.9, 1.2, 0.6))
                    
        case .volcanic:
            // Deep blacks with bright lava oranges and reds
            return (SIMD3<Float>(0.05, 0.02, 0.02), // Near black
                    SIMD3<Float>(1.0, 0.3, 0.0),    // Bright orange
                    SIMD3<Float>(1.0, 0.8, 0.1),    // Lava yellow
                    SIMD3<Float>(0.8, 0.1, 0.0),    // Deep red
                    SIMD3<Float>(1.5, 0.7, 0.4))
                    
        case .neonCyber:
            // Cyberpunk neon - hot pink, electric cyan, purple
            return (SIMD3<Float>(1.0, 0.0, 0.6),    // Hot pink
                    SIMD3<Float>(0.0, 1.0, 1.0),    // Electric cyan
                    SIMD3<Float>(0.6, 0.0, 1.0),    // Purple
                    SIMD3<Float>(1.0, 0.3, 0.8),    // Magenta
                    SIMD3<Float>(1.0, 1.0, 0.8))
                    
        case .neonSunset:
            // Neon sunset - orange, magenta, violet
            return (SIMD3<Float>(1.0, 0.4, 0.0),    // Neon orange
                    SIMD3<Float>(1.0, 0.0, 0.5),    // Magenta
                    SIMD3<Float>(0.5, 0.0, 1.0),    // Violet
                    SIMD3<Float>(1.0, 0.6, 0.2),    // Light orange
                    SIMD3<Float>(1.2, 0.9, 0.7))
                    
        case .neonMatrix:
            // Matrix green on black
            return (SIMD3<Float>(0.0, 1.0, 0.0),    // Pure neon green
                    SIMD3<Float>(0.0, 0.6, 0.2),    // Dark green
                    SIMD3<Float>(0.5, 1.0, 0.5),    // Light green
                    SIMD3<Float>(0.0, 0.8, 0.3),    // Medium green
                    SIMD3<Float>(0.8, 1.0, 0.6))
        }
    }
    
    // Suggested post-processing for this scheme - BOOSTED saturation values
    var postProcessing: (saturation: Float, contrast: Float, gamma: Float) {
        switch self {
        case .classic:    return (2.0, 1.15, 0.45)   // Boosted saturation
        case .ocean:      return (1.8, 1.12, 0.48)
        case .fire:       return (2.2, 1.2, 0.42)    // Extra vibrant
        case .forest:     return (1.8, 1.1, 0.5)
        case .nebula:     return (2.3, 1.15, 0.42)   // Very saturated
        case .mono:       return (0.6, 1.3, 0.46)    // Low saturation, high contrast
        case .aurora:     return (2.5, 1.15, 0.4)    // Maximum vibrancy
        case .volcanic:   return (2.0, 1.35, 0.38)   // High contrast for drama
        case .neonCyber:  return (2.8, 1.2, 0.38)    // Extreme saturation for neon
        case .neonSunset: return (2.6, 1.25, 0.4)    // Warm neon
        case .neonMatrix: return (3.0, 1.4, 0.35)    // Maximum green intensity
        }
    }
    
    // Neon mode parameters (only used when isNeonMode is true)
    // hueFreq: color variation speed (low=smooth gradients, high=more color zones)
    // hueOffset: shifts which palette color appears at center
    // bandFreq: radial glow rings (0=none, higher=more rings)
    // stripeFreq: (unused in new impl)
    // stripeStrength: (unused in new impl)
    // glowSharpness: how quickly glow falls off (higher=sharper edges)
    // satPower: saturation boost (lower=more saturated)
    var neonParams: (hueFreq: Float, hueOffset: Float, bandFreq: Float, stripeFreq: Float, 
                     stripeStrength: Float, glowSharpness: Float, satPower: Float) {
        switch self {
        case .neonCyber:
            // Hot pink/cyan - smooth gradient, subtle rings, sharp glow
            return (1.5, 0.0, 3.0, 0.0, 0.0, 4.0, 0.2)
        case .neonSunset:
            // Orange/magenta/violet - medium gradient, no rings, softer glow
            return (2.0, 0.33, 0.0, 0.0, 0.0, 2.5, 0.25)
        case .neonMatrix:
            // Pure green tones - tight color (low freq), strong rings, very sharp
            return (0.5, 0.0, 6.0, 0.0, 0.0, 5.0, 0.15)
        default:
            return (1.5, 0.0, 2.0, 0.0, 0.0, 3.0, 0.3)
        }
    }
    
    // Create shader-compatible ColorSchemeParams with new modular lighting effects
    func toShaderParams(colorMix: Float,
                        animTime: Float = 0.0, 
                        hueRotation: HueRotationEffect = .off,
                        pulse: PulseEffect = .off,
                        glow: GlowEffect = .off,
                        bloom: BloomEffect = .off) -> ColorSchemeParams {
        let pal = palette
        let pp = postProcessing
        let neon = neonParams
        return ColorSchemeParams(
            color1: pal.color1,
            color2: pal.color2,
            color3: pal.color3,
            altMixFactors: pal.altMixFactors,
            saturation: pp.saturation,
            contrast: pp.contrast,
            gamma: pp.gamma,
            brightness: 0.0,
            vibrance: 1.0,
            colorCurve: 1.0,
            shadows: 1.0,
            highlights: 1.0,
            neonIntensity: isNeonMode ? 1.0 : 0.0,
            hueFrequency: neon.hueFreq,
            hueOffset: neon.hueOffset,
            bandFrequency: neon.bandFreq,
            glowSharpness: neon.glowSharpness,
            saturationPower: neon.satPower,
            // === GRADIENT (legacy path — disabled) ===
            gradientStops: (
                SIMD4<Float>(0,0,0,0), SIMD4<Float>(0,0,0,0), SIMD4<Float>(0,0,0,0), SIMD4<Float>(0,0,0,0),
                SIMD4<Float>(0,0,0,0), SIMD4<Float>(0,0,0,0), SIMD4<Float>(0,0,0,0), SIMD4<Float>(0,0,0,0)
            ),
            gradientStopCount: 0,
            colorMappingMode: 0,
            gradientRepeat: 1.0,
            gradientOffset: 0.0,
            useGradientColoring: 0,
            gradientSmoothing: 1.0,
            gradientLoopSmooth: 0,
            _gradPad: (0.0),
            // === MODULAR LIGHTING EFFECTS ===
            animTime: animTime,
            hueRotationEnabled: hueRotation.enabled ? 1 : 0,
            hueRotationSpeed: hueRotation.speed,
            hueRotationIntensity: hueRotation.intensity,
            pulseEnabled: pulse.enabled ? 1 : 0,
            pulseSpeed: pulse.speed,
            pulseAmount: pulse.amount,
            glowEnabled: glow.enabled ? 1 : 0,
            glowIntensity: glow.intensity,
            bloomEnabled: bloom.enabled ? 1 : 0,
            bloomStrength: bloom.strength,
            beatFlashEnabled: 0,
            beatFlashIntensity: 0.0
        )
    }
}
