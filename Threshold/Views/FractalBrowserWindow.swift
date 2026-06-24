import SwiftUI

struct FractalVariant: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let formulaOverrides: [(Int, Float)]
    var targetFractalScale: Float?
    var externalURL: String?

    static func == (lhs: FractalVariant, rhs: FractalVariant) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.summary == rhs.summary &&
        lhs.targetFractalScale == rhs.targetFractalScale &&
        lhs.externalURL == rhs.externalURL &&
        lhs.formulaOverrides.count == rhs.formulaOverrides.count &&
        zip(lhs.formulaOverrides, rhs.formulaOverrides).allSatisfy { left, right in
            left.0 == right.0 && left.1 == right.1
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(summary)
        hasher.combine(targetFractalScale)
        hasher.combine(externalURL)
        hasher.combine(formulaOverrides.count)
        for (index, value) in formulaOverrides {
            hasher.combine(index)
            hasher.combine(value)
        }
    }
}

struct FractalTypeBrowserInfo: Identifiable, Hashable {
    let id: String
    let type: FractalModelType?
    let title: String
    let icon: String
    let subtitle: String
    let historicalInfo: String
    let variants: [FractalVariant]
    var externalReferenceURL: String?

    init(
        type: FractalModelType,
        subtitle: String,
        historicalInfo: String,
        variants: [FractalVariant],
        externalReferenceURL: String? = nil
    ) {
        self.id = "native-\(type.rawValue)"
        self.type = type
        self.title = type.displayName
        self.icon = type.icon
        self.subtitle = subtitle
        self.historicalInfo = historicalInfo
        self.variants = variants
        self.externalReferenceURL = externalReferenceURL
    }

    init(
        id: String,
        title: String,
        icon: String,
        subtitle: String,
        historicalInfo: String,
        variants: [FractalVariant],
        externalReferenceURL: String
    ) {
        self.id = id
        self.type = nil
        self.title = title
        self.icon = icon
        self.subtitle = subtitle
        self.historicalInfo = historicalInfo
        self.variants = variants
        self.externalReferenceURL = externalReferenceURL
    }
}

struct FractalFamilyInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let historicalInfo: String
    let types: [FractalTypeBrowserInfo]
}

enum FractalBrowserCatalog {
    private struct CatalogOverride: Decodable {
        struct Family: Decodable {
            struct TypeInfo: Decodable {
                struct VariantOverride: Decodable {
                    let index: Int
                    let value: Float
                }

                struct Variant: Decodable {
                    let id: String
                    let name: String
                    let summary: String
                    let formulaOverrides: [VariantOverride]?
                    let targetFractalScale: Float?
                    let externalURL: String?
                }

                let id: String
                let title: String
                let icon: String
                let fractalTypeRawValue: Int32?
                let subtitle: String
                let historicalInfo: String
                let variants: [Variant]
                let externalReferenceURL: String?
            }

            let id: String
            let name: String
            let summary: String
            let historicalInfo: String
            let types: [TypeInfo]
        }

        let families: [Family]
    }

    static var families: [FractalFamilyInfo] {
        mergeFamilies(base: builtInFamilies, overrides: loadedFamilies)
            .compactMap { family in
                let filteredTypes = family.types
                guard !filteredTypes.isEmpty else { return nil }
                return FractalFamilyInfo(
                    id: family.id,
                    name: family.name,
                    summary: family.summary,
                    historicalInfo: family.historicalInfo,
                    types: filteredTypes
                )
            }
    }

    private static func mergeFamilies(base: [FractalFamilyInfo], overrides: [FractalFamilyInfo]?) -> [FractalFamilyInfo] {
        guard let overrides, !overrides.isEmpty else { return base }

        var mergedByID: [String: FractalFamilyInfo] = [:]
        for family in base {
            mergedByID[family.id] = family
        }
        for family in overrides {
            mergedByID[family.id] = family
        }

        // Preserve built-in ordering first, then append brand-new override families.
        var ordered: [FractalFamilyInfo] = []
        for family in base {
            if let merged = mergedByID.removeValue(forKey: family.id) {
                ordered.append(merged)
            }
        }
        for family in overrides where mergedByID[family.id] != nil {
            if let merged = mergedByID.removeValue(forKey: family.id) {
                ordered.append(merged)
            }
        }
        return ordered
    }

