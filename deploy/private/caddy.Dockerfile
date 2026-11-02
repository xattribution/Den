# syntax=docker/dockerfile:1
# Caddy with the Cloudflare DNS module, for the private setup (docs/hosting.md, "Private: home
# networks plus Tailscale"). The internet can't reach this server's port 80, so Caddy proves it
# owns DEN_DOMAIN with the ACME DNS-01 challenge instead: it writes a TXT record through
# Cloudflare's API. The stock image doesn't carry that module, so this builds Caddy with it.
# Both versions are pinned; change them on purpose, together with the tag in compose.yaml.

FROM caddy:2.11.7-builder AS build
RUN xcaddy build --with github.com/caddy-dns/cloudflare@v0.2.4

FROM caddy:2.11.7
COPY --from=build /usr/bin/caddy /usr/bin/caddy
# Fail the build, not the first certificate, if the module didn't make it in.
RUN caddy list-modules | grep -qx 'dns.providers.cloudflare'
