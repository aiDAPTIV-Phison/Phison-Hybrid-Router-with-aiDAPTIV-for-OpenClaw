---
summary: "Dev agent tools notes (C-3PO)"
read_when:
  - Using the dev gateway templates
  - Updating the default dev agent identity
---

# TOOLS.md - User Tool Notes (editable)

This file is for _your_ notes about external tools and conventions.
It does not define which tools exist; OpenClaw provides built-in tools internally.

## Examples

### imsg

- Send an iMessage/SMS: describe who/what, confirm before sending.
- Prefer short messages; avoid sending secrets.

### sag

- Text-to-speech: specify voice, target speaker/room, and whether to stream.

Add whatever else you want the assistant to know about your local toolchain.

OpenClaw injects `TOOLS.md` into `# Project Context` when it exists. Do not use the `read` tool on `TOOLS.md` unless you are editing it, the user asks, or the system prompt says it was truncated.
