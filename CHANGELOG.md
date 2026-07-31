# Changelog

## 1.5.0 — 2026-07-31

- Rebuilt the main energy-flow graphic around continuously weighted ribbons
  and dedicated label-safe destination nodes, so low-power branches no longer
  overlap, clip, or hide text as values change.
- Reworked the adapter and battery presentation into compact independent nodes
  and removed visible measured/estimated/approximation markers from the app UI.
- Enumerated the complete local AppleSMC capability table at startup while
  mapping only independently known read-only keys into the product UI.
- Preserved missing, unsupported, failed, and real zero-value SMC outcomes;
  added safe numeric decoding for float, integer, and fixed-point SMC types.
- Added direct Wi-Fi and USB rail support when the corresponding known SMC keys
  exist, while retaining dynamic residual allocation when a rail is absent.
- Increased the IOReport energy-delta window from 100 ms to 500 ms after
  device testing reproduced zero frames and misleading one-frame GPU spikes;
  continuous live QA now keeps CPU/GPU branches stable and power-balanced.
- Added a same-frame physical budget guard: a clearly impossible standard GPU
  sample falls back to the latest recent valid value, an impossible enhanced
  GPU sample falls back to the standard channel, and CPU/display values are
  bounded before the residual branch is calculated.
- Fixed enhanced sampling incorrectly timing out before `powermetrics` produced
  its first complete sample on a cold launch.
- Added initial-sample signalling, stale-child reconciliation, bounded session
  handoff retries, and durable XPC callback ownership for reliable relaunches.
- Avoided permanently marking a known SMC key missing unless the complete,
  uncapped `#KEY` index walk succeeded without a single enumeration failure.

## 1.4.1 — 2026-07-31

- Fixed “登录时启动” on a clean installation: `.notFound` now performs the
  initial `SMAppService.mainApp.register()` call instead of being treated as a
  terminal path error.
- Added explicit pending-approval state, a direct shortcut to Login Items
  settings, delayed status refresh, and clearer errors for registration races.
- Replaced the empty “其他功耗分项” state with a live 4–6 item estimate that
  reacts to system load, memory bandwidth, chip activity, and fan speed.
- Kept directly readable ANE/DRAM/media/ISP/Fabric/PCIe channels separate from
  estimated items; every modeled value is marked with `≈` and the modeled sum
  is bounded by the residual “other” power budget.
- Verified the expanded 420-point panel with six estimate cards and no text
  overflow.

## 1.4.0 — 2026-07-31

- Added dynamic CPU, GPU, display, and residual-power branches whose widths,
  labels, and terminal caps adapt to live power values.
- Added conservative CPU-power fallback estimation when a privileged
  `powermetrics` field is unavailable.
- Kept every flow label inside its animating ribbon, including the
  secondary battery path.
- Compact menu-bar battery now places the number inside the icon, omits the
  percent sign and separator gap, and turns green only while charging.
- Added a narrowly scoped launchd root helper so the same 1.4.0 binary needs
  administrator approval only once, including across relaunches and reboots.
- Added fixed-path staging, identifier plus CDHash validation, client UID
  validation, and a three-method XPC API with no arbitrary command surface.

### Known limitations

- Apple Silicon and macOS 13 or newer are required.
- The downloadable build is hardened ad-hoc signed but not Apple notarized.
- Rebuilding or upgrading changes the exact CDHash and requires one new
  approval. Stable cross-version identity requires Developer ID signing,
  notarization, and migration to `SMAppService`.
