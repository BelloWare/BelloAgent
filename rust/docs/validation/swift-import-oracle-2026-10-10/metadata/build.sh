#!/bin/zsh
# Builds the metadata oracle from the Swift app at 6319e368: MetadataStore and
# the record types it encodes, unchanged (the attachment record is the first
# 28 lines of Attachments.swift, the struct itself), plus stubs for app types
# named only in code the oracle never runs.
set -eu
R=/Users/admin/projects/pi-app; S=src; mkdir -p $S
for f in Storage/MetadataStore.swift Storage/TopicRecord.swift Storage/ChatRecordMerge.swift Composer/SkillSelection.swift Workspaces/CostLimit.swift Host/WireValue.swift; do
  git -C $R show 6319e368:apps/macos/PiApp/$f > $S/$(basename $f)
done
git -C $R show 6319e368:apps/macos/PiApp/Composer/Attachments.swift | sed -n 1,28p > $S/AttachmentRecord.swift
swiftc -O $S/*.swift stubs.swift main.swift -o metadata-oracle
