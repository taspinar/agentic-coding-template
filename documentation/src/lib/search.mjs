/** Match every query word against the page title and rendered text. */
export function searchPages(pages, query) {
  const words = query.toLocaleLowerCase().trim().split(/\s+/).filter(Boolean);
  if (!words.length) return [];
  return pages.filter(page => words.every(word =>
    `${page.title} ${page.text}`.toLocaleLowerCase().includes(word)));
}
