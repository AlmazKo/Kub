# Kub — agent guide

Minimal **native macOS Kubernetes viewer**, AppKit (no SwiftUI), targeting **macOS 14+** (Sonoma;
built against the macOS 26 SDK, so it shows Liquid Glass on macOS 26 and classic chrome on 14/15).
For developers (not ops): browse ~22 resource kinds across all namespaces; inspect a pod's
containers/health/owning workload; stop pods, restart/scale/roll back controllers; follow logs,
read events, port-forward, scrape Prometheus **/metrics**, and pull JVM heap dumps / async-profiler
flame graphs (notified on completion). Data comes from
`kubectl` (reuses the user's kubeconfig, including EKS exec-auth). **Read-mostly and prod-safe:**
secret *values* are never shown on screen; mutating actions go through a prod-flagged confirm that
shows the exact command.

**Name & branding.** "Kub" = *Cub* + *Kubernetes*. The mascot is a low-poly polar bear cub with
Kubernetes-wheel paw pads (About artwork, `Kub/Resources/AboutHero.png`); the About slogan
"The bear necessities of Kubernetes." puns on Baloo's "Bare Necessities" (bear + minimal viewer).
Keep the bear/minimalism wordplay in future branding copy (icons, taglines, release notes).

## Build / run / verify

Native **Xcode project** (`Kub.xcodeproj`, Xcode 26+). Sources live in `Kub/` — a
**synchronized folder group**, so new files are picked up automatically (no manual
`pbxproj` edits). `xcode-select` points at Command Line Tools, so CLI builds need
`DEVELOPER_DIR`:

```bash
open Kub.xcodeproj        # edit + ⌘R — Run gives the icon, native debugger, AND cluster access
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Kub.xcodeproj -scheme Kub -configuration Debug -derivedDataPath .xcbuild build
open .xcbuild/Build/Products/Debug/Kub.app
```

- **Build settings that must hold** (breaking them was the whole migration pain):
  **App Sandbox OFF** — the app spawns `kubectl` and reads `~/.kube` / `~/.aws`, all of
  which the sandbox blocks; **Swift 6** language mode with **`SWIFT_DEFAULT_ACTOR_ISOLATION
  = nonisolated`** — the code annotates `@MainActor` explicitly and relies on non-isolated
  `Sendable` service/model types (`KubectlClient`, `KubectlProcess`, the model structs), which
  the template's default MainActor isolation breaks; **no storyboard** (`main.swift` bootstraps
  `NSApplication`). Must build **clean (no warnings)** — strict concurrency is on.
- This is a GUI app with **no test suite**. Verify by: build, **`pkill -f "Kub.app/Contents/MacOS/Kub"`
  before `open`** (else `open` re-activates a stale instance), then confirm the process is alive AND
  fresh (`ps -p <pid> -o lstart=` later than the binary mtime), survives a poll cycle (~5s), and
  check `~/Library/Logs/DiagnosticReports/` for `*kub*` crashes.
