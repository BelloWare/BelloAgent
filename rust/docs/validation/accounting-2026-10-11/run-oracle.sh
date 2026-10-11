#!/bin/sh
# Regenerates swift-usage.json and swift-app.json from Swift 0.1.122 (6319e368).
# SWIFT=<checkout>/swift-agent-0.1.122 OUT=<scratch dir> ./run-oracle.sh
set -eu
S="$SWIFT/apps/macos/PiApp"
swiftc -O -module-name PiAgentCore -o "$OUT/helper" helper-src/main.swift "$SWIFT"/packages/swift-host/Sources/PiAgentCore/*.swift
swiftc -O -module-name Oracle -o "$OUT/app" app-src/*.swift "$S/Design/MetricFormats.swift" \
  "$S/Dashboard/GatewayAccounting.swift" "$S/Dashboard/SessionStatsPills.swift" "$S/Storage/SessionReference.swift" \
  "$S/Inspector/MetricsFooter.swift" "$S/Workspaces/CostLimit.swift"
"$OUT/helper" usage-cases.json > swift-usage.json
"$OUT/app" swift-usage.json formats.json sessions.json gateway-aggregate.sql > swift-app.json
