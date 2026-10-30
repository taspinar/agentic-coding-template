import { site } from "../../site.config";

const base = import.meta.env.BASE_URL.replace(/\/?$/, "/");

/** A link to a page or file of the site, under the base path. */
export function href(path = ""): string {
  return base + path.replace(/^\/+/, "");
}

/** A link to a file of the repository on its default branch. */
export function repoFile(path: string): string {
  return `${site.repository}/blob/${site.branch}/${path}`;
}

/** A link to an Issue or a pull request of the repository. */
export function issue(number: number): string {
  return `${site.repository}/issues/${number}`;
}

/** A link to a pull request of the repository. */
export function pull(number: number): string {
  return `${site.repository}/pull/${number}`;
}

/** The sections of the site, in the order of the navigation. */
export const sections = [
  { path: "workflow/", label: "Workflow" },
  { path: "features/", label: "Features" },
  { path: "examples/", label: "Examples" },
  { path: "docs/", label: "Docs", keep: true },
  { path: "about/", label: "About" },
] as const;
