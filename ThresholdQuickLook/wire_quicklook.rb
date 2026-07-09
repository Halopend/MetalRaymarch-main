#!/usr/bin/env ruby
# Wires two macOS Quick Look app-extension targets (thumbnail + preview) into
# Threshold.xcodeproj and embeds them in the ThresholdMac host app.
#
# Idempotent-ish: refuses to run if the targets already exist (pass FORCE=1 to
# delete+recreate them). Dry-run friendly: point PROJECT at a copy first.
#
# Usage:
#   GEM_HOME=$HOME/.gem ruby wire_quicklook.rb /path/to/Threshold.xcodeproj
#
# Requires the `xcodeproj` gem.

require "xcodeproj"

PROJECT_PATH = ARGV[0] or abort "usage: wire_quicklook.rb <Threshold.xcodeproj>"
FORCE = ENV["FORCE"] == "1"

HOST_TARGET   = "ThresholdMac"
DEPLOY        = "26.0"
TEAM          = "PMHYFM3SU4"
HOST_BUNDLE   = "com.puppypower.Threshold"
BRIDGING      = "Threshold/Rendering/ShaderTypes.h"

# Repo-relative source paths shared by BOTH extensions (the render closure,
# discovered by the M1 CLI proof), plus the QL glue and the shader.
SHARED_SOURCES = [
  # --- render closure: existing app source files (reused, not duplicated) ---
  "Threshold/Parameters/FractalPreset.swift",
  "Threshold/Parameters/RenderSettings.swift",
  "Threshold/Parameters/RenderSettingsSnapshot.swift",
  "Threshold/Rendering/Core/RendererMath.swift",
  "Threshold/Rendering/Core/RenderPrecompute.swift",
  "Threshold/Rendering/Core/UniformsBuilder.swift",
  "Threshold/Rendering/Core/RenderModes.swift",
  "Threshold/App/FractalModelType.swift",
  "Threshold/App/FormulaCatalog.swift",
  "Threshold/App/FractalTypeDescriptor.swift",
  "Threshold/App/LightingTypes.swift",
  "Threshold/Parameters/GradientColorSystem.swift",
  "Threshold/Parameters/QualityPreset.swift",
  "Threshold/Formulas/EmbeddedFormula.swift",
  "Threshold/Parameters/Config/AudioReactiveConfig.swift",
  "Threshold/Parameters/Config/ColorConfig.swift",
  "Threshold/Parameters/Config/DisplayConfig.swift",
  "Threshold/Parameters/Config/GeometryConfig.swift",
  "Threshold/Parameters/Config/GestureConfig.swift",
  "Threshold/Parameters/Config/GestureDefaults.swift",
  "Threshold/Parameters/Config/LightingConfig.swift",
  "Threshold/Parameters/Config/PerFractalGestureStore.swift",
  "Threshold/Parameters/Config/QualityConfig.swift",
  "Threshold/Parameters/Config/SafetyBubbleConfig.swift",
  "Threshold/Parameters/Config/HandAttractionConfig.swift",
  "Threshold/Gestures/FingerGestureAction.swift",
  "Threshold/Gestures/MenuToggleGestureMode.swift",
  "Threshold/Audio/MusicReactiveTypes.swift",
  "Threshold/Parameters/ParameterTargetID.swift",
  "Threshold/Parameters/SettingsPersistence.swift",
  "Threshold/Parameters/SpaceWarpStackModel.swift",
  "Threshold/Parameters/ControlSpec.swift",
  "Threshold/Parameters/SpaceWarpStackSimplifier.swift",
  "Threshold/Parameters/ModuleRegistry.swift",
  "Threshold/Parameters/Module.swift",
  # --- embedded distance-estimator runtime compile (custom .threshfx DEs) ---
  "Threshold/Rendering/Core/CustomShaderCompiler.swift",
  "Threshold/Rendering/Generated/EmbeddedMetalSources.swift",
  # --- metal (compiled into each appex's own default.metallib) ---
  "Threshold/Rendering/Shaders.metal",
  # --- new shared glue (lives under ThresholdQuickLook/Shared) ---
  "ThresholdQuickLook/Shared/HeadlessRenderer.swift",
  "ThresholdQuickLook/Shared/RenderKitStubs.swift",
  "ThresholdQuickLook/Shared/ThresholdPreviewRender.swift",
]

