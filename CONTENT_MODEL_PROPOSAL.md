# Content model: current state and a unified structure

Status: proposal / design review. No code changed by this document.

The symptom that started this review: **the "Custom Scenes" category feels
wrong, and `.threshfx` files seem to show up in it.** That is real, and it is a
symptom of a deeper problem — the app currently has *four unrelated taxonomies*
that all try to answer "what is this thing and where does it belong," and no
single one of them is authoritative.

This document first maps exactly how content is organized today (with
`file:line` references), then proposes one structure that the app and the user
can both follow.

---

## The short version

**Three file types. Three folders. Four rules.**

| File type | What it is | Lives in | The *variety* lives inside the file |
| --- | --- | --- | --- |
| `.thresh` | a scene — camera, formula, palette, lighting | `Scenes/…` | music-reactive mappings, mixed-mode flag, embedded effect |
| `.threshanim` | a timeline of keyframes | `Animations/…` | attached song, embedded effect |
| `.threshfx` | a reusable GPU effect | `Effects/…` | `kind`: distance estimator, space warp, 2D filter, … |

1. **Extension = kind.** Exactly three, matching the roots one-to-one. The old
   `.threshmp` and `.threshanimv` disappear — those differences were content
   fields masquerading as file types.
2. **Folder = category.** Any folder you create under a root is a category and
   appears in the sidebar, live.
3. **Tags = labels.** Free-form and cross-cutting; reserved tags become real
   fields.
4. **An effect is either a library item or embedded — never both.** Embedded
   effects are private to their document, wear an "embedded" icon, and can be
   promoted with one click.

Browse UI: a sidebar built from your folders, plus Smart Views (Recent,
Favorites, Music Reactive, Custom DE, Mixed, Animated) that are *filters*, so a
scene can be in several at once.

Old extensions are read forever; new saves write the three new ones.

The rest of this document is the evidence and the fine print.

---

## Part 1 — How it is organized today

### 1.1 The four parallel taxonomies

| # | Taxonomy | Lives in | Authoritative? | What it drives |
| --- | --- | --- | --- | --- |
| 1 | **File extension** | `.threshscene` `.threshmp` `.threshanim` `.threshanimv` `.threshfx` | Yes, for import routing | Import decode, Quick Look, export labels |
| 2 | **Folder** | `<root>/{Scenes, Music Presets, Animations, Formulas}` | Yes, for reads; derived for writes | Which scanner sees the file |
| 3 | **Browse tab** | `Jumping Off / Music Reactive / Animated / Mixed / Custom Scenes` | No — computed at runtime | Which section of Browse shows the item |
| 4 | **In-file metadata** | `tags[]`, `mixedModeScene`, `embeddedFormula.category`, catalog `category`, `supportedEffectTags` | Mixed | Tag filter, platform visibility, formula grouping |

None of these four is the single source of truth, and several of them are
*derived from each other in inconsistent directions*:

```
extension ──► import route
folder    ──► read scope, but ALSO sniffed for semantics ("Mixed" folder sets mixedModeScene)
field     ──► written folder (hasMusicReactiveMappings chooses Scenes/ vs Music Presets/)
field     ──► browse tab   (isCustomScenePreset, hasMusicReactiveMappings, mixedModeScene)
```

So the folder decides semantics for bundled files, but a field decides the
folder for saved files. That bidirectional coupling is the root of the jumble.

### 1.2 The storage layout

`StorageLocation` (`Threshold/Parameters/StorageLocation.swift:12-20, 52-60`)
is the single source of truth for *where* content lives:

```
<root>/                      local:  <sandbox>/Documents/Threshold/
  ├── Scenes/                    iCloud: <container>/Documents/
  ├── Music Presets/
  ├── Animations/
  ├── Settings/
  └── Formulas/
Backups/                     always local, never synced
```

The subfolder list is a **fixed, hardcoded array** (`StorageLocation.swift:60`,
`190-197`). The app creates these folders; it does not enumerate any others.

The scans are **flat, non-recursive**:

- Scenes + Music Presets: `PresetManager.swift:518-525` — `contentsOfDirectory`
  on exactly two folders, extension filter only.
- Animations: `AnimationManager.swift:92-106` — `contentsOfDirectory` on
  `Animations/` only (the `.threshanim` load at `AnimationTypes.swift:1362-1374`
  is the *bundled* example scan, also non-recursive).
- Formulas: `FormulaLibraryStore.swift:64-80` — `contentsOfDirectory` on
  `Formulas/`, `pathExtension == "threshfx"`.

**A user-created subfolder is invisible.** Adding `Scenes/Caverns/` produces no
new category, no new group, no error — the files inside are simply never
scanned. Adding a new *top-level* folder does nothing at all.

