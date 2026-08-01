//
//  FractalAtlas.swift
//  Threshold
//
//  Brand system and an editorial atlas of the ideas that shaped fractal space.
//

import SwiftUI
import Foundation
import Observation

// MARK: - Threshold Brand

enum ThresholdBrand {
    static let ember = Color(red: 1.00, green: 0.31, blue: 0.23)
    static let bloom = Color(red: 1.00, green: 0.22, blue: 0.72)
    static let ether = Color(red: 0.28, green: 0.88, blue: 1.00)
    static let ultraviolet = Color(red: 0.43, green: 0.28, blue: 1.00)
    static let void = Color(red: 0.025, green: 0.025, blue: 0.06)
}

struct ThresholdGlyph: View {
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle()
                .fill(ThresholdBrand.void)

            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: size * 0.19, style: .continuous)
                    .stroke(
                        AngularGradient(
                            colors: [
                                ThresholdBrand.ember,
                                ThresholdBrand.bloom,
                                ThresholdBrand.ether,
                                ThresholdBrand.ember
                            ],
                            center: .center
                        ),
                        lineWidth: max(1.5, size * 0.045)
                    )
                    .frame(width: size * 0.56, height: size * 0.56)
                    .rotationEffect(.degrees(Double(index) * 45))
            }

            Circle()
                .fill(ThresholdBrand.void)
                .frame(width: size * 0.18, height: size * 0.18)
                .overlay {
                    Circle()
                        .stroke(ThresholdBrand.ether.opacity(0.8), lineWidth: 1)
                }
        }
        .frame(width: size, height: size)
        .shadow(color: ThresholdBrand.bloom.opacity(0.3), radius: size * 0.22)
        .accessibilityHidden(true)
    }
}

struct ThresholdBrandLockup: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 10 : 14) {
            ThresholdGlyph(size: compact ? 38 : 52)

