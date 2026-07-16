# Security Policy

## Reporting a vulnerability

Please report security issues privately. Do not open a public GitHub issue for a
vulnerability.

- Use GitHub's private vulnerability reporting for this repository
  (Security tab, "Report a vulnerability"), or
- Email the maintainer at the address on the GitHub profile of the repository
  owner.

Include what you found, the version or commit, and the steps to reproduce.

We aim to acknowledge reports within a few days, but this is a personal project
maintained as time allows, so response may be slower.

There is no bug bounty and no paid reward program.

## Scope notes

- API keys must live only in the Cloudflare Worker secrets (or local
  `worker/.dev.vars`, which is gitignored). The Mac app should never ship raw
  provider keys.
- Every proxied Worker route (except `GET /` health) requires `x-vidi-key`.
- The optional local vidi-chat agent binds loopback; treat LAN exposure of that
  port as out of scope for a default install.
- Screen Recording, Microphone, and Accessibility permissions are required for
  core features; grant them only on machines you trust.

If you find behavior that contradicts any of the above, that is exactly the kind
of report we want.
