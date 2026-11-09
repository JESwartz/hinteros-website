# HinterOS.org

The project website: what HinterOS is, the stable ISO download with its checksum and signature,
and the launcher running in the browser. Static files, built with Nix, hosted on Cloudflare Pages.

## Build

```
nix build .#preview     # the site with release.example.json, kept out of search engines
nix run .#serve         # the preview on http://localhost:8000
nix build .#site        # the real site; needs ./release.json (see Releasing)
nix flake check         # builds the preview and tests publish-iso
```

Nix sees only files git tracks: `git add` a new file before building.

The docs pages come from the `hinteros-docs` repo, pinned in `flake.lock`. To publish a docs
change, run `nix flake update hinteros-docs`, commit `flake.lock`, then deploy.

| Path | What |
|---|---|
| `src/*.html` | The pages. `{{name}}` placeholders are filled from `release.json`; `{{header}}` and `{{footer}}` are `src/_header.html` and `src/_footer.html` |
| `src/try.html` | The Demo page: the `<!-- demo -->` block when the demo is built in, `<!-- nodemo -->` otherwise |
| `src/style.css`, `src/site.js` | Styles (the launcher's colours and typeface), copy buttons and the click-to-start demo |
| `src/_headers` | Cloudflare Pages headers: the CSP (allows Cloudflare Web Analytics and the Flutter demo), caching |
| `build.py` | Renders `src/` into the output directory, copies the fonts and the demo to `/demo/` |
| `release.json` | The current stable release, written by `publish-iso`. Not in the repo until 1.0.0 is published |
| `release.example.json` | Example data for the preview. Its hashes are zeros |
| `scripts/publish-iso.sh` | `nix run .#publish-iso`, see Releasing; `scripts/publish-iso-test.sh` is its check |
| `/docs/` | Docs come from the `hinteros-docs` flake input (`build.py --docs`), wrapped in `src/_docs.html` |
| `/img/shots/` | The launcher screenshots: `hinteros-docs`' `images/*.png`, converted to WebP by `flake.nix` |

The launcher demo comes from `hinteros-launcher`'s `packages.x86_64-linux.web-demo` (a Flutter
web build with base href `/demo/`). Until that output exists, `demo = null` in `flake.nix` and the
Demo page says the demo is on its way. Once it exists, add `hinteros-launcher` as a flake input
pinned to the revision the stable release uses and set `demo` to its `web-demo`.

## Releasing

After `nix run .#promote -- stable` in the system repo has pushed the release:

1. `nix run .#publish-iso` in this checkout. It clones the system repo, checks that the `stable`
   tip is a release commit (`HinterOS <version>`) signed by a key in its own
   `release/allowed_signers`, builds the ISO from exactly that commit, writes
   `dist/<version>/{hinteros-<version>-x86_64.iso,SHA256SUMS,SHA256SUMS.sig,release.json}`, signs
   `SHA256SUMS` with the release key file (`ssh-keygen -Y sign -n file`, passphrase on the
   terminal, never ssh-agent) and verifies it. It then copies `release.json` here.
   `--dry-run` shows what it would do; `--key`, `--ref`, `--repo`, `--out` and `--base-url` as
   in the script's header.
2. Upload the ISO, `SHA256SUMS` and `SHA256SUMS.sig` to the release's download location
   (default `https://git.hinteros.org/hinteros/releases/download/v<version>/`,
   a Forgejo release on the tag `v<version>`). The script prints a `curl | diff` to check it.
3. Commit `release.json`, then deploy.

## Deploy

Cloudflare Pages, direct upload (Pages' own build machines have no Nix).
`.forgejo/workflows/deploy.yml` deploys on every push, on the `hinteros-host` runner: `main`
to hinteros.org (only once `release.json` is committed), any other branch as a preview on
`<branch>.hinteros.pages.dev`. It needs the repo secrets `CLOUDFLARE_API_TOKEN` (a custom
token with Account → Cloudflare Pages → Edit) and `CLOUDFLARE_ACCOUNT_ID`. By hand:

```
nix build .#site
nix develop -c wrangler pages deploy result --project-name hinteros --branch main
```

One-time setup in the Cloudflare dashboard:

- Workers & Pages → Create → Pages → Direct upload, project name `hinteros`.
- The project → Custom domains: `hinteros.org` and `www.hinteros.org`. Then a redirect rule
  `www.hinteros.org/*` → `https://hinteros.org/${1}`.
- The project → Metrics → Web Analytics → Enable. Cloudflare adds its beacon to every page;
  `src/_headers` already allows it in the CSP. No cookies, so no consent banner.
- The ISO download host (git.hinteros.org) must stay **DNS only** (grey cloud): Cloudflare's proxy
  doesn't cache files this size and its terms discourage serving them.

`wrangler pages deploy` with any other `--branch` makes a preview deployment on
`<branch>.hinteros.pages.dev`; deploy `.#preview` there, never to `main`.

## License

GPL-3.0-only, like the rest of HinterOS. Atkinson Hyperlegible is under the SIL Open Font
License 1.1.