            VStack(alignment: .leading, spacing: compact ? 0 : 3) {
                Text("THRESHOLD")
                    .font(compact ? .headline : .title2)
                    .fontWeight(.black)
                    .tracking(compact ? 2.4 : 4.2)

                if !compact {
                    Text("A SPATIAL FRACTAL INSTRUMENT")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .tracking(1.8)
                        .foregroundStyle(ThresholdBrand.ether)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Threshold, a spatial fractal instrument")
    }
}

struct ThresholdFieldBackground: View {
    var body: some View {
        ZStack {
            ThresholdBrand.void

            Circle()
                .fill(ThresholdBrand.ultraviolet.opacity(0.24))
                .frame(width: 520, height: 520)
                .blur(radius: 110)
                .offset(x: 360, y: -250)

            Circle()
                .fill(ThresholdBrand.ember.opacity(0.17))
                .frame(width: 420, height: 420)
                .blur(radius: 120)
                .offset(x: -430, y: 280)

            Circle()
                .fill(ThresholdBrand.ether.opacity(0.11))
                .frame(width: 300, height: 300)
                .blur(radius: 100)
                .offset(x: 80, y: 360)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Atlas Model

enum FractalLineage: String, CaseIterable, Hashable {
    case foundations = "Foundations"
    case complexDynamics = "Complex Dynamics"
    case recursiveGeometry = "Recursive Geometry"
    case chaos = "Chaos"
    case naturalSystems = "Natural Systems"
    case computerGraphics = "Computer Graphics"
    case threeDimensional = "3D Frontier"

    var symbol: String {
        switch self {
        case .foundations: return "point.3.connected.trianglepath.dotted"
        case .complexDynamics: return "function"
        case .recursiveGeometry: return "square.3.layers.3d"
        case .chaos: return "waveform.path.ecg"
        case .naturalSystems: return "leaf"
        case .computerGraphics: return "display"
        case .threeDimensional: return "cube.transparent"
        }
    }
}

enum FractalAccent: Hashable {
    case ember
    case bloom
    case ether
    case ultraviolet
    case gold
    case green

    var color: Color {
        switch self {
        case .ember: return ThresholdBrand.ember
        case .bloom: return ThresholdBrand.bloom
        case .ether: return ThresholdBrand.ether
        case .ultraviolet: return ThresholdBrand.ultraviolet
        case .gold: return Color(red: 1.0, green: 0.76, blue: 0.22)
        case .green: return Color(red: 0.33, green: 1.0, blue: 0.56)
        }
    }
}

struct FractalInfluence: Identifiable, Hashable {
    let id: String
    let pioneer: String
    let work: String
    let period: String
    let lineage: FractalLineage
    let summary: String
    let interpretation: String
    let presetName: String
    let symbol: String
    let accent: FractalAccent
    /// The specific topic or passage scope supporting the historical paraphrase.
    var sourceBasis: String = ""
    let sourceName: String
    let sourceURL: URL
    /// What to look for inside the loaded experience — connects visible
    /// features of the interpretation to the mathematical idea.
    var fieldNotes: String = ""
    /// The default runtime for this Atlas entry. Only distance-estimator entries
    /// participate in PresetManager; other studies stay in their own canvas.
    var defaultSceneRenderer: AtlasSceneRenderer = .distanceEstimator
    /// A native Atlas canvas, if this entry has one. It is intentionally separate
    /// from the immersive Mandelbox renderer.
    var sceneBlueprint: AtlasSceneBlueprint? = nil
}

enum FractalAtlas {
    private static let cantor = URL(string: "https://mathshistory.st-andrews.ac.uk/Biographies/Cantor/")!
    private static let cayley = URL(string: "https://mathshistory.st-andrews.ac.uk/Biographies/Cayley/")!
    private static let matrixTransformations = URL(string: "https://math.libretexts.org/Courses/Canada_College/Linear_Algebra_and_Its_Application/05%3A_Linear_Transformations/5.03%3A_Matrix_Transformations")!
    private static let weierstrass = URL(string: "https://mathshistory.st-andrews.ac.uk/Biographies/Weierstrass/")!
    private static let poincare = URL(string: "https://mathshistory.st-andrews.ac.uk/Biographies/Poincare/")!
    private static let peano = URL(string: "https://mathshistory.st-andrews.ac.uk/Biographies/Peano/")!
    private static let hilbert = URL(string: "https://en.wikipedia.org/wiki/Hilbert_curve")!
    private static let koch = URL(string: "https://en.wikipedia.org/wiki/Koch_snowflake")!
    private static let sierpinski = URL(string: "https://mathshistory.st-andrews.ac.uk/Biographies/Sierpinski/")!
    private static let julia = URL(string: "https://mathshistory.st-andrews.ac.uk/Biographies/Julia/")!
    private static let fatou = URL(string: "https://mathshistory.st-andrews.ac.uk/Biographies/Fatou/")!
    private static let hausdorff = URL(string: "https://mathshistory.st-andrews.ac.uk/Biographies/Hausdorff/")!
    private static let menger = URL(string: "https://en.wikipedia.org/wiki/Menger_sponge")!
    private static let richardson = URL(string: "https://en.wikipedia.org/wiki/Coastline_paradox")!
    private static let ibmMandelbrot = URL(string: "https://www.ibm.com/history/benoit-mandelbrot")!
    private static let douadyHubbard = URL(string: "https://www.numdam.org/item/ASENS_1985_4_18_2_287_0/")!
    private static let brooksMatelski = URL(string: "https://abel.math.harvard.edu/archive/118r_spring_05/handouts/mandelbrot.pdf")!
    private static let carpenter = URL(string: "https://doi.org/10.1145/965105.807478")!
    private static let hutchinson = URL(string: "https://iumj.org/article/2972/")!
    private static let norton = URL(string: "https://dblp.org/rec/conf/siggraph/Norton82")!
    private static let deJong = URL(string: "https://paulbourke.net/fractals/peterdejong/")!
    private static let beautyOfFractals = URL(string: "https://link.springer.com/book/10.1007/978-3-642-61717-1")!
    private static let pickover = URL(string: "https://en.wikipedia.org/wiki/Pickover_stalk")!
    private static let barnesleyIFS = URL(string: "https://people.math.sc.edu/Burkardt/m_src/fern/fern.html")!
    private static let musgrave = URL(string: "https://doi.org/10.1145/74334.74337")!
    private static let buddhabrot = URL(string: "https://en.wikipedia.org/wiki/Buddhabrot")!
    private static let lorenz = URL(string: "https://en.wikipedia.org/wiki/Lorenz_system")!
    private static let mandelbulb = URL(string: "https://en.wikipedia.org/wiki/Mandelbulb")!
    private static let mandelbox = URL(string: "https://en.wikipedia.org/wiki/Mandelbox")!
    private static let distanceFields = URL(string: "https://iquilezles.org/articles/distfunctions/")!

    static let entries: [FractalInfluence] = [
        FractalInfluence(
            id: "cantor",
            pioneer: "Georg Cantor",
            work: "The Cantor Set",
            period: "1883",
            lineage: .foundations,
            summary: "An interval repeatedly loses its middle third, leaving an uncountable dust with no length. It is one of the clearest early demonstrations that infinity can have structure.",
            interpretation: "Sparse chambers, hard intervals, and luminous gaps turn subtraction into architecture.",
            presetName: "Georg Cantor — Dust",
            symbol: "ellipsis",
            accent: .gold,
            sourceBasis: "MacTutor’s Cantor biography covers the 1883 construction, including its uncountability, zero measure, and self-similarity.",
            sourceName: "MacTutor: Georg Cantor biography",
            sourceURL: cantor
        ),
        FractalInfluence(
            id: "weierstrass",
            pioneer: "Karl Weierstrass",
            work: "The Weierstrass Function",
            period: "1872",
            lineage: .foundations,
            summary: "A continuous curve that is nowhere differentiable challenged the assumption that smoothness was hiding inside every continuous form.",
            interpretation: "Fine surface noise refuses to settle into a smooth reading, even as the larger volume remains continuous.",
            presetName: "Karl Weierstrass — Continuum",
            symbol: "waveform.path",
            accent: .ether,
            sourceBasis: "MacTutor’s Weierstrass biography describes the 1872 continuous, nowhere-differentiable example.",
            sourceName: "MacTutor: Karl Weierstrass biography",
            sourceURL: weierstrass
        ),
        FractalInfluence(
            id: "cayley-identity",
            pioneer: "Arthur Cayley",
            work: "The Identity Field",
            period: "1855–1858",
            lineage: .foundations,
            summary: "The identity matrix makes the baseline visible: every point remains where it began. It is the neutral operation against which every other grid transformation can be read.",
            interpretation: "The source and image panels coincide, making correspondence—not spectacle—the first lesson of the Atlas grid.",
            presetName: "Arthur Cayley — Identity Grid",
            symbol: "square.grid.2x2",
            accent: .ether,
            sourceBasis: "MacTutor documents Cayley’s formative matrix work in 1855 and 1858. LibreTexts presents the identity matrix as the transformation that leaves every vector unchanged.",
            sourceName: "LibreTexts: Matrix Transformations",
            sourceURL: matrixTransformations,
            fieldNotes: "Compare the two panels point for point. The unit square, basis vectors, axes, and grid retain their position: this is the control case for every other matrix study.",
            defaultSceneRenderer: .analytic,
            sceneBlueprint: .gridIdentity
        ),
        FractalInfluence(
            id: "cayley-shear",
            pioneer: "Arthur Cayley",
            work: "The Sheared Unit Square",
            period: "1855–1858",
            lineage: .foundations,
            summary: "Matrix multiplication makes a geometric rule precise: the shear matrix sends each point (x, y) to (x + ky, y). A square becomes a parallelogram while its area stays fixed.",
            interpretation: "A split coordinate field keeps the source grid beside its transformed image, so the matrix reads as motion rather than notation.",
            presetName: "Arthur Cayley — Shear Grid",
            symbol: "square.grid.2x2",
            accent: .gold,
            sourceBasis: "MacTutor credits Cayley with founding matrix theory through his early expository papers and his 1855 and 1858 work on matrix algebra. The grid study uses the standard x-direction shear matrix A = [[1, k], [0, 1]].",
            sourceName: "MacTutor: Arthur Cayley biography",
            sourceURL: cayley,
            fieldNotes: "Move the shear control. Vertical grid lines lean because their x-coordinate gains a multiple of y; horizontal lines stay parallel to the x-axis. The unit square follows the same rule and becomes a parallelogram.",
            defaultSceneRenderer: .analytic,
            sceneBlueprint: .gridShear
        ),
        FractalInfluence(
            id: "cayley-rotation",
            pioneer: "Arthur Cayley",
            work: "Rotation About the Origin",
            period: "1855–1858",
            lineage: .foundations,
            summary: "A rotation matrix turns every vector by the same angle around the origin. Length and area persist, but the grid’s alignment with the screen disappears.",
            interpretation: "The paired field makes an abstract cosine-and-sine matrix readable as a rigid turn of the familiar unit square.",
            presetName: "Arthur Cayley — Rotation Grid",
            symbol: "rotate.right",
            accent: .bloom,
            sourceBasis: "MacTutor documents Cayley’s formative matrix work in 1855 and 1858. LibreTexts gives the standard two-dimensional rotation matrix built from sine and cosine.",
            sourceName: "LibreTexts: Matrix Transformations",
            sourceURL: matrixTransformations,
            fieldNotes: "Move the angle control. The colored basis vectors rotate together and the unit square stays a square, revealing a transformation that preserves distance.",
            defaultSceneRenderer: .analytic,
            sceneBlueprint: .gridRotation
        ),
        FractalInfluence(
            id: "cayley-dilation",
            pioneer: "Arthur Cayley",
            work: "Uniform Dilation",
            period: "1855–1858",
            lineage: .foundations,
            summary: "Scalar multiplication enlarges or contracts every direction by the same factor. The geometry stays similar while area changes by the square of that factor.",
            interpretation: "The image panel keeps the same coordinate language while the unit square and grid spacing breathe outward or inward.",
            presetName: "Arthur Cayley — Dilation Grid",
            symbol: "arrow.up.left.and.arrow.down.right",
            accent: .gold,
            sourceBasis: "MacTutor documents Cayley’s formative matrix work in 1855 and 1858. LibreTexts uses diagonal matrices to show uniform scaling in the coordinate plane.",
            sourceName: "LibreTexts: Matrix Transformations",
            sourceURL: matrixTransformations,
            fieldNotes: "Adjust the scale factor. Both basis vectors lengthen by the same amount, so the unit square remains square even as its area changes.",
            defaultSceneRenderer: .analytic,
            sceneBlueprint: .gridDilation
        ),
        FractalInfluence(
            id: "cayley-reflection",
            pioneer: "Arthur Cayley",
            work: "Reflection in the y-Axis",
            period: "1855–1858",
            lineage: .foundations,
            summary: "Reflection reverses one coordinate: points retain their distance from the origin but swap orientation across an axis. Its determinant is negative, announcing the flip.",
            interpretation: "A mirrored grid makes orientation visible—the colored first basis vector crosses the y-axis while the second remains in place.",
            presetName: "Arthur Cayley — Reflection Grid",
            symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
            accent: .ultraviolet,
            sourceBasis: "MacTutor documents Cayley’s formative matrix work in 1855 and 1858. LibreTexts presents reflection matrices as coordinate transformations in the plane.",
            sourceName: "LibreTexts: Matrix Transformations",
            sourceURL: matrixTransformations,
            fieldNotes: "The image has the same shape and area as the source, but its handedness is reversed. The e₁ vector points left; e₂ remains upright.",
            defaultSceneRenderer: .analytic,
            sceneBlueprint: .gridReflection
        ),
        FractalInfluence(
            id: "cayley-projection",
            pioneer: "Arthur Cayley",
            work: "Projection onto the x-Axis",
            period: "1855–1858",
            lineage: .foundations,
            summary: "A projection removes one component of every vector. Here y is sent to zero, so a two-dimensional grid collapses onto a one-dimensional line.",
            interpretation: "The image panel lets the entire coordinate field fold onto its horizontal axis, exposing a transformation that loses information.",
            presetName: "Arthur Cayley — Projection Grid",
            symbol: "arrow.down.to.line.compact",
            accent: .green,
            sourceBasis: "MacTutor documents Cayley’s formative matrix work in 1855 and 1858. LibreTexts introduces matrix transformations and their geometric effects on vectors in the plane.",
            sourceName: "LibreTexts: Matrix Transformations",
            sourceURL: matrixTransformations,
            fieldNotes: "Every vertical coordinate disappears in the image. The second basis vector collapses to the origin, while the first remains as the surviving horizontal direction.",
            defaultSceneRenderer: .analytic,
            sceneBlueprint: .gridProjection
        ),
        FractalInfluence(
            id: "poincare",
            pioneer: "Henri Poincaré",
            work: "Homoclinic Tangles",
            period: "1890",
            lineage: .chaos,
            summary: "Poincaré’s study of dynamical systems exposed trajectories so intricately tangled that they became an early mathematical glimpse of deterministic chaos.",
            interpretation: "A tense, looping field uses animated light and asymmetric folds to suggest an orbit that never repeats.",
            presetName: "Henri Poincaré — Tangle",
            symbol: "scribble.variable",
            accent: .bloom,
            sourceBasis: "MacTutor’s Poincaré biography describes the three-body memoir, homoclinic points, and chaotic motion.",
            sourceName: "MacTutor: Henri Poincaré biography",
            sourceURL: poincare
        ),
        FractalInfluence(
            id: "peano",
            pioneer: "Giuseppe Peano",
            work: "The Peano Curve",
            period: "1890",
            lineage: .recursiveGeometry,
            summary: "The first space-filling curve showed that a one-dimensional path could pass through every point in a two-dimensional region.",
            interpretation: "Dense corridors and nested turns compress the feeling of a vast path into a bounded room.",
            presetName: "Giuseppe Peano — Continuum",
            symbol: "point.bottomleft.forward.to.point.topright.scurvepath",
            accent: .ultraviolet,
            sourceBasis: "MacTutor’s Peano biography records the 1890 space-filling curve and its passage through the unit square.",
            sourceName: "MacTutor: Giuseppe Peano biography",
            sourceURL: peano
        ),
        FractalInfluence(
            id: "hilbert",
            pioneer: "David Hilbert",
            work: "The Hilbert Curve",
            period: "1891",
            lineage: .recursiveGeometry,
            summary: "Hilbert refined the space-filling curve into a recursively ordered path whose local steps build surprising global continuity.",
            interpretation: "Orthogonal folds become an impossible passage with a cool, diagrammatic light.",
            presetName: "David Hilbert — Passage",
            symbol: "arrow.turn.down.right",
            accent: .ether,
            sourceBasis: "The Hilbert-curve entry describes Hilbert’s 1891 recursively defined space-filling curve.",
            sourceName: "Wikipedia: Hilbert curve",
            sourceURL: hilbert
        ),
        FractalInfluence(
            id: "koch",
            pioneer: "Helge von Koch",
            work: "The Koch Curve",
            period: "1904",
            lineage: .recursiveGeometry,
            summary: "A simple segment repeatedly grows triangular teeth; the related Koch snowflake encloses finite area while its perimeter grows without bound.",
            interpretation: "Cold crystalline ridges repeat from monumental shelves down to glittering edges.",
            presetName: "Helge von Koch — Snowline",
            symbol: "snowflake",
            accent: .ether,
            sourceBasis: "The Koch snowflake entry covers the repeated triangular construction and the resulting finite-area, unbounded-perimeter figure.",
            sourceName: "Wikipedia: Koch snowflake",
            sourceURL: koch
        ),
        FractalInfluence(
            id: "sierpinski",
            pioneer: "Wacław Sierpiński",
            work: "Triangle & Carpet",
            period: "1915–1916",
            lineage: .recursiveGeometry,
            summary: "Repeated removal turns ordinary triangles and squares into infinitely perforated structures, balancing strict order with expanding emptiness.",
            interpretation: "Deep voids puncture a hot geometric lattice, making negative space the protagonist.",
            presetName: "Wacław Sierpiński — Void",
            symbol: "triangle",
            accent: .ember,
            sourceBasis: "MacTutor’s Sierpiński biography covers the Sierpiński triangle and carpet and their recursive removal constructions.",
            sourceName: "MacTutor: Wacław Sierpiński biography",
            sourceURL: sierpinski
        ),
        FractalInfluence(
            id: "julia",
            pioneer: "Gaston Julia",
            work: "Julia Sets",
            period: "1918",
            lineage: .complexDynamics,
            summary: "Julia studied how repeated complex functions divide the plane into stable and chaotic behavior. Different constants bloom into connected dendrites or scattered dust.",
            interpretation: "Branching magenta filaments gather around a glowing basin, poised between cohesion and escape.",
            presetName: "Gaston Julia — Dendrite",
            symbol: "tree",
            accent: .bloom,
            sourceBasis: "MacTutor’s Julia biography describes Julia’s iteration of rational functions and the resulting Julia sets.",
            sourceName: "MacTutor: Gaston Julia biography",
            sourceURL: julia
        ),
        FractalInfluence(
            id: "fatou",
            pioneer: "Pierre Fatou",
            work: "Fatou Sets",
            period: "1917–1920",
            lineage: .complexDynamics,
            summary: "Fatou independently developed the foundations of complex iteration, identifying regions where repeated functions behave regularly.",
            interpretation: "A calm cobalt basin sits inside a volatile perimeter, shifting attention from chaos to its stable complement.",
            presetName: "Pierre Fatou — Basin",
            symbol: "circle.hexagongrid",
            accent: .ether,
            sourceBasis: "MacTutor’s Fatou biography describes regular domains under iteration and Fatou’s independent work on iteration theory.",
            sourceName: "MacTutor: Pierre Fatou biography",
            sourceURL: fatou
        ),
        FractalInfluence(
            id: "hausdorff",
            pioneer: "Felix Hausdorff",
            work: "Fractional Dimension",
            period: "1918",
            lineage: .foundations,
            summary: "Hausdorff supplied a rigorous way to describe dimensions beyond whole numbers—the conceptual measuring tool later used throughout fractal geometry.",
            interpretation: "Scale and surface density sit between solid, plane, and line, lit as a dimensional specimen.",
            presetName: "Felix Hausdorff — Dimension",
            symbol: "ruler",
            accent: .gold,
            sourceBasis: "MacTutor’s Hausdorff biography covers Hausdorff measure and dimension as a generalization beyond integer dimensions.",
            sourceName: "MacTutor: Felix Hausdorff biography",
            sourceURL: hausdorff
        ),
        FractalInfluence(
            id: "menger",
            pioneer: "Karl Menger",
            work: "The Menger Sponge",
            period: "1926",
            lineage: .recursiveGeometry,
            summary: "Menger carried Sierpiński’s logic into three dimensions: a cube repeatedly hollowed until its surface grows without bound while its volume approaches zero.",
            interpretation: "Box-fold geometry becomes porous monumentality—an architectural ancestor of the Mandelbox.",
            presetName: "Karl Menger — Sponge",
            symbol: "cube",
            accent: .ultraviolet,
            sourceBasis: "The Menger sponge entry covers the 1926 construction and its zero-volume, infinite-surface limit.",
            sourceName: "Wikipedia: Menger sponge",
            sourceURL: menger
        ),
        FractalInfluence(
            id: "richardson",
            pioneer: "Lewis Fry Richardson",
            work: "The Coastline Paradox",
            period: "1961",
            lineage: .naturalSystems,
            summary: "Richardson observed that a coastline’s measured length grows as the measuring stick becomes smaller, revealing scale-dependent roughness in the natural world.",
            interpretation: "Oceanic ridges keep revealing new coves as the viewer moves closer.",
            presetName: "Lewis Fry Richardson — Coastline",
            symbol: "water.waves",
            accent: .ether,
            sourceBasis: "The coastline paradox entry covers Richardson’s ruler-dependent coastline measurements.",
            sourceName: "Wikipedia: Coastline paradox",
            sourceURL: richardson
        ),
        FractalInfluence(
            id: "lorenz",
            pioneer: "Edward Lorenz",
            work: "The Lorenz Attractor",
            period: "1963",
            lineage: .chaos,
            summary: "A simplified weather model produced a butterfly-shaped strange attractor and made sensitivity to initial conditions tangible.",
            interpretation: "Two glowing lobes trade energy through a pulsing atmospheric hinge.",
            presetName: "Edward Lorenz — Butterfly",
            symbol: "wind",
            accent: .bloom,
            sourceBasis: "The Lorenz-system entry covers the 1963 weather model, butterfly-shaped attractor, and sensitivity to initial conditions.",
            sourceName: "Lorenz system reference",
            sourceURL: lorenz
        ),
        FractalInfluence(
            id: "mandelbrot-coast",
            pioneer: "Benoît Mandelbrot",
            work: "Fractal Geometry",
            period: "1967–1975",
            lineage: .naturalSystems,
            summary: "Mandelbrot connected fractional dimension and statistical self-similarity to rough natural forms such as coastlines and clouds, then coined the term fractal.",
            interpretation: "A grand naturalistic terrain oscillates between geological mass and impossible detail.",
            presetName: "Benoît Mandelbrot — Infinite Coast",
            symbol: "globe.americas.fill",
            accent: .ember,
            sourceBasis: "IBM’s history says Mandelbrot coined the term fractal and applies fractal geometry to clouds and coastlines.",
            sourceName: "IBM history: Benoît Mandelbrot",
            sourceURL: ibmMandelbrot
        ),
        FractalInfluence(
            id: "brooks-matelski",
            pioneer: "Robert Brooks & Peter Matelski",
            work: "First Published Mandelbrot Image",
            period: "1978",
            lineage: .complexDynamics,
            summary: "Their study of Kleinian groups included the first published image of the set that would soon become synonymous with fractal geometry.",
            interpretation: "High-contrast monochrome recalls an early plotter image translated into sculptural depth.",
            presetName: "Brooks & Matelski — First Plot",
            symbol: "printer.dotmatrix",
            accent: .gold,
            sourceBasis: "Harvard’s lecture notes identify Brooks and Matelski’s 1978 paper as the first published image of the Mandelbrot set.",
            sourceName: "Harvard: Mandelbrot set lecture notes",
            sourceURL: brooksMatelski
        ),
        FractalInfluence(
            id: "carpenter",
            pioneer: "Loren Carpenter",
            work: "Vol Libre",
            period: "1980",
            lineage: .computerGraphics,
            summary: "Carpenter used recursive subdivision to create convincing computer-generated mountains, proving fractals could bring natural richness to moving images.",
            interpretation: "Copper light rakes across an endless procedural range suspended in space.",
            presetName: "Loren Carpenter — Terrain",
            symbol: "mountain.2.fill",
            accent: .ember,
            sourceBasis: "The ACM abstract presents simple methods for generating and displaying fractal curves and surfaces through statistical subdivision.",
            sourceName: "ACM: Computer rendering of fractal curves and surfaces",
            sourceURL: carpenter
        ),
        FractalInfluence(
            id: "hutchinson",
            pioneer: "John E. Hutchinson",
            work: "Iterated Function Systems",
            period: "1981",
            lineage: .foundations,
            summary: "Hutchinson formalized how sets of contractive transformations converge on a unique attractor, providing the mathematical spine of IFS fractals.",
            interpretation: "Repeated transformations pull luminous fragments toward a stable central form.",
            presetName: "John Hutchinson — Attractor",
            symbol: "arrow.trianglehead.merge",
            accent: .ultraviolet,
            sourceBasis: "Hutchinson’s 1981 paper formalizes the attractor produced by contractive transformations.",
            sourceName: "Hutchinson, Fractals and Self-Similarity",
            sourceURL: hutchinson
        ),
        FractalInfluence(
            id: "norton",
            pioneer: "Alan Norton",
            work: "Geometric Fractals in 3D",
            period: "1982",
            lineage: .computerGraphics,
            summary: "Norton developed practical methods to generate and display geometric fractals in three dimensions, connecting recursive mathematics to early solid computer imagery.",
            interpretation: "A restrained, shaded solid emphasizes recursive silhouette over spectacle.",
            presetName: "Alan Norton — Geometric Solid",
            symbol: "cube.fill",
            accent: .gold,
            sourceBasis: "The DBLP record identifies Norton’s 1982 SIGGRAPH paper on generating and displaying geometric fractals in 3-D.",
            sourceName: "DBLP: Alan Norton, Generation and display of geometric fractals in 3-D",
            sourceURL: norton
        ),
        FractalInfluence(
            id: "dejong",
            pioneer: "Peter de Jong",
            work: "De Jong Attractors",
            period: "1980s",
            lineage: .chaos,
            summary: "A compact pair of iterative equations became known for producing smoky, symmetric strange attractors from tiny parameter changes.",
            interpretation: "Soft orbit-density glow wraps a dark core like long-exposure particles.",
            presetName: "Peter de Jong — Strange Loop",
            symbol: "atom",
            accent: .bloom,
            sourceBasis: "Paul Bourke’s page gives the de Jong equations and describes the attractors generated by iterating them.",
            sourceName: "Paul Bourke: Peter de Jong attractors",
            sourceURL: deJong,
            fieldNotes: "Nothing here has edges — brightness marks where orbits dwell. The hot magenta cores are dense regions of the map, dispersing into dust-fine speckle where trajectories rarely visit: an attractor read as a long-exposure density image, not a surface."
        ),
        FractalInfluence(
            id: "douady-hubbard",
            pioneer: "Adrien Douady & John H. Hubbard",
            work: "The Connectedness Locus",
            period: "1985",
            lineage: .complexDynamics,
            summary: "Douady and Hubbard established foundational properties of the Mandelbrot set and helped turn its striking images into a rigorous mathematical object.",
            interpretation: "Connected chambers glow along a precise boundary, pairing visual wonder with structural calm.",
            presetName: "Douady & Hubbard — Connected",
            symbol: "link",
            accent: .ether,
            sourceBasis: "The Numdam record identifies Douady and Hubbard’s 1985 paper on polynomial-like mappings, the mathematical work named by this entry.",
            sourceName: "Douady & Hubbard: On the dynamics of polynomial-like mappings",
            sourceURL: douadyHubbard,
            fieldNotes: "The light lives on the boundary: every dark chamber mouth is circled by an exact cyan rim, and the rims chain together without a break. Follow any edge — connectedness made visible as one continuous glowing line between inside and outside."
        ),
        FractalInfluence(
            id: "peitgen-richter",
            pioneer: "Heinz-Otto Peitgen & Peter Richter",
            work: "The Beauty of Fractals",
            period: "1985–1986",
            lineage: .computerGraphics,
            summary: "Their 1986 book, The Beauty of Fractals, presented images of complex dynamical systems alongside rigorous mathematical material.",
            interpretation: "A saturated gallery-piece palette celebrates the moment computation made infinity visible.",
            presetName: "Peitgen & Richter — Beauty",
            symbol: "photo.artframe",
            accent: .bloom,
            sourceBasis: "Springer identifies this as a 1986 book by Peitgen and Richter, subtitled Images of Complex Dynamical Systems.",
            sourceName: "Springer: The Beauty of Fractals",
            sourceURL: beautyOfFractals,
            fieldNotes: "Every dome wears its iteration history as nested rings of color — purple core, magenta halo, teal terraces, orange arcs. Follow any ring inward and you are walking down the iteration count toward the boundary."
        ),
        FractalInfluence(
            id: "pickover",
            pioneer: "Clifford Pickover",
            work: "Biomorphs & Stalks",
            period: "1980s",
            lineage: .computerGraphics,
            summary: "Pickover explored computational forms that appear uncannily biological and introduced orbit-based techniques that reveal hidden structures around complex sets.",
            interpretation: "Acid-green emissive veins make a synthetic organism appear to breathe.",
            presetName: "Clifford Pickover — Biomorph",
            symbol: "microbe.fill",
            accent: .green,
            sourceBasis: "The Pickover-stalk entry covers orbit-trap features and the biomorph-like forms associated with Pickover’s work.",
            sourceName: "Wikipedia: Pickover stalk",
            sourceURL: pickover,
            fieldNotes: "A single acid-green organism hangs off-center in the void: an almond body with a banded interior, a warty rim of cilia along its silhouette, one ringed eye-spot trailing behind. It looks captured rather than composed — the lifelike specimen a convergence test never meant to draw."
        ),
        FractalInfluence(
            id: "barnsley",
            pioneer: "Michael Barnsley",
            work: "The Fractal Fern",
            period: "1988",
            lineage: .naturalSystems,
            summary: "Barnsley showed how a handful of affine transformations and probabilities could grow a remarkably convincing fern.",
            interpretation: "Verdant repeated blades gather into an organic, gently pulsing whole.",
            presetName: "Michael Barnsley — Fern",
            symbol: "leaf.fill",
            accent: .green,
            sourceBasis: "The University of South Carolina page describes the Barnsley fern as an iterated affine mapping and cites Fractals Everywhere (1988).",
            sourceName: "University of South Carolina: Barnsley fractal fern",
            sourceURL: barnesleyIFS,
            fieldNotes: "Find the single oval leaflet, then count its sizes: broad lobes rimming the canopy, sprays of smaller ones fanning upward, rows of ever-tinier copies receding into the dark. Copies of copies of copies — how a handful of contractive transformations grows an entire fern."
        ),
        FractalInfluence(
            id: "musgrave",
            pioneer: "F. Kenton Musgrave",
            work: "Multifractal Terrain",
            period: "1989",
            lineage: .naturalSystems,
            summary: "Musgrave expanded procedural terrain with multifractal models whose roughness changes across a surface, giving digital landscapes geological variety.",
            interpretation: "Layered volcanic relief moves from smooth plateaus to turbulent detail.",
            presetName: "Kenton Musgrave — Multifractal",
            symbol: "mountain.2",
            accent: .ember,
            sourceBasis: "The ACM paper describes local control of frequency, fractal dimension, and statistical characteristics in eroded fractal terrain.",
            sourceName: "ACM SIGGRAPH: The synthesis and rendering of eroded fractal terrains",
            sourceURL: musgrave,
            fieldNotes: "Read the relief patch by patch: smooth volcanic plates sit directly beside shattered, turbulent detail at the same distance. The changing roughness is the visual cue this interpretation borrows from multifractal terrain."
        ),
        FractalInfluence(
            id: "green",
            pioneer: "Melinda Green",
            work: "The Buddhabrot",
            period: "1993",
            lineage: .computerGraphics,
            summary: "Green’s orbit-density rendering exposed ghostly trajectories outside the Mandelbrot set, producing a probabilistic image rather than a conventional escape-time map.",
            interpretation: "Long-exposure nebula light accumulates around a shadowed, meditative center.",
            presetName: "Melinda Green — Buddhabrot",
            symbol: "aqi.medium",
            accent: .gold,
            sourceBasis: "The Buddhabrot entry attributes the 1993 discovery to Melinda Green and describes its orbit-density rendering outside the set.",
            sourceName: "Wikipedia: Buddhabrot",
            sourceURL: buddhabrot,
            fieldNotes: "Nothing here has a surface: the golden mass is an exposure, not an object. Brightness marks where light lingered, dissolving through filament trails into black — the way the Buddhabrot is drawn not as a set but as the accumulated histogram of a million passing orbits."
        ),
        FractalInfluence(
            id: "white-nylander",
            pioneer: "Daniel White & Paul Nylander",
            work: "The Mandelbulb",
            period: "2009",
            lineage: .threeDimensional,
            summary: "Their spherical-coordinate power formula produced the first widely recognized three-dimensional analogue of the Mandelbrot set.",
            interpretation: "A bulbous, baroque mass is lit like a newly discovered celestial body.",
            presetName: "White & Nylander — Bulb",
            symbol: "circle.dotted.circle.fill",
            accent: .bloom,
            sourceBasis: "The Mandelbulb entry covers White and Nylander’s 2009 spherical-coordinate power formula and its three-dimensional analogue.",
            sourceName: "Wikipedia: Mandelbulb",
            sourceURL: mandelbulb,
            fieldNotes: "One rounded body hangs alone in dark space, buds breaking from its equator and dotted froth marking finer growth across the crust. This interpretation treats a Mandelbrot-like idea as a volumetric celestial object: mass first, eruption after."
        ),
        FractalInfluence(
            id: "lowe",
            pioneer: "Tom Lowe",
            work: "The Mandelbox",
            period: "2010",
            lineage: .threeDimensional,
            summary: "Lowe’s box-fold and sphere-fold construction opened a new family of navigable 3D fractals with architectural depth and extraordinary variation.",
            interpretation: "This is Threshold’s native lineage: monumental box folds, recursive vaults, and responsive spatial scale.",
            presetName: "Tom Lowe — Box",
            symbol: "shippingbox.fill",
            accent: .ember,
            sourceBasis: "The Mandelbox entry attributes the box-fold and sphere-fold construction to Tom Lowe in 2010.",
            sourceName: "Wikipedia: Mandelbox",
            sourceURL: mandelbox,
            fieldNotes: "Stand off-axis in the ember vault: box-fold ribs recede as dark chasms while the great sphere-fold port falls from glowing rim into black interior. The same vault repeats at three scales, down to thousands of lit window-pores — architecture you can enter, not a facade."
        ),
        FractalInfluence(
            id: "quilez",
            pioneer: "Inigo Quilez",
            work: "Distance-Field Craft",
            period: "2000s–present",
            lineage: .threeDimensional,
            summary: "Quilez’s distance-function references collect signed-distance primitives, operations, and repetition techniques for describing procedural shapes in real-time rendering.",
            interpretation: "Clean distance-field shading, restrained fog, and high-frequency detail foreground the rendering craft itself.",
            presetName: "Inigo Quilez — Distance Field",
            symbol: "rays",
            accent: .ether,
            sourceBasis: "Quilez’s distance-function reference is the source for the signed-distance primitives, operations, and repetition techniques named here.",
            sourceName: "Distance functions by Inigo Quilez",
            sourceURL: distanceFields,
            fieldNotes: "Watch how light falls across the flanged ring: every drilled edge is crisp, every gradient smooth, nothing sparkles or dithers. The surface reads as machined steel because the distance field is being marched precisely — the noiseless restraint is itself the craft this entry honors."
        )
    ]
}

// MARK: - Atlas Scene Slots

/// Native 2D studies that render inside the Atlas window, rather than through
/// the immersive Mandelbox renderer.
enum AtlasSceneBlueprint: String, Codable, Hashable {
    case gridIdentity
    case gridShear
    case gridRotation
    case gridDilation
    case gridReflection
    case gridProjection
}

enum AtlasSceneStatus: String, Codable, CaseIterable, Identifiable, Hashable {
    case placeholder
    case inProgress
    case populated

    var id: Self { self }

    var displayName: String {
        switch self {
        case .placeholder: return "Placeholder"
        case .inProgress: return "In progress"
        case .populated: return "Populated"
        }
    }

    var detail: String {
        switch self {
        case .placeholder:
            return "The Atlas slot is reserved but has no authored scene yet."
        case .inProgress:
            return "The scene has a design direction but is not ready to render."
        case .populated:
            return "The authored scene is ready for its own renderer integration."
        }
    }
}

/// Renderer families for Atlas scenes. The Atlas editorial entry is deliberately
/// separate from the current Mandelbox distance-estimator preset, because future
/// interpretations may be analytic, parametric, imported, or something else.
enum AtlasSceneRenderer: String, Codable, CaseIterable, Identifiable, Hashable {
    case placeholder
    case distanceEstimator
    case analytic
    case parametric
    case imported

    var id: Self { self }

    var displayName: String {
        switch self {
        case .placeholder: return "Not populated yet"
        case .distanceEstimator: return "Distance estimator"
        case .analytic: return "Analytic / formula"
        case .parametric: return "Parametric / procedural"
        case .imported: return "Imported / media"
        }
    }

    var detail: String {
        switch self {
        case .placeholder:
            return "Reserve the Atlas slot while the scene is being designed."
        case .distanceEstimator:
            return "Use the existing distance-field rendering path."
        case .analytic:
            return "Leave room for a direct mathematical or symbolic renderer."
        case .parametric:
            return "Build the scene from a parameterized geometric system."
        case .imported:
            return "Attach a future image, volume, animation, or authored asset."
        }
    }
}

struct AtlasSceneRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let atlasEntryID: String
    var title: String
    var status: AtlasSceneStatus
    var renderer: AtlasSceneRenderer
    var notes: String
    var modifiedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, atlasEntryID, title, status, renderer, notes, modifiedAt
    }

    init(
        id: UUID,
        atlasEntryID: String,
        title: String,
        status: AtlasSceneStatus,
        renderer: AtlasSceneRenderer,
        notes: String,
        modifiedAt: Date
    ) {
        self.id = id
        self.atlasEntryID = atlasEntryID
        self.title = title
        self.status = status
        self.renderer = renderer
        self.notes = notes
        self.modifiedAt = modifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let renderer = try container.decode(AtlasSceneRenderer.self, forKey: .renderer)

        self.id = try container.decode(UUID.self, forKey: .id)
        self.atlasEntryID = try container.decode(String.self, forKey: .atlasEntryID)
        self.title = try container.decode(String.self, forKey: .title)
        self.status = try container.decodeIfPresent(AtlasSceneStatus.self, forKey: .status)
            ?? (renderer == .placeholder ? .placeholder : .inProgress)
        self.renderer = renderer
        self.notes = try container.decode(String.self, forKey: .notes)
        self.modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
    }

    var isPlaceholder: Bool {
        status != .populated
    }

    static func placeholder(for entry: FractalInfluence) -> AtlasSceneRecord {
        AtlasSceneRecord(
            id: UUID(),
            atlasEntryID: entry.id,
            title: entry.pioneer + " — Atlas Scene",
            status: .placeholder,
            renderer: .placeholder,
            notes: "Reserved for a dedicated interpretation of " + entry.work + ".",
            modifiedAt: Date()
        )
    }
}

/// Persists Atlas scene slots independently from PresetManager and the DE presets.
@MainActor
@Observable
final class AtlasSceneStore {
    private(set) var scenes: [AtlasSceneRecord] = []

