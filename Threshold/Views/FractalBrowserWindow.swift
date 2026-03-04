import SwiftUI
import UniformTypeIdentifiers

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
                let filteredTypes = family.types.filter { $0.type != .pseudoKnightyan }
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
        guard let url = Bundle.main.url(forResource: "fractal_browser_catalog", withExtension: "json", subdirectory: "FractalBrowser") ??
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
                FractalTypeBrowserInfo(type: .amazingSurface, subtitle: "Mandelbox-derived hybrid surface", historicalInfo: "Amazing Surface variants emerged from community experimentation with fold modes and pre-transforms.", variants: []),
                FractalTypeBrowserInfo(type: .mandalayBox, subtitle: "Scale/fold hybrid with Julia mode", historicalInfo: "Mandalay Box combines box-fold motifs with additional control channels for hybrid behavior.", variants: [])
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
                FractalTypeBrowserInfo(type: .quaternionJulia, subtitle: "4D Julia slice rendered in 3D", historicalInfo: "Quaternion Julia sets adapt complex dynamics into four dimensions and are often sampled as 3D slices.", variants: [])
            ]
        ),
        FractalFamilyInfo(
            id: "ifs",
            name: "Kaleidoscopic IFS",
            summary: "Iterated fold-and-scale systems with polyhedral symmetry.",
            historicalInfo: "IFS families trace back to Barnsley-style affine systems, later expanded by kaleidoscopic fold techniques in demoscene and raymarch work.",
            types: [
                FractalTypeBrowserInfo(type: .menger, subtitle: "Recursive cubic void lattice", historicalInfo: "The Menger sponge is a classic 3D extension of Cantor-like recursive removal.", variants: []),
                FractalTypeBrowserInfo(type: .sierpinski, subtitle: "Tetrahedral recursive simplex", historicalInfo: "Sierpinski constructions are among the earliest textbook self-similar fractals.", variants: []),
                FractalTypeBrowserInfo(type: .dodecahedron, subtitle: "Golden-ratio fold symmetries", historicalInfo: "Polyhedral IFS variants leverage Platonic and Archimedean symmetry groups.", variants: []),
                FractalTypeBrowserInfo(type: .octahedron, subtitle: "Octahedral abs-fold variant", historicalInfo: "Octahedral fold sets are efficient and common in shader-based fractal rendering.", variants: []),
                FractalTypeBrowserInfo(type: .icosahedron, subtitle: "Icosahedral five-fold symmetry", historicalInfo: "Icosahedral systems are prized for dense, quasi-organic repetition.", variants: []),
                FractalTypeBrowserInfo(type: .mengerSphere, subtitle: "Menger + optional spherification", historicalInfo: "Hybrid systems blending cubic and spherical operators became popular in modern real-time renderers.", variants: [])
            ]
        ),
        FractalFamilyInfo(
            id: "julia",
            name: "Julia Box",
            summary: "Conditional folds and Julia constants for structured hybrids.",
            historicalInfo: "Julia-box style distance estimators emerged from practical experimentation in shader communities.",
            types: [
                FractalTypeBrowserInfo(type: .pseudoKleinian, subtitle: "Pseudo-Kleinian lattice", historicalInfo: "Pseudo-Kleinian formulas are practical approximations inspired by Kleinian group aesthetics.", variants: []),
                FractalTypeBrowserInfo(type: .theliPseudoKleinian, subtitle: "Julia-box fold + Menger base hybrid", historicalInfo: "Theli-at style hybrid combining a scale-1 Julia-box operator with a Menger-like base DE.", variants: []),
                FractalTypeBrowserInfo(type: .sphereSponge, subtitle: "Recursive sphere inversion sponge", historicalInfo: "Sphere inversion techniques connect classical geometry and modern DE fractal workflows.", variants: []),
                FractalTypeBrowserInfo(type: .surfaceKIFS, subtitle: "KIFS with rotation controls", historicalInfo: "Surface KIFS formulas expanded artist control via explicit rotational parameterization.", variants: [])
            ]
        ),
        FractalFamilyInfo(
            id: "experimental",
            name: "Experimental",
            summary: "Alternative rendering techniques and work-in-progress fractal systems.",
            historicalInfo: "These renderers use fundamentally different approaches — Flame uses 2D IFS with non-linear variations, Buddhabrot uses orbit density histograms. Both are experimental and may have limited feature support.",
            types: [
                FractalTypeBrowserInfo(
                    id: "flam3-core",
                    title: "Fractal Flame (flam3)",
                    icon: "flame.fill",
                    subtitle: "2D/2.5D IFS with weighted non-linear variations",
                    historicalInfo: "Fractal Flames were introduced by Scott Draves and Erik Reckase (early 2000s). flam3 defines transform sets, variation weights, affine coefficients, and rendering metadata in XML.",
                    variants: [
                        FractalVariant(
                            id: "flam3-repo",
                            name: "flam3 Project",
                            summary: "Open the canonical flam3 repository and docs.",
                            formulaOverrides: [],
                            targetFractalScale: nil,
                            externalURL: "https://github.com/scottdraves/flam3"
                        ),
                        FractalVariant(
                            id: "flame-wiki",
                            name: "Fractal Flame Overview",
                            summary: "Background and algorithm references.",
                            formulaOverrides: [],
                            targetFractalScale: nil,
                            externalURL: "https://en.wikipedia.org/wiki/Fractal_flame"
                        ),
                        FractalVariant(
                            id: "electric-sheep",
                            name: "Electric Sheep",
                            summary: "Community-driven flame animation project.",
                            formulaOverrides: [],
                            targetFractalScale: nil,
                            externalURL: "https://electricsheep.org/"
                        )
                    ],
                    externalReferenceURL: "https://github.com/scottdraves/flam3"
                ),
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
    @State private var showFlameImporter = false
    @State private var importedFlame: FlameDocument?
    @State private var flamePreviewImage: CGImage?
    @State private var isRenderingFlame = false
    @State private var flameStatusText = ""
    @State private var flameErrorText: String?
    @State private var activeFlameRenderToken = UUID()
    @StateObject private var flameLibrary = FlameLibrary.shared

    private var flameImportTypes: [UTType] {
        var types: [UTType] = [.xml]
        if let flam3Type = UTType(filenameExtension: "flam3") {
            types.append(flam3Type)
        }
        return types
    }

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

            // Rehydrate local preview panel from shared app state when reopening.
            importedFlame = appModel.importedFlame
            flamePreviewImage = appModel.importedFlamePreviewImage
            flameStatusText = appModel.importedFlameStatusText
            flameErrorText = appModel.importedFlameErrorText
        }
        .fileImporter(
            isPresented: $showFlameImporter,
            allowedContentTypes: flameImportTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importFlame(from: url)
            case .failure(let error):
                flameErrorText = error.localizedDescription
                appModel.importedFlameErrorText = error.localizedDescription
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
            flameToolsPanel
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
        .onTapGesture {
            selectedTypeID = info.id
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

    @ViewBuilder
    private var flameToolsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Flame Import + Render", systemImage: "flame")
                    .font(.headline)
                Spacer()
                Button {
                    showFlameImporter = true
                } label: {
                    Label("Import .flam3", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }

            if isRenderingFlame {
                ProgressView("Rendering flame preview…")
            } else if let image = flamePreviewImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            } else {
                Text("Import a .flam3 XML file to generate a first-pass native flame accumulation preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let importedFlame {
                Text("Loaded: \(importedFlame.name) • \(importedFlame.transforms.count) transforms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !flameStatusText.isEmpty {
                Text(flameStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let flameErrorText {
                Text(flameErrorText)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            // ── Flame Library ─────────────────────────────────────────────
            if !flameLibrary.entries.isEmpty {
                Divider()
                Text("Flame Library")
                    .font(.subheadline.bold())
                Text("Bundled reference flames — tap to load and render.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                let columns = [GridItem(.adaptive(minimum: 130), spacing: 8)]
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(flameLibrary.entries) { entry in
                        Button {
                            loadLibraryFlame(entry.flame)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "flame.fill")
                                    .font(.title3)
                                    .foregroundStyle(.orange.gradient)
                                Text(entry.flame.name)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text("\(entry.flame.transforms.count) xforms")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(importedFlame?.name == entry.flame.name
                                          ? Color.orange.opacity(0.18)
                                          : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.quaternary)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
        .onAppear {
            flameLibrary.loadIfNeeded()
        }
    }

    private var buddhabrotToolsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("3D Buddhabrot", systemImage: "atom")
                    .font(.headline)
                Spacer()
                Button {
                    appModel.runtimeViewMode = .buddhabrot
                } label: {
                    Label("Launch Buddhabrot", systemImage: "play.fill")
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

    /// Load a flame from the built-in library and start rendering + realtime mode.
    private func loadLibraryFlame(_ flame: FlameDocument) {
        let renderToken = UUID()
        activeFlameRenderToken = renderToken

        importedFlame = flame
        appModel.importedFlame = flame
        flameErrorText = nil
        flameStatusText = "Rendering quick preview…"
        appModel.importedFlameErrorText = nil
        appModel.importedFlameStatusText = flameStatusText
        isRenderingFlame = true

        Task {
            let quickOutput = await Task.detached(priority: .userInitiated) {
                FlameRenderer.render(
                    flame: flame,
                    width: 360,
                    height: 360,
                    iterations: 260_000,
                    burnIn: 8_000
                )
            }.value

            await MainActor.run {
                guard activeFlameRenderToken == renderToken else { return }
                flamePreviewImage = quickOutput?.image
                appModel.importedFlamePreviewImage = quickOutput?.image
                if let quickOutput {
                    flameStatusText = "Quick preview: \(quickOutput.sampleCount) samples • refining…"
                } else {
                    flameStatusText = "Quick preview produced no output • refining…"
                }
                appModel.importedFlameStatusText = flameStatusText
                appModel.runtimeViewMode = .flame
            }

            let fullOutput = await Task.detached(priority: .userInitiated) {
                FlameRenderer.render(
                    flame: flame,
                    width: 720,
                    height: 720,
                    iterations: 1_200_000,
                    burnIn: 18_000
                )
            }.value

            await MainActor.run {
                guard activeFlameRenderToken == renderToken else { return }
                flamePreviewImage = fullOutput?.image
                if let fullOutput {
                    flameStatusText = "Rendered \(fullOutput.sampleCount) samples"
                } else {
                    flameStatusText = "Render produced no output"
                }
                appModel.importedFlame = flame
                appModel.importedFlamePreviewImage = fullOutput?.image ?? quickOutput?.image
                appModel.importedFlameStatusText = flameStatusText
                appModel.importedFlameErrorText = nil
                appModel.runtimeViewMode = .flame
                isRenderingFlame = false
            }
        }
    }

    private func importFlame(from url: URL) {
        let renderToken = UUID()
        activeFlameRenderToken = renderToken

        flameErrorText = nil
        flameStatusText = "Parsing .flam3…"
        isRenderingFlame = true
        appModel.importedFlameErrorText = nil
        appModel.importedFlameStatusText = flameStatusText

        Task {
            do {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }

                let data = try Data(contentsOf: url)
                let parser = FlameXMLParser()
                let flame = try parser.parse(data: data)

                await MainActor.run {
                    guard activeFlameRenderToken == renderToken else { return }
                    importedFlame = flame
                    appModel.importedFlame = flame
                    flameStatusText = "Rendering quick preview…"
                    appModel.importedFlameStatusText = flameStatusText
                }

                let quickOutput = await Task.detached(priority: .userInitiated) {
                    FlameRenderer.render(
                        flame: flame,
                        width: 360,
                        height: 360,
                        iterations: 260_000,
                        burnIn: 8_000
                    )
                }.value

                await MainActor.run {
                    guard activeFlameRenderToken == renderToken else { return }
                    flamePreviewImage = quickOutput?.image
                    appModel.importedFlamePreviewImage = quickOutput?.image
                    if let quickOutput {
                        flameStatusText = "Quick preview: \(quickOutput.sampleCount) samples • refining…"
                    } else {
                        flameStatusText = "Quick preview produced no output • refining…"
                    }
                    appModel.importedFlameStatusText = flameStatusText
                    appModel.runtimeViewMode = .flame
                }

                let fullOutput = await Task.detached(priority: .userInitiated) {
                    FlameRenderer.render(
                        flame: flame,
                        width: 720,
                        height: 720,
                        iterations: 1_200_000,
                        burnIn: 18_000
                    )
                }.value

                await MainActor.run {
                    guard activeFlameRenderToken == renderToken else { return }
                    importedFlame = flame
                    flamePreviewImage = fullOutput?.image
                    if let fullOutput {
                        flameStatusText = "Rendered \(fullOutput.sampleCount) samples"
                    } else {
                        flameStatusText = "Render produced no output"
                    }

                    // Promote to global runtime state so Flame can be the active mode.
                    appModel.importedFlame = flame
                    appModel.importedFlamePreviewImage = fullOutput?.image ?? quickOutput?.image
                    appModel.importedFlameStatusText = flameStatusText
                    appModel.importedFlameErrorText = nil
                    appModel.runtimeViewMode = .flame
                    isRenderingFlame = false
                }
            } catch {
                await MainActor.run {
                    guard activeFlameRenderToken == renderToken else { return }
                    flameErrorText = error.localizedDescription
                    appModel.importedFlameErrorText = error.localizedDescription
                    isRenderingFlame = false
                }
            }
        }
    }
}
