## Unreleased

- Invites by message keep the invite key's public half and say when an invite lets a device in
  by itself; `setupLink` and `den_hub setup-link` print the first parent's link and QR code; a
  push tells the parents when someone joined with an invite.
- A calendar for another family: a `shared` calendar link (`shared.ics`, the family's Everyone
  events only, UIDs `<eventId>@<familyId>.den`) with a watch stream (`/ics/<secret>/watch`);
  a hub subscribed to one hears changes in about a second, never echoes or relays another
  family's events, and removes its copies when the family stops sharing. Every feed answers with
  an ETag and `304`. `DEN_PEER_HUBS` lets a hub fetch from the other families' addresses on the
  same server through its reverse proxy on loopback.

## 0.1.0

- First hub: HTTP API and event stream per docs/hub-api.md, WebSocket sync, MCP over HTTP and stdio, OAuth 2.1, calendar feeds in and out, reminders, mDNS, setup codes and browser linking, CLI.
