# node-b/caddy-sites

Extra Caddy sites for host B's public entry point. `../Caddyfile` imports every `*.caddy` file
here (mounted read-only at `/etc/caddy/sites`); `00-default.caddy` is a placeholder that keeps
the import valid when there is nothing else.

A second chain on this host does not start a Caddy of its own (`docs/runbook.md` section 9); its
hostnames are served from here. For Finchain mainnet, copy `mainnet.caddy.example` to
`mainnet.caddy`, check the upstream address and ports against `node-b/.env.mainnet`, point the
DNS A records of `rpc.mainnet.finchain.one` and `ws.mainnet.finchain.one` at this host's public
address, and reload Caddy without restarting anything:

```bash
docker compose -p finchain-b exec caddy caddy reload --config /etc/caddy/Caddyfile
```

The copied `*.caddy` files are host configuration and stay out of the repository (`.gitignore`);
the example and the placeholder are tracked.