    private static let loadedFamilies: [FractalFamilyInfo]? = {
        guard let url = Bundle.main.url(forResource: "fractal_browser_catalog", withExtension: "json", subdirectory: "Formulas") ??
                        Bundle.main.url(forResource: "fractal_browser_catalog", withExtension: "json") else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let override = try JSONDecoder().decode(CatalogOverride.self, from: data)
            return override.families.map { family in
                let mappedTypes: [FractalTypeBrowserInfo] = family.types.map { typeInfo in
                    let variants = typeInfo.variants.map { variant in
                        FractalVariant(
                            id: variant.id,
                            name: variant.name,
                            summary: variant.summary,
                            formulaOverrides: (variant.formulaOverrides ?? []).map { ($0.index, $0.value) },
                            targetFractalScale: variant.targetFractalScale,
                            externalURL: variant.externalURL
                        )
                    }

                    if let raw = typeInfo.fractalTypeRawValue,
                       let type = FractalModelType(rawValue: raw) {
                        return FractalTypeBrowserInfo(
                            type: type,
                            subtitle: typeInfo.subtitle,
                            historicalInfo: typeInfo.historicalInfo,
                            variants: variants,
                            externalReferenceURL: typeInfo.externalReferenceURL
                        )
                    }

                    return FractalTypeBrowserInfo(
                        id: typeInfo.id,
                        title: typeInfo.title,
                        icon: typeInfo.icon,
                        subtitle: typeInfo.subtitle,
                        historicalInfo: typeInfo.historicalInfo,
                        variants: variants,
                        externalReferenceURL: typeInfo.externalReferenceURL ?? "https://github.com/scottdraves/flam3"
                    )
                }

                return FractalFamilyInfo(
                    id: family.id,
                    name: family.name,
                    summary: family.summary,
                    historicalInfo: family.historicalInfo,
                    types: mappedTypes
                )
            }
        } catch {
            print("[FractalBrowserCatalog] Failed to load fractal_browser_catalog.json: \(error)")
            return nil
        }
    }()

    private static let builtInFamilies: [FractalFamilyInfo] = [
        FractalFamilyInfo(
            id: "box",
            name: "Box Folds",
            summary: "Fold/inversion systems inspired by Mandelbox-style transforms.",
            historicalInfo: "Box-fold fractals grew out of Tom Lowe’s Mandelbox work (2010), extending escape-time ideas with geometric folds and sphere inversions.",
            types: [
                FractalTypeBrowserInfo(
                    type: .mandelbox,
                    subtitle: "Classic fold + sphere inversion structure",
                    historicalInfo: "Mandelbox popularized rich 3D detail with simple fold rules and became a cornerstone of raymarched fractal art.",
                    variants: [
                        FractalVariant(
                            id: "mandelbox-classic",
                            name: "Classic",
                            summary: "Balanced fold shape with stable interior cavities.",
                            formulaOverrides: [(0, 0.8), (1, 1.0), (2, 0.5)],
                            targetFractalScale: 2.8
                        ),
                        FractalVariant(
                            id: "mandelbox-cavern",
                            name: "Cavernous",
                            summary: "Larger fold radius and softer shell for cave-like spaces.",
                            formulaOverrides: [(0, 0.6), (1, 1.35), (2, 0.72)],
                            targetFractalScale: 2.5
                        )
                    ]
                ),
                FractalTypeBrowserInfo(
                    type: .mandelboxSphereProjection,
                    subtitle: "Mandelbox with post-fold spherical projection",
                    historicalInfo: "A production accident yielded a compelling sphere-projected Mandelbox silhouette; halopend shaped the behavior into this controllable formula variant.",
                    variants: []
                )
            ]
        ),
        FractalFamilyInfo(
            id: "power",
            name: "Power / Quaternion",
            summary: "Escape-time power maps and higher-dimensional analogs.",
            historicalInfo: "Power-based 3D fractals evolved from attempts to generalize the Mandelbrot set to 3D spherical coordinates and quaternion spaces.",
            types: [
                FractalTypeBrowserInfo(
                    type: .mandelbulb,
                    subtitle: "3D Mandelbrot-style power fractal",
                    historicalInfo: "The Mandelbulb (c. 2009) became the de facto 3D analog to the Mandelbrot set in digital art communities.",
                    variants: [
                        FractalVariant(
                            id: "mandelbulb-classic8",
                            name: "Classic Power 8",
                            summary: "Canonical lobed Mandelbulb form.",
                            formulaOverrides: [(0, 8.0), (1, 4.0), (2, 1.0), (3, 0)],
                            targetFractalScale: 2.8,
                            externalURL: nil
                        ),
                        FractalVariant(
                            id: "mandelbulb-round3",
                            name: "Rounded Power 3",
                            summary: "Softer bulb silhouette and broad lobes.",
                            formulaOverrides: [(0, 3.0), (1, 4.0), (2, 1.0), (3, 0)],
                            targetFractalScale: 2.6,
                            externalURL: nil
                        ),
                        FractalVariant(
                            id: "mandelbulb-spike16",
                            name: "Spiky Power 16",
                            summary: "Sharper spines and denser radial detail.",
                            formulaOverrides: [(0, 16.0), (1, 6.0), (2, 1.0), (3, 0)],
                            targetFractalScale: 3.2,
                            externalURL: nil
                        ),
                        FractalVariant(
                            id: "mandelbulb-julia",
                            name: "Julia Bulb",
                            summary: "Julia-mode Mandelbulb using constant C offset.",
                            formulaOverrides: [(0, 8.0), (1, 4.0), (2, 1.0), (8, 1), (9, 0.2), (10, -0.15), (11, 0.35)],
                            targetFractalScale: 2.9,
                            externalURL: nil
                        )
                    ],
                    externalReferenceURL: "https://en.wikipedia.org/wiki/Mandelbulb"
                ),
                FractalTypeBrowserInfo(type: .quaternionJulia, subtitle: "4D Julia slice rendered in 3D", historicalInfo: "Quaternion Julia sets adapt complex dynamics into four dimensions and are often sampled as 3D slices.", variants: []),
                FractalTypeBrowserInfo(type: .mandelbulbJulia, subtitle: "Julia-mode Mandelbulb with constant C offset", historicalInfo: "The Julia variant fixes a constant C and iterates from each spatial point, producing symmetric bulb forms.", variants: [])
            ]
        ),
        FractalFamilyInfo(
            id: "julia",
            name: "Hybrid Folds",
            summary: "Conditional folds and inversions for structured hybrids.",
            historicalInfo: "Hybrid fold distance estimators emerged from practical experimentation combining box folds, sphere inversions, and Kleinian-group techniques in shader communities.",
            types: [
                FractalTypeBrowserInfo(type: .boxSphereFolder, subtitle: "Recursive box/sphere inversion hybrid", historicalInfo: "Sphere inversion techniques connect classical geometry and modern DE fractal workflows.", variants: []),
                FractalTypeBrowserInfo(type: .theliPseudoKleinian, subtitle: "Fold-based pseudo-Kleinian hybrid", historicalInfo: "Pseudo-Kleinian formulas combine conditional folds and offsets for rich cavity structures.", variants: []),
                FractalTypeBrowserInfo(type: .kleinian, subtitle: "Classical Kleinian group fold dynamics", historicalInfo: "Kleinian-style systems in raymarched fractals derive from Möbius-transform inspired fold operations.", variants: [])
            ]
        ),
        FractalFamilyInfo(
            id: "experimental",
            name: "Experimental",
            summary: "Alternative rendering techniques and work-in-progress fractal systems.",
            historicalInfo: "Buddhabrot uses orbit density histograms — an experimental rendering technique with limited feature support.",
            types: [
                FractalTypeBrowserInfo(
                    id: "buddhabrot-3d",
                    title: "3D Buddhabrot",
                    icon: "atom",
                    subtitle: "Orbit density histogram rendering",
                    historicalInfo: "The Buddhabrot technique, named by Melinda Green (1993), visualizes Mandelbrot escape orbits as density maps. The 3D extension renders orbit density in volumetric space.",
                    variants: [],
                    externalReferenceURL: "https://en.wikipedia.org/wiki/Buddhabrot"
                )
            ]
        ),
        FractalFamilyInfo(
            id: "ifs",
            name: "Kaleidoscopic IFS",
            summary: "Iterated fold-and-scale systems with polyhedral symmetry.",
            historicalInfo: "IFS families trace back to Barnsley-style affine systems, later expanded by kaleidoscopic fold techniques in demoscene and raymarch work.",
            types: [
                FractalTypeBrowserInfo(type: .menger, subtitle: "Recursive cubic void lattice", historicalInfo: "The Menger sponge is a classic 3D extension of Cantor-like recursive removal.", variants: []),
                FractalTypeBrowserInfo(type: .octahedron, subtitle: "Octahedral abs-fold variant", historicalInfo: "Octahedral fold sets are efficient and common in shader-based fractal rendering.", variants: []),
                FractalTypeBrowserInfo(type: .mengerSphere, subtitle: "Menger + optional spherification", historicalInfo: "Hybrid systems blending cubic and spherical operators became popular in modern real-time renderers.", variants: [])
            ]
        )
    ]

    static func family(for type: FractalModelType) -> FractalFamilyInfo? {
        families.first { family in
            family.types.contains { $0.type == type }
        }
    }
}