- **Screenshots are blocked** (Screen Recording isn't granted to Claude) — visual changes and live
  streaming (logs follow / port-forward) can't be confirmed by the agent; state assumptions and ask
  the user to verify look-and-feel and end-to-end streaming.
- The data layer can be checked read-only against the live cluster with `kubectl get <kind> -A -o json`
  (and `kubectl rollout history …` is a safe read). **Don't run destructive/mutating commands
  against a live cluster** (the Bash classifier also blocks `exec`/`cp`/mutations — verify those
  features by building/running; the user tests in-app).
- **Demo cluster** for screenshots and end-to-end checks: `scripts/demo-cluster.sh up|apply|open|down` —
  a two-node minikube profile `kub-demo` with a fake fleet (`scripts/demo/*.yaml`) in its **own
  kubeconfig** (`~/.kube/kub-demo.config`, contexts `acme-prod-eu` / `acme-staging-eu`). `open` launches
  Kub with only that kubeconfig, so real contexts never appear on screen. Mutations are fine there —
  always pass `--context acme-prod-eu` with that `KUBECONFIG`, never the default one.

## Architecture (`Kub/`)

- `main.swift` — `NSApplication` bootstrap (programmatic, no storyboard/`@main`).
- `AppDelegate.swift` — main menu (incl. **Settings… ⌘,**), About panel, Dock icon; `applicationDidFinishLaunching` seeds the default enabled kinds + registers the diagnostics-completion `Notifier`; `applicationWillTerminate` → `windowController.shutdown()` (kill child processes on Cmd-Q).
- `Settings.swift` / `SettingsWindowController.swift` — UserDefaults-backed `Settings` store + the ⌘, window (**JDK integration** toggle + the heap-dump folder picker).
- `MainWindowController.swift` — window, toolbar (context picker + customize + group/**bookmarks**/details/**port-forwards**/**tasks**/refresh + search), `NSSplitViewController` (full-height sidebar), binds the view model, confirm popovers, detail-panel coordination + **live-log stream** + **metrics scrape** + **diagnostics tasks** (surfaced in the **Tasks** dropdown + a completion notification), context color band, window sizing. `shutdown()` tears down every child process/task.
- `SidebarViewController.swift` — flat source-list of `ResourceKind`s (element counts, one thin **enabled/disabled divider**, drag-to-reorder / cross-divider show-hide). No section headers, no pinned-kinds section (namespace bookmarks live in the table now).
- `ResourceListViewController.swift` — the main table (one `ResourceKind` across all namespaces), **grouped by a chosen dimension** (`GroupBy`: namespace / status / node / workload — toggled from the toolbar **Group** island, collapsible groups with resource-type header icons), sortable + reorder/show-hide columns (autosaved per kind) + **content-fit-on-open** (`ColumnFit`), a clickable **namespace-bookmark paw**, **type-to-search** (`SpeedSearchTableView`), per-row mini actions, a rich **row context menu** (delete/restart, scale, roll back, port-forward, bookmark namespace), bottom status bar, centered empty/error/loading text, and the bottom detail split.
- `DetailPaneView.swift` — bottom detail pane; a title with the kind's icon + a segmented switcher over per-kind `DetailSection`s (hidden when nothing's selected). Content modes: text (`DescribeFormatter` colored key/value + clickable `kub://` cross-refs, `LogFormatter` theme-aware ANSI+timestamp), `TopReportView`, `NodePodsView`, `NamespaceInventoryView`, `LiveLogView`, `MetricsView`, `EventsTableView`. A shared header **search field** filters the active table / highlights text, and **type-to-search** (`SpeedSearch`) starts filtering as soon as the pane has focus (Esc clears).
- `EventsTableView.swift` — native, sortable per-resource **Events** table (Time / Type / Reason / Message / Count, newest first, Type colored by `statusKind`); the Events detail tab.
- `SpeedSearch.swift` — IntelliJ-style **type-to-search** primitives (`SpeedSearchTableView` / `SpeedSearchTextView`): a printable keystroke on a focused table/text view routes to the shared search field; Esc clears.
- `ColumnFit.swift` — text-measures columns to their content (header + widest cell) for compact-on-open sizing.
- `StatusCellView.swift` — status icon+text cell (the health icon lives in the **Status** column, not next to the name), `configureNamespace` (bolder+dimmer), `MiniActionCell` (row button), and `BadgeCellView`/`ArchBadge` (colored capsule for CPU arch).
- `ConfirmPopover.swift` — transient, **opaque** `NSPopover` confirm for mutating actions (replaces the old NSAlert `ConfirmDialog`); key/value grid, prod-only warning, optional stepper, and a **live monospaced preview of the exact command** (updates as the stepper changes); anchored to the triggering row/pane. The Context row shows the context's **emoji + color** when the user customized it (an optional per-value color in the detail-row model).
- `LiveLogView.swift` — live `logs -f` view: `LogFormatter` render + filter, **Wrap / Time / Follow(auto-scroll)** toggles, pause/clear, 50k-line cap (chunk-trimmed) with non-contiguous layout for scroll perf; `LogPump` coalesces off-main lines into batched main-thread flushes. **Follow auto-suspends** when the user live-scrolls up off the tail and resumes when they scroll back to the bottom (via `NSScrollView.didLiveScroll` — user-driven only, so our own scrollToEnd / resize don't toggle it).
- `PortForward.swift` — `PortForwardController` (@MainActor): session model + start popover (local/remote ports) + sessions-list popover (status, open-in-browser, copy, stop).
- `ActivityController.swift` — `ActivityController` (@MainActor): the **Tasks** toolbar dropdown listing in-flight long diagnostics (heap dump / profile) with a progress bar (determinate for profiles, indeterminate for heap dumps) + elapsed time + Stop; a 0.5s ticker refreshes rows while the popover is open. Both this and Port-forwards are disabled while their list is empty.
- `Diagnostics.swift` — `AsyncProfile` presets, `ProcessAction`, `DiagnosticPaths` (async-profiler tar resolved from the **app bundle**), `LocalProcess`.
- `Notifier.swift` — `Notifier` (`@unchecked Sendable`, `UNUserNotificationCenterDelegate`): a local notification when a heap dump / profile finishes; clicking it reveals the artifact in Finder. Gated on **live** authorization (`canDeliver()`), else the caller falls back to the reveal popover.
- `Metrics.swift` — Prometheus `/metrics` model + `PrometheusParser` (text exposition — CRLF, `+Inf`/`-Inf`/`NaN`, quoted labels, trailing timestamps) + `MetricsDiscovery` (endpoint resolution) + `MetricsSources`.
- `MetricsView.swift` — the **Metrics** detail tab (pods): a filterable, sortable table (metric / labels / value; TYPE+HELP on hover) + an editable `port`/`path` + Load toolbar for a manual override.
- `ClusterViewModel.swift` — `@MainActor` owner of all state + polling + per-context caches (`rowCache`/`countCache`/`nodeArchCache`); `podMetrics(for:override:)` (discover endpoint → scrape → parse off-main).
- `KubeService.swift` — `protocol KubeService` (Sendable) + `KubectlClient`; incl. `podMetrics` (ephemeral **port-forward + local HTTP GET**) and `metricsSources` (ServiceMonitors/PodMonitors/Services, best-effort/empty without the operator).
- `Kubectl.swift` — async one-shot runner (`run`, gated) **and a streaming primitive** (`KubectlProcess` / `stream`, ungated) for `logs -f` / `port-forward`; `PortForwardReady` bridges a port-forward's stdout to an async "ready on local port N" await (single-resolve, cancellation-aware).
- `Models.swift` — lean `Decodable` structs (incl. `containerStatus.lastState`+`image`, pod `conditions`, `ownerReferences`/`labels`/`annotations`, node `nodeInfo`, `IntOrString`, Service `selector`/port `targetPort`, `K8sServiceMonitor`/`K8sPodMonitor`).
- `Domain.swift` — `ResourceKind` (~22 kinds; + `scalable`/`rollbackable`/`isNamespaced`/…), `ResourceRow`, `StatusKind`, `DetailSection` (incl. `.metrics`), `ResourceColumn` (+ `.badge` style), **`GroupBy`** (namespace/status/node/workload).
- `PodStatus.swift` — `Derive` (JSON → `ResourceRow`), pod STATUS derivation, `healthReport` (the "Why" tab — with owning-workload + OOM/restart forensics), `containersReport` (Containers tab), `controllingWorkload` (resolve Pod→ReplicaSet→Deployment), `Quantity`, `Age`.
- `TopReport*.swift` / `TopSummaryView.swift` — pod `top` process table + CPU/Mem indicator card.
- `ContextAppearance.swift` (per-context color/emoji, `ResourceKindStore` incl. the **developer default enabled set** + one-time seed, **`PinnedNamespaces`** — per-context namespace bookmarks) / `ContextCustomizeViewController.swift`.

`MainWindowController → ClusterViewModel → KubeService` is the dependency direction. The UI is
driven by `ClusterViewModel`'s `on*Changed` closures.

## Key conventions & invariants

- **kubectl behind a protocol.** All cluster access goes through `KubeService`; `KubectlClient`
  shells out (`get -A -o json`, `get pod -o json`, `delete`, `rollout restart|undo|history`,
  `scale`, `describe`, `logs`(+`-f`), `port-forward`, `get events`, `get -o name` for counts,
  `exec`/`cp` for diagnostics). Swappable for a native client later — keep UI/VM kubectl-agnostic.
- **Swift 6 strict concurrency.** UI types are `@MainActor`. `KubeService` is `Sendable`; models are
  `Sendable` value types. Non-Sendable statics (NSFont, ISO formatters, `LogFormatter`/`DescribeFormatter`)
  are created locally per call. Streaming/`@unchecked Sendable` helpers (`KubectlProcess`, `LogPump`,
  `DataBox`) guard their state with an `NSLock` and marshal to `@MainActor` via `DispatchQueue.main.async`.
- **Generic resource model.** Adding a kind = (1) `ResourceKind` case + `displayName`/`singularName`/
  `kubectlResource`/`symbol`/`section`/`primaryAction`/`columns` in `Domain.swift` (most switches are
  exhaustive — the compiler lists what to fill), (2) a `Decodable` struct in `Models.swift`, (3) a
  `Derive.<kind>` in `PodStatus.swift` returning a `ResourceRow`, (4) a `case` in
  `KubectlClient.resources(kind:context:)`. `primaryAction` is optional; add `.scalable` / `.rollbackable`
  to opt a controller into scale / rollout-undo. **Cluster-scoped kinds** (PV/StorageClass/nodes/namespaces)
  set `isNamespaced=false` (drops the `-A`), get `[.overview]` detail sections (the events query needs a
  namespace), and rely on `describe()` omitting `-n` when namespace is empty.
- **Detail tabs.** A kind lists its `DetailSection`s via `ResourceKind.detailSections`. Adding a tab =
  a `DetailSection` case (+ `.title`) + a branch in `ClusterViewModel.detailText` (or a dedicated
  content view) + a `setText`/`show(...)` route in `DetailPaneView`. The switches are exhaustive —
  don't fold a new case into a grouped arm that returns empty. Pods: Overview / **Why** / **Containers** /
  Logs (live) / Events / **Metrics** / Top. Controllers: Overview / **History** / Events.
- **Metrics tab (pods).** `podMetrics(for:override:)` scrapes a pod's Prometheus `/metrics` over an
  **ephemeral `kubectl port-forward` + local HTTP GET** (the kubelet path — the API-server pod proxy
  hangs on the user's EKS). The port-forward is torn down on success/error/timeout/cancellation; the
  exposition text is parsed **off the main actor** (`Task.detached`). Endpoint discovery order (first
  "confident" hit is scraped automatically, else the guess is pre-filled and waits for Load): a
  **ServiceMonitor/PodMonitor** that targets the pod (authoritative — exact port+path, resolving
  SM→Service→pod and port-name→targetPort) → `prometheus.io/port`+`/path` → a container port named
  `*metrics*`/`*prom*` → a best-effort guess (management/http port → first port → 8080).
- **Diagnostics completion notifications.** A finished heap dump / profile posts a `UNUserNotification`
  (click → reveal in Finder). `runDiagnostic` uses it **only when `Notifier.canDeliver()`** (live
  authorization) is true; otherwise it falls back to the row-anchored reveal popover, so the artifact
  path is never silently lost. Without a bundle id (bare binary) notifications are skipped entirely.
- **Tasks dropdown.** Long diagnostics register in `ActivityController` (`runDiagnostic` → `begin`, torn
  down in the task's `defer` → `finish`) and show progress in the **Tasks** toolbar popover. Stop
  cancels the client-side wait (the in-pod `kubectl exec` is one-shot, so it may still finish — the row
  is removed immediately regardless). Torn down in `shutdown()`.
- **Default enabled kinds.** `ResourceKindStore.defaultEnabled` (a developer top-7: pods, deployments,
  services, ingresses, configMaps, secrets, events) is seeded **once** on first launch
  (`seedDefaultsIfNeeded`, guarded by a flag) into the disabled set; everything else starts hidden but is
  one right-click / drag away. Later show/hide choices persist.
- **Hide System Namespaces.** A persisted View-menu toggle (**⌘⇧K**, UserDefaults `HideSystemNamespaces`)
  drops `kube-*` namespaces from the table via `ResourceRow.isSystemNamespace` (`ResourceListViewController.applyFilter`).
  Other menu/row affordances: **⌘F** focuses the search field, and the row context menu has **Copy Name**.
- **Search everywhere.** Besides the toolbar search (`⌘F`), a focused table or read-only text view starts a
  **type-to-search** the moment you type (`SpeedSearch` → the pane/table filter), Esc clears — on the main
  table and every detail table/text view (Events / node-pods / namespace-inventory / describe).
- **Settings / JDK integration.** `Settings.jdkIntegrationEnabled` (⌘, window, default on) gates the JVM
  diagnostics: when off, the process **Top** tab's right-click "JDK" submenu (Heap Dump / Profile) doesn't
  appear. The menu reads the setting fresh each right-click.
- **Mutations always confirm.** delete / restart / **scale** / **rollback** / heap-dump / profile go
  through `ConfirmPopover` (prod/remote flagged → Return defaults to Cancel). Polling is **paused**
  around the popover (`pauseForConfirm`/`resumeAfterConfirm`) because it's anchored to a table row.
- **Streaming processes** (`logs -f`, `port-forward`) use `Kubectl.stream` → `KubectlProcess`, which
  runs **outside** the concurrency gate (a stream would otherwise hold a slot forever) and is
  **stoppable**. Every stream handle must be torn down on section/row change, details-off, minimize,
  window close, **and app terminate** (via `shutdown()`), or child kubectl processes orphan to launchd
  and leak bound ports.
- **Secret values are never shown.** Secrets/ConfigMaps display only key counts; the "Why" tab reads
  only status reasons. (A future decode-to-clipboard must stay explicit-consent, off-screen.)
- **Polling model.** The *visible* kind polls every **5s**; *other* kinds' sidebar counts every **60s**
  (`loadCount` reuses fresh cached data). The Top tab live-polls every ~3s. Auto-refresh + counts pause
  during a confirm. Pod arch is joined from a **60s-TTL `nodeArchCache`** so it never rides the 5s poll.
- **Per-context caches** (`rowCache`/`countCache`/`nodeArchCache`, keyed by context): switching contexts
  (or kinds) shows cached data instantly, then refreshes. Namespace bookmarks (`PinnedNamespaces`) are per-context too.
- **Events "unread" badge.** The Events sidebar counter shows `+N` new events since you last viewed the
  Events tab (per-context `seenEventKeys` baseline, event identity = `metadata.name` fresh from
  `eventKeys`, on the 60s counts cadence), hidden while Events is the visible kind. See the state-machine
  in `ClusterViewModel.applyEventKeys`.
- **Bottom status bar** shows all *in-flight* kubectl commands — latest + `+N more`, with a loader.
- **Errors** are shown **centered in the content area** (red, wrapping), not a banner.

## Gotchas (these bit us — don't reintroduce)

- **EKS exec-auth needs PATH.** GUI launches get a minimal `PATH` without `/opt/homebrew/bin` /
  `/usr/local/bin`, so kubectl can't find the `aws` exec-credential plugin. `Kubectl.augmentedEnvironment()`
  augments `PATH` on every spawned process (one-shot **and** streaming) — keep that.
- **Orphaned child processes on Cmd-Q.** `NSApplication.terminate` (Cmd-Q/Quit/Dock) does **not** fire
  `windowWillClose`, so teardown lives in `MainWindowController.shutdown()` called from **both**
  `windowWillClose` and `AppDelegate.applicationWillTerminate`. Without it, `port-forward`/`logs -f`
  children survive and hold their ports.
- **Content-fit columns + no stretch.** Tables use `.noColumnAutoresizing` so fitted widths hold;
  the main table therefore needs a **horizontal scroller** (`hasHorizontalScroller`) or wide kinds
  (Events) push the trailing action button off-screen. Fit runs once per kind (gated on whether a
  saved autosave layout exists) so manual resizes stick.
- **Labels can widen the resizable window.** Long-text labels (`statusLabel`, detail title) must use
  `.defaultLow` horizontal compression resistance; the detail text view **wraps**; the centered
  empty/error label is capped ≤460 with word wrapping.
- **Window default size & autosave.** Default is **1200×720** and the **detail pane starts visible**
  (`showDetails` defaults on — `object(forKey:) as? Bool ?? true`). To change the default size, bump the
  autosave-name suffix (currently `KubMainWindow4`) and/or grow on show (`ensureComfortableSize`).
- **Context color.** `NSPopUpButton.bezelColor` doesn't reliably tint a Liquid-Glass toolbar popup; the
  context color is a **thin band over the content area** (`ResourceListViewController.setContextBandColor`).
- **Full-height sidebar** needs `fullSizeContentView` + `titlebarAppearsTransparent` + unified toolbar +
  sidebar split item; content pins to the **safe area** top.
- **Sidebar drag + show/hide.** The list is enabled kinds → one **enabled/disabled divider** (`.separator`)
  → disabled kinds; there are no section headers and no pinned-kinds section (namespace bookmarks moved
  into the table). Dragging a kind across the divider toggles show/hide (`reconcile` derives the enabled
  set from each kind's position vs the separator). Rebuild/reload wraps `reloadData` in
  `isUpdatingSelection` so AppKit's auto-select on reload doesn't fire a spurious navigation.
- **Arch badge on selection.** `BadgeCellView` drops the colored pill for white text on an emphasized
  (selected) row via `backgroundStyle`; re-resolves its layer color on light/dark switch.
- **`NSPopover` edge on a flipped table.** Row-anchored confirm popovers use `.maxY` (above/below the
  row), not `.maxX`; the built-in show animation is disabled (`animates=false`) in favor of a ~90ms
  content fade.
- **Confirm popover is opaque + shows the command.** `ConfirmPopover` fills an opaque
  `windowBackgroundColor` (a transparent popover over a table reads as a rendering glitch), and renders the
  **exact kubectl command** in a monospaced `commandBox` (`textBackgroundColor` + separator border) that
  live-updates from the stepper. The warning line is **prod-only** (`contextIsDangerous` no longer flags
  merely-remote contexts).
- **Cluster-scoped detail = Overview only.** PV/StorageClass (and any `isNamespaced=false` kind) list only
  `[.overview]`: the Events/Top/Logs queries need a namespace, and `describe()` must omit `-n` when the
  namespace is empty (passing `-n ""` errors). Don't give a cluster-scoped kind a namespaced detail tab.
- **Log scroll must not stall the app.** `LiveLogView` sets `layoutManager.allowsNonContiguousLayout =
  true` and **chunk-trims** (`maxLines=50000` → drop to `trimTo=40000` in one splice) instead of rebuilding
  the whole document per batch — a full re-layout on every append froze the *whole* app while scrolling.
  `LogPump` still coalesces off-main lines into batched main-thread flushes.
- **Detail header uses the kind icon, and hides when empty.** The detail title shows `row.kind.symbol`
  (the sidebar icon), not the type name. The section switcher's `sections` default to `[]` so the tab
  strip is **hidden until a row is selected** (an empty strip over "nothing selected" looked broken).
- **Never re-enable App Sandbox.** `ENABLE_APP_SANDBOX` must stay **NO** — the sandbox blocks spawning
  `kubectl`, network, and reading `~/.kube` / `~/.aws`, which silently breaks *everything*. The Xcode
  app template turns it on by default; the same goes for `SWIFT_DEFAULT_ACTOR_ISOLATION` (must be
  `nonisolated`, not the template's `MainActor`). See **Build / run / verify**.
- **Metrics transport = port-forward, not the API-server proxy.** `kubectl get --raw .../proxy/metrics`
  *hangs* on the user's managed EKS (the control plane can't route to pods). `podMetrics` uses an
  ephemeral `port-forward pod/NAME :remote` (kubectl picks the local port — parse it from "Forwarding
  from 127.0.0.1:<port>") + a `URLSession` GET with a timeout. Every path must `handle.stop()` the
  port-forward, or it orphans.
- **Prometheus parser + CRLF.** Swift fuses `"\r\n"` into a **single grapheme**, so a plain
  `split("\n")` sees no line breaks in a CRLF document and collapses it to one garbage sample. Normalize
  first, guarded at the **scalar** level (`text.unicodeScalars.contains("\r")` — the Character-level
  `contains("\r")` is *false* for CRLF).
- **Notifications gate on authorization, not a bundle id.** `Notifier.isAvailable` (has a bundle id) is
  not enough — a denied/undetermined permission makes `add()` silently drop the banner. Gate on
  `await canDeliver()` (live `authorizationStatus`) and fall back to the popover, or the diagnostic
  result vanishes with no trace.

## App icon

The icon is an asset-catalog icon set (`Kub/Assets.xcassets/AppIcon.appiconset`, 16–1024px,
already squircle-rounded). Xcode compiles it into the bundle (`AppIcon.icns` + `CFBundleIconName`);
`AppDelegate` additionally sets `NSApp.applicationIconImage` from `Bundle.main`'s `AppIcon.icns`.
To change the icon, replace the PNGs in `AppIcon.appiconset`.

## Diagnostics — the "JDK integration" (heap dump / async-profiler)

The JVM diagnostics are grouped as an opt-out **JDK integration**, gated by
`Settings.jdkIntegrationEnabled` (⌘, → "Enable JDK integration", default on). When enabled, right-click a
process row in the pod **Top** tab → the **"JDK" submenu** (Heap Dump / Profile); when disabled the submenu
doesn't appear. async-profiler ships **inside the app bundle** (`Kub/Resources/async-profiler-4.4-linux-x64.tar`,
bundled by Xcode, resolved via `Bundle.main`, version string in `DiagnosticPaths.asyncProfilerVersion`)
and is uploaded into the pod per run (linux/amd64 only). Heap dump locates the JVM's own `jcmd`. Both run on
a separate `diag` gate so a multi-minute op can't starve polling; artifacts land in
`/tmp/kub/profiles/<ns>/` (profiles) and `<Settings.heapDumpsDirectory>/<ns>/` (heap dumps — default
`~/Downloads/Kub`, user-picked in ⌘,; Downloads costs a one-time TCC prompt, an open-panel pick doesn't). All are confirm-gated and prod-flagged. In-flight runs
show progress in the **Tasks** toolbar dropdown and post a **completion notification** (click → reveal
in Finder), falling back to a reveal popover when notifications aren't authorized.

## Release

This repository publishes **code only**. Building, signing, notarizing and
distributing live in untracked local files — `CLAUDE.local.md` is the entry
point. Releasing, notarizing, tagging and pushing are **outward actions**:
never run them unless explicitly asked.

- `CHANGELOG.md` follows Keep a Changelog and tracks `MARKETING_VERSION` and the
  `vX.Y` tags. Add entries when shipping, not on every commit.

## Git

- `Kub.xcodeproj` + its shared scheme (`xcshareddata/xcschemes/Kub.xcscheme`) and the bundled
  `Kub/Resources/*.tar` are committed; `xcuserdata` is not. Bundle id is `almazko.Kub`.
- `.claude/` is gitignored; local settings never belong in a commit.

## Out of scope (room to grow)

Watch streams instead of polling, YAML view (Quick Look), command palette (⌘K), menu-bar extra,
notifications on bad status, CPU/MEM history sparklines via `kubectl top`, multi-container log
selection, decode-secret-to-clipboard, Helm/CRD browsing (incl. Argo `Applications`). The `KubeService`
protocol leaves room for a native API client.