# Per-extension definition.
EXTS = [
  {
    key:       "Thumbnail",
    name:      "ThresholdQLThumbnail",
    bundle:    "#{HOST_BUNDLE}.QLThumbnail",
    infoplist: "ThresholdQuickLook/Thumbnail/Info.plist",
    entitle:   "ThresholdQuickLook/Thumbnail/ThresholdQLThumbnail.entitlements",
    sources:   ["ThresholdQuickLook/Thumbnail/ThumbnailProvider.swift"],
    frameworks:["QuickLookThumbnailing.framework", "Metal.framework", "MetalKit.framework"],
  },
  {
    key:       "Preview",
    name:      "ThresholdQLPreview",
    bundle:    "#{HOST_BUNDLE}.QLPreview",
    infoplist: "ThresholdQuickLook/Preview/Info.plist",
    entitle:   "ThresholdQuickLook/Preview/ThresholdQLPreview.entitlements",
    sources:   ["ThresholdQuickLook/Preview/PreviewViewController.swift",
                "ThresholdQuickLook/Preview/InteractiveFractalView.swift"],
    frameworks:["Quartz.framework", "Metal.framework", "MetalKit.framework"],
  },
]

proj = Xcodeproj::Project.open(PROJECT_PATH)
host = proj.targets.find { |t| t.name == HOST_TARGET } or abort "no #{HOST_TARGET} target"

# --- helper: find-or-create an EXPLICIT SOURCE_ROOT file reference ---
#
# The project uses Xcode-16 synchronized folder groups (the whole `Threshold/`
# folder auto-populates the app targets, with zero explicit build files). A
# synchronized group is all-or-exclude, so we CANNOT cherry-pick a subset of
# Threshold's files into an extension that way. Instead we create explicit
# SOURCE_ROOT-relative file references (in a dedicated flat group so they don't
# visually collide with the synchronized `Threshold` folder) and add those to
# the extension target's build phase. A physical file backing two distinct
# references across two targets is fine — each target compiles its own.
def source_root_ref(proj, group, path)
  existing = group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXFileReference) && c.path == path }
  return existing if existing
  ref = group.new_reference(path, :project)  # :project => source_tree "SOURCE_ROOT"
  ref.name = File.basename(path)
  ref
end

# --- remove pre-existing targets if FORCE (fully idempotent: strip the host's
#     embed build-file + dependency, delete the leaked .appex product ref, and —
#     after the loop — drop any orphaned product refs and the whole navigator
#     group left by earlier runs, so re-running never accumulates cruft) ---
EXTS.each do |e|
  if (t = proj.targets.find { |x| x.name == e[:name] })
    abort "target #{e[:name]} already exists (set FORCE=1 to recreate)" unless FORCE
    prod = t.product_reference
    host.copy_files_build_phases.each do |ph|
      ph.files.dup.each { |bf| ph.remove_build_file(bf) if bf.file_ref == prod }
    end
    host.dependencies.dup.each { |d| d.remove_from_project if (d.target rescue nil) == t }
    t.remove_from_project
    prod.remove_from_project if prod   # remove_from_project(target) leaves this behind
  end
end
if FORCE
  # Sweep orphaned appex product refs (from this or prior runs) out of Products.
  proj.products_group.files.dup.each do |f|
    f.remove_from_project if f.path.to_s =~ /^ThresholdQL(Thumbnail|Preview)\.appex$/
  end
  # Drop the navigator group entirely so duplicate subgroups never linger; it is
  # recreated below. (ThresholdQuickLook is NOT a synchronized folder, so these
  # are just organizational refs.)
  proj.main_group.children
      .select { |c| c.display_name == "ThresholdQuickLook" && c.is_a?(Xcodeproj::Project::Object::PBXGroup) }
      .each(&:remove_from_project)
