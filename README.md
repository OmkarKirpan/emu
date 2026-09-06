# emu

A cycle-accurate NES emulator, written from scratch in Zig and compiled to WebAssembly, with a React/TypeScript/Vite host shell rendering via WebGPU (Canvas 2D fallback). Learning project — depth over shortcuts.

Planning is tracked as a wayfinder map on Linear (workspace: OmkarKirpan, team: Engineering) — see `docs/agents/issue-tracker.md`. The map is complete; implementation follows the milestone roadmap it produced, starting from `core/` (Zig, native + wasm32) and `web/` (React+TS+Vite).

## Deployment

Deployed to **Cloudflare Pages** by `.github/workflows/deploy.yml` on every push to `main`.

The host choice is constrained, not preferential. The emulator core runs in a Worker over `SharedArrayBuffer`-backed wasm memory, which only exists in a [cross-origin isolated](https://developer.mozilla.org/en-US/docs/Web/API/Window/crossOriginIsolated) context — meaning the host **must** serve both:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Without them `SharedArrayBuffer` is undefined and the wasm module refuses to instantiate — the app doesn't degrade, it doesn't start. **GitHub Pages is therefore not an option**: it provides no way to set custom response headers. Cloudflare Pages, Netlify and Vercel all can; this repo is configured for the first.

These headers are declared exactly once, in `web/vite.config.ts`, and applied three ways from that single source: `server.headers` (dev), `preview.headers` (`vite preview`), and a generated `dist/_headers` (Cloudflare Pages). They're then verified at three levels — `web/e2e/isolation.spec.ts` in CI against the preview server; `web/scripts/verify-headers-local.mjs`, also in CI, running `web/scripts/check-headers.mjs` against `wrangler pages dev` (Cloudflare's own local Pages emulator, `_headers` processing included) so a `_headers`-specific regression is caught on every PR without needing Cloudflare credentials; and `check-headers.mjs` again, against the live deployment URL, after each real deploy.

### One-time setup

1. Create a Cloudflare Pages project named `emu` as a **Direct Upload** project (this workflow uploads a built `dist/`; no Cloudflare-side build config is wanted).
2. Add repository secrets `CLOUDFLARE_API_TOKEN` (needs *Cloudflare Pages: Edit*) and `CLOUDFLARE_ACCOUNT_ID`.
3. Set repository variable `DEPLOY_ENABLED` to `true` — the deploy job skips itself until then, so the workflow can't fail confusingly on a fork or before setup.

To check any deployment by hand: `cd web && npm run check-headers https://your-deployment-url`.
