// The one place for the public name, the repository and the address of the
// site. SITE_URL and BASE_PATH come from the environment, so the same build
// serves the project path on GitHub Pages and a future root domain:
//
//   SITE_URL=https://taspinar.github.io BASE_PATH=/agentic-coding-template/ npm run build
//   SITE_URL=https://example.org BASE_PATH=/ npm run build

/** A base path with one slash at each end: "/" or "/name/". */
function basePath(value: string | undefined): string {
  const trimmed = (value ?? "/agentic-coding-template/").replace(/^\/+|\/+$/g, "");
  return trimmed ? `/${trimmed}/` : "/";
}

export const site = {
  /** The product name. */
  name: "Agentic Coding Template",
  /** The short name, used in the mark and in page titles. */
  shortName: "ACT",
  /** The positioning line. */
  tagline: "Autonomous coding. Accountable engineering.",
  /** The supporting line, the description of the home page. */
  description:
    "An open-source, risk-aware workflow for AI coding agents. From requirements to verified pull requests, with independent reviews, traceable evidence and human control.",
  /** The repository on GitHub, without a trailing slash. */
  repository: "https://github.com/taspinar/agentic-coding-template",
  /** The branch whose files the site links to. */
  branch: "main",
  /** The origin the site is served from, without a path. */
  siteUrl: (process.env.SITE_URL || "https://taspinar.github.io").replace(/\/+$/, ""),
  /** The path the site is served under. */
  basePath: basePath(process.env.BASE_PATH),
};
