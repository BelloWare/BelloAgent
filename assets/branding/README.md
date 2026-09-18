# Bello Agent icon

The owner selected **Soft Flat Scout** (`bello-agent-flat-01-soft.png`) on
2026-09-16 for Bello Agent 0.1.6. The orange and ivory robot has a charcoal face
and the **Bello** wordmark on its chest.

[bello-agent-icon.png](bello-agent-icon.png) is the unchanged 1254×1254 imagegen
master. Its SHA-256 is
`7d0dfb6361abd2da309b414cbbeddc6b5e39a336aa89f80bf11561f655a6779e`.
It includes the approved opaque exterior margin. App, onboarding and website
assets are deterministic resizes or byte copies, with no redraw or invented
transparency mask. The historical `scripts/draw-app-icon.swift` artwork is no
longer the selected icon.

To rebuild every application size from the approved master:

```sh
swift scripts/generate-app-icon.swift assets/branding/bello-agent-icon.png apps/macos/PiApp/Assets.xcassets/AppIcon.appiconset
sips -Z 128 assets/branding/bello-agent-icon.png --out assets/branding/bello-agent-icon-128.png
sips -Z 128 assets/branding/bello-agent-icon.png --out apps/macos/PiApp/Assets.xcassets/BelloAgentIcon.imageset/bello-agent-128.png
sips -Z 256 assets/branding/bello-agent-icon.png --out apps/macos/PiApp/Assets.xcassets/BelloAgentIcon.imageset/bello-agent-256.png
```

The website copy (`assets/bello_agent_icon.png` on belloware.com) is staged from
this master by `scripts/stage-release-site.py` during release. The imagegen
provenance and prompt are recorded in [icon-0.1.6-prompt.md](icon-0.1.6-prompt.md).
