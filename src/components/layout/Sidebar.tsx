import { useEffect, useState } from "react";
import {
  BarChart3,
  ChevronLeft,
  ChevronRight,
  KeyRound,
  Settings,
  ShieldCheck,
  Waypoints,
} from "lucide-react";
import brandIcon from "../../../brand/icon.svg";
import { cn } from "cn";

export type PageId = "accounts" | "usage" | "proxy" | "settings";

const groups: { label: string; items: { id: PageId; label: string; icon: typeof KeyRound }[] }[] = [
  {
    label: "OPERATIONS",
    items: [
      { id: "accounts", label: "Accounts", icon: KeyRound },
      { id: "proxy", label: "Proxies", icon: Waypoints },
    ],
  },
  { label: "INSIGHTS", items: [{ id: "usage", label: "Usage", icon: BarChart3 }] },
  { label: "SYSTEM", items: [{ id: "settings", label: "Settings", icon: Settings }] },
];

interface SidebarProps {
  active: PageId;
  onSelect: (id: PageId) => void;
}

export function Sidebar({ active, onSelect }: SidebarProps) {
  const [collapsed, setCollapsed] = useState(false);
  const [compact, setCompact] = useState(() => window.matchMedia("(max-width: 820px)").matches);
  const isCollapsed = collapsed || compact;

  useEffect(() => {
    const query = window.matchMedia("(max-width: 820px)");
    const updateCompact = () => setCompact(query.matches);
    updateCompact();
    query.addEventListener("change", updateCompact);
    return () => query.removeEventListener("change", updateCompact);
  }, []);

  return (
    <aside
      data-collapsed={isCollapsed}
      className={cn(
        "app-sidebar flex h-full shrink-0 flex-col border-r border-sidebar-border bg-sidebar",
        isCollapsed
          ? "w-16"
          : "w-[clamp(13.75rem,15.5vw,19.25rem)] max-[820px]:w-16",
      )}
    >
      <div className="app-sidebar__brand">
        <img src={brandIcon} alt="" aria-hidden="true" className="size-8 shrink-0 rounded-lg grayscale" />
        <div className="app-sidebar__brand-copy">
          <div className="truncate text-sm font-semibold text-sidebar-foreground">RelayDock</div>
          <div className="text-xs text-sidebar-foreground/75">LOCAL CONTROL</div>
        </div>
      </div>

      <nav aria-label="Primary navigation" className="app-sidebar__nav">
        {groups.map((group) => (
          <section key={group.label} className="app-sidebar__group" aria-label={group.label}>
            <h2 className="app-sidebar__group-label">{group.label}</h2>
            <div className="app-sidebar__items">
              {group.items.map(({ id, label, icon: Icon }) => (
                <button
                  key={id}
                  type="button"
                  aria-current={active === id ? "page" : undefined}
                  aria-label={label}
                  title={label}
                  onClick={() => onSelect(id)}
                  className={cn("app-sidebar__item", active === id && "app-sidebar__item--active")}
                >
                  <Icon aria-hidden="true" className="size-4 shrink-0" />
                  <span className="app-sidebar__item-label">{label}</span>
                </button>
              ))}
            </div>
          </section>
        ))}
      </nav>

      <div className="app-sidebar__footer">
        <div className="app-sidebar__local" title="This app's local API binds to 127.0.0.1 only">
          <ShieldCheck aria-hidden="true" className="size-4 shrink-0 text-primary" />
          <div className="app-sidebar__local-copy">
            <span>LOCAL ONLY</span>
            <span>127.0.0.1</span>
          </div>
        </div>
        <button
          type="button"
          className="app-sidebar__collapse"
          aria-label={isCollapsed ? "Expand sidebar" : "Collapse sidebar"}
          aria-expanded={!isCollapsed}
          title={isCollapsed ? "Expand sidebar" : "Collapse sidebar"}
          onClick={() => setCollapsed((value) => !value)}
        >
          {isCollapsed ? <ChevronRight aria-hidden="true" className="size-4" /> : <ChevronLeft aria-hidden="true" className="size-4" />}
          <span className="app-sidebar__collapse-label">{isCollapsed ? "Expand" : "Collapse"}</span>
        </button>
      </div>
    </aside>
  );
}
