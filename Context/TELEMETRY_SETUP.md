# Telemetry setup and release runbook

Threshold has two deliberately separate telemetry paths:

| Path | Purpose | Leaves the device? | User choice |
| --- | --- | --- | --- |
| `UsageAnalytics` | Small, aggregate product-usage windows | Yes, to the app's CloudKit public database | Explicit opt-in; default off |
| `MetricKitReporter` | Apple-generated performance and diagnostic reports | No; JSON envelopes stay in Application Support | Not part of the CloudKit sharing switch |

Do not join these paths. In particular, do not upload MetricKit payloads, crash stacks,
raw preset names, user-authored content, display names, account identifiers, or stable
device identifiers through `UsageAnalytics`.

"Anonymous" below means that Threshold adds no account or stable user identifier to a
usage record. CloudKit can still attach service-managed metadata to a public-database
write, so this is not a promise of cryptographic anonymity. Review that distinction,
the CloudKit security roles, and the App Store privacy answers before each release.

## Platform behavior

The app targets and current deployment floors are:

| Scheme | Platform | Deployment floor |
| --- | --- | --- |
| `Threshold` | visionOS | 26.0 |
| `ThresholdMac` | macOS | 15.6 |
| `ThresholdiOS` | iPadOS | 26.0 |

With the Xcode 27 / Swift 6.4 SDK, `MetricKitReporter` uses the modern
`MetricManager` asynchronous report sequences on OS 27 and newer. macOS and iPadOS
consume metric and diagnostic reports. visionOS consumes diagnostic reports only;
`MetricManager.metricReports` is unavailable there.

The reporter uses `MXMetricManager` / `MXMetricManagerSubscriber` on earlier supported
OS releases or when compiled by a toolchain that cannot see the modern API. The
visionOS path remains diagnostics-only. Registration happens in each app's `App.init`
so a process-lifetime subscriber is present as early as possible. Quick Look extensions
do not register a reporter.

MetricKit delivery is opportunistic, normally covers earlier sessions, and is not
guaranteed on every launch. A lack of immediate production payloads is not itself a
failure. Use simulated payloads and deterministic store tests for the release gate.

`Analytics/RenderSignposts.swift` is a separate, Instruments-oriented trace stream.
Its per-frame `OSSignposter` intervals are intentionally not MetricKit signposts. Do
not move those high-frequency events onto a MetricKit log handle: the system limits
MetricKit signpost processing, and per-frame traffic would crowd out useful critical
sections. Add a separate, sparse signpost path only if an aggregated MetricKit use case
is defined and tested.

## Usage analytics consent contract

`AnalyticsEnabled` must behave as an explicit opt-in:

1. An unset preference means disabled.
2. No sampling, CloudKit access, pending-upload drain, or upload occurs before the user
   turns sharing on.
3. Turning sharing off clears the current in-memory window and deletes the pending
   outbox. Data collected before opt-out must not be uploaded after a later opt-in.
4. The first-launch and Settings copy must describe the same fields and destination as
   this document and `PrivacyInfo.xcprivacy`.

Each completed aggregate window is first placed in the bounded local outbox, then the
in-memory accumulators are reset. Its UUID becomes the deterministic CloudKit record
name `usage-<lowercase UUID>`. Every retry therefore targets the same record instead
of creating a new one. If CloudKit committed an earlier request but its acknowledgement
was lost, a conflict for that exact record ID is treated as delivered. Remove an outbox
item only after a confirmed save or that exact conflict; no iCloud account, a missing
entitlement, and transient network errors must leave it queued while consent remains
enabled. The queue retains at most ten windows.

## CloudKit configuration

### Identifier and capabilities

All three app variants use bundle identifier `com.puppypower.Threshold` and container:

```text
iCloud.com.puppypower.Threshold
```

The source entitlements are:

- visionOS: `Threshold/Threshold.entitlements`
- macOS: `Threshold/ThresholdMac.entitlements`
- iPadOS: `Threshold/ThresholdiOS.entitlements`

For every distribution profile, confirm the App ID has iCloud/CloudKit enabled, the
container is assigned to the App ID, and the signed product contains
`com.apple.developer.icloud-container-identifiers` plus `CloudKit` in
`com.apple.developer.icloud-services`. Source plist files are not proof that the
provisioned archive contains those entitlements.

The current client requires an iCloud identity before it writes. Configure the public
database with least privilege: authenticated clients need create access to
`UsageSnapshot`, while arbitrary clients should not be able to enumerate analytics
records. Verify the effective `_world`, `_icloud`, and `_creator` privileges in
CloudKit Console rather than relying on development defaults.

### `UsageSnapshot` schema

Create `UsageSnapshot` in the **Development** public database with these fields. Keep
the field names and types exact; all fields may be optional so older and newer builds
can coexist.