    private var fileURL: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("atlas_scenes.json")
    }

    init() {
        load()
    }

    func scene(for atlasEntryID: String) -> AtlasSceneRecord? {
        scenes.first(where: { $0.atlasEntryID == atlasEntryID })
    }

    func upsert(_ scene: AtlasSceneRecord) {
        if let index = scenes.firstIndex(where: { $0.atlasEntryID == scene.atlasEntryID }) {
            scenes[index] = scene
        } else {
            scenes.append(scene)
        }
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            scenes = try decoder.decode([AtlasSceneRecord].self, from: data)
        } catch {
            print("⚠️ Failed to load Atlas scenes: \(error)")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(scenes).write(to: fileURL, options: .atomic)
        } catch {
            print("⚠️ Failed to save Atlas scenes: \(error)")
        }
    }
}

// MARK: - Atlas Experience

struct FractalAtlasView: View {
    @Environment(AppModel.self) private var appModel

    @State private var selectedID = FractalAtlas.entries.first?.id ?? ""
    @State private var query = ""
    @State private var selectedLineage: FractalLineage?

    private var filteredEntries: [FractalInfluence] {
        FractalAtlas.entries.filter { entry in
            let matchesLineage = selectedLineage == nil || entry.lineage == selectedLineage
            let matchesQuery = query.isEmpty
                || entry.pioneer.localizedCaseInsensitiveContains(query)
                || entry.work.localizedCaseInsensitiveContains(query)
                || entry.lineage.rawValue.localizedCaseInsensitiveContains(query)
                || entry.summary.localizedCaseInsensitiveContains(query)
                || entry.interpretation.localizedCaseInsensitiveContains(query)
            return matchesLineage && matchesQuery
        }
    }

