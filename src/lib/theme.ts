export type Theme = "light" | "dark" | "system";

const darkQuery = () => window.matchMedia("(prefers-color-scheme: dark)");

export function resolveTheme(theme: Theme | string): theme is "light" | "dark" {
  return theme === "light" || theme === "dark";
}

/** Applies a theme to <html> and returns what was actually used. */
export function applyTheme(theme: Theme | string): "light" | "dark" {
  const resolved = resolveTheme(theme) ? theme : darkQuery().matches ? "dark" : "light";
  document.documentElement.classList.toggle("dark", resolved === "dark");
  return resolved;
}

/** Follows the OS when theme === "system". Call once on mount, returns cleanup. */
export function watchSystemTheme(current: () => string) {
  const query = darkQuery();
  const handler = () => {
    if (current() === "system") applyTheme("system");
  };
  query.addEventListener("change", handler);
  return () => query.removeEventListener("change", handler);
}
