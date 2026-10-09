import { BarChart3, KeyRound, Settings, Waypoints } from "lucide-react";
import { cn } from "cn";

export type PageId = "accounts" | "usage" | "proxy" | "settings";

const items: { id: PageId; label: string; icon: typeof KeyRound }[] = [
  { id: "accounts", label: "Accounts", icon: KeyRound },
  { id: "usage", label: "Usage", icon: BarChart3 },
  { id: "proxy", label: "Proxies", icon: Waypoints },
  { id: "settings", label: "Settings", icon: Settings },
];

interface SidebarProps {
  active: PageId;
  onSelect: (id: PageId) => void;
}

export function Sidebar({ active, onSelect }: SidebarProps) {
  return (
    <aside className="flex w-52 shrink-0 flex-col gap-1 border-r border-border bg-muted/40 p-3">
      <div className="mb-4 px-2 pt-1">
        <div className="text-sm font-semibold">opencode zero limit</div>
        <div className="text-xs text-muted-foreground">free tier keeper</div>
      </div>
      {items.map(({ id, label, icon: Icon }) => (
        <button
          key={id}
          type="button"
          onClick={() => onSelect(id)}
          className={cn(
            "flex items-center gap-2 rounded-md px-2.5 py-2 text-sm transition-colors",
            active === id
              ? "bg-accent font-medium text-accent-foreground"
              : "text-muted-foreground hover:bg-accent/60 hover:text-foreground",
          )}
        >
          <Icon className="size-4" />
          {label}
        </button>
      ))}
    </aside>
  );
}
