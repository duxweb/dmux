import type { ReactNode } from "react";
import { Button } from "./Button";
import { PressableButton } from "./PressableButton";
import { Tooltip } from "./Tooltip";
import type { AppIcon } from "../icons";
import { Plus, X } from "../icons";
import { tm } from "../i18n";

export type TabStripItem = {
  id: string;
  label: ReactNode;
  icon?: AppIcon;
  closable?: boolean;
};

type Props = {
  items: TabStripItem[];
  activeId: string;
  addLabel?: string;
  className?: string;
  emptyLabel?: ReactNode;
  onSelect: (id: string) => void;
  onClose?: (id: string) => void;
  onAdd?: () => void;
  onRename?: (id: string, label: string) => void;
  onReorder?: (sourceId: string, targetId: string) => void;
};

export function TabStrip({
  items,
  activeId,
  addLabel = tm("workspace.create_tab", "New Tab"),
  className,
  emptyLabel,
  onSelect,
  onClose,
  onAdd,
  onRename,
  onReorder,
}: Props) {
  const renameTab = (item: TabStripItem) => {
    if (!onRename || typeof item.label !== "string") return;
    const next = window.prompt(tm("common.rename", "Rename"), item.label)?.trim();
    if (!next || next === item.label) return;
    onRename(item.id, next);
  };

  return (
    <div className={`tab-strip ${className ?? ""}`}>
      <div className="tab-strip-scroll">
        {items.length === 0 && emptyLabel ? (
          <div className="tab-strip-empty">{emptyLabel}</div>
        ) : (
          items.map((item) => {
            const Icon = item.icon;
            const active = item.id === activeId;
            return (
              <div
                key={item.id}
                className={`tab-strip-item group ${active ? "active" : ""}`}
                draggable={Boolean(onReorder)}
                onDragStart={(event) => {
                  event.dataTransfer.effectAllowed = "move";
                  event.dataTransfer.setData("text/plain", item.id);
                }}
                onDragOver={(event) => {
                  if (!onReorder) return;
                  event.preventDefault();
                  event.dataTransfer.dropEffect = "move";
                }}
                onDrop={(event) => {
                  if (!onReorder) return;
                  event.preventDefault();
                  const sourceId = event.dataTransfer.getData("text/plain");
                  if (!sourceId || sourceId === item.id) return;
                  onReorder(sourceId, item.id);
                }}
              >
                <PressableButton
                  className="tab-strip-select"
                  onPressUp={() => onSelect(item.id)}
                  onDoubleClick={() => renameTab(item)}
                >
                  {Icon ? <Icon size={13} strokeWidth={2.1} className="flex-shrink-0" /> : null}
                  <span className="truncate">{item.label}</span>
                </PressableButton>
                {item.closable && onClose ? (
                  <PressableButton
                    aria-label={tm("terminal.tab.close", "Close Tab")}
                    className={`tab-strip-close ${active ? "opacity-100" : "opacity-0 group-hover:opacity-100"}`}
                    onPressUp={(event) => {
                      event.continuePropagation();
                      onClose(item.id);
                    }}
                  >
                    <X size={11} strokeWidth={2.2} />
                  </PressableButton>
                ) : null}
              </div>
            );
          })
        )}
      </div>
      {onAdd ? (
        <Tooltip label={addLabel} placement="bottom">
          <Button
            isIconOnly
            size="sm"
            variant="ghost"
            onPress={onAdd}
            aria-label={addLabel}
            className="h-6 w-6 min-w-6 flex-shrink-0 text-ink-mute"
          >
            <Plus size={13} strokeWidth={2.2} />
          </Button>
        </Tooltip>
      ) : null}
    </div>
  );
}