The iCloud watcher is likewise scoped to two flat folders
(`PresetManager.swift:342-352`), with an extension predicate of
`.threshscene`/`.threshmp` only.

### 1.3 The browse tabs are runtime partitions, not categories

`FractalBrowseTab` (`FractalGridView.swift:10-16`):

```swift
case jumpingOff   = "Jumping Off"
case musicReactive = "Music Reactive"
case animated      = "Animated"
case mixed         = "Mixed"
case customScenes  = "Custom Scenes"
```

Each tab is a filter over one flat preset list
(`FractalGridView.swift:487-507`):

| Tab | Predicate |
| --- | --- |
| Jumping Off | `isJumpingOffPreset && mixedModeScene != true` |
| Music Reactive | `!isCustomScenePreset && !isJumpingOffPreset && mixedModeScene != true` |
| Mixed | `mixedModeScene == true` |
| Custom Scenes | `isCustomScenePreset` |

And these predicates are themselves defined off content fields
(`FractalPreset.swift:1688-1731`):

```swift
var isCustomScenePreset: Bool { embeddedFormula != nil }        // :1688
var isJumpingOffPreset: Bool { !isCustomScenePreset && !hasMusicReactiveMappings } // :1715
```

Two consequences worth naming:

1. **The tabs are mutually exclusive partitions of one list, not views.** A
   scene that is both music-reactive *and* custom-DE is force-classified as
   Custom and vanishes from Music Reactive (`musicReactivePresets` excludes
   `isCustomScenePreset`). You cannot be in two tabs at once, even though the
   underlying traits are independent.
2. **"Custom Scenes" is an implementation detail promoted to a category.** It
   means "this `.threshscene` carries an embedded distance estimator" — i.e. a
   *format* property, not a subject, theme, or user grouping. A saved scene that
   happens to embed a DE lands there whether or not the user thinks of it as
   "custom."

### 1.4 Why `.threshfx` looks like it shows up under Custom Scenes

A standalone `.threshfx` is **not** a library item with its own home in the
browse UI. On import it is converted into a scene:

1. Decode a `.threshfx` → `EmbeddedFormulaContainer`
   (`AppModel+ExternalImport.swift:151-153`).
2. Convert it to a `FractalPreset` via `makeCustomPreset(from:)`
   (`AppModel+EmbeddedFormula.swift:247-270`), which sets
   `fractalType = .custom` and attaches the formula.
3. Route it into the normal **preset import** flow
   (`AppModel+ExternalImport.swift:202-217`).
4. On commit, `loadStaticScene(..., options: [.saveToLibrary, ...])` persists it
   (`AppModel+SceneLoading.swift:115-117` → `PresetManager.importPreset` →
   `writeNewPresetFile`, `PresetManager.swift:855-859`), which writes a
   **`.threshscene` (or `.threshmp`) into `Scenes/`**.
5. That written scene has `embeddedFormula != nil`, so it satisfies
   `isCustomScenePreset` and appears as a card under **Custom Scenes**.

Meanwhile the same formula can *also* be:

- a `.threshfx` file in `Formulas/`, listed in Metal DE Studio via
  `FormulaLibraryStore.entries` (`FormulaCodeEditorView.swift:239`);
- a tile in the Shape → Formula picker's "Custom" section, sourced from
  `FractalFormulaOrder.customFormulas(in: presetManager.presets)` — i.e. scanned
  out of *scenes*, not out of `Formulas/` (`FractalGridView.swift:990-1032`).

