import type { ReactNode } from "react";
import { Button } from "../components/Button";
import { tm } from "../i18n";

type WindowFrameProps = {
  title?: ReactNode;
  children: ReactNode;
  footer?: ReactNode;
  header?: ReactNode;
  mainClassName?: string;
  mainScrollable?: boolean;
};

export function WindowFrame({
  title,
  children,
  footer,
  header,
  mainClassName,
  mainScrollable = true,
}: WindowFrameProps) {
  return (
    <div className="app-shell h-screen overflow-hidden text-ink flex flex-col">
      {(header !== undefined || title !== undefined) && (
        <header className="flex-shrink-0 border-b border-line/45 bg-surface-chrome">
          {header ?? (
            <div className="flex h-11 items-center px-5">
              <div className="truncate text-[13.5px] font-semibold leading-none tracking-tight">{title}</div>
            </div>
          )}
        </header>
      )}

      <main
        className={`min-h-0 flex-1 flex flex-col ${mainScrollable ? "overflow-y-auto" : "overflow-hidden"} no-drag ${mainClassName ?? "px-6 py-5"}`}
      >
        {children}
      </main>

      {footer !== undefined && (
        <footer className="min-h-[56px] flex-shrink-0 px-5 py-2.5 flex items-center justify-end gap-2 border-t border-line/45 bg-surface-chrome no-drag">
          {footer}
        </footer>
      )}
    </div>
  );
}

export function WindowFooterActions({
  onCancel,
  onSubmit,
  submitLabel,
  cancelLabel,
  disabled,
  busy,
}: {
  onCancel: () => void;
  onSubmit: () => void;
  submitLabel?: string;
  cancelLabel?: string;
  disabled?: boolean;
  busy?: boolean;
}) {
  return (
    <>
      <Button variant="ghost" onPress={onCancel}>
        {cancelLabel ?? tm("common.cancel", "Cancel")}
      </Button>
      <Button variant="primary" disabled={disabled} onPress={onSubmit}>
        {busy ? tm("common.processing", "Processing") : (submitLabel ?? tm("common.save", "Save"))}
      </Button>
    </>
  );
}
