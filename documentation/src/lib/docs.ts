// The sidebar of the documentation: its pages in groups, in the order of the
// sidebar and of the previous and next links. A page is the id of an entry of
// the docs collection, or a page of its own (the workflow reference, built
// from src/lib/steps.ts) with its title.

export type Page = { id: string; title?: string };

export const groups: { label?: string; pages: Page[] }[] = [
  { pages: [{ id: "index" }, { id: "getting-started" }] },
  { label: "Concepts", pages: [{ id: "risk-policy" }, { id: "verification-and-completion" }, { id: "agent-roles" }] },
  { label: "Workflow", pages: [{ id: "detailed-workflow" }, { id: "reference/workflow", title: "Workflow reference" }] },
  { label: "Reference", pages: [{ id: "configuration-and-security" }, { id: "technical-reference" }] },
  { label: "Setup and maintenance", pages: [{ id: "github-setup" }, { id: "updating" }, { id: "troubleshooting" }] },
];

/** The path of a page under the site, without the base. */
export const path = (id: string) => `docs/${id === "index" ? "" : id + "/"}`;

/**
 * The groups with the title of every page, from the collection where the page
 * is an entry. Every entry of the collection is in exactly one group.
 */
export function sidebar(entries: { id: string; data: { title: string } }[]) {
  const listed = groups.flatMap((group) => group.pages.map((page) => page.id));
  for (const entry of entries) {
    if (listed.filter((id) => id === entry.id).length !== 1) throw new Error(`docs sidebar: ${entry.id} is not listed exactly once`);
  }
  return groups.map((group) => ({
    label: group.label,
    pages: group.pages.map((page) => {
      const title = page.title ?? entries.find((entry) => entry.id === page.id)?.data.title;
      if (!title) throw new Error(`docs sidebar: ${page.id} is not a page`);
      return { id: page.id, title };
    }),
  }));
}
