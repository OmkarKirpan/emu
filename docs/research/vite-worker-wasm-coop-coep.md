# Vite: Worker + Wasm bundling, and COOP/COEP headers for dev/build

Researched against Vite's official docs (vite.dev, current as of Vite 8.x, Sept 2026) and MDN.
Answers ENG-58.

## Bottom line

1. **Worker that loads wasm** — bundle the worker with the constructor pattern:
   ```js
   const worker = new Worker(new URL('./worker.ts', import.meta.url), { type: 'module' })
   ```
   The `new URL(...)` must appear literally inline inside `new Worker(...)`, and any options object must be static (string literals) — Vite's detection is syntactic. Because the worker is created with `type: 'module'`, the worker script itself can use static `import` syntax, so *inside* `worker.ts` use one of the wasm-import forms below (most commonly `?init`).
   [vite.dev/guide/features#web-workers](https://vite.dev/guide/features#web-workers)

2. **Raw `.wasm` import, no wasm-bindgen tooling** — the recommended, most controllable form is **`?init`**:
   ```js
   import init from './example.wasm?init'
   const instance = await init(importObject)
   ```
   This gives an initialization function returning `Promise<WebAssembly.Instance>`, with an optional `importObject` forwarded to `WebAssembly.instantiate`. Vite also supports a bare `import * as m from './example.wasm'` (auto-instantiates and re-exposes exports as named ES exports — less control, and requires top-level `await` support), and a `?url` suffix to just get the resolved asset URL for manual `fetch()`/`WebAssembly.instantiateStreaming()`. For a hand-wired Zig module needing manual control over instantiation (custom imports, memory, etc.), **`?init` is the one Vite's own docs frame as the "explicit control" option** — that's the current-recommended pattern here.
   [vite.dev/guide/features#webassembly](https://vite.dev/guide/features#webassembly)
   In production, `.wasm` files smaller than `build.assetsInlineLimit` are inlined as base64; larger ones are emitted as static assets and fetched on demand — this applies uniformly, whether imported via `?init`, bare import, or `?url`.

3. **`vite dev` COOP/COEP** — set them directly in config via `server.headers`:
   ```js
   export default defineConfig({
     server: {
       headers: {
         'Cross-Origin-Opener-Policy': 'same-origin',
         'Cross-Origin-Embedder-Policy': 'require-corp',
       },
     },
   })
   ```
   [vite.dev/config/server-options#server-headers](https://vite.dev/config/server-options#server-headers)
   **`vite preview` needs its own, separate config** — `preview.headers` is a distinct option (also typed `OutgoingHttpHeaders`, "Specify server response headers") and is *not* inherited from `server.headers`. If you want `vite preview` to also cross-origin-isolate (useful to sanity-check the production build locally), duplicate the same two headers under `preview.headers`.
   [vite.dev/config/preview-options#preview-headers](https://vite.dev/config/preview-options#preview-headers)

4. **Production static-host deployment** — this is **entirely a hosting-platform concern, independent of Vite**. Vite's own "Building for Production" guide and "Deploying a Static Site" guide contain **no mention** of COOP/COEP, cross-origin isolation, or any response-header configuration for the built output — the build step only emits static files (HTML/JS/CSS/wasm assets); it does not run an HTTP server and has no header pipeline for the deployed artifact.
   [vite.dev/guide/build](https://vite.dev/guide/build) · [vite.dev/guide/static-deploy](https://vite.dev/guide/static-deploy)
   So headers must be configured on whichever static host serves the build output — e.g. a Netlify `_headers` file, a Vercel `vercel.json` `headers` block, or a Cloudflare Pages `_headers` file — using each platform's own mechanism. `vite preview` (with `preview.headers` set, per point 3) is useful as a local stand-in to confirm the app behaves correctly once cross-origin-isolated, but it does not substitute for, or influence, the real hosting configuration.

---

## Supporting detail

### 1–2. Worker + Wasm (vite.dev/guide/features)

**Web Workers** ([source](https://vite.dev/guide/features#web-workers)):
- Primary pattern: `new Worker(new URL('./worker.js', import.meta.url))`; add `{ type: 'module' }` for an ES module worker.
- Constraint from the docs: the `new URL()` constructor must be used **directly inside** the `new Worker()` declaration, and constructor options must be static value literals — Vite's import analysis is pattern-matching source syntax, not evaluating arbitrary expressions.
- Alternative: import-suffix syntax — `import MyWorker from './worker.js?worker'` — whose default export is a worker constructor you instantiate yourself (`new MyWorker()`). Add `&inline` to inline the worker as base64 in the production build, or `&url` to just get the worker script's URL.

**WebAssembly** ([source](https://vite.dev/guide/features#webassembly)):
- Direct import: `import init from './example.wasm'` — Vite reads the module's imports/exports from the wasm binary itself, instantiates it, and re-exposes its exports as ES named exports. (Docs note this is treated as an async module and needs top-level `await` support in the target.)
- Explicit-control import: `import init from './example.wasm?init'` then `const instance = await init(importObject)` — default export is an init function returning `Promise<WebAssembly.Instance>`; `importObject` is passed through to `WebAssembly.instantiate` as its second argument.
- Asset-URL import: append `?url` to resolve the `.wasm` file to a URL string, for manual fetch/instantiate (e.g. `WebAssembly.instantiateStreaming(fetch(url), importObject)`).
- Production build: `.wasm` assets smaller than `build.assetsInlineLimit` are base64-inlined; otherwise emitted as a static asset in the build output and fetched on demand at runtime.
- TypeScript note from the docs: enable `allowArbitraryExtensions` in `tsconfig.json` and add a `.d.wasm.ts` (or similar) ambient declaration if you want typed imports of `.wasm?init` etc.

Neither the Worker section nor the WebAssembly section on vite.dev cross-references the other — there's no documented "Worker importing wasm" special case. Because a `type: 'module'` worker is itself processed as an ES module by Vite, the same `?init` / `?url` / bare-import syntax documented for the main app applies unchanged inside the worker's source file.

### 3. Dev/preview headers (vite.dev/config)

- `server.headers` — type `OutgoingHttpHeaders`, described only as "Specify server response headers" ([source](https://vite.dev/config/server-options#server-headers)). No built-in named preset for COOP/COEP; you supply the header names/values directly, as in the snippet above.
- `preview.headers` — same type and same one-line description, listed independently under Preview Options ([source](https://vite.dev/config/preview-options#preview-headers)). Other `preview.*` options (e.g. `preview.host`, `preview.port`) explicitly document defaulting to their `server.*` counterpart when unset; `preview.headers` carries no such "defaults to server.headers" note, confirming it is a separate, independently-set option — `vite preview` will not pick up `server.headers` automatically.
- `vite preview` itself is documented as a way to locally serve the `dist/` production build to smoke-test it before deploying — the natural place to verify cross-origin isolation actually works against the real build output, provided `preview.headers` is set.

### 4. Production headers (vite.dev/guide/build, vite.dev/guide/static-deploy)

- `vite.dev/guide/build` ("Building for Production") documents `vite build` output, browser compatibility targets, public base path, chunking, library mode, and multi-page apps. It has no section on HTTP response headers or cross-origin isolation.
- `vite.dev/guide/static-deploy` ("Deploying a Static Site") documents host-specific deploy steps for Netlify, Vercel, Cloudflare Pages, GitHub Pages, and others — all framed purely in terms of build command / output directory / CLI or Git-based deploy flow. It does not mention `_headers` files, `vercel.json` headers blocks, or any header configuration for any of the listed hosts.
- Conclusion: Vite has no build-time or runtime mechanism that ships response headers with the static output. Once `vite build` produces static files, serving them with COOP/COEP is 100% the responsibility of whatever serves those files in production (Netlify `_headers`, Vercel `vercel.json`, Cloudflare Pages `_headers`, a custom Nginx/Express server, etc.) — Vite is out of the picture at that point.

### MDN — header semantics

- **Cross-Origin-Opener-Policy** ([MDN](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cross-Origin-Opener-Policy)): controls whether a document shares its top-level browsing context group with cross-origin documents it opens/is opened by. `same-origin` isolates the document into its own browsing context group (required for cross-origin isolation); default is `unsafe-none` (no isolation). Also offers `same-origin-allow-popups` for cases needing popups (e.g. OAuth) while still isolating the main window.
- **Cross-Origin-Embedder-Policy** ([MDN](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cross-Origin-Embedder-Policy)): controls whether the document can load cross-origin `no-cors` subresources at all. `require-corp` blocks any cross-origin no-cors resource that doesn't explicitly opt in via `Cross-Origin-Resource-Policy` (or is fetched in real CORS mode); `credentialless` is a looser alternative that allows such resources but strips credentials. Default is `unsafe-none`.
- Both docs agree: **cross-origin isolation** (`self.crossOriginIsolated === true`, unlocking `SharedArrayBuffer` and unthrottled `performance.now()`) requires **both** headers to be sent together — `Cross-Origin-Opener-Policy: same-origin` **and** `Cross-Origin-Embedder-Policy: require-corp` (or `credentialless`). Neither header alone is sufficient.

## Sources

- https://vite.dev/guide/features#web-workers
- https://vite.dev/guide/features#webassembly
- https://vite.dev/config/server-options#server-headers
- https://vite.dev/config/preview-options#preview-headers
- https://vite.dev/guide/build
- https://vite.dev/guide/static-deploy
- https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cross-Origin-Opener-Policy
- https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cross-Origin-Embedder-Policy