struct FractalBrowserWindow: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL

    @State private var selectedFamilyID: String = FractalBrowserCatalog.families.first?.id ?? ""
    @State private var selectedTypeID: String = "native-0"

    private var selectedFamily: FractalFamilyInfo? {
        FractalBrowserCatalog.families.first { $0.id == selectedFamilyID }
    }

    var body: some View {
        HStack(spacing: 0) {
            familyRail
            Divider()
            detailPane
        }
        .padding(12)
        .frame(minWidth: 920, minHeight: 660)
        .onAppear {
            let currentType = appModel.renderSettings.fractalType
            selectedTypeID = "native-\(currentType.rawValue)"
            if let family = FractalBrowserCatalog.family(for: currentType) {
                selectedFamilyID = family.id
            }
        }
    }

    private var familyRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Fractal Families")
                    .font(.headline)

                ForEach(FractalBrowserCatalog.families) { family in
                    Button {
                        selectedFamilyID = family.id
                        if let first = family.types.first {
                            selectedTypeID = first.id
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(family.name)
                                .font(.subheadline.weight(.semibold))
                            Text(family.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(selectedFamilyID == family.id ? Color.blue.opacity(0.20) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 280)
        .padding(.trailing, 12)
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let family = selectedFamily {
                    familyDetailContent(family)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12)
    }

    @ViewBuilder
    private func familyDetailContent(_ family: FractalFamilyInfo) -> some View {
        Text(family.name)
            .font(.title3.bold())
        Text(family.historicalInfo)
            .font(.subheadline)
            .foregroundStyle(.secondary)

        if family.id == "experimental" {
            buddhabrotToolsPanel
        }

        Divider()

        Text("Family Types")
            .font(.headline)

        ForEach(family.types) { info in
            familyTypeCard(info)
        }
    }

    @ViewBuilder
    private func familyTypeCard(_ info: FractalTypeBrowserInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(info.title, systemImage: info.icon)
                    .font(.subheadline.bold())
                Spacer()
                familyTypeActionButton(info)
            }

            Text(info.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(info.historicalInfo)
                .font(.caption)
                .foregroundStyle(.tertiary)

            if !info.variants.isEmpty {
                Divider()
                Text("Variants")
                    .font(.caption.bold())
                ForEach(info.variants) { variant in
                    variantRow(info: info, variant: variant)
                }
            }
        }
        .padding(10)
        .background {
            if selectedTypeID == info.id {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.opacity(0.10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let equation = primaryEquation(for: info) {
                Text(equation)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
            }
        }
        .onTapGesture {
            selectedTypeID = info.id
        }
    }

    private func primaryEquation(for info: FractalTypeBrowserInfo) -> String? {
        guard let type = info.type else { return nil }

        switch type {
        case .mandelbox:
            return "p_{n+1} = scale * boxFold(sphereFold(p_n)) + c"
        case .mandelboxSphereProjection:
            return "p_{n+1} = scale * projSphere(boxFold(sphereFold(p_n))) + c"
        case .mandelbulb:
            return "z_{n+1} = z_n^p + c"
        case .mandelbulbJulia:
            return "z_{n+1} = z_n^p + c_{julia}"
        case .menger:
            return "p_{n+1} = scale * fold_menger(p_n) + c"
        case .quaternionJulia:
            return "q_{n+1} = q_n^2 + c"
        case .octahedron:
            return "p_{n+1} = scale * fold_octahedral(p_n) + c"
        case .mengerSphere:
            return "p_{n+1} = scale * blend_menger_sphere(p_n) + c"
        case .theliPseudoKleinian:
            return "p_{n+1} = fold(p_n) + c"
        case .kleinian:
            return "z_{n+1} = fold(z_n) + c"
        case .boxSphereFolder:
            return "p_{n+1} = fold_box_sphere(p_n) + c"
        case .custom:
            return nil
        }
    }

    @ViewBuilder
    private func familyTypeActionButton(_ info: FractalTypeBrowserInfo) -> some View {
        if let type = info.type {
            Button("Load") {
                loadType(type)
            }
            .buttonStyle(.borderedProminent)
        } else if let externalReferenceURL = info.externalReferenceURL,
                  let url = URL(string: externalReferenceURL) {
            Button("Open Reference") {
                openURL(url)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func variantRow(info: FractalTypeBrowserInfo, variant: FractalVariant) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(variant.name)
                    .font(.caption.weight(.semibold))
                Text(variant.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            variantActionButton(info: info, variant: variant)
        }
    }

    @ViewBuilder
    private func variantActionButton(info: FractalTypeBrowserInfo, variant: FractalVariant) -> some View {
        if let type = info.type {
            Button("Load Variant") {
                loadVariant(type: type, variant: variant)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else if let externalURL = variant.externalURL,
                  let url = URL(string: externalURL) {
            Button("Open") {
                openURL(url)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var buddhabrotToolsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("3D Buddhabrot", systemImage: AppIcons.atom)
                    .font(.headline)
                Spacer()
                Button {
                    appModel.runtimeViewMode = .buddhabrot
                } label: {
                    Label("Launch Buddhabrot", systemImage: AppIcons.playFill)
                }
                .buttonStyle(.borderedProminent)
            }
            Text("Orbit density histogram rendering. Switches to the Buddhabrot renderer — a fundamentally different rendering technique from raymarching.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
    }

    private func loadType(_ type: FractalModelType) {
        appModel.runtimeViewMode = .raymarch
        appModel.renderSettings.fractalType = type
        appModel.gestureController?.applyFractalDefaults()
        appModel.gestureController?.syncWithSettings()
        selectedTypeID = "native-\(type.rawValue)"
        NotificationCenter.default.post(name: AppModel.fractalSettingsDidChangeNotification, object: nil)
    }

    private func loadVariant(type: FractalModelType, variant: FractalVariant) {
        appModel.runtimeViewMode = .raymarch
        appModel.renderSettings.fractalType = type
        appModel.gestureController?.applyFractalDefaults()

        let fp = FormulaCatalog.shared.buildParams(for: type, overrides: variant.formulaOverrides)
        appModel.renderSettings.formulaParams = fp

        if let targetScale = variant.targetFractalScale {
            appModel.renderSettings.targetFractalScale = targetScale
            appModel.renderSettings.fractalScale = targetScale
        }

        appModel.gestureController?.syncWithSettings()
        selectedTypeID = "native-\(type.rawValue)"
        NotificationCenter.default.post(name: AppModel.fractalSettingsDidChangeNotification, object: nil)
    }
}
