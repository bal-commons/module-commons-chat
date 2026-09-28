import {defineConfig} from "vite";

// For bundlers: lit and ui-core stay external, so an app shares one copy of each.
export default defineConfig({
  build: {
    lib: {entry: "src/index.ts", formats: ["es"], fileName: () => "index.js"},
    rollupOptions: {external: [/^lit/, /^@bal-commons\//]},
    sourcemap: true,
    emptyOutDir: true
  }
});
