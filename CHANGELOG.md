# Changelog

## 1.5.2 — 2026-08-06

- Reconciled raw AppleSmartBattery flags with the public IOPowerSources state,
  `AppleRawExternalConnected`, charger activity and the known SMC `CHCC`
  signal, so cable and charging transitions no longer depend on one lagging
  boolean.
- Added an IOPowerSources change watcher for immediate refresh when AC power or
  charging state changes, while retaining the regular two-second sample loop.
- Made live SMC `PPBR` the preferred battery-flow magnitude and stopped using
  the charger's single-cell voltage as the primary whole-pack power estimate.
- Kept active charging ahead of a stale full flag, while suppressing `CHCC`
  residue when the system has already confirmed a fully charged battery.
- Restored the percent sign in the main battery rail and added explicit
  “正在充电 · 充入 xW”, “电池输出” and “已接电源 · 未充电” states.
- Rebuilt the battery branch as a directional flow: charging uses a green
  left-pointing arrow into the battery, discharge points toward the system,
  and an idle/full battery leaves only a thin neutral connection.
- Extended the charging preview to exercise the complete main panel instead of
  tinting only the menu-bar icon, and added six battery-state regression tests.

## 1.5.1 — 2026-08-01

- Expanded the native system About panel with a polished project summary
  containing the GitHub repository, live version/build metadata, an explicit
  dependency statement, five open-source acknowledgements, and bundled full
  license documents.
- Accepted complete XML plist documents as immediate powermetrics frame
  boundaries in addition to NUL delimiters. This removes the one-frame startup
  delay seen when macOS prefixes each frame with NUL and prevents a healthy
  enhanced stream from racing the startup watchdog.
- Kept an immediately decoded first frame even when it arrives before the XPC
  start reply, and prevented that later reply from downgrading active sampling
  back to its startup state.
- Fixed intermittent CPU-power disappearance when `powermetrics` publishes a
  zero or partial `cpu_power` frame while CPU activity remains nonzero.
- Added the same-frame `cpu_energy / elapsed_ns` average-power fallback used by
  established Apple Silicon monitors, covering CPU, GPU and ANE domains.
- Added a combined-package residual, standard IOReport value and conservative
  local estimate as ordered CPU fallbacks instead of letting a zero enhanced
  field suppress every lower-priority source.
- Reconciled CPU and GPU together when asynchronous candidates exceed their
  shared system budget, so GPU evaluation order no longer makes only CPU vanish.
- Switched the privileged plist stream to unbuffered output, paired guarded
  immediate-sample requests with explicit flush signals, and extended the cold
  startup safety window so a delayed first frame does not disable enhancement.
- Added eight host-free regression tests for plist energy conversion, zero and
  partial frames, fallback priority, invalid intervals and budget allocation.

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