| Field(s) | CloudKit type |
| --- | --- |
| `timestamp` | Date/Time |
| `sessionDuration` | Double |
| `qualityDistribution` | String (JSON object) |
| `fractalTypeDistribution` | String (JSON object) |
| `gradientPresetDistribution` | String (JSON object) |
| `lightingPresetDistribution` | String (JSON object) |
| `avgFractalScale`, `avgFoldingLimit`, `avgSphereRadius`, `avgMinDistance` | Double |
| `avgColorMix`, `avgGlowIntensity`, `avgSafetyBubbleRadius` | Double |
| `avgBloomStrength`, `avgFogIntensity`, `avgFPS` | Double |
| `usedAudioReactive`, `usedHandGestures`, `usedRecording` | Int64 (`0` or `1`) |
| `usedSharePlay`, `usedGradientColoring`, `usedAnimation` | Int64 (`0` or `1`) |
| `presetsLoaded`, `presetsSaved` | Int64 |
| `deviceModel`, `osVersion`, `appVersion` | String |

The idempotency UUID is encoded in the `CKRecord.ID` record name, not in a schema
field. There is one `gradientPresetDistribution` field. Do not recreate the old second
gradient accumulator or overwrite the field twice.

`PresetSnapshot`, full preset JSON, and `favoritePresets`/raw preset names are not part
of anonymous usage analytics. If they remain in an older production schema, treat them
as retired fields and verify that current binaries never write them.

Add query/sort indexes only for an operational need. Exact timestamps combined with
device and OS versions can increase identifiability, so minimize dashboard access and
retention even though the client sends no stable user ID.

### Development-to-production promotion

1. Exercise a signed development build against the Development environment and inspect
   one record of every supported app version.
2. Export the schema for review. `cktool` uses a saved developer token or `--token`:

   ```sh
   xcrun cktool export-schema \
     --team-id PMHYFM3SU4 \
     --container-id iCloud.com.puppypower.Threshold \
     --environment development \
     --output-file /tmp/Threshold-CloudKit-development.ckdb
   ```

3. In CloudKit Console, deploy the reviewed schema and security-role changes to
   Production. TestFlight and App Store builds use Production; creating a type only in
   Development is insufficient.
4. Export Production separately and compare the `UsageSnapshot` names, types, indexes,
   and roles with Development.
5. Install through TestFlight, explicitly opt in, create more than ten seconds of
   active usage, background once, and confirm exactly one idempotently named record.
6. Repeat while offline and while signed out of iCloud. The app must not crash or hang,
   and it must not silently discard a consented outbox item.

CloudKit does not provide an application-level retention policy automatically. Before
shipping, assign an owner and a documented deletion/aggregation schedule for raw
`UsageSnapshot` records. Because the payload intentionally contains no application
user ID, individual-record deletion by user identity may be impossible; consent copy
and the privacy policy must not promise otherwise.

## Local MetricKit report store

`MetricKitReportStore` writes envelopes below:

```text
Application Support/Threshold/MetricKitReports
```

Each file is named deterministically as either `metric-<sha256>.json` or
`diagnostic-<sha256>.json`. Writes are atomic, identical payloads deduplicate, and the
directory is excluded from device backups. Default retention limits are:

| Kind | Count limit | Byte limit |
| --- | ---: | ---: |
| Metric | 30 files | 24 MiB |
| Diagnostic | 50 files | 64 MiB |

Pruning keeps the newest report even if it alone exceeds the byte cap. These files can
contain process state and diagnostic call stacks. The iPadOS and visionOS directory
and files use `completeUntilFirstUserAuthentication` protection. Keep them inside the
sandbox, do not expose them through document sharing, and do not copy them to CloudKit
or another network sink.

On macOS, the sandboxed path is under the app container, typically:

```text
~/Library/Containers/com.puppypower.Threshold/Data/Library/Application Support/Threshold/MetricKitReports
```

For iPadOS and visionOS, use Xcode's Devices and Simulators window to download the
signed app container when manual inspection is necessary.

### Simulating delivery on a device

1. Run a signed Debug build on a physical Mac, iPad, or Vision Pro from Xcode and leave
   the debugger attached long enough for `MetricKitReporter.start()` to run.
2. Choose **Debug > Simulate MetricKit Payloads** in Xcode.
3. Confirm new JSON envelopes appear in the Application Support directory. Replaying
   the exact same payload and reporting interval should not create a duplicate file.
4. On macOS/iPadOS, expect both metric and diagnostic envelopes when the platform
   supplies them. On visionOS, require diagnostic envelopes only.
5. Confirm the CloudKit `UsageSnapshot` record count did not change. MetricKit is
   local-only even when community sharing is enabled.
6. Exercise enough simulated files to cross both the count and byte limits, or rely on
   the injected temporary-directory tests, and confirm the newest file survives.

Simulator behavior is not a production-delivery guarantee. Before release, also run a
TestFlight build on real hardware and inspect the container after normal use. Daily
delivery can take more than 24 hours and remains opportunistic.

## Privacy manifest and App Store answers