end

# --- ensure host has an Embed App Extensions copy-files phase (dst = PlugIns) ---
embed = host.copy_files_build_phases.find { |p| p.symbol_dst_subfolder_spec == :plug_ins }
unless embed
  embed = host.new_copy_files_build_phase("Embed App Extensions")
  embed.symbol_dst_subfolder_spec = :plug_ins
end

# --- dedicated navigator group holding the explicit refs (one per extension) ---
root_group = proj.main_group.children.find { |c| c.display_name == "ThresholdQuickLook" && c.is_a?(Xcodeproj::Project::Object::PBXGroup) } ||
             proj.main_group.new_group("ThresholdQuickLook")

EXTS.each do |e|
  puts "== creating #{e[:name]} (#{e[:bundle]})"
  target = proj.new_target(:app_extension, e[:name], :osx, DEPLOY)

  # Build settings on both configs.
  target.build_configurations.each do |cfg|
    s = cfg.build_settings
    s["PRODUCT_NAME"]                 = "$(TARGET_NAME)"
    s["PRODUCT_BUNDLE_IDENTIFIER"]    = e[:bundle]
    s["INFOPLIST_FILE"]               = e[:infoplist]
    s["CODE_SIGN_ENTITLEMENTS"]       = e[:entitle]
    s["MACOSX_DEPLOYMENT_TARGET"]     = DEPLOY
    s["DEVELOPMENT_TEAM"]             = TEAM
    s["SWIFT_VERSION"]                = "6.0"
    s["SWIFT_OBJC_BRIDGING_HEADER"]   = BRIDGING
    s["GENERATE_INFOPLIST_FILE"]      = "NO"
    s["SKIP_INSTALL"]                 = "YES"
    s["CODE_SIGN_STYLE"]              = "Automatic"
    s["ENABLE_HARDENED_RUNTIME"]      = "YES"
    s["LD_RUNPATH_SEARCH_PATHS"]      = ["$(inherited)", "@executable_path/../../../../Frameworks"]
    # Keep parity with the app: the shaders reference no user headers beyond the repo tree.
    s["MTL_HEADER_SEARCH_PATHS"]      = "$(inherited)"
  end

  # Per-extension navigator subgroup for the explicit refs.
  grp = root_group.new_group(e[:name])

  # Source files: shared closure + per-ext glue (explicit SOURCE_ROOT refs).
  (SHARED_SOURCES + e[:sources]).each do |p|
    ref = source_root_ref(proj, grp, p)
    target.source_build_phase.add_file_reference(ref, true)
  end

  # Frameworks.
  e[:frameworks].each do |fw|
    ref = proj.frameworks_group.files.find { |f| f.display_name == fw } ||
          proj.frameworks_group.new_reference("System/Library/Frameworks/#{fw}").tap { |r| r.source_tree = "SDKROOT" }
    target.frameworks_build_phase.add_file_reference(ref, true)
  end

  # Info.plist + entitlements as file refs (visible in navigator, not compiled).
  source_root_ref(proj, grp, e[:infoplist])
  source_root_ref(proj, grp, e[:entitle])

  # Ship catalog.json at Contents/Resources/Formulas/catalog.json so FormulaCatalog
  # finds it (subdirectory:"Formulas" lookup) — silences the "catalog.json not
  # found in bundle" log and matches the app bundle layout. The still-render path
  # does not need it; this just gives catalog-driven lookups real descriptors.
  catref = source_root_ref(proj, grp, "Threshold/Formulas/catalog.json")
  cphase = target.new_copy_files_build_phase("Copy Formula Catalog")
  cphase.symbol_dst_subfolder_spec = :resources
  cphase.dst_path = "Formulas"
  cphase.add_file_reference(catref, true)

  # Embed into host + depend on it.
  appex_ref = target.product_reference
  bf = embed.add_file_reference(appex_ref, true)
  bf.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
  host.add_dependency(target)
  puts "   embedded in #{HOST_TARGET}, #{target.source_build_phase.files.count} sources"
end

proj.save
puts "saved #{PROJECT_PATH}"
