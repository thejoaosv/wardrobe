// Reads CHANGELOG.md sections shaped like "## 1.2.0 — 2026-11-17" followed by "- note" lines, newest first.
export function parseChangelog(markdown) {
  return markdown.split(/^## /m).slice(1).map((section) => {
    const [heading, ...lines] = section.split("\n");
    const [version, date = null] = heading.split(/\s+[—-]\s+/).map((part) => part.trim());
    return { version, date, notes: lines.filter((line) => line.startsWith("- ")).map((line) => line.slice(2).trim()) };
  });
}