    private var selectedEntry: FractalInfluence? {
        filteredEntries.first(where: { $0.id == selectedID }) ?? filteredEntries.first
    }

    var body: some View {
        ZStack {
            ThresholdFieldBackground()

            VStack(spacing: 18) {
                atlasHeader
                lineageFilters

                HStack(spacing: 18) {
                    atlasIndex
                        .frame(width: 350)

                    if let selectedEntry {
                        FractalInfluenceDetail(
                            entry: selectedEntry,
                            appModel: appModel
                        )
                        .id(selectedEntry.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    }
                }
            }
            .padding(28)
        }
        .frame(minWidth: 980, minHeight: 680)
        .onChange(of: query) { _, _ in
            selectFirstVisibleEntry()
        }
        .onChange(of: selectedLineage) { _, _ in
            selectFirstVisibleEntry()
        }
        .textSelection(.enabled)
    }

    private var atlasHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            ThresholdBrandLockup()

            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: 1, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("THE FRACTAL ATLAS")
                    .font(.headline)
                    .fontWeight(.bold)
                    .tracking(1.4)
                Text("Ideas that taught infinity how to take shape.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(FractalAtlas.entries.count) STUDIES")
                .font(.caption)
                .fontWeight(.bold)
                .tracking(1.3)
                .foregroundStyle(ThresholdBrand.ether)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(ThresholdBrand.ether.opacity(0.1), in: Capsule())
        }
    }

    private var lineageFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                lineageButton(title: "All", symbol: "sparkles", lineage: nil)

                ForEach(FractalLineage.allCases, id: \.self) { lineage in
                    lineageButton(
                        title: lineage.rawValue,
                        symbol: lineage.symbol,
                        lineage: lineage
                    )
                }
            }
        }
    }

    private func lineageButton(
        title: String,
        symbol: String,
        lineage: FractalLineage?
    ) -> some View {
        let isSelected = selectedLineage == lineage

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedLineage = lineage
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    isSelected ? ThresholdBrand.bloom.opacity(0.22) : .white.opacity(0.055),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(
                            isSelected ? ThresholdBrand.bloom.opacity(0.75) : .white.opacity(0.1),
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
    }

    private var atlasIndex: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search people, works, ideas", text: $query)
                    .textFieldStyle(.plain)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))

            ScrollView {
                LazyVStack(spacing: 8) {
                    if filteredEntries.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .padding(.top, 80)
                    } else {
                        ForEach(filteredEntries) { entry in
                            FractalInfluenceRow(
                                entry: entry,
                                isSelected: selectedEntry?.id == entry.id,
                                sceneStatus: sceneStatus(for: entry)
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedID = entry.id
                                }
                            }
                        }
                    }
                }
            }
            .contentMargins(.vertical, 2)

            HStack {
                Text(
                    filteredEntries.count == FractalAtlas.entries.count
                        ? "ALL \(FractalAtlas.entries.count) STUDIES"
                        : "SHOWING \(filteredEntries.count) OF \(FractalAtlas.entries.count)"
                )
                .font(.caption2)
                .fontWeight(.bold)
                .tracking(1.1)
                .foregroundStyle(.secondary)

                Spacer()

                if selectedLineage != nil || !query.isEmpty {
                    Button("Clear filters") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedLineage = nil
                            query = ""
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(ThresholdBrand.ether)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .background(.black.opacity(0.19), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
    }

    private func selectFirstVisibleEntry() {
        if !filteredEntries.contains(where: { $0.id == selectedID }) {
            selectedID = filteredEntries.first?.id ?? ""
        }
    }

    private func sceneStatus(for entry: FractalInfluence) -> AtlasSceneStatus {
        if let scene = appModel.atlasSceneStore.scene(for: entry.id) {
            return scene.status
        }
        return entry.sceneBlueprint == nil ? .placeholder : .populated
    }
}

private struct FractalInfluenceRow: View {
    let entry: FractalInfluence
    let isSelected: Bool
    let sceneStatus: AtlasSceneStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: entry.symbol)
                    .font(.headline)
                    .foregroundStyle(entry.accent.color)
                    .frame(width: 34, height: 34)
                    .background(entry.accent.color.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.pioneer)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(entry.work)
                            .lineLimit(1)
                        Text("·")
                        Text(entry.period)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if sceneStatus != .populated {
                    Label(sceneStatus.displayName, systemImage: "rectangle.dashed")
                        .font(.caption2)
                        .foregroundStyle(entry.accent.color.opacity(0.8))
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(
                        isSelected ? entry.accent.color : Color.white.opacity(0.28)
                    )
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .background(
                isSelected ? entry.accent.color.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isSelected ? entry.accent.color.opacity(0.5) : .clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Open the \(entry.work) interpretation")
    }
}

// MARK: - Native Atlas Grid Studies

/// A small, reusable 2D rendering surface for mathematical studies. It never
/// reaches the immersive renderer: the Atlas owns its own grid-space visuals.
private struct AtlasGridTransformationScene: View {
    let blueprint: AtlasSceneBlueprint
    let accent: Color

    @State private var parameter: Double

    init(blueprint: AtlasSceneBlueprint, accent: Color) {
        self.blueprint = blueprint
        self.accent = accent
        _parameter = State(initialValue: blueprint.defaultParameter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("GRID TRANSFORMATION STUDY")
                        .atlasEyebrow(color: accent)
                    Text(blueprint.canvasTitle)
                        .font(.headline)
                        .fontWeight(.semibold)
                }

                Spacer()

                Text("ANALYTIC CANVAS")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .tracking(1.0)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("SOURCE SPACE")
                Spacer()
                Text("IMAGE SPACE")
            }
            .font(.caption2)
            .fontWeight(.bold)
            .tracking(1.0)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)

            AtlasGridTransformationCanvas(
                transform: blueprint.matrix(parameter: parameter),
                accent: accent
            )
            .frame(height: 270)

            VStack(alignment: .leading, spacing: 6) {
                if blueprint.hasInteractiveControl {
                    HStack {
                        Text(blueprint.parameterLabel)
                        Spacer()
                        Text(blueprint.parameterValue(parameter))
                            .monospacedDigit()
                            .foregroundStyle(accent)
                    }
                    .font(.caption)

                    Slider(
                        value: $parameter,
                        in: blueprint.parameterRange,
                        step: blueprint.parameterStep
                    )
                    .tint(accent)
                } else {
                    Text("FIXED TRANSFORMATION")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .tracking(1.0)
                        .foregroundStyle(.secondary)
                }

                Text(blueprint.matrixNotation(parameter: parameter))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(accent.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(blueprint.canvasTitle) grid transformation. The source grid and unit square are shown beside their transformed image.")
    }
}

private struct AtlasMatrix2D {
    let a: CGFloat
    let b: CGFloat
    let c: CGFloat
    let d: CGFloat

    static let identity = AtlasMatrix2D(a: 1, b: 0, c: 0, d: 1)

    func applying(x: CGFloat, y: CGFloat) -> (x: CGFloat, y: CGFloat) {
        (a * x + b * y, c * x + d * y)
    }
}

private extension AtlasSceneBlueprint {
    var canvasTitle: String {
        switch self {
        case .gridIdentity: return "Identity"
        case .gridShear: return "Shear"
        case .gridRotation: return "Rotation"
        case .gridDilation: return "Uniform Dilation"
        case .gridReflection: return "Reflection in the y-Axis"
        case .gridProjection: return "Projection onto the x-Axis"
        }
    }

    var defaultParameter: Double {
        switch self {
        case .gridShear: return 0.75
        case .gridRotation: return 32
        case .gridDilation: return 1.28
        case .gridIdentity, .gridReflection, .gridProjection: return 0
        }
    }

    var hasInteractiveControl: Bool {
        switch self {
        case .gridShear, .gridRotation, .gridDilation: return true
        case .gridIdentity, .gridReflection, .gridProjection: return false
        }
    }

    var parameterLabel: String {
        switch self {
        case .gridShear: return "Shear k"
        case .gridRotation: return "Angle θ"
        case .gridDilation: return "Scale s"
        case .gridIdentity, .gridReflection, .gridProjection: return ""
        }
    }

    var parameterRange: ClosedRange<Double> {
        switch self {
        case .gridShear: return -1.5...1.5
        case .gridRotation: return -90...90
        case .gridDilation: return 0.35...1.6
        case .gridIdentity, .gridReflection, .gridProjection: return 0...1
        }
    }

    var parameterStep: Double {
        switch self {
        case .gridRotation: return 1
        case .gridShear, .gridDilation: return 0.05
        case .gridIdentity, .gridReflection, .gridProjection: return 1
        }
    }

    func parameterValue(_ parameter: Double) -> String {
        switch self {
        case .gridRotation: return "\(Int(parameter.rounded()))°"
        case .gridDilation: return parameter.formatted(.number.precision(.fractionLength(2))) + "×"
        case .gridShear: return parameter.formatted(.number.precision(.fractionLength(2)))
        case .gridIdentity, .gridReflection, .gridProjection: return ""
        }
    }

    func matrix(parameter: Double) -> AtlasMatrix2D {
        switch self {
        case .gridIdentity:
            return .identity
        case .gridShear:
            return AtlasMatrix2D(a: 1, b: CGFloat(parameter), c: 0, d: 1)
        case .gridRotation:
            let radians = CGFloat(parameter * .pi / 180)
            return AtlasMatrix2D(
                a: cos(radians), b: -sin(radians),
                c: sin(radians), d: cos(radians)
            )
        case .gridDilation:
            let scale = CGFloat(parameter)
            return AtlasMatrix2D(a: scale, b: 0, c: 0, d: scale)
        case .gridReflection:
            return AtlasMatrix2D(a: -1, b: 0, c: 0, d: 1)
        case .gridProjection:
            return AtlasMatrix2D(a: 1, b: 0, c: 0, d: 0)
        }
    }

    func matrixNotation(parameter: Double) -> String {
        switch self {
        case .gridIdentity:
            return "A = [ 1  0 ]    T(x, y) = (x, y)\n    [ 0  1 ]"
        case .gridShear:
            return "Aₖ = [ 1  k ]    T(x, y) = (x + ky, y)\n     [ 0  1 ]"
        case .gridRotation:
            return "Aθ = [ cos θ  −sin θ ]    θ = \(Int(parameter.rounded()))°\n     [ sin θ   cos θ ]"
        case .gridDilation:
            return "Aₛ = [ s  0 ]    T(x, y) = (sx, sy)\n     [ 0  s ]"
        case .gridReflection:
            return "A = [ −1  0 ]    T(x, y) = (−x, y)\n    [  0  1 ]"
        case .gridProjection:
            return "P = [ 1  0 ]    T(x, y) = (x, 0)\n    [ 0  0 ]"
        }
    }
}

private struct AtlasGridTransformationCanvas: View {
    let transform: AtlasMatrix2D
    let accent: Color

    var body: some View {
        Canvas { context, size in
            var context = context
            let outerInset: CGFloat = 2
            let gap: CGFloat = 18
            let panelWidth = max(1, (size.width - outerInset * 2 - gap) / 2)
            let panelHeight = max(1, size.height - outerInset * 2)
            let sourceRect = CGRect(x: outerInset, y: outerInset, width: panelWidth, height: panelHeight)
            let imageRect = CGRect(x: sourceRect.maxX + gap, y: outerInset, width: panelWidth, height: panelHeight)

            drawPanel(context: &context, rect: sourceRect, accent: accent)
            drawPanel(context: &context, rect: imageRect, accent: accent)
            drawGrid(context: &context, rect: sourceRect, transform: .identity, accent: accent)
            drawGrid(context: &context, rect: imageRect, transform: transform, accent: accent)
            drawUnitSquare(context: &context, rect: sourceRect, transform: .identity, accent: accent)
            drawUnitSquare(context: &context, rect: imageRect, transform: transform, accent: accent)
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }

    private func drawPanel(context: inout GraphicsContext, rect: CGRect, accent: Color) {
        context.fill(
            Path(roundedRect: rect, cornerRadius: 12),
            with: .color(.black.opacity(0.24))
        )
        context.stroke(
            Path(roundedRect: rect, cornerRadius: 12),
            with: .color(accent.opacity(0.16)),
            lineWidth: 1
        )
    }

    private func drawGrid(context: inout GraphicsContext, rect: CGRect, transform: AtlasMatrix2D, accent: Color) {
        var clippedContext = context
        clippedContext.clip(to: Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 11))

        for coordinate in -4...4 {
            let value = CGFloat(coordinate)
            let isAxis = coordinate == 0
            let style = isAxis ? Color.white.opacity(0.70) : Color.white.opacity(0.12)
            let width: CGFloat = isAxis ? 1.25 : 0.55

            var vertical = Path()
            vertical.move(to: gridPoint(x: value, y: -4, in: rect, transform: transform))
            vertical.addLine(to: gridPoint(x: value, y: 4, in: rect, transform: transform))
            clippedContext.stroke(vertical, with: .color(style), lineWidth: width)

            var horizontal = Path()
            horizontal.move(to: gridPoint(x: -4, y: value, in: rect, transform: transform))
            horizontal.addLine(to: gridPoint(x: 4, y: value, in: rect, transform: transform))
            clippedContext.stroke(horizontal, with: .color(style), lineWidth: width)
        }

        let origin = gridPoint(x: 0, y: 0, in: rect, transform: transform)
        let e1 = gridPoint(x: 1, y: 0, in: rect, transform: transform)
        let e2 = gridPoint(x: 0, y: 1, in: rect, transform: transform)
        drawVector(context: &clippedContext, from: origin, to: e1, color: accent)
        drawVector(context: &clippedContext, from: origin, to: e2, color: ThresholdBrand.bloom)
    }

    private func drawUnitSquare(context: inout GraphicsContext, rect: CGRect, transform: AtlasMatrix2D, accent: Color) {
        let corners: [(CGFloat, CGFloat)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
        var square = Path()
        square.move(to: gridPoint(x: corners[0].0, y: corners[0].1, in: rect, transform: transform))
        for corner in corners.dropFirst() {
            square.addLine(to: gridPoint(x: corner.0, y: corner.1, in: rect, transform: transform))
        }
        square.closeSubpath()

        context.fill(square, with: .color(accent.opacity(0.28)))
        context.stroke(square, with: .color(accent.opacity(0.95)), lineWidth: 2)
    }

    private func drawVector(context: inout GraphicsContext, from origin: CGPoint, to endpoint: CGPoint, color: Color) {
        var vector = Path()
        vector.move(to: origin)
        vector.addLine(to: endpoint)
        context.stroke(vector, with: .color(color.opacity(0.92)), lineWidth: 2.2)
        context.fill(
            Path(ellipseIn: CGRect(x: endpoint.x - 3.5, y: endpoint.y - 3.5, width: 7, height: 7)),
            with: .color(color)
        )
    }

    private func gridPoint(x: CGFloat, y: CGFloat, in rect: CGRect, transform: AtlasMatrix2D) -> CGPoint {
        let transformed = transform.applying(x: x, y: y)
        let scale = min(rect.width, rect.height) / 8.8
        return CGPoint(
            x: rect.midX + transformed.x * scale,
            y: rect.midY - transformed.y * scale
        )
    }
}

private struct FractalInfluenceDetail: View {
    let entry: FractalInfluence
    @Bindable var appModel: AppModel

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    @State private var didLoadExperience = false
    @State private var isOpeningImmersiveSpace = false
    @State private var showingSceneWorkshop = false

    private var preset: FractalPreset? {
        guard entry.defaultSceneRenderer == .distanceEstimator else { return nil }
        return appModel.presetManager.presets.first(where: { $0.name == entry.presetName })
    }

    private var atlasScene: AtlasSceneRecord? {
        appModel.atlasSceneStore.scene(for: entry.id)
    }

    private var resolvedSceneStatus: AtlasSceneStatus {
        atlasScene?.status ?? (entry.sceneBlueprint == nil ? .placeholder : .populated)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero

                atlasSceneSlot

                if let blueprint = entry.sceneBlueprint {
                    AtlasGridTransformationScene(blueprint: blueprint, accent: entry.accent.color)
                }

                if entry.defaultSceneRenderer == .distanceEstimator && preset == nil {
                    renderableExperiencePlaceholder
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("THE IDEA")
                        .atlasEyebrow(color: entry.accent.color)
                    Text(entry.summary)
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("THRESHOLD INTERPRETATION")
                        .atlasEyebrow(color: ThresholdBrand.ether)
                    Text(entry.interpretation)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !entry.fieldNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("READING THE FORM")
                            .atlasEyebrow(color: entry.accent.color)
                        Text(entry.fieldNotes)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()
                    .overlay(.white.opacity(0.12))

                HStack(spacing: 12) {
                    if entry.defaultSceneRenderer == .distanceEstimator {
                        Button {
                            loadExperience()
                        } label: {
                            Label(
                                preset == nil
                                    ? "Scene Placeholder"
                                    : (didLoadExperience ? "Experience Loaded" : "Load Experience"),
                                systemImage: didLoadExperience ? "checkmark.circle.fill" : "viewfinder"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(entry.accent.color)
                        .disabled(preset == nil)
                    } else {
                        Label("Rendered in the Atlas canvas", systemImage: "square.grid.2x2")
                            .font(.caption)
                            .foregroundStyle(entry.accent.color)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(entry.accent.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    }

                    Link(destination: entry.sourceURL) {
                        Label("Source", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.bordered)
                }

                if didLoadExperience {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(
                            appModel.immersiveSpaceState == .open
                                ? "The interpretation is now live in the immersive field."
                                : "The interpretation is ready to enter the immersive field."
                        )
                        .font(.caption)
                        .foregroundStyle(ThresholdBrand.ether)

                        if appModel.immersiveSpaceState != .open {
                            Button {
                                enterImmersiveSpace()
                            } label: {
                                Label(
                                    isOpeningImmersiveSpace ? "Entering…" : "Enter Immersive Space",
                                    systemImage: "visionpro"
                                )
                            }
                            .buttonStyle(.bordered)
                            .tint(ThresholdBrand.ether)
                            .disabled(isOpeningImmersiveSpace || appModel.immersiveSpaceState == .inTransition)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("SOURCE / CLAIM SCOPE")
                        .atlasEyebrow(color: entry.accent.color)

                    Text("The Idea is a paraphrase of the linked source. Threshold Interpretation and Reading the Form are original editorial descriptions of this app’s rendering, not historical claims about the source.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(entry.sourceBasis)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Link(destination: entry.sourceURL) {
                        Label("Read \(entry.sourceName) in context", systemImage: "book.closed")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }

                Text(
                    entry.defaultSceneRenderer == .distanceEstimator
                        ? "Atlas experiences are native Mandelbox interpretations of each lineage—not exact simulations of the original formulae."
                        : "This study renders as a native Atlas canvas, independently of the immersive Mandelbox renderer."
                )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(24)
        }
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.2), value: didLoadExperience)
        .sheet(isPresented: $showingSceneWorkshop) {
            AtlasSceneWorkshopView(
                entry: entry,
                store: appModel.atlasSceneStore
            )
        }
    }

    private var atlasSceneSlot: some View {
        let status = resolvedSceneStatus
        let isPlaceholder = status != .populated

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    isPlaceholder ? "SCENE PLACEHOLDER" : "ATLAS SCENE",
                    systemImage: isPlaceholder ? "rectangle.dashed" : "rectangle.3.group"
                )
                .atlasEyebrow(color: entry.accent.color)

                Spacer()

                Text(status.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let atlasScene {
                Text("Renderer family: \(atlasScene.renderer.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if entry.sceneBlueprint != nil {
                Text("Renderer family: \(entry.defaultSceneRenderer.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text("Atlas scenes can use a formula, a parametric system, imported media, or the existing DE path.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button {
                showingSceneWorkshop = true
            } label: {
                Label(
                    atlasScene == nil && entry.sceneBlueprint == nil
                        ? "Create Atlas Scene"
                        : "Open Scene Workshop",
                    systemImage: "slider.horizontal.3"
                )
            }
            .buttonStyle(.bordered)
            .tint(entry.accent.color)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(entry.accent.color.opacity(isPlaceholder ? 0.08 : 0.12), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    entry.accent.color.opacity(0.28),
                    style: StrokeStyle(lineWidth: 1, dash: isPlaceholder ? [6, 5] : [])
                )
        }
    }

    private var renderableExperiencePlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("RENDERABLE EXPERIENCE PLACEHOLDER", systemImage: "viewfinder")
                .atlasEyebrow(color: entry.accent.color)

            Text("The current distance-estimator preset for this entry is unavailable. The Atlas scene slot remains independent and can use another renderer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    entry.accent.color.opacity(0.42),
                    ThresholdBrand.ultraviolet.opacity(0.18),
                    .black.opacity(0.2)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .stroke(entry.accent.color.opacity(0.2), lineWidth: 34)
                .frame(width: 250, height: 250)
                .offset(x: 330, y: -70)

            Image(systemName: entry.symbol)
                .font(.system(size: 112, weight: .ultraLight))
                .foregroundStyle(entry.accent.color.opacity(0.15))
                .offset(x: 420, y: -44)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(entry.lineage.rawValue.uppercased(), systemImage: entry.lineage.symbol)
                    Text("·")
                    Text(entry.period)
                }
                .font(.caption)
                .fontWeight(.bold)
                .tracking(1.2)
                .foregroundStyle(entry.accent.color)

                Text(entry.pioneer)
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .minimumScaleFactor(0.72)
                    .lineLimit(2)

                Text(entry.work)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(24)
        }
        .frame(minHeight: 230)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(entry.accent.color.opacity(0.25), lineWidth: 1)
        }
    }

    private func loadExperience() {
        guard let preset else { return }

        Task {
            await appModel.preparePipelineHandler?(preset)
        }
        // Through the manager, so the atlas entry this scene came from is on
        // record if the viewer goes on to build something from it.
        appModel.presetManager.loadPreset(preset, into: appModel.renderSettings)
        appModel.gestureController?.syncWithSettings()

        withAnimation {
            didLoadExperience = true
        }
    }

    private func enterImmersiveSpace() {
        guard appModel.immersiveSpaceState == .closed else { return }

        isOpeningImmersiveSpace = true
        appModel.immersiveSpaceState = .inTransition

        Task { @MainActor in
            switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
            case .opened:
                // The compositor updates the state to .open from its lifecycle callback.
                break
            case .userCancelled, .error:
                appModel.immersiveSpaceState = .closed
            @unknown default:
                appModel.immersiveSpaceState = .closed
            }

            isOpeningImmersiveSpace = false
        }
    }
}

private struct AtlasSceneWorkshopView: View {
    let entry: FractalInfluence
    let store: AtlasSceneStore

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AtlasSceneRecord

    init(entry: FractalInfluence, store: AtlasSceneStore) {
        self.entry = entry
        self.store = store
        _draft = State(initialValue: store.scene(for: entry.id) ?? .placeholder(for: entry))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Atlas Entry") {
                    Text(entry.pioneer)
                        .font(.headline)
                    Text(entry.work)
                        .foregroundStyle(.secondary)
                }

                Section("Scene Slot") {
                    TextField("Scene title", text: $draft.title)

                    Picker("Scene status", selection: $draft.status) {
                        ForEach(AtlasSceneStatus.allCases) { status in
                            Text(status.displayName)
                                .tag(status)
                        }
                    }

                    Text(draft.status.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Renderer family", selection: $draft.renderer) {
                        ForEach(AtlasSceneRenderer.allCases) { renderer in
                            Text(renderer.displayName)
                                .tag(renderer)
                        }
                    }

                    Text(draft.renderer.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: $draft.notes)
                        .frame(minHeight: 120)
                } header: {
                    Text("Scene Notes")
                } footer: {
                    Text("These notes and the renderer choice belong to the Atlas scene slot, not to the distance-estimator preset.")
                }
            }
            .navigationTitle("Atlas Scene Workshop")
            .textSelection(.enabled)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Scene Slot") {
                        draft.modifiedAt = Date()
                        store.upsert(draft)
                        dismiss()
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private extension View {
    func atlasEyebrow(color: Color) -> some View {
        self
            .font(.caption)
            .fontWeight(.black)
            .tracking(1.5)
            .foregroundStyle(color)
    }
}
