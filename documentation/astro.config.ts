import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";
import searchIndex from "./integrations/search.mjs";
import { site } from "./site.config";

export default defineConfig({
  site: site.siteUrl,
  base: site.basePath,
  output: "static",
  trailingSlash: "always",
  build: { format: "directory" },
  integrations: [mdx(), searchIndex()],
  markdown: {
    // Highlighted at build time; the colours are the terminal tokens of the
    // design system (src/styles/site.css), not those of a Shiki theme.
    shikiConfig: { theme: "css-variables" },
  },
});
