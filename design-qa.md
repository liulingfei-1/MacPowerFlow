# MacPowerFlow 1.4 Design and Release QA

## Comparison target

- Source visual truth: user-provided reference screenshot
- Final Release ZIP, collapsed: local QA artifact
  `.build/final-1.4.0-release-collapsed.png`
- Final Release ZIP, secondary details expanded: local QA artifact
  `.build/final-1.4.0-release-expanded.png`
- Captured panel: `420 × 752 px`, dark appearance
- Package: `MacPowerFlow 1.4.0 (5)`, arm64
- Package SHA-256:
  `e33a5550b41fbbb28e3f8c254c8b0653daf01c07583a24b5c782c3d7e58987fb`
- Package size: `1,308,149 bytes`

The reference has one processor branch. MacPowerFlow intentionally keeps CPU,
GPU, display, and other power visible as four independent live branches because
those values are part of the requested product behavior.

## Visual thesis and information plan

The interface is a compact graphite instrument panel. Green is reserved for the
charging state; otherwise hierarchy comes from spacing, scale, and restrained
gray contrast. The first screen moves from source and charge state, through one
dominant energy-flow visual, to optional secondary channels and then detailed
electrical and thermal readings.

The only continuous layout motion is the `0.35 s` power-flow transition.
Branch thickness, label position, compact/two-line label mode, and terminal cap
height all move from the same live values. The secondary-channel disclosure is
the other deliberate layout transition.

## Label-containment pass

- CPU, GPU, display, and other branch heights are calculated from the current
  power distribution rather than fixed percentages.
- Each branch label samples the narrowest height across its full horizontal
  span, subtracts an internal safety margin, and switches between a two-line
  value/label or a compact single line.
- Every main branch label is masked by the exact animating
  `FlowRibbonShape`; a glyph cannot paint outside either curved edge during a
  value change.
- The upper battery/secondary-source connector is now also a real dynamic
  ribbon. Its height follows battery power with a readable minimum, its compact
  value has no artificial space before `W`, and the value is masked by that
  ribbon.
- The final Release was observed at two substantially different live samples:
  CPU `≈17.0 → ≈22.3 W`, GPU `≈1.0 → ≈1.5 W`, and other
  `≈20.6 → ≈11.0 W`. The zero-flow `0.0W` secondary label and all four branch
  labels remained inside their borders.

## Layout, color, and content pass

- The `420 px` panel preserves the reference's compact pill row, charge rail,
  source/system/consumer silhouette, and dense detail rhythm.
- The top row has one compact refresh control. No administrator shield or
  separator dot consumes permanent space.
- CPU and GPU appear only in the main energy visual. The expanded secondary
  section does not duplicate them and instead lists available ANE, memory,
  media, ISP, fabric, PCIe, or activity clues.
- “Other” is explicitly presented as a residual estimate and explains what may
  be included without inventing unavailable sensor wattages.
- The menu item renderer uses one composite image: percentage digits sit inside
  the battery body, the percent sign is omitted, and system load starts exactly
  at the battery canvas edge with no title separator or appended blank.
- Charging colors the battery, bolt, and digits green. Noncharging uses the
  semantic system label color.
- Collapsed and expanded views show no overlap, broken wrapping, card collision,
  or edge clipping.

## Accessibility and interaction pass

- The final extracted Release was launched with `--preview`, then its real
  accessibility disclosure button was used to expand the secondary details.
- The energy-flow accessibility value includes source, battery, system, CPU,
  GPU, display, and other wattages.
- Tray accessibility retains the full percentage and charging state even though
  the visible percent sign is intentionally omitted.
- Refresh and disclosure remain keyboard/accessibility buttons with descriptive
  labels.

## Privileged-service security pass

- The root XPC service exposes only protocol-version, start-sampling, and
  stop-sampling operations. It accepts no executable path, shell command,
  argument list, environment, or output path from the app.
- `/usr/bin/powermetrics` uses one compile-time path and argument list.
- The helper launches it with `posix_spawn` without
  `POSIX_SPAWN_SETPGROUP`, tracks its exact PID, sends TERM then bounded KILL,
  and reaps it with `waitpid`.
- First approval stages the prevalidated helper and installer through the
  system `/usr/bin/install` into fixed `root:wheel 0555` paths. The app
  recomputes identifier plus CDHash from those root-owned copies before the
  staged installer can execute.
- The staged installer accepts only the exact app requirement and invoking UID,
  writes only fixed root-owned destinations, and removes both staging files.
- A matching installed helper receives three connection retries before any
  reinstall decision, avoiding a password prompt caused only by slow launchd
  startup.
- The real root installation was intentionally not performed during automated
  QA; the user's first normal launch remains the approval point.

## Build and package verification

- Debug arm64 build with Swift and Objective-C warnings treated as errors:
  passed.
- Release static analysis with warnings treated as errors: passed.
- Installer Swift warnings-as-errors typecheck: passed.
- Project plist lint and release-script shell syntax: passed.
- Release ZIP was extracted and the outer app, helper, and installer all passed
  strict code-signature verification.
- Extracted binary: Mach-O 64-bit arm64.
- Extracted version/build: `1.4.0 (5)`.
- Security scan found no shell, `popen`, `system`, or `sudoers` interface in the
  shared service, helper, XPC protocol, or privileged runner.

Xcode reports a host-only CoreSimulator 1051.54/1051.55 version mismatch.
Simulator support is unrelated to this macOS target; all macOS build, analysis,
signing, archive extraction, and runtime visual checks completed successfully.

## Platform limitation

This local package is hardened ad-hoc signed and binds the installed helper to
the exact 1.4.0 App CDHash. The same binary remains password-free across app
relaunches and Mac reboots. Rebuilding or upgrading the app changes that hash
and therefore requires one new approval. Stable cross-version identity requires
a Developer ID Application certificate, notarization, and an
`SMAppService`-based LaunchDaemon.

final result: passed
