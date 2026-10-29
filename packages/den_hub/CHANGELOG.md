## Unreleased

- Invites by message keep the invite key's public half and say when an invite lets a device in
  by itself; `setupLink` and `den_hub setup-link` print the first parent's link and QR code; a
  push tells the parents when someone joined with an invite.

## 0.1.0

- First hub: HTTP API and event stream per docs/hub-api.md, WebSocket sync, MCP over HTTP and stdio, OAuth 2.1, calendar feeds in and out, reminders, mDNS, setup codes and browser linking, CLI.
