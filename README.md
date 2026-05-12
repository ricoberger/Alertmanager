# Alertmanager

**Alertmanager** is a native macOS app for viewing alerts from
[Prometheus Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/)
and [Grafana Alerting](https://grafana.com/docs/grafana/latest/alerting/).

![Alertmanager](.github/assets/screenshot.png)

## Features

- Connect to multiple
  [Prometheus Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/)
  and [Grafana Alerting](https://grafana.com/docs/grafana/latest/alerting/)
  instances, with basic authentication or bearer token authentication (token can
  be read from a file or a shell command)
- Save custom filters scoped by Alertmanager, receiver, labels, and alert state
  (firing, silenced, inhibited)
- Menu bar mode that surfaces a configurable filter at a glance
- Desktop notifications for new alerts matching a filter, with quick actions for
  source, silence, runbook, and Grafana dashboard/panel
- Alert details with status, receivers, timestamps, and labels — plus direct
  links to the source and a one-click silence action
- Quick links to runbooks (`runbook_url` annotation) and Grafana dashboards and
  panels (`__dashboardUid__` / `__panelId__` annotations)
- Configurable refresh interval (1 minute to 1 hour)
- Import and export the full configuration (Alertmanagers, filters, settings) as
  JSON

## Development

```bash
# Build (Debug, macOS)
xcodebuild -project Alertmanager.xcodeproj -scheme Alertmanager -configuration Debug build

# Build (Release)
xcodebuild -project Alertmanager.xcodeproj -scheme Alertmanager -configuration Release archive -archivePath build/Alertmanager.xcarchive
```

```bash
# Run all tests
xcodebuild -project Alertmanager.xcodeproj -scheme Alertmanager test

# Unit tests only (Swift Testing)
xcodebuild test -project Alertmanager.xcodeproj -scheme Alertmanager -only-testing:AlertmanagerTests

# UI tests only (XCTest)
xcodebuild test -project Alertmanager.xcodeproj -scheme Alertmanager -only-testing:AlertmanagerUITests
```

### SourceKit-LSP / `buildServer.json`

To make the SourceKit-LSP working properly with the Xcode project, a
`buildServer.json` file must be generated at the project root using
[`xcode-build-server`](https://github.com/SolaWing/xcode-build-server)
(installable via Homebrew: `brew install xcode-build-server`).

```bash
rm .bundle; xcodebuild -project Alertmanager.xcodeproj -scheme Alertmanager -configuration Debug -resultBundlePath .bundle build
xcode-build-server config -project Alertmanager.xcodeproj -scheme Alertmanager
```
