import {defineConfig} from "vite";

const banner = "/*! @bal-commons/chat-ui 0.1.0 | Apache-2.0 | Bundles Lit (BSD-3-Clause, Copyright (c) 2017 Google LLC)"
  + " and @bal-commons/ui-core (Apache-2.0); see THIRD_PARTY_NOTICES.md */";

// For a plain <script type="module">: everything in one file, from a CDN or the app's own server.
export default defineConfig({
  build: {
    lib: {entry: "src/index.ts", formats: ["es"], fileName: () => "chat-ui.bundle.js"},
    rollupOptions: {output: {banner}},
    sourcemap: true,
    emptyOutDir: false
  }
});
