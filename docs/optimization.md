# Performance Optimization Plan

This document tracks concrete steps to reduce startup stalls, main‑isolate jitter, and runtime overhead in FlClash. Items are grouped by area with rationale and implementation notes.

## 1) Startup / First Frame
- **Defer non-critical init**: Move DeviceInfo/PackageInfo, SharedPreferences fetch, localization load, dynamic color fetch, and window init to after first frame. Hydrate UI with cached defaults first.
- **Lazy singletons**: Turn `Preferences` and `Request` into lazy holders so `SharedPreferences.getInstance()` and Dio creation are deferred until first use.
- **Geo seed off-main**: Copy `MMDB/GEOIP/GEOSITE/ASN` assets in an isolate; avoid `flush: true` unless required, and skip write when files already exist.

## 2) Config / Profile Handling
- **Isolate config patching**: Run `patchRawConfig` + file write in a worker isolate to avoid UI stalls during profile apply/start.
- **Provider path patching**: Move proxy/rule provider path rewriting into the same isolate while keeping IO on the worker side.

## 3) Runtime Loops & IPC
- **Gate traffic/runtime ticks**: Only run 1s updates when relevant UI is visible; consider lower frequency when backgrounded.
- **Offload heavy parsing**: Decode large connection/proxy lists (`getConnections`) in an isolate.
- **Throttled IP resolve**: Wrap `NetworkInterface.list` in `Isolate.run`, cache last IP, and avoid frequent recompute on connectivity changes.
- **Gate polling**: Run traffic/runtime updates at 1s only when relevant views are active and the app is foreground; otherwise degrade to slower cadence to reduce IPC and rebuilds.
- **Trim `checkIp` fan-out**: Limit to a prioritized subset of endpoints, short timeouts, and debounce invocations; cache success briefly.

## 4) Verification
- Measure time-to-first-frame and frame build times in profile mode before/after changes.
- Smoke test: profile switch, start/stop core, connectivity change, check IP, export/backup flows.
