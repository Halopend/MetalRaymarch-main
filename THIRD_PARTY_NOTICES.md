# Third-party notices and provenance status

This file records known third-party source references and unresolved licensing
items in the Threshold repository. It is a transparency inventory, not a new
license grant, a warranty of provenance, or a claim that the audit is complete.
The notice in or accompanying each item and the upstream license, when
verified, control that item.

## Mandelbulber GPLv3 references — exact status unresolved

The following source headers identify Mandelbulber2's GPLv3 implementation as a
reference and retain their author/source attribution:

| Threshold file | Stated upstream reference |
| --- | --- |
| `Threshold/Formulas/Kleinian/Kleinian.h` | Mandelbulber2 [`fractal_pseudo_kleinian.cpp`](https://github.com/buddhi1980/mandelbulber2/blob/master/mandelbulber2/formula/definition/fractal_pseudo_kleinian.cpp); Theli-at and Knighty |
| `Threshold/Formulas/Menger/Menger.h` | Mandelbulber2 [`fractal_menger_sponge.cpp`](https://github.com/buddhi1980/mandelbulber2/blob/master/mandelbulber2/formula/definition/fractal_menger_sponge.cpp); Karl Menger and Knighty |

The cited Mandelbulber files and upstream repository identify the project as
GPLv3, but the Threshold headers do not record an exact upstream commit or
establish whether the Threshold implementations are independent
reimplementations or adaptations. They also do not preserve the upstream
Mandelbulber Team copyright notice or state a Threshold modification date.

Do not infer an "or later" grant for upstream portions from Threshold's project
license. If these files contain adapted Mandelbulber code, treat the upstream
portions conservatively as `GPL-3.0-only` unless an applicable "or later" grant
is verified, preserve the upstream copyright and license notices, mark the
modifications and date, and convey the combined covered work under GPLv3. If
they were independently implemented from the described methods, document that
provenance clearly. The current inline author/source references do not resolve
this question.

## Fragmentarium source with unverified license terms

All 17 tracked files under `Sources/HybridPKFraments/` are imported or
community-derived Fragmentarium shader sources. Their headers credit or refer
to authors and modifiers including Theli-at, Knighty, syntopia, Eiffie,
ChrisJRodgers, Kali, and TGM. No complete, verified upstream license grant is
present for this directory. Several files expressly record that the imported
snippet arrived without license text.

These files are therefore **not offered under Threshold's blanket GPL grant on
the strength of this repository notice**. Attribution is not permission. Do not
copy or redistribute them unless and until the applicable copyright holder's
license or another valid legal basis has been verified. The project should
verify, replace, or remove this corpus before treating the repository as a
fully redistributable release.

## Bundled formula ports with no recorded license field

The following bundled scenes and presets contain embedded Metal formula source
whose metadata credits Knighty or Fragmentarium-derived work and describes a
Threshold port, but currently provides neither a license identifier nor an
upstream source URL:

- `Threshold/Examples/Custom Scene Example/Polychora 24-Cell.threshscene`
- `Threshold/Examples/Scenes/Box.threshscene`
- `Threshold/Examples/Scenes/Great_sphere_AC36AB1F.threshscene`
- `Threshold/Examples/Scenes/Highlighter.threshscene`
- `Threshold/Examples/Scenes/Hyperbolic_Tessellation_B1D7E3A2.threshscene`
- `Threshold/Examples/Scenes/Menger Sphere.threshscene`
- `Threshold/Examples/Scenes/Newton Heightfield.threshscene`
- `Threshold/Examples/Scenes/Polychora_(4D_Solids)_2B1C086E.threshscene`
- `Threshold/Examples/Scenes/Pseudo_Kleinian_880ABBF6.threshscene`
- `Threshold/Examples/Scenes/Pseudo_Kleinian_Quaternion_Julia_D3B14883.threshscene`
- `Threshold/Examples/Scenes/Pseudo_Knightyan_F2F53E77.threshscene`
- `Threshold/Examples/Scenes/Pseudo_MandalayBox_95B889CF.threshscene`
- `Threshold/Examples/Scenes/Rock_the_cradle.threshscene`
- `Threshold/Examples/Music Presets/Legendary_Kid.threshmp`
- `Threshold/Examples/Music Presets/Mandala_PC.threshmp`

No additional redistribution permission for the embedded third-party portions
is asserted here. Their provenance and license must be resolved individually.

Two additional samples describe translations from shader or DE source but do
not record the source URL or license:

- `Threshold/Examples/Scenes/Fractal_Cartoon_F7A845E9.threshscene` describes a
  translation of Kali's "Fractal Cartoon" shader; and
- `Threshold/Examples/Scenes/Wave_Rail_B4234FA7.threshscene` describes a
  translation of a supplied waved-rail DE snippet.

Resolve whether these are independently implemented from ideas or adapted from
copyrightable source, and record the applicable provenance and license.

## Benchy model data

`Threshold/Resources/Benchy.sdfbin` is generated model data built into app
targets. Repository comments identify `3dbenchy-2.stl` as its source, but the
repository does not record the exact source URL, version, download date, author,
or license that applied to the source used for this binary. Resolve and record
that provenance before redistributing the asset in a release.

## Web research cache

The 21 tracked files under `.firecrawl/` are cached search results, scraped web
pages, and document extracts from multiple publishers. They are not Threshold
source code and are not covered by the project's GPL grant. Some cached sources
assert "All Rights Reserved" and others use source-specific terms, including
attribution licenses.

A local ignore rule does not remove already tracked files from repository
history or future clones. Treat this directory as a research cache, not a
redistributable project component, and remove it from public release artifacts
unless each retained item has been reviewed and its terms satisfied.

## Browser-loaded libraries

`SpaceTransformationsExplorer.html` references these versioned libraries from
the unpkg CDN at runtime:

- `@floating-ui/core` 1.7.3;
- `@floating-ui/dom` 1.7.4; and
- `lucide` 1.17.0.

The CDN files are not stored in this repository. If the explorer is deployed,
packaged for offline use, or changed to vendor those libraries, verify and
preserve the upstream license and copyright notices for the exact versions.

## Method and publication credits

Several original Threshold formula implementations credit mathematical methods,
papers, or community publications in their source headers. A method citation is
not necessarily evidence that source code was copied, and `License: N/A` is not
a license. Preserve the credits, but verify provenance before assuming either
that no upstream copyright applies or that an attribution supplies permission.

Known ambiguities include `Threshold/Formulas/MengerSphere/MengerSphere.h`,
which says `License: N/A` while citing a GPLv3 Mandelbulber implementation, and
`Threshold/Examples/Scenes/Embedded_Mandelbulb_3F4AF708.threshscene`, whose
embedded source credits Daniel White and Paul Nylander but records no license or
source URL. Similar `License: N/A` wording in implementation headers should be
read as an unresolved provenance statement, not as a waiver, public-domain
dedication, or exception to an otherwise applicable license.

Please report missing notices or provenance corrections to
[jean.fradet@me.com](mailto:jean.fradet@me.com).
