import Testing
@testable import Threshold

@Suite("Transformation equation unlock")
struct TransformationEquationUnlockTests {
    @Test("Catalog covers every built-in kind exactly once")
    func completeUniqueCoverage() {
        let lessons = TransformationEquationCatalog.lessons
        let lessonIDs = lessons.map(\.id)
        let kindIDs = SpaceWarpKind.allCases.map(\.rawValue)
        let spokenMath = lessons.map(\.spokenMathematicalNotation)

        #expect(lessons.count == 19)
        #expect(lessons.count == SpaceWarpKind.allCases.count)
        #expect(Set(lessonIDs) == Set(SpaceWarpKind.allCases.map(TransformationLessonID.core)))
        #expect(Set(lessonIDs).count == lessons.count)
        #expect(lessonIDs.allSatisfy { $0.rawValue.hasPrefix("core.") })
        #expect(
            TransformationUnlockProgress.runtimeKindIDs(from: Set(lessonIDs))
                == Set(kindIDs)
        )
        #expect(lessons.allSatisfy { !$0.mathematicalNotation.isEmpty })
        #expect(spokenMath.allSatisfy { !$0.isEmpty })
        #expect(Set(spokenMath).count == lessons.count)
        #expect(lessons.allSatisfy {
            $0.spokenMathematicalNotation != $0.mathematicalNotation
        })
        func normalizedProductWords(_ value: String) -> String {
            var separated = ""
            for character in value {
                if character.isUppercase,
                   let previous = separated.last,
                   !previous.isWhitespace {
                    separated.append(" ")
                }
                if character.isLetter || character.isNumber {
                    separated.append(contentsOf: String(character).lowercased())
                } else {
                    separated.append(" ")
                }
            }
            return " " + separated.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ") + " "
        }
        let distinctiveCatalogNames = lessons
            .map(\.kind)
            .filter { $0 != .scale && $0 != .mirror }
            .map { normalizedProductWords($0.displayName) }
        for lesson in lessons {
            let lockedCopy = [
                lesson.mathematicalNotation,
                lesson.spokenMathematicalNotation,
                lesson.hint,
            ] + TransformationEquationCatalog.cheatSheet(for: lesson).flatMap {
                [$0.notation, $0.meaning]
            }
            let normalizedLockedCopy = normalizedProductWords(lockedCopy.joined(separator: " "))
            #expect(
                !normalizedLockedCopy.contains(normalizedProductWords(lesson.kind.displayName)),
                "Locked copy names \(lesson.kind.displayName)"
            )
            for hiddenName in distinctiveCatalogNames {
                #expect(
                    !normalizedLockedCopy.contains(hiddenName),
                    "Locked copy for \(lesson.kind.displayName) names another catalog feature"
                )
            }
        }
        #expect(lessons.allSatisfy { !$0.metalNotation.isEmpty })
        #expect(lessons.allSatisfy { !$0.hint.isEmpty })
    }

    @Test("Education levels cover the catalog once in authored order")
    func educationLevelCoverage() {
        let levels = TransformationEducationPath.levels
        let orderedKinds = levels.flatMap(\.kinds)

        #expect(levels.map(\.id) == [1, 2, 3, 4, 5])
        #expect(levels.map(\.requiredToAdvance) == [2, 3, 4, 2, nil])
        #expect(levels.map(\.kinds) == [
            [.scale, .mirror, .tiling],
            [.ripple, .boxFold, .planeFold, .offsetFold],
            [.sphereFold, .inversion, .shells, .kaleidoscope, .circle, .scaleRepeat],
            [.mengerFold, .twist, .bend],
            [.coxeter, .icosahedralCut, .mandelboxStep],
        ])
        #expect(orderedKinds.count == SpaceWarpKind.allCases.count)
        #expect(Set(orderedKinds) == Set(SpaceWarpKind.allCases))
        #expect(Set(orderedKinds).count == orderedKinds.count)
        #expect(levels.allSatisfy { $0.lessons.map(\.kind) == $0.kinds })
        for level in levels {
            for kind in level.kinds {
                #expect(TransformationEducationPath.level(containing: kind)?.id == level.id)
            }
        }
    }

    @Test("Every authored complete Metal mapping unlocks only its own kind")
    func canonicalEquationsAndAliases() {
        for lesson in TransformationEquationCatalog.lessons {
            #expect(TransformationEquationCatalog.match(lesson.mathematicalNotation) == nil)
            #expect(TransformationEquationCatalog.match(lesson.metalNotation) == lesson.kind)
            for alias in lesson.acceptedAliases {
                #expect(TransformationEquationCatalog.match(alias) == lesson.kind)
            }
        }
    }

    @Test("Formatting may vary without changing Metal tokens")
    func formattingVariants() {
        for lesson in TransformationEquationCatalog.lessons {
            let formatted = "/* equation transcription */\n"
                + lesson.metalNotation
                    .replacingOccurrences(of: " ", with: " \n\t")
                + "\n// end"
            #expect(TransformationEquationCatalog.match(formatted) == lesson.kind)
        }

        #expect(TransformationEquationCatalog.match(
            "p = mix(p, abs(p), clamp(op.strength, 0.0, 1.0F));"
        ) == .mirror)
        #expect(TransformationEquationCatalog.match("p = p * op.strength") == .scale)
        #expect(TransformationEquationCatalog.match("p *= op.strength") == .scale)

        let ripple = TransformationEquationCatalog.lessons.first { $0.kind == .ripple }!
        var missingInternalTerminator = ripple.metalNotation
        if let semicolon = missingInternalTerminator.firstIndex(of: ";") {
            missingInternalTerminator.remove(at: semicolon)
        }
        #expect(TransformationEquationCatalog.match(missingInternalTerminator) == nil)
        #expect(TransformationEquationCatalog.assess(
            missingInternalTerminator,
            for: ripple
        ) == .statementBoundary)
    }

    @Test("Focused attempts accept local renaming and explain near misses")
    func focusedAttemptFeedback() {
        let scale = TransformationEquationCatalog.lessons.first { $0.kind == .scale }!
        let mirror = TransformationEquationCatalog.lessons.first { $0.kind == .mirror }!
        let ripple = TransformationEquationCatalog.lessons.first { $0.kind == .ripple }!
        let renamedRipple = ripple.metalNotation
            .replacingOccurrences(of: "float3 axis =", with: "float3 direction =")
            .replacingOccurrences(of: "p + axis *", with: "p + direction *")
            .replacingOccurrences(of: "dot(p, axis)", with: "dot(p, direction)")
            .replacingOccurrences(of: "float freq =", with: "float frequency =")
            .replacingOccurrences(of: " * freq", with: " * frequency")

        #expect(TransformationEquationCatalog.assess(
            renamedRipple,
            for: ripple
        ) == .matched)
        #expect(TransformationEquationCatalog.match(renamedRipple) == .ripple)
        #expect(TransformationEquationCatalog.assess(
            "p = p *",
            for: scale
        ) == .incomplete)
        #expect(TransformationEquationCatalog.assess(
            "p = (p * op.strength;",
            for: scale
        ) == .unbalancedDelimiters)
        #expect(TransformationEquationCatalog.assess(
            "p = p * op.Strength;",
            for: scale
        ) == .caseMismatch)
        #expect(TransformationEquationCatalog.assess(
            "p = p; * op.strength",
            for: scale
        ) == .statementBoundary)
        #expect(TransformationEquationCatalog.assess(
            scale.mathematicalNotation,
            for: scale
        ) == .nonASCIIPunctuation)
        #expect(TransformationEquationCatalog.assess(
            mirror.metalNotation,
            for: scale
        ) == .differentLesson(mirror.id))
        #expect(!TransformationEquationAttempt.incomplete.guidance.isEmpty)
    }

    @Test("Matcher requires the complete authored point map")
    func rejectsPartialAndExtraCode() {
        let mirror = TransformationEquationCatalog.lessons.first { $0.kind == .mirror }!
        let ripple = TransformationEquationCatalog.lessons.first { $0.kind == .ripple }!

        #expect(TransformationEquationCatalog.match("") == nil)
        #expect(TransformationEquationCatalog.match("p = abs(p);") == nil)
        #expect(TransformationEquationCatalog.match("float angle = op.strength * dot(p, axis) * 1.5f;") == nil)
        #expect(TransformationEquationCatalog.match("float r2 = dot(p.xz, p.xz);") == nil)
        #expect(TransformationEquationCatalog.match("please use \(mirror.metalNotation)") == nil)
        #expect(TransformationEquationCatalog.match("\(mirror.metalNotation) p = p;") == nil)
        #expect(TransformationEquationCatalog.match(String(ripple.metalNotation.dropLast())) == nil)
    }

    @Test("Metal matching is case-sensitive and token-safe")
    func rejectsLexerNearMisses() {
        let mirror = TransformationEquationCatalog.lessons.first { $0.kind == .mirror }!

        #expect(TransformationEquationCatalog.match(mirror.metalNotation.uppercased()) == nil)
        #expect(TransformationEquationCatalog.match(
            "p = mix(p, a b s(p), clamp(op.strength, 0.0f, 1.0f));"
        ) == nil)
        #expect(TransformationEquationCatalog.match(
            "p = mix(p, abs(p), clamp(op.strength, 0.0 f, 1.0f));"
        ) == nil)
        #expect(TransformationEquationCatalog.match(
            "p = mix(p, abs(p), clamp(op.strength, 0.0e, 1.0f));"
        ) == nil)
        #expect(TransformationEquationCatalog.match(
            "p = mix(p, abs(p), clamp(op.strength, 0.0f, 1.0f));;"
        ) == nil)
        #expect(TransformationEquationCatalog.match(
            "p = mix(p, abs(p), clamp(op.strength, 0.0f, 1.0f)); /*"
        ) == nil)
        #expect(TransformationEquationCatalog.match(
            "p = mix(p, abs(p), clamp(op.strength, 0.0f, 1.0f))；"
        ) == nil)
        #expect(TransformationEquationCatalog.match(
            "p = mix(p, abs(p), clamp(op.strength, 0.0f, 1.0f)); // accepted comment"
        ) == .mirror)
    }

    @Test("General Coxeter and fixed icosahedral mappings stay distinct")
    func reflectionMappingsAreDistinct() {
        let coxeter = TransformationEquationCatalog.lessons.first { $0.kind == .coxeter }!
        let icosahedral = TransformationEquationCatalog.lessons.first { $0.kind == .icosahedralCut }!

        #expect(coxeter.metalNotation != icosahedral.metalNotation)
        #expect(coxeter.metalNotation.contains("op.p1"))
        #expect(icosahedral.metalNotation.contains("-0.809016994f"))
        #expect(TransformationEquationCatalog.match(coxeter.metalNotation) == .coxeter)
        #expect(TransformationEquationCatalog.match(icosahedral.metalNotation) == .icosahedralCut)
    }

    @Test("Lessons use real point-map code rather than invented helpers")
    func noPseudoHelpersOrPartialAssignments() {
        let forbidden = [
            "rotate(", "sphereFold(", "sortDescending(", "descendingSort(",
            "coxeterFold(", "foldAcrossCoxeterMirrors(", "boxFold(",
        ]
        for lesson in TransformationEquationCatalog.lessons {
            #expect(lesson.metalNotation.contains("p"))
            #expect(forbidden.allSatisfy { !lesson.metalNotation.contains($0) })
        }
    }

    @Test("Each lesson receives a compact relevant cheat sheet")
    func contextualCheatSheets() {
        for lesson in TransformationEquationCatalog.lessons {
            let entries = TransformationEquationCatalog.cheatSheet(for: lesson)
            #expect((2...8).contains(entries.count))
            #expect(entries.first?.notation == "p = expression;")
            #expect(Set(entries.map(\.notation)).count == entries.count)
            #expect(entries.allSatisfy { !$0.meaning.isEmpty })
        }

        let mirror = TransformationEquationCatalog.lessons.first { $0.kind == .mirror }!
        let ripple = TransformationEquationCatalog.lessons.first { $0.kind == .ripple }!
        let kaleidoscope = TransformationEquationCatalog.lessons.first { $0.kind == .kaleidoscope }!
        let scaleRepeat = TransformationEquationCatalog.lessons.first { $0.kind == .scaleRepeat }!
        let coxeter = TransformationEquationCatalog.lessons.first { $0.kind == .coxeter }!
        let mandelbox = TransformationEquationCatalog.lessons.first { $0.kind == .mandelboxStep }!

        #expect(TransformationEquationCatalog.cheatSheet(for: mirror).map(\.notation).contains("abs(x) / fabs(x)"))
        #expect(TransformationEquationCatalog.cheatSheet(for: ripple).map(\.notation).contains("sin / cos / sincos"))
        #expect(TransformationEquationCatalog.cheatSheet(for: kaleidoscope).map(\.notation).contains("atan2(y, x)"))
        #expect(TransformationEquationCatalog.cheatSheet(for: kaleidoscope).map(\.notation).contains("fmod(x, period)"))
        #expect(TransformationEquationCatalog.cheatSheet(for: scaleRepeat).map(\.notation).contains("log / exp"))
        #expect(TransformationEquationCatalog.cheatSheet(for: coxeter).map(\.notation).contains("op.p1/p2 · op.axisX/Y"))
        #expect(!TransformationEquationCatalog.cheatSheet(for: coxeter).map(\.notation).contains("op.axisX/Y/Z"))
        #expect(TransformationEquationCatalog.cheatSheet(for: mandelbox).map(\.notation).contains("p0"))
        #expect(TransformationEquationCatalog.cheatSheet(for: mandelbox).map(\.notation).contains("fma(a, b, c)"))
    }

    @Test("Unlock progress round-trips stable semantic lesson IDs")
    func progressRoundTrip() {
        let expected: Set<TransformationLessonID> = [
            .core(.mirror),
            .core(.scale),
            .core(.tiling),
        ]
        let encoded = TransformationUnlockProgress.encode(expected)

        #expect(TransformationUnlockProgress.defaultsKey == "Transformations.unlockedEquationLessonIDs.v2")
        #expect(TransformationUnlockProgress.legacyDefaultsKey == "Transformations.unlockedEquationRawIDs.v1")
        #expect(encoded == #"["core.mirror","core.scale","core.tiling"]"#)
        #expect(TransformationUnlockProgress.decode(encoded) == expected)
        #expect(TransformationUnlockProgress.runtimeKindIDs(from: expected) == [
            SpaceWarpKind.mirror.rawValue,
            SpaceWarpKind.scale.rawValue,
            SpaceWarpKind.tiling.rawValue,
        ])
    }

    @Test("Equation drafts follow lesson identity and preserve pack drafts")
    func perLessonDrafts() {
        let scale = TransformationLessonID.core(.scale)
        let mirror = TransformationLessonID.core(.mirror)
        let future = TransformationLessonID(rawValue: "pack.wave")

        var encoded = TransformationEquationDraftStore.update(
            "p = p * op.strength;",
            for: scale,
            in: ""
        )
        encoded = TransformationEquationDraftStore.update(
            "mirror work",
            for: mirror,
            in: encoded
        )
        encoded = TransformationEquationDraftStore.update(
            "future work",
            for: future,
            in: encoded
        )

        #expect(TransformationEquationDraftStore.draft(for: scale, in: encoded)
            == "p = p * op.strength;")
        #expect(TransformationEquationDraftStore.draft(for: mirror, in: encoded)
            == "mirror work")
        encoded = TransformationEquationDraftStore.update("", for: scale, in: encoded)
        #expect(TransformationEquationDraftStore.draft(for: scale, in: encoded).isEmpty)
        #expect(TransformationEquationDraftStore.draft(for: mirror, in: encoded)
            == "mirror work")
        #expect(TransformationEquationDraftStore.draft(for: future, in: encoded)
            == "future work")
        #expect(TransformationEquationDraftStore.legacyLessonID(focusedRawID: -1)
            == .core(.mirror))
        #expect(TransformationEquationDraftStore.legacyLessonID(
            focusedRawID: Int(SpaceWarpKind.scale.rawValue)
        ) == .core(.scale))
        #expect(TransformationEquationDraftStore.legacyLessonID(focusedRawID: 999) == nil)
    }

    @Test("Representative V1 learners never lose an already-open level")
    func legacyCurriculumCompatibility() {
        let legacySnapshots: [(String, Set<Int>)] = [
            ("2,15", [1, 2]),
            ("2,3,7,12,15", [1, 2, 3]),
            ("2,3,4,5,6,7,9,12,15", [1, 2, 3, 4]),
            ("0,2,3,4,5,6,7,9,12,13,15", [1, 2, 3, 4, 5]),
        ]

        for (legacy, expectedOpenLevels) in legacySnapshots {
            let mapped = TransformationUnlockProgress.decode(
                "",
                legacyEncoded: legacy
            )
            #expect(TransformationEducationPath.unlockedLevelIDs(mappedIDs: mapped)
                .isSuperset(of: expectedOpenLevels))
        }
    }

    @Test("Education levels open at their authored boundaries")
    func educationProgressionBoundaries() {
        func ids(_ kinds: [SpaceWarpKind]) -> Set<TransformationLessonID> {
            Set(kinds.map(TransformationLessonID.core))
        }

        let empty: Set<TransformationLessonID> = []
        #expect(TransformationEducationPath.unlockedLevelIDs(mappedIDs: empty) == [1])
        #expect(TransformationEducationPath.guideLessons(mappedIDs: empty).map(\.kind) == [
            .scale, .mirror, .tiling,
        ])

        let oneFoundation = ids([.mirror])
        #expect(TransformationEducationPath.unlockedLevelIDs(mappedIDs: oneFoundation) == [1])

        let openLevelTwo = ids([.mirror, .scale])
        #expect(TransformationEducationPath.unlockedLevelIDs(mappedIDs: openLevelTwo) == [1, 2])

        let twoFolds = openLevelTwo.union(ids([.ripple, .boxFold]))
        #expect(TransformationEducationPath.unlockedLevelIDs(mappedIDs: twoFolds) == [1, 2])

        let openLevelThree = twoFolds.union(ids([.planeFold]))
        #expect(TransformationEducationPath.unlockedLevelIDs(mappedIDs: openLevelThree) == [1, 2, 3])

        let threeRadial = openLevelThree.union(ids([.sphereFold, .inversion, .shells]))
        #expect(TransformationEducationPath.unlockedLevelIDs(mappedIDs: threeRadial) == [1, 2, 3])

        let openLevelFour = threeRadial.union(ids([.kaleidoscope]))
        #expect(TransformationEducationPath.unlockedLevelIDs(mappedIDs: openLevelFour) == [1, 2, 3, 4])

        let oneComposition = openLevelFour.union(ids([.mengerFold]))
        #expect(TransformationEducationPath.unlockedLevelIDs(mappedIDs: oneComposition) == [1, 2, 3, 4])

        let openLevelFive = oneComposition.union(ids([.twist]))
        #expect(TransformationEducationPath.unlockedLevelIDs(mappedIDs: openLevelFive) == [1, 2, 3, 4, 5])
        #expect(TransformationEducationPath.deepestUnlockedLevel(mappedIDs: openLevelFive).id == 5)

        let everything = ids(SpaceWarpKind.allCases)
        #expect(TransformationEducationPath.unlockedLevelIDs(mappedIDs: everything) == [1, 2, 3, 4, 5])
        #expect(TransformationEducationPath.levels.allSatisfy {
            TransformationEducationPath.isComplete($0, mappedIDs: everything)
        })
        #expect(TransformationEducationPath.guideLessons(mappedIDs: everything).count == 19)
    }

    @Test("Out-of-order knowledge stays mapped without skipping level gates")
    func outOfOrderEducationProgress() {
        let outOfOrder: Set<TransformationLessonID> = [
            .core(.ripple),
            .core(.boxFold),
            .core(.planeFold),
            .core(.coxeter),
        ]

        #expect(TransformationEducationPath.unlockedLevelIDs(mappedIDs: outOfOrder) == [1])
        let guideKinds = TransformationEducationPath.guideLessons(mappedIDs: outOfOrder).map(\.kind)
        #expect(guideKinds == [
            .scale, .mirror, .tiling,
            .ripple, .boxFold, .planeFold,
            .coxeter,
        ])
    }

    @Test("Education guidance follows the deepest open level and its real blocker")
    func educationGuidance() {
        func ids(_ kinds: [SpaceWarpKind]) -> Set<TransformationLessonID> {
            Set(kinds.map(TransformationLessonID.core))
        }

        let empty: Set<TransformationLessonID> = []
        #expect(TransformationEducationPath.preferredLesson(mappedIDs: empty)?.kind == .scale)

        let oneFoundation = ids([.scale])
        #expect(TransformationEducationPath.preferredLesson(mappedIDs: oneFoundation)?.kind == .mirror)

        let openLevelTwo = ids([.mirror, .scale])
        #expect(TransformationEducationPath.preferredLesson(mappedIDs: openLevelTwo)?.kind == .ripple)

        let levelThree = TransformationEducationPath.levels[2]
        let blockerFromEmpty = TransformationEducationPath.blockingLevel(
            for: levelThree,
            mappedIDs: empty
        )
        #expect(blockerFromEmpty?.id == 1)
        #expect(TransformationEducationPath.mappingsRemainingToAdvance(
            from: blockerFromEmpty!,
            mappedIDs: empty
        ) == 2)

        let levelFour = TransformationEducationPath.levels[3]
        let blockerFromLevelTwo = TransformationEducationPath.blockingLevel(
            for: levelFour,
            mappedIDs: openLevelTwo
        )
        #expect(blockerFromLevelTwo?.id == 2)
        #expect(TransformationEducationPath.mappingsRemainingToAdvance(
            from: blockerFromLevelTwo!,
            mappedIDs: openLevelTwo
        ) == 3)
    }

    @Test("One threshold mapping reports every transitively opened level")
    func cascadingLevelUnlock() {
        let before: Set<TransformationLessonID> = [
            .core(.mirror),
            .core(.ripple),
            .core(.boxFold),
            .core(.planeFold),
            .core(.sphereFold),
            .core(.inversion),
            .core(.shells),
            .core(.kaleidoscope),
            .core(.mengerFold),
            .core(.twist),
        ]
        var after = before
        after.insert(.core(.scale))

        #expect(TransformationEducationPath.unlockedLevelIDs(mappedIDs: before) == [1])
        #expect(TransformationEducationPath.newlyUnlockedLevels(
            before: before,
            after: after
        ).map(\.id) == [2, 3, 4, 5])
        #expect(TransformationEducationPath.preferredLesson(mappedIDs: after)?.kind == .coxeter)
        #expect(TransformationEducationPath.unmappedLessonCount(mappedIDs: after) == 8)

        let finalLevelComplete = after.union([
            .core(.coxeter),
            .core(.icosahedralCut),
            .core(.mandelboxStep),
        ])
        #expect(TransformationEducationPath.isComplete(
            TransformationEducationPath.levels[4],
            mappedIDs: finalLevelComplete
        ))
        #expect(TransformationEducationPath.unmappedLessonCount(mappedIDs: finalLevelComplete) == 5)
    }

    @Test("Just Use opens the catalog without granting Education progress")
    func experienceModeAccess() {
        let encoded = TransformationUnlockProgress.unlock(.mirror, in: "")
        let mappedLessons = TransformationUnlockProgress.decode(encoded)
        let mapped = TransformationUnlockProgress.runtimeKindIDs(from: mappedLessons)

        #expect(TransformationExperienceMode.defaultsKey == "Transformations.experienceMode.v1")
        #expect(TransformationExperienceMode.decode("education") == .education)
        #expect(TransformationExperienceMode.decode("justUse") == .justUse)
        #expect(TransformationExperienceMode.decode("unexpected") == .education)

        #expect(TransformationAccessPolicy.addMenuLessons(
            mode: .education,
            mappedIDs: mapped
        ).map(\.kind) == [.mirror])
        #expect(TransformationAccessPolicy.canAdd(
            .mirror,
            mode: .education,
            mappedIDs: mapped
        ))
        #expect(!TransformationAccessPolicy.canAdd(
            .twist,
            mode: .education,
            mappedIDs: mapped
        ))
        #expect(TransformationAccessPolicy.canAdd(
            .twist,
            mode: .justUse,
            mappedIDs: mapped
        ))
        #expect(TransformationAccessPolicy.addMenuLessons(
            mode: .justUse,
            mappedIDs: mapped
        ).map(\.kind) == TransformationEquationCatalog.lessons.map(\.kind))
        #expect(TransformationAccessPolicy.canInspectSource(
            for: .mirror,
            mode: .education,
            mappedIDs: mapped
        ))
        #expect(TransformationAccessPolicy.canInspectSource(
            for: .twist,
            mode: .justUse,
            mappedIDs: mapped
        ))
        #expect(!TransformationAccessPolicy.canInspectSource(
            for: .twist,
            mode: .education,
            mappedIDs: mapped
        ))
        #expect(!TransformationAccessPolicy.canInteract(
            withRawKindID: 999,
            mode: .justUse,
            mappedIDs: [SpaceWarpKind.twist.rawValue]
        ))
        var unknown = SpaceWarpOpValue(kind: .mirror)
        unknown.type = 999
        #expect(!TransformationAccessPolicy.hasExactInstance(
            of: .twist,
            in: [unknown]
        ))
        #expect(TransformationAccessPolicy.hasExactInstance(
            of: .twist,
            in: [unknown, SpaceWarpOpValue(kind: .twist)]
        ))
        let recipe = WarpCatalog.recipes[0]
        let partiallyMapped = Set(recipe.requiredKinds.dropLast().map(\.rawValue))
        #expect(TransformationAccessPolicy.missingKinds(
            for: recipe,
            mode: .education,
            mappedIDs: partiallyMapped
        ) == [recipe.requiredKinds.last!])
        #expect(!TransformationAccessPolicy.canApply(
            recipe,
            mode: .education,
            mappedIDs: partiallyMapped
        ))
        #expect(TransformationAccessPolicy.instantiate(
            recipe,
            mode: .education,
            mappedIDs: partiallyMapped
        ) == nil)
        #expect(TransformationAccessPolicy.canApply(
            recipe,
            mode: .education,
            mappedIDs: Set(recipe.requiredKinds.map(\.rawValue))
        ))
        #expect(TransformationAccessPolicy.canApply(
            recipe,
            mode: .justUse,
            mappedIDs: []
        ))
        #expect(TransformationAccessPolicy.instantiate(
            recipe,
            mode: .justUse,
            mappedIDs: []
        )?.count == recipe.instantiate(ifAllowed: { _ in true })?.count)
        #expect(TransformationAccessPolicy.eligibleKinds(
            from: WarpCatalog.randomPalette,
            mode: .education,
            mappedIDs: [SpaceWarpKind.twist.rawValue]
        ) == [.twist])
        #expect(TransformationUnlockProgress.encode(mappedLessons) == encoded)
    }

    @Test("Education blocks hidden music modulation at the render boundary")
    func runtimeMusicAccessBoundary() {
        func packedStrength(_ settings: RenderSettings) -> Float {
            withUnsafePointer(to: settings.snapshot().spaceWarpStack.ops) { tuple in
                tuple.withMemoryRebound(
                    to: SpaceWarpOp.self,
                    capacity: Int(kMaxSpaceWarpOps)
                ) { $0[0].strength }
            }
        }

        let settings = RenderSettings()
        var op = SpaceWarpOpValue(kind: .twist)
        op.strength = 0.4
        settings.spaceWarpStack = [op]
        let offset = [
            SpaceWarpFieldKey(slot: 0, field: .strength): Float(0.5),
        ]

        // RenderSettings stays permissive for standalone lower-level callers;
        // AppModel installs the persisted app policy before rendering begins.
        settings.setSpaceWarpAudioOffsets(offset)
        #expect(abs(packedStrength(settings) - 0.9) < 1e-5)
        settings.setSpaceWarpAudioOffsets([:])

        settings.setSpaceWarpInteractionAccess(
            allowsUnmapped: false,
            mappedKindIDs: []
        )
        settings.setSpaceWarpAudioOffsets(offset)
        #expect(abs(packedStrength(settings) - 0.4) < 1e-5)

        settings.setSpaceWarpInteractionAccess(
            allowsUnmapped: false,
            mappedKindIDs: [SpaceWarpKind.twist.rawValue]
        )
        settings.setSpaceWarpAudioOffsets(offset)
        #expect(abs(packedStrength(settings) - 0.9) < 1e-5)

        // Relocking removes an already-published transient immediately.
        settings.setSpaceWarpInteractionAccess(
            allowsUnmapped: false,
            mappedKindIDs: []
        )
        #expect(abs(packedStrength(settings) - 0.4) < 1e-5)

        // A future raw kind must not inherit Twist's access through the model's
        // rendering fallback.
        var unknown = op
        unknown.type = 999
        settings.spaceWarpStack = [unknown]
        settings.setSpaceWarpInteractionAccess(
            allowsUnmapped: false,
            mappedKindIDs: [SpaceWarpKind.twist.rawValue]
        )
        settings.setSpaceWarpAudioOffsets(offset)
        #expect(abs(packedStrength(settings) - 0.4) < 1e-5)

        settings.setSpaceWarpInteractionAccess(
            allowsUnmapped: true,
            mappedKindIDs: []
        )
        settings.setSpaceWarpAudioOffsets(offset)
        #expect(abs(packedStrength(settings) - 0.4) < 1e-5)

        settings.spaceWarpStack = [op]
        settings.setSpaceWarpInteractionAccess(
            allowsUnmapped: true,
            mappedKindIDs: []
        )
        settings.setSpaceWarpAudioOffsets(offset)
        #expect(abs(packedStrength(settings) - 0.9) < 1e-5)
    }

    @Test("Assistance cannot reveal an unmapped answer before its focused hint")
    func assistanceProgression() {
        let initial = TransformationAssistanceStage.vocabulary

        #expect(TransformationAssistancePolicy.advance(
            from: initial,
            event: .revealAnswer,
            isMapped: false,
            isFocused: true
        ) == .vocabulary)
        #expect(TransformationAssistancePolicy.advance(
            from: initial,
            event: .requestHint,
            isMapped: false,
            isFocused: false
        ) == .vocabulary)

        let hinted = TransformationAssistancePolicy.advance(
            from: initial,
            event: .requestHint,
            isMapped: false,
            isFocused: true
        )
        #expect(hinted == .hint)
        #expect(TransformationAssistancePolicy.canRevealAnswer(
            from: hinted,
            isMapped: false,
            isFocused: true
        ))

        let answered = TransformationAssistancePolicy.advance(
            from: hinted,
            event: .revealAnswer,
            isMapped: false,
            isFocused: true
        )
        #expect(answered == .fullAnswer)
        #expect(TransformationAssistancePolicy.advance(
            from: answered,
            event: .requestHint,
            isMapped: false,
            isFocused: true
        ) == .fullAnswer)
        #expect(TransformationAssistancePolicy.advance(
            from: initial,
            event: .revealAnswer,
            isMapped: true,
            isFocused: false
        ) == .fullAnswer)
    }

    @Test("V1 progress migrates while unknown V2 pack IDs survive")
    func progressMigrationAndUnknownPreservation() {
        let encoded = #"["future.wave","core.mirror","core.mirror","bad id"]"#
        let legacy = "999, 2, 2, -1, nope, 15"

        #expect(TransformationUnlockProgress.decode(
            encoded,
            legacyEncoded: legacy
        ) == [
            .core(.mirror), .core(.scale),
        ])
        #expect(TransformationUnlockProgress.migratedEncoding(
            encoded,
            legacyEncoded: legacy
        ) == #"["core.mirror","core.scale","future.wave"]"#)
        #expect(TransformationUnlockProgress.unlock(
            .tiling,
            in: encoded,
            legacyEncoded: legacy
        ) == #"["core.mirror","core.scale","core.tiling","future.wave"]"#)
        #expect(TransformationUnlockProgress.encode([
            TransformationLessonID(rawValue: "future.wave"),
            TransformationLessonID(rawValue: "bad id"),
            .core(.mirror),
        ]) == #"["core.mirror","future.wave"]"#)
    }

    @Test("Unlocking is idempotent")
    func progressUnlockIsIdempotent() {
        let once = TransformationUnlockProgress.unlock(.mirror, in: "")
        let twice = TransformationUnlockProgress.unlock(.mirror, in: once)
        let withScale = TransformationUnlockProgress.unlock(.scale, in: twice)

        #expect(once == twice)
        #expect(TransformationUnlockProgress.contains(.mirror, in: withScale))
        #expect(TransformationUnlockProgress.contains(.scale, in: withScale))
        #expect(!TransformationUnlockProgress.contains(.tiling, in: withScale))
    }

    @Test("Stale progress snapshots merge without losing mapped or future IDs")
    func progressSnapshotMerge() {
        let cached = #"["core.mirror","future.wave"]"#
        let freshlyPersisted = #"["core.scale","pack.echo"]"#
        let merged = TransformationUnlockProgress.unlock(
            .tiling,
            merging: [cached, freshlyPersisted],
            legacyEncodedValues: ["7,999"]
        )

        #expect(merged == #"["core.mirror","core.ripple","core.scale","core.tiling","future.wave","pack.echo"]"#)
        #expect(TransformationUnlockProgress.decode(merged) == [
            .core(.mirror),
            .core(.ripple),
            .core(.tiling),
            .core(.scale),
        ])
    }

    @Test("Matcher rejects input beyond its fixed cap")
    func inputCap() {
        let mirror = TransformationEquationCatalog.lessons.first { $0.kind == .mirror }!
        let oversized = mirror.metalNotation
            + String(repeating: " ", count: TransformationEquationCatalog.maximumInputLength)

        #expect(oversized.utf8.count > TransformationEquationCatalog.maximumInputLength)
        #expect(TransformationEquationCatalog.match(oversized) == nil)
    }

    @Test("Metal source scanner supports warp functions with extra arguments")
    func sourceScannerHandlesMandelboxArity() {
        let step = WarpSource.metalFunction(named: "warpMandelboxStep")
        let deUpdate = WarpSource.metalFunction(named: "warpMandelboxDEUpdate")

        #expect(step?.contains("float3 p, float3 p0, SpaceWarpOp op") == true)
        #expect(step?.contains("return fma(folded") == true)
        #expect(deUpdate?.contains("float currentDE, float originDE") == true)
        #expect(deUpdate?.contains("return fma(currentDE") == true)
    }
}
