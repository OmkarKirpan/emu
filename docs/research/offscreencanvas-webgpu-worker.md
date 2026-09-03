# OffscreenCanvas + WebGPU (and Canvas2D fallback) in a Dedicated Worker

Research for ENG-57 (parent: ENG-54, wayfinder planning map). Compiled 2026-09-03.

## Bottom line

**The locked architecture is viable today, but WebGPU-in-a-worker is not yet universal — the Canvas2D fallback path is what makes the architecture safe to ship now.**

- `OffscreenCanvas.getContext('2d')` inside a dedicated Worker is rock solid everywhere that matters: Chrome/Edge 69+, Firefox 105+, Safari 16.4+, all with full worker support. This has been "Baseline: Widely available" since March 2023. Treat this path as unconditionally available on any browser worth targeting in 2026. [MDN: OffscreenCanvas](https://developer.mozilla.org/en-US/docs/Web/API/OffscreenCanvas), [MDN browser-compat-data: api/OffscreenCanvas.json](https://github.com/mdn/browser-compat-data/blob/main/api/OffscreenCanvas.json)
- `OffscreenCanvas.getContext('webgpu')` inside a dedicated Worker **does** work in current shipping Chrome/Edge, Firefox, and Safari as of the versions below — but each has platform caveats (GPU/OS gating in Chrome and Firefox in particular), so WebGPU cannot be assumed universally available even on a browser that nominally "supports" it. The Canvas2D fallback is therefore load-bearing, not cosmetic.
- `navigator.gpu` (as `WorkerNavigator.gpu`) is exposed inside `DedicatedWorkerGlobalScope` per spec and in all three engines' current implementations — the worker can feature-detect WebGPU itself with no main-thread round trip, **except** in Firefox where it is explicitly unavailable in Service Workers (dedicated workers are fine).
- `transferControlToOffscreen()` is a one-shot, irreversible operation per canvas element (throws `InvalidStateError` on a second call, and on any prior `getContext()` call on the main-thread canvas). After transfer, the original `<canvas>` becomes an inert "placeholder" — its `width`/`height` content-attribute changes become a no-op — so a 256x240 NES framebuffer that needs to resize its backing store must do so from inside the worker (`offscreenCanvas.width = …`), not by touching the DOM element. Upscaling for display should be done with CSS (`width`/`height` style + `image-rendering: pixelated`) on the placeholder `<canvas>`, which is unaffected by placeholder mode since CSS sizing is orthogonal to the canvas's backing-store resolution.

**Recommendation for the wayfinder architecture:** build the renderer against `getContext('2d')` as the always-available baseline, add `getContext('webgpu')` as a progressive enhancement behind a `WorkerNavigator.gpu` + `requestAdapter()` feature check performed inside the worker itself, and expect a meaningful slice of real users (Firefox on Linux/older macOS, Safari <26, Chrome on unsupported GPU/Linux configs) to fall back to Canvas2D. That fallback must be treated as a first-class, not a "just in case," rendering path.

---

## 1. `OffscreenCanvas.getContext('webgpu')` in a dedicated Worker

Per-browser status (from MDN's `browser-compat-data`, which mirrors what MDN's and caniuse's public tables render, cross-checked against the Chromium/Mozilla/WebKit sources below):

| Browser | Ships webgpu context | Platform gates | Worker support |
|---|---|---|---|
| Chrome / Edge | Shipped by default since **Chrome 113** (April 2023); refined through 144 | 113: ChromeOS, macOS, Windows only. Later versions extended to Linux, gated to GPUs meeting a minimum feature level (e.g. Intel Gen12+ on Linux) | Yes — `OffscreenCanvas` (including `webgpu` context) works in dedicated workers since the initial ship; this was explicit in the "Intent to Ship" |
| Firefox | Shipped starting **Firefox 141** (Windows only); macOS Apple-silicon support added in 145/147; no Linux, no macOS-Intel as of research date | Windows-only at 141; Apple-silicon macOS phased in later; Firefox for Android not supported | Yes in dedicated workers; explicitly **not** available in Service Workers |
| Safari | Shipped in **Safari 26.0** (macOS/iOS/iPadOS) | No documented additional platform gate beyond the OS/Safari version itself | Yes — OffscreenCanvas + webgpu context both landed together in 26.0 |

Sources:
- Chromium "Intent to Ship: WebGPU" (blink-dev mailing list) — Chrome 113, initial platforms ChromeOS/macOS/Windows: https://groups.google.com/a/chromium.org/g/blink-dev/c/VomzPhvJCxI
- Chrome Developers, "Chrome ships WebGPU": https://developer.chrome.com/blog/webgpu-release
- Chrome Developers, "What's New in WebGPU (Chrome 143)" (tracks the ongoing platform/feature rollout): https://developer.chrome.com/blog/new-in-webgpu-143
- Mozilla Bugzilla 1753302, "Make WebGPU accessible via OffscreenCanvas" — RESOLVED FIXED, patch series titled "Expose WebGPU on DOM workers", worker-thread mochitests added: https://bugzilla.mozilla.org/show_bug.cgi?id=1753302
- MDN `browser-compat-data`, `api/OffscreenCanvas.json` (getContext, webgpu context row) and `api/GPU.json`: https://github.com/mdn/browser-compat-data/blob/main/api/OffscreenCanvas.json , https://github.com/mdn/browser-compat-data/blob/main/api/GPU.json
- caniuse, "OffscreenCanvas API: getContext: webgpu context": https://caniuse.com/mdn-api_offscreencanvas_getcontext_webgpu_context
- WebKit's dedicated feature-status page has been retired ("Please see MDN or Can I Use? for updated support data") — Safari's WebGPU ship is tracked via MDN/caniuse rather than a standalone webkit.org/status entry: https://webkit.org/status/

**Caveat on all three:** none of these are unconditional. A `requestAdapter()` call can still legitimately return `null` on a nominally-supported browser/OS combination (missing/blocklisted GPU driver, virtualized/headless environment, disabled hardware acceleration). Feature-detection must check both "does `getContext('webgpu')` exist" and "did `requestAdapter()` resolve to a non-null adapter" before committing to the WebGPU path.

## 2. `OffscreenCanvas.getContext('2d')` in a dedicated Worker

This is uniformly available and behaves the same as main-thread Canvas2D:

- Base `OffscreenCanvas` + `getContext('2d')`: Chrome/Edge 69+, Firefox 105+, Safari 16.4+ (Safari 16.4 shipped 2D-only first; WebGL/WebGL2 contexts on OffscreenCanvas landed in later Safari point releases — irrelevant here since 2D is the fallback path).
- `OffscreenCanvas` itself is explicitly documented as available inside Web Workers (constructible there, and it's the primary intended use case): "Baseline: Widely available" since March 2023.
- `OffscreenCanvasRenderingContext2D` implements the same drawing API surface as `CanvasRenderingContext2D` (draw image, `putImageData`/`getImageData`, paths, etc.), so a `putImageData`-based NES framebuffer blit needs no special-casing for running inside a worker vs. on the main thread.

Sources:
- MDN, "OffscreenCanvas": https://developer.mozilla.org/en-US/docs/Web/API/OffscreenCanvas
- MDN, "OffscreenCanvas.getContext()": https://developer.mozilla.org/en-US/docs/Web/API/OffscreenCanvas/getContext
- MDN `browser-compat-data`, `api/OffscreenCanvas.json` (2d context row): https://github.com/mdn/browser-compat-data/blob/main/api/OffscreenCanvas.json
- WebKit blog / release notes on Safari 16.4 OffscreenCanvas (2D-only at launch), referenced via search of webkit.org bug/status material: https://bugs.webkit.org/show_bug.cgi?id=254974

## 3. Is `navigator.gpu` accessible from `DedicatedWorkerGlobalScope`?

Yes. The WebGPU spec exposes the `GPU` interface's entry point as `WorkerNavigator.gpu` in addition to `Navigator.gpu`, and MDN documents the `GPU` interface itself as "available in Web Workers." Per MDN's compat data for `WorkerNavigator.gpu`:

| Browser | Worker support for `navigator.gpu` | Notes |
|---|---|---|
| Chrome/Edge | Yes, since 113 (partial) / 144 (current shape) | Same platform gates as the OffscreenCanvas webgpu context above |
| Firefox | Yes in dedicated workers since 141 | Explicitly **not** exposed in Service Workers |
| Safari | Yes, since 26.0 | — |

This means a dedicated worker can do its own `if (!('gpu' in navigator)) { fallback to 2d }` / `const adapter = await navigator.gpu.requestAdapter()` feature-detection entirely locally, with no message round-trip to the main thread needed just to decide which backend to use.

Sources:
- MDN, "GPU" interface (notes "Available in Web Workers", documents `WorkerNavigator.gpu`): https://developer.mozilla.org/en-US/docs/Web/API/GPU
- MDN `browser-compat-data`, `api/Navigator.json` and `api/WorkerNavigator.json` (`gpu` property): https://github.com/mdn/browser-compat-data/blob/main/api/Navigator.json , https://github.com/mdn/browser-compat-data/blob/main/api/WorkerNavigator.json
- W3C WebGPU spec, §4.1 "navigator.gpu": https://www.w3.org/TR/webgpu/ (editor's draft with full IDL: https://gpuweb.github.io/gpuweb/)

## 4. Gotchas transferring `<canvas>` → Worker via `transferControlToOffscreen()`

From the WHATWG HTML spec's canvas chapter and MDN:

- **One-time-only transfer.** `transferControlToOffscreen()` throws `InvalidStateError` if the canvas's context mode is not `none` — i.e. if you've already called `getContext()` on the main-thread canvas, *or* already transferred it once before. There is no way to transfer a canvas to a worker, take it back, and transfer it again (or to a second worker). Design the worker/canvas pairing as permanent for the life of that canvas element. [WHATWG HTML spec, "Transferring control to offscreen"](https://html.spec.whatwg.org/multipage/canvas.html#offscreencanvas)
- **Must transfer before calling `getContext()` on the main thread.** If your bootstrap code accidentally calls `canvas.getContext(...)` on the main thread first (e.g. a feature-detection probe), the subsequent `transferControlToOffscreen()` call will throw. Do all context creation only after the transfer, and only on the resulting `OffscreenCanvas` inside the worker.
- **Post-transfer, the original `<canvas>` becomes a placeholder.** The spec defines a "placeholder" context mode for the DOM element after transfer; attribute-change steps for `width`/`height` become a no-op in that mode. Practically: **resizing the framebuffer's backing store must happen by setting `width`/`height` on the `OffscreenCanvas` object from inside the worker** (via a `postMessage` command from the main thread telling the worker to resize, if resize is triggered by a main-thread event like a window resize observer). Setting `canvas.width = …` on the main-thread placeholder element does nothing to the actual bitmap.
- **CSS-based upscaling is unaffected and is the right tool for a 256x240 NES framebuffer.** The backing store (`OffscreenCanvas.width/height`) should stay at the native resolution (256x240, or 256x224/240 depending on region), and the *display* size should be scaled via ordinary CSS (`canvas { width: ...; height: ...; image-rendering: pixelated }`) on the main-thread placeholder `<canvas>` element. CSS size is independent of the canvas's drawing-buffer resolution and independent of placeholder mode, so resizing the displayed element (e.g. responsive layout, integer-scale changes, fullscreen) needs no worker round-trip at all — only a *resolution* change (which the NES framebuffer never needs, since its native resolution is fixed) would require messaging the worker.
- **Transfer timing:** `transferControlToOffscreen()` can be called as soon as the `<canvas>` element exists in the DOM (or even detached) — there's no requirement to wait for a layout/paint event — but the resulting `OffscreenCanvas` must be sent to the worker via `postMessage(..., [offscreen])` (structured-clone transfer list), and it is unusable on the main thread after that point (it's a transferable object, so the reference is neutered on the sending side, per the standard Transferable pattern used throughout the platform).

Sources:
- WHATWG HTML Standard, §4.12.5 "The canvas element" / "Offscreen canvases" (transferControlToOffscreen algorithm, placeholder concept, context-mode exceptions): https://html.spec.whatwg.org/multipage/canvas.html#offscreencanvas
- MDN, "HTMLCanvasElement: transferControlToOffscreen() method": https://developer.mozilla.org/en-US/docs/Web/API/HTMLCanvasElement/transferControlToOffscreen
- MDN, "OffscreenCanvas" (transferable-object framing, worker usage pattern): https://developer.mozilla.org/en-US/docs/Web/API/OffscreenCanvas

## Summary table

| Capability | Chrome/Edge | Firefox | Safari |
|---|---|---|---|
| `OffscreenCanvas` + `getContext('2d')` in dedicated Worker | 69+ | 105+ | 16.4+ |
| `OffscreenCanvas` + `getContext('webgpu')` in dedicated Worker | 113+ (platform-gated) | 141+ (Windows only initially; Apple-silicon macOS later; no Linux) | 26.0+ |
| `WorkerNavigator.gpu` in dedicated Worker | 113+ | 141+ (not in Service Workers) | 26.0+ |
| Behind a flag anywhere currently? | No (shipped by default since 113) | No (shipped by default since 141) | No (shipped by default since 26.0) |

No browser currently requires an experimental flag for either the 2D or WebGPU OffscreenCanvas-in-worker path in its shipping-release channel — but WebGPU's *effective* reach is narrowed by OS/GPU gating (Chrome, Firefox) well below "every user on a browser that lists support," so the Canvas2D fallback should be assumed to actually trigger for a non-trivial share of real users, not treated as a theoretical safety net.
