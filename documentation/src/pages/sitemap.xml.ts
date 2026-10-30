// sitemap.xml: every page of the site, with its full address.
import type { APIRoute } from "astro";
import { getCollection } from "astro:content";
import { href, sections } from "../lib/links";

export const GET: APIRoute = async ({ site }) => {
  const docs = await getCollection("docs");
  const paths = [
    "",
    ...sections.map((section) => section.path).filter((path) => path !== "docs/"),
    ...docs.map((page) => (page.id === "index" ? "docs/" : `docs/${page.id}/`)),
  ];
  const urls = paths.map((path) => `  <url><loc>${new URL(href(path), site).href}</loc></url>`);
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls.join("\n")}
</urlset>
`;
  return new Response(body, { headers: { "Content-Type": "application/xml" } });
};