`Threshold/PrivacyInfo.xcprivacy` must be embedded in each distributed app variant and
must agree with both implementation and consent copy.

- CloudKit `UsageSnapshot` data leaves the device, so it is collected even though the
  destination is the developer's own CloudKit container.
- The current manifest declares Product Interaction for aggregate feature/preset use,
  Performance Data for `avgFPS`, and Other Diagnostic Data for the device/OS/app
  context sent with a usage window. Each is unlinked, nontracking, and used for App
  Functionality plus Analytics.
- Local-only MetricKit files are not collected by Threshold. Do not declare Crash Data
  solely because the files exist on-device; the current manifest intentionally has no
  Crash Data entry. If any future change exports them, update the manifest, App Store
  Connect privacy answers, consent, retention policy, and this runbook before enabling
  that export.
- Keep tracking false. There are no tracking domains and the data must not be combined
  across companies' apps or used for advertising.
- Revalidate the required-reason API entries for UserDefaults, system boot time, and
  file timestamps whenever those APIs or their purposes change.

The Quick Look extensions are separate bundles. If their compiled code accesses a
required-reason API, give each extension an appropriate privacy manifest; the containing
app's manifest is not a substitute for reviewing extension code.

## dSYM retention and symbolication

MetricKit diagnostics refer to binary UUIDs. A diagnostic is useful only while the
matching symbols still exist.

1. Archive every TestFlight and App Store build; do not distribute an ad-hoc Release
   build whose `.xcarchive` is discarded.
2. Retain the complete archive and every dSYM for at least as long as a report from that
   build can be retained or exported. Prefer retaining symbols for the supported life
   of every shipped build.
3. Record the bundle version, Git SHA, archive path, and binary/dSYM UUIDs together.
4. Verify UUID agreement before diagnosing a report:

   ```sh
   xcrun dwarfdump --uuid Threshold.xcarchive/Products/Applications/Threshold.app/Contents/MacOS/Threshold
   xcrun dwarfdump --uuid Threshold.xcarchive/dSYMs/Threshold.app.dSYM
   ```

   For iPadOS/visionOS, the executable is
   `Threshold.xcarchive/Products/Applications/Threshold.app/Threshold`.
5. Never upload a dSYM or symbolicated call stack through the usage-analytics CloudKit
   path.

Release configurations must continue to use `dwarf-with-dsym`. Treat a missing dSYM or
a UUID mismatch as a release-pipeline failure, not as something that can be recovered
after a diagnostic arrives.

## Verification commands

Run the full cross-platform gate. `all` includes iPadOS so a platform-conditional
MetricKit change cannot pass by compiling only macOS and visionOS:

```sh
Scripts/build.sh all
```

For focused iteration:

```sh
Scripts/build.sh mac
Scripts/build.sh vision
Scripts/build.sh ios
Scripts/build.sh test
```

Validate configuration files and the packaged manifest:

```sh
plutil -lint \
  Threshold/PrivacyInfo.xcprivacy \
  Threshold/Threshold.entitlements \
  Threshold/ThresholdMac.entitlements \
  Threshold/ThresholdiOS.entitlements

find /path/to/Threshold.app -name PrivacyInfo.xcprivacy -print
```

Inspect a signed archive rather than trusting source entitlements:

```sh
codesign -d --entitlements :- /path/to/Threshold.app 2>/dev/null | plutil -p -
```

The automated suite must cover, at minimum:

- unset/explicit analytics consent behavior;
- opt-out purge of in-memory state and the outbox;
- stable namespaced CloudKit record IDs and retry idempotency;
- no-entitlement, no-account, save-failure, and server-record-already-exists paths;
- MetricKit envelope Codable/hash stability and duplicate suppression;
- per-kind MetricKit count and byte pruning with an injected temporary directory.

Finish with a signed archive/TestFlight smoke test. Unsigned builds are useful compile
gates, but they cannot prove CloudKit entitlements, Production schema availability,
MetricKit delivery, or App Store privacy correctness.

## Release checklist

- [ ] Sharing is off on a clean install and no CloudKit call occurs before explicit opt-in.
- [ ] Opt-out purges current and queued usage analytics.
- [ ] Development and Production `UsageSnapshot` schemas and security roles match.
- [ ] Signed entitlements name `iCloud.com.puppypower.Threshold` on every app variant.
- [ ] Current binaries do not write raw preset names, `PresetSnapshot`, or MetricKit data.
- [ ] The manifest declares Product Interaction, Performance Data, and Other Diagnostic
      Data for CloudKit usage windows; MetricKit stays local-only with no Crash Data.
- [ ] App Store Connect answers, UI copy, the manifest, and the privacy policy agree.
- [ ] MetricKit simulation writes only to Application Support and respects both caps.
- [ ] Real-device macOS, iPadOS, and visionOS behavior has been checked.
- [ ] The distributed archive and matching dSYMs are retained with UUID/build metadata.
- [ ] `Scripts/build.sh all` and the clean serial test suite pass.