So one object is presented in **three places** (Custom Scenes cards, the formula
picker's "Custom" group, and the DE Studio library list), keyed off three
different scans of two different folders. That is the "jumbled" feeling.

There is a second, subtler inconsistency in the same area. The runtime keeps
only **one** embedded formula registered at a time
(`FormulaCatalog.registerEphemeral`, `FormulaCatalog.swift:204-232`), and
`unregisterEphemeral` is called on every scene change — so an embedded DE is
effectively private to the document that carries it. But the Shape → Formula
picker enumerates embedded formulas across *every* scene and presents them as
selectable, reusable tiles:

```swift
FractalFormulaOrder.customFormulas(in: presetManager?.presets ?? [])  // :991
```

Selecting one calls `pushCustomFormula` (`ControlStateStore.swift:495-507`),
which installs it globally. So the UI advertises embedded formulas as a shared
library while the engine treats them as one-off scene data. That contradiction
is exactly the "source of the formula is unclear" problem.

### 1.5 In-file metadata is doing too many jobs

`FractalPreset.tags: [String]` (`FractalPreset.swift:371-372`) is documented as
user-authored labels, and `SceneTagging` (`SceneTags.swift:35-101`) governs them:
max 12, max 28 chars, case-insensitive dedupe, whitespace collapse.

But the same array also carries **reserved semantic values**:

```swift
static let screenOnlyTag = "Screen only"   // SceneTags.swift:41
static let macOnlyTag    = "Mac only"      // SceneTags.swift:45
```

These drive **platform visibility** (`filterSceneCatalogPresets`,
`PresetManager.swift:450-501`), are surfaced as ordinary chips in the tag filter
bar (`FractalGridView.swift:537-589`), and count against the user's 12-tag
budget. `"Screen only"` implies `"Mac only"` (`SceneTags.swift:73-75`). Older
tech debt already flags the normalizer (`TECH_DEBT.md:174`, item 30).

`mixedModeScene` is a typed `Bool`, but for *bundled* content it is inferred from
the **folder name**: any bundled file whose path contains `Mixed` gets
`preset.mixedModeScene = true` (`PresetManager.swift:1505-1511`). So folder →
field for bundled files.

`EmbeddedFormula.category: String?` (`EmbeddedFormula.swift:86`) defaults to
`"Custom"` in the UI (`FractalGridView.swift:1088`) and appears alongside
*another* hardcoded category list for built-in formulas:
`FractalFormulaOrder.categoryOrder = ["Box Folds", "Power / Quaternion",
"Hybrid Folds", "Kaleidoscopic IFS"]` (`FractalGridView.swift:21`), mirrored by
`catalog.json` and `FractalModelType.category` (`FractalModelType.swift:44`).

### 1.6 Bundled examples use yet another scheme

The bundled `Threshold/Examples/` tree does not mirror the storage root:

```
Examples/
  Scenes/                 50 .threshscene
  Mixed/                  8 .threshscene   ← folder name becomes mixedModeScene
  Music Presets/          32 .threshmp
  Animations/             6 .threshanim
  Formulas/               3 .threshfx
  Custom Scene Example/   1 .threshscene   ← one-off special folder
```

And the loader special-cases each of these by name
(`PresetManager.swift:1456-1467`), then adds a `subdirectory: nil` fallback and
a **deep enumeration of the entire resource path**
(`PresetManager.swift:1479-1489`), then de-duplicates by ID. There's also a
stale reference to `fractal_browser_catalog.json`
(`FractalBrowserWindow.swift:147`) that does not exist in the repo, so that
family taxonomy silently falls back to hardcoded Swift.

### 1.7 Friction summary

1. **"Custom Scenes" is a format artifact masquerading as a category.**
2. **Folder ≠ category.** Only four fixed folders exist; user subfolders are
   ignored; new top-level folders do nothing.
3. **Two in-file grouping systems** (`tags[]` and `embeddedFormula.category`)
   plus catalog categories, with no shared vocabulary.
4. **Reserved tags pollute the user tag namespace** and the tag UI.
5. **Tabs don't compose** (mutually exclusive partitions of independent traits).
6. **Folder→field and field→folder coupling** in opposite directions.
7. **No user-defined categories at all** — the tag chip row is the only
   user-controlled grouping, and it is a flat cross-cutting filter, not a place
   you can put things.
8. **Bundled examples teach a different structure than the user's own store.**
9. **Three surfaces for one formula object**, keyed off different scans.
10. **Embedded vs library provenance is invisible and inconsistent** — the UI
    offers embedded formulas as reusable, the engine keeps them scene-private,
    and nothing tells the user which is which.
11. **`.threshfx` is treated as "a fractal DE" everywhere**, even though the
    container already has a `kind` discriminator and is meant to carry new
    effect kinds (2D filters, and more).
12. **Five extensions for three schemas.** `.threshmp` and `.threshanimv` are
    the *same JSON* as `.threshscene` / `.threshanim` — just renamed at save
    time by a content field (`preset(hasMusic:)`, `animation(hasSong:)`,
    `PresetManager.swift:66-72`). A trait is masquerading as a file type.

---

## Part 2 — Proposed unified structure

### 2.1 The one-line rule

> **The folder is the category. The file extension is the kind. Tags are
> cross-cutting labels. Content traits are derived, never authored as tags.
> An effect is either a library item or embedded — never both.**

Everything below follows from that. In particular:

- There are exactly **three file types**: `.thresh` (a scene), `.threshanim`
  (a timeline), `.threshfx` (an effect). See §2.3.
- The in-file `category` field stops being a grouping key and becomes a
  *portability hint* only.
- `.threshfx` is one broad kind ("Threshold effect") whose specific kind —
  distance estimator, space warp, 2D filter, … — lives in its in-file `kind`
  field and selects which effect section it belongs to.
- A formula embedded inside a scene/animation document is
  **private to that document**: not part of the reusable library, and shown with
  an "embedded" marker so its source is unambiguous.

### 2.2 Five concepts, five jobs

| Concept | Where it lives | Who owns it | Role |
| --- | --- | --- | --- |
| **Kind** | File extension; for `.threshfx`, the in-file `kind` refines it | App | Which library section |
| **Category** | Folder path on disk | User | Organization / grouping / navigation |
| **Tags** | In-file `tags[]` | User | Orthogonal labels + filters (favorites, wip, live) |
| **Traits** | In-file typed fields | Derived / toggled | `hasMusic`, `mixedMode`, `hasEmbeddedEffect` |
| **Provenance** | Library file vs embedded in a document | App | Reusable effect, or private to one document |

**Rule: an item appears under exactly one Category (its folder) but may match
any number of Tags and Traits.** Kind is not a folder; it is a property of the
file that the folder merely *defaults* to. Provenance is not a folder either —
it is a fact about where an effect definition physically lives.

### 2.3 Three file types: collapsing the extensions

The five extensions in use today cover only **three document schemas**. Two of
them are cosmetic renames chosen at save time by a content field:

| Today | Picked by | Actual schema | Tomorrow |
| --- | --- | --- | --- |
| `.threshscene` | — | `FractalPreset` | **`.thresh`** |
| `.threshmp` | `hasMusicReactiveMappings` at save time (`ThresholdExportFormat.preset(hasMusic:)`) | same `FractalPreset` | **`.thresh`** |
| `.threshanim` | — | `AnimationScene` | **`.threshanim`** (name unchanged) |
| `.threshanimv` | `attachedSong != nil` at save time (`ThresholdExportFormat.animation(hasSong:)`) | same `AnimationScene` | **`.threshanim`** |
| `.threshfx` | — | `EmbeddedFormulaContainer` | **`.threshfx`** (unchanged) |

This is not a format change: both merged pairs share one decoder today
(`AppModel+ExternalImport.swift:138-153`), and the distinctions the extensions
encoded are already traits we surface as Smart Views ("Music Reactive",
"Music Video"). Collapsing them means:

- **Write path stops branching.** `preset(hasMusic:)` and `animation(hasSong:)`
  are deleted; `ThresholdExportFormat` shrinks from five cases to three.
- **Import routing becomes a three-way switch** on the extension.
- **The hierarchy is unambiguous:** extension tells you the kind, folder tells
  you the place, fields tell you the flavor. Nothing is decided twice.
- UTType declarations, Quick Look, share sheets, and the export-tab format
  reference all shrink accordingly.

Consequences for the `Music Presets/` root: with `.threshmp` gone, music presets
are just scenes. `Music Presets/` stops being a kind root and shows up as an
ordinary category (its files are `.thresh`-schema scenes); "Music Reactive"
finds them wherever they live. This also resolves decision point D3.

Compatibility: **read all five extensions forever**; **write only the three
new ones.** See §2.10.

### 2.4 On-disk layout

Three kind roots — one per file type — and **everything below a kind root is a
user category**:

```
<root>/
  Scenes/                           ← kind root: every .thresh
    Caverns/                        ← category "Caverns"
      Ice Caves/                    ← subcategory "Caverns/Ice Caves"
        Frozen.thresh
    Ambient.blur.thresh
  Animations/                       ← kind root: every .threshanim
    Intros/                         ← category "Intros"
  Effects/                          ← kind root: every .threshfx
    Distance Estimators/            ← sub-kind (from the payload `kind`)
      Mandelbox Variants/           ← category "Mandelbox Variants"
    2D Filters/                     ← sub-kind
  Settings/                         ← hidden, app-managed (not a category)
```

An older install's `Music Presets/` or `Formulas/` folder isn't deleted or
migrated behind the user's back — it simply shows up as an ordinary category
(the files inside are `.thresh`-schema scenes and `.threshfx` effects).

Rules:

- **Top-level folder = kind.** Reserved names: `Scenes`, `Animations`,
  `Effects`. `Settings/` is hidden. `Backups/` is outside the root. Legacy
  `Music Presets/` and `Formulas/` are read as ordinary categories.
- **The first folder level under `Effects/` is the effect sub-kind**, derived
  from the payload's `kind` (so it is app-managed, not a user category); levels
  below it are user categories. The other kind roots have no sub-kind level.
- **Any folder below a kind root = a category**, nested arbitrarily.
  `Scenes/Caverns/Ice Caves` → breadcrumb `Caverns / Ice Caves`.
- **The app enumerates folders, not just files**, so an empty new category
  appears immediately.
- **Scans and watchers become recursive** for all three roots (local FSEvents /
  DispatchSource, iCloud `NSMetadataQuery` with recursive scope).
- **"New Category"** in the UI creates a real folder; an external
  `mkdir <root>/Scenes/Caverns` shows up on the next watcher pass with no app
  action. That is the user's requested behavior.
- A file dropped into a non-reserved top-level folder is an edge case: treat the
  folder as a category of the kind inferred from the file extension, and surface
  a one-time "keep it here or move it into `<Kind>/`?" notice rather than
  silently ignoring it. (See decision point D1.)

### 2.5 In-file metadata

**Keep** `tags: [String]` as the user's cross-cutting labels. Unchanged on disk;
unchanged normalization (`SceneTagging`).

**Promote the reserved tags to typed fields.** Add to `FractalPreset` /
`AnimationScene`:

```jsonc
"platformVisibility": "all" | "flat" | "mac"   // replaces "Screen only"/"Mac only" in tags
"mixedModeScene": true                          // already typed; stop deriving it from folder
```

Decode shim: on read, if `platformVisibility` is absent and `tags` contains a
reserved tag, derive the field and drop the reserved tag from the exposed tag
list. On write, emit both for one release (field + reserved tag) so older builds
still filter correctly, then drop the tag emission in a later release. This
retires the namespace collision and frees the 12-tag budget.

**Demote `embeddedFormula.category`.** Keep it in the file for portability and
attribution, but never use it for library grouping. The formula's library
location is its folder under `Formulas/`. In the picker it becomes a secondary
caption (`author` is already a caption, `FractalGridView.swift:950-955`).

**Introduce an optional `categoryPath` on export.** When a file is shared, write
its folder-relative category into the file (e.g. `"categoryPath": "Caverns/Ice
Caves"`). On import, offer to restore it into that folder; if the user declines
or it's absent, place it in the chosen category. Folder always wins once the
file is on disk — the field is a suggestion, never a second truth.

### 2.6 `.threshfx` is a multi-kind container

`.threshfx` already carries a discriminator — `EffectKind` is `fractal` | `spaceWarp`
(`EmbeddedFormula.swift:39-46`) — but almost every consumer assumes "fractal DE."
As 2D filters and other effect kinds arrive, `kind` becomes the real extension
point and the model must stop collapsing it.

Proposed effect-kind taxonomy (extensible; the enum is the registry):

| `kind` | Payload defines | Library section |
| --- | --- | --- |
| `de` (today's `fractal`) | `DE_<stem>` + `DE_<stem>_Dist` | Distance Estimators |
| `spaceWarp` | `customSpaceWarp` + `customSpaceWarpDEScale` | Space Warps |
| `filter2D` *(new)* | a fullscreen `filter2D(...)` entry point | 2D Filters |
| …future | whatever the contract specifies | … |

Consequences:

- **Keep one extension and one on-disk root for all `.threshfx`.** A single root
  keeps sharing/routing simple; `kind` selects the section inside the UI.
- **Generalize the container.** `EmbeddedFormulaContainer` becomes a
  kind-discriminated `ThresholdEffectContainer`; `EmbeddedFormula` becomes the
  DE-specific payload of a general `EmbeddedEffect`. Absent `kind` keeps decoding
  as `de` (today's back-compat rule).
- **The UI groups by `kind` first, then by folder category.**
  ```
  EFFECTS
    Distance Estimators
      Mandelbox Variants/     ← user folder category
      Caverns/
    Space Warps
      Twists/
    2D Filters
      Bloom & Glow/
  ```
- **Naming.** The on-disk root is currently `Formulas/`, which no longer fits
  once it holds filters. Recommend `Effects/` (with `Formulas/` read as a legacy
  alias for one release), `FormulaLibraryStore` → `EffectLibraryStore`, and the
  DE Studio becoming an effect-kind-aware "Effect Studio." (See D4.)

### 2.7 Provenance: library effect vs embedded effect

Every effect definition has exactly one of two provenances:

| Provenance | Physical home | Reusable? | Listed in library? | Editable in Studio? |
| --- | --- | --- | --- | --- |
| **Library effect** | a `.threshfx` file under `Effects/` | Yes — any scene can reference it | Yes, under its `kind` + category | Yes |
| **Embedded effect** | inside a `.threshscene` / `.threshanim` / `.threshmp` | No — private to that document | **No** | Only through that document |

This matches what the engine already does: `FormulaCatalog.registerEphemeral`
holds a single runtime slot (`FormulaCatalog.swift:204-232`) and scene changes
unregister it, so an embedded DE is already scene-local. The **UI** is what
contradicts it, by enumerating embedded formulas from every scene as selectable
tiles (`FractalGridView.swift:990-1032`). Fixing that is a core part of the
overhaul.

Rules:

1. **The Shape → Formula / Effects picker and the Studio library list read
   `EffectLibraryStore` only** — never scan scenes for embedded payloads.
   `FractalFormulaOrder.customFormulas(in:)` is retired.
2. **An embedded effect is reachable only through the document that carries
   it.** Loading that scene installs it; you cannot select it for a different
   scene.
3. **Sharing still works.** An embedded effect travels inside its scene (that is
   the portability guarantee in `CUSTOM_SCENES.md`). The distinction is about
   *reuse*, not portability.
4. **Promotion is explicit: "Extract to Effects…".** From the active-effect
   header (or a scene's embedded-effect badge), the user picks a `kind` +
   category and the app writes a real `.threshfx`, optionally re-pointing the
   document at the library copy.

#### 2.7.1 Iconography (making the source obvious)

The user-visible cue the request calls for:

| Where | Library effect | Embedded effect |
| --- | --- | --- |
| Tile / list row | existing `function` glyph, caption "Library" | distinct glyph (e.g. `link`), caption **"Embedded in <Scene>"** |
| Scene card | — | small badge on the card (visible before opening) |
| Active-effect header | "Library · <category>" | **"Embedded — not shared"** + **Extract to Effects…** button |
| Studio library list | all `.threshfx`, grouped by `kind` | never shown |

Choosing a visually distinct, persistent marker is the mechanism that
"encourages `.threshfx`-based DE definitions": an author who wants their DE
reusable sees plainly that an inline one is not, and has a one-click path to
promote it.

### 2.8 Front end: sections, categories, smart views, tags

Replace the five mutually-exclusive tabs with a **sidebar** built from the disk:

```
LIBRARY
  Scenes                    (kind)
    Caverns                 (folder-derived category, live)
      Ice Caves
    ...
  Music Presets
  Animations
  Effects                   (kind: every .threshfx)
    Distance Estimators     (sub-kind, from the payload's `kind`)
      Mandelbox Variants    (folder-derived category)
    Space Warps
    2D Filters

SMART VIEWS                 (filters — an item may appear in several)
  Recent
  Custom DE                 (hasEmbeddedEffect)  ← what "Custom Scenes" should become
  Music Reactive            (hasMusic)
  Mixed                     (mixedMode)
  Animated
  ★ Favorites               (tag: favorite)

TAGS                        (cross-cutting filter chips from tags[])
  #live  #wip  #cavern ...
```

Key changes:

- **Sections and categories come from the folder tree** — the thing users edit
  directly.
- **Smart Views are filters, not partitions.** They compose: a scene can be in
  "Custom DE" and "Music Reactive" and inside `Scenes/Caverns` at once.
- **"Custom Scenes" is retired as a category.** `hasEmbeddedEffect` becomes a
  smart view and a small **badge on scene cards** (§2.6.1). This removes the
  format-property-as-category confusion.
- **Effects are one section grouped by `kind`, then by folder category.** The
  picker/Studio list reads `EffectLibraryStore` only — one surface per object.
- **Embedded effects are never listed as reusable.** They appear only as a badge
  on their owning document and in the active-effect header, with an
  **Extract to Effects…** action (§2.6).
- **Importing a standalone `.threshfx`** loads it as the active effect and, if
  saved, writes it under `Effects/<Kind>/<Category>/` — it **no longer
  materializes a phantom `.threshscene` card in `Scenes/`**. (See D2.)
- **Tag chips stay**, but reserved chips disappear (promoted to fields).

### 2.9 Worked examples

**A user adds a category.** They create `<root>/Scenes/Caverns/` (Finder, Files
app, or "New Category"). The recursive watcher sees the folder and the sidebar
shows `Scenes ▸ Caverns`. Dragging `Frozen.threshscene` in adds it to that
category. No app metadata to edit.

**A user tags a file.** They add tags `wip`, `live` to a scene. It stays in its
category and becomes reachable from the Tags section and any smart view using
those tags. Tags never move the file.

**A user imports a `.threshfx`.** Preview opens the effect. Its `kind` determines
which effect section it lands in (`Effects ▸ Distance Estimators` or
`Effects ▸ 2D Filters`), plus the category they pick. It never creates a scene
card.

**A user authors a 2D filter.** Same `.threshfx` container with
`"kind": "filter2D"`; it appears under `Effects ▸ 2D Filters`, not among the
distance estimators. Scenes can embed it the same way.

**A user embeds a DE in a scene (inline).** The DE works and travels with the
scene, and the scene card shows an "embedded" badge. The effect is **not**
selectable for any other scene. The active-effect header reads
"Embedded — not shared" and offers **Extract to Effects…**, which writes a real
`.threshfx` and optionally re-points the scene at it. This is the path that
nudges authors toward reusable, `.threshfx`-based definitions.

**A user shares a scene.** Export writes `categoryPath` and normal tags. On the
recipient's machine, import offers to place it in the matching category; the
scene keeps working even if they decline. A scene that carried an embedded
effect still travels with it, and that effect still is not added to the
recipient's reusable library.

### 2.10 Compatibility and migration

Nothing here requires a file-format break for existing users:

| Current | New behavior |
| --- | --- |
| `Scenes/*.threshscene` (flat) | Unchanged; they are in the root category of Scenes |
| `Music Presets/*.threshmp` | Unchanged; "Music Presets" kind root retained |
| `tags` with `"Screen only"` / `"Mac only"` | Decoded into `platformVisibility`; re-emitted both ways for one release |
| `mixedModeScene` on bundled files | Stops being folder-sniffed; set explicitly in each example file (one-time script) |
| Bundled `Examples/Mixed`, `Examples/Custom Scene Example` | Folded into `Examples/Scenes/<Category>/` with explicit fields |
| `embeddedFormula.category` | Still read/exported, no longer a grouping key |
| `.threshfx` with no `kind` | Decodes as `de` (distance estimator) — unchanged |
| `.threshfx` under `Formulas/` | Read as an alias of `Effects/` for one release, then migrated |
| Embedded formula inside a scene | Marked embedded; never listed in the library; still travels with the scene |
| `.threshfx` imported from outside | Saved under `Effects/<Kind>/`, not converted into a `Scenes/` scene |

Suggested phasing:

- **Phase 0 — index layer.** Introduce a `LibraryIndex` that recursively scans
  all roots and emits `(url, kind, subKind, categoryPath, provenance, tags,
  traits)`. No UI change yet. This is the keystone; everything else reads it.
- **Phase 1 — sidebar.** Build the sidebar/categories from `LibraryIndex`.
  Keep the old tabs available as Smart Views for continuity.
- **Phase 2 — metadata.** Promote reserved tags to `platformVisibility`; stop
  folder-sniffing for `mixedModeScene`; write `categoryPath` on export.
- **Phase 3 — effect kinds and provenance.** Generalize
  `EmbeddedFormulaContainer` → `ThresholdEffectContainer` (kind-discriminated);
  rename `FormulaLibraryStore` → `EffectLibraryStore` and group by `kind`;
  point the picker and Studio at the library only; add the embedded badge/icon
  and **Extract to Effects…**; stop the `.threshfx`→`Scenes/` materialization.
- **Phase 4 — cleanup.** Delete `FractalBrowseTab`, `customScenePresets()`,
  `isCustomScenePreset`-based partitioning, `FractalFormulaOrder.customFormulas(in:)`,
  the `Examples/*` name special-casing, `FractalFormulaOrder.categoryOrder`, and
  the dead `fractal_browser_catalog` reference.

### 2.11 Concrete code touch points

| Concern | Current location | Change |
| --- | --- | --- |
| Fixed subfolder list | `StorageLocation.swift:52-60, 190-197` | Enumerate instead of hardcode categories; keep kind roots reserved |
| Flat preset scan | `PresetManager.swift:518-525` | Recursive; carry `categoryPath` |
| Flat formula scan | `FormulaLibraryStore.swift:64-80` | Recursive; carry `categoryPath` |
| Flat iCloud watcher | `PresetManager.swift:342-352` | Recursive scope + all extensions |
| Tab partitions | `FractalGridView.swift:10-16, 487-507` | Replace with sidebar + Smart Views |
| Format-as-category | `FractalPreset.swift:1688-1690` | Drop; becomes a trait/badge |
| Reserved tags | `SceneTags.swift:38-101` | Promote to `platformVisibility` + shim |
| Folder-sniffed mixed | `PresetManager.swift:1505-1511` | Set in files; remove sniff |
| `.threshfx`→scene | `AppModel+ExternalImport.swift:202-217`, `AppModel+EmbeddedFormula.swift:247-270` | Route to `Effects/<Kind>/` instead |
| Effect-kind enum | `EmbeddedFormula.swift:39-46` (`EffectKind`) | Extend with `filter2D` etc.; drives library sections |
| Effect container | `EmbeddedFormula.swift:19-31` | Generalize to kind-discriminated `ThresholdEffectContainer` |
| Embedded listed as reusable | `FractalGridView.swift:990-1032` + `ControlStateStore.swift:495-507` | Remove scene scan; picker/Studio read the library only |
| Embedded marker / badge | `FractalGridView.swift:1063-1124` + scene cards | Add "embedded" icon/badge and **Extract to Effects…** |
| Formula library name | `FormulaLibraryStore.swift` | → `EffectLibraryStore`, grouped by `kind` |
| Hardcoded formula categories | `FractalGridView.swift:21` | Derive from effect kind + folder/library |
| Bundled special-casing | `PresetManager.swift:1456-1489` | One deterministic recursive resource scan |

---

## Part 3 — Decision points

**D1 — Where do user categories live?**
- **A (recommended):** Kind roots fixed at top; categories are subfolders
  (`Scenes/Caverns/`). Unambiguous, no dual placement, preserves compatibility.
- **B:** A single flat `Library/` root; every folder is a category and kind comes
  from the extension. Simpler mental model, but kinds mingle and section
  semantics get fuzzier.
- **C:** A + an optional cross-kind `Collections/<Name>/` layer for mixed
  groupings (like albums vs library). More power, more concepts.

**D2 — Is a `.threshfx` a first-class item, or a scene attachment?**
- **A (recommended):** First-class effect library item under `Effects/`; scenes
  that embed one show an "embedded" badge and a link. Removes the phantom-card
  behavior.
- **B:** Keep materializing an editable scene on import, but file it under an
  `Effects/` category rather than `Scenes/`.

**D3 — Do Music Presets stay a separate kind root, or become Scenes + a
`hasMusic` trait?**
- **A:** Keep the separate root (lowest migration risk).
- **B:** Merge into Scenes and treat music-reactivity as a trait/Smart View
  (cleaner, but changes where `.threshmp` files live).

**D4 — How do effect kinds map to the on-disk root?**
- **A (recommended):** One root for every `.threshfx` (`Effects/`, migrating
  `Formulas/`), with the payload `kind` selecting the UI section. Simple to share
  and route.
- **B:** One root folder per kind (`Effects/Distance Estimators/`,
  `Effects/2D Filters/`). More discoverable in Finder, but kind now lives in two
  places (folder *and* `kind`) and can disagree.
- **C:** Split the extension per kind (`.threshde`, `.threshfilter`). Clearest
  routing, most churn, breaks existing shares.

**D5 — What should "Extract to Effects…" do to the source document?**
- **A (recommended):** Write the `.threshfx` and offer to re-point the document
  at the library copy; keep the option to leave the inline copy as-is.
- **B:** Always copy and leave the document untouched (no risk, possible
  duplicate drift).
- **C:** Always move (no duplication, but silently changes the scene's
  portability).

---

## Appendix — quick reference index

- Storage roots and subfolders: `Threshold/Parameters/StorageLocation.swift:12-20, 52-60, 190-197`
- Flat preset scan: `Threshold/Parameters/PresetManager.swift:518-525`
- Write routing by music field: `Threshold/Parameters/PresetManager.swift:855-859`
- iCloud watcher scope: `Threshold/Parameters/PresetManager.swift:342-352`
- Browse tab enum: `Threshold/Views/FractalGridView.swift:10-16`
- Tab partitions: `Threshold/Views/FractalGridView.swift:487-507`
- Formula category order: `Threshold/Views/FractalGridView.swift:21`
- Formula picker "Custom": `Threshold/Views/FractalGridView.swift:990-1032, 1088`
- `isCustomScenePreset`: `Threshold/Parameters/FractalPreset.swift:1688-1690`
- Tag rules: `Threshold/Views/SceneTags.swift:35-101`
- Reserved tags: `Threshold/Views/SceneTags.swift:38-45, 73-91`
- `mixedModeScene` filtering: `Threshold/Parameters/PresetManager.swift:450-501`
- Folder→mixed sniff: `Threshold/Parameters/PresetManager.swift:1505-1511`
- Formula library store: `Threshold/Formulas/FormulaLibraryStore.swift:64-80`
- Effect kind enum: `Threshold/Formulas/EmbeddedFormula.swift:39-46`
- Effect tag enum: `Threshold/App/LightingTypes.swift:20-46`
- Embedded registered one-at-a-time: `Threshold/App/FormulaCatalog.swift:204-260`
- Embedded exposed as reusable (picker): `Threshold/Views/FractalGridView.swift:990-1032`
- Activating a picker formula: `Threshold/App/ControlStateStore.swift:495-507`
- Custom formula tile (icon): `Threshold/Views/FractalGridView.swift:1063-1124`
- `.threshfx`→preset: `Threshold/App/AppModel+ExternalImport.swift:202-217`
- `makeCustomPreset`: `Threshold/App/AppModel+EmbeddedFormula.swift:247-270`
- Import persistence: `Threshold/App/AppModel+SceneLoading.swift:115-117`
- Embedded formula schema: `Threshold/Formulas/EmbeddedFormula.swift:58-119`
- Formula catalog categories: `Threshold/Formulas/catalog.json`
- Bundled example loading: `Threshold/Parameters/PresetManager.swift:1442-1531`
- Prior notes: `README.md:288-293`, `TECH_DEBT.md:174`
