# Changelog

All notable changes to Kub are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/); versions track the app's
`MARKETING_VERSION` and the `vX.Y` release tags.

## [0.2] — 2026-07-13

First public release.

### Added
- **~22 resource kinds across all namespaces** in one sortable table, grouped by
  namespace, status, node or workload, with collapsible groups, per-context
  namespace bookmarks and type-to-search in every table and text view.
- **Pod detail tabs:** Overview, *Why* (status reasons, OOM and restart
  forensics, the owning workload), Containers, Mounts, live Logs, a native
  Events table, Prometheus Metrics and the process Top.
- **Live logs** with filter, wrap, timestamps and follow that pauses on scroll-up;
  an interactive **Shell** into a container.
- **Port-forwards** started from a row and managed from the toolbar.
- **Actions:** delete, restart, scale and roll back, each behind a confirmation
  that previews the exact `kubectl` command and flags production contexts.
- **JDK integration:** heap dumps and async-profiler flame graphs from the Top
  tab, with progress in the Tasks dropdown and a completion notification.
- Per-context colour and emoji, a View-menu toggle to hide `kube-*` namespaces,
  and an About window.
