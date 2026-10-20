import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
// The custom-app SDK, its types and the media uploader, built from sd-phone's source like the rest.
import { sdkAssets } from '../../sd-phone/web/vite-plugin-sdk.ts';

// sd-phone's web/src IS the tablet UI — nothing is forked or copied. `@` points at that tree
// where it lives and `@device` swaps in the profile it gets compiled against.
const phoneRoot = fileURLToPath(new URL('../../sd-phone', import.meta.url));

// Mirrors sd-phone/web/vite.config.ts: 3D models ride inside their importing chunk as data
// URLs, because FiveM's NUI file server answers 404 for a .glb even when fxmanifest lists it,
// and Vite 8's own `?inline` route cannot load the file on Windows.
function inlineModels(): Plugin {
    return {
        name: 'sd-inline-models',
        enforce: 'pre',
        load(id) {
            if (!id.endsWith('.glb')) return null;
            const base64 = readFileSync(id).toString('base64');
            return `export default ${JSON.stringify(`data:model/gltf-binary;base64,${base64}`)};`;
        },
    };
}

export default defineConfig({
    plugins: [inlineModels(), react(), sdkAssets()],
    base: './',
    resolve: {
        alias: {
            '@': fileURLToPath(new URL('../../sd-phone/web/src', import.meta.url)),
            '@device': fileURLToPath(new URL('./device.ts', import.meta.url)),
        },
        // Those sd-phone modules are consumed as source, so their bare `react` imports would
        // otherwise resolve from their own directory and pick up sd-phone/web/node_modules — a
        // second React, and "Invalid hook call" the first time a hook runs. Listing a package
        // here anchors it to this project's node_modules no matter which tree imports it.
        dedupe: ['react', 'react-dom', 'react/jsx-runtime', 'zustand', 'lucide-react', 'clsx', 'class-variance-authority', 'html2canvas'],
    },
    // The locale catalogs are globbed relative to sd-phone's own i18n source file, so they
    // resolve to sd-phone/locales and rollup bundles them without help. The dev server serves
    // files, not bundles, so it needs both resource roots on its allowlist.
    // That allowlist serves all of sd-tablet AND sd-phone over HTTP, so the bind is pinned to
    // loopback rather than left to the default. Never run this dev server with --host.
    server: {
        host: '127.0.0.1',
        fs: { allow: ['..', phoneRoot] },
    },
    build: {
        // FiveM's CEF and the dev browser (Edge) are both modern Chromium, so
        // skip downleveling to the generic es2020 baseline.
        target: 'chrome110',
        // fxmanifest.lua's `ui_page` points at `web/build/index.html`.
        outDir: 'build',
        emptyOutDir: true,
        assetsDir: 'assets',
        cssCodeSplit: false,
        rollupOptions: {
            output: {
                // Fingerprint the entry too. fxmanifest globs
                // `web/build/assets/*.js` and the generated index.html points at
                // whatever the hash is, so the name can change freely. It MUST
                // change, because FiveM's NUI caches `index.js` by URL and serves
                // a stale copy across restarts when the name is fixed.
                entryFileNames: 'assets/index-[hash].js',
                chunkFileNames: 'assets/[name]-[hash].js',
                assetFileNames: 'assets/[name]-[hash][extname]',
            },
        },
    },
});
