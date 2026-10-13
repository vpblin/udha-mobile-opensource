#!/bin/bash
# Compiles the Foundation-only wire layer natively and runs assertions.
# No simulator involved, so this is fast and deterministic.
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
swiftc -O \
  Udha.ai/Bridge/AttentionEvent.swift \
  Udha.ai/Bridge/BridgeModels.swift \
  Udha.ai/Bridge/ConnectionHealth.swift \
  Udha.ai/Terminal/TerminalGrid.swift \
  Udha.ai/Terminal/TerminalLinks.swift \
  Udha.ai/Bridge/MachineStats.swift \
  Udha.ai/Machines/MachineHistory.swift \
  Udha.ai/Bridge/BridgeProtocol.swift \
  Udha.ai/Meetings/MeetingModels.swift \
  Udha.ai/Videos/VideoModels.swift \
  Udha.ai/Agents/BridgeAgent.swift \
  tests/main.swift \
  -o "$OUT/protocoltests"
"$OUT/protocoltests"
