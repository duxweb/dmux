import {
  autoUpdate,
  flip,
  FloatingPortal,
  offset,
  shift,
  useFloating,
  useHover,
  useInteractions,
  useRole,
  useTransitionStyles,
  type Placement,
} from "@floating-ui/react";
import { type ReactElement, type ReactNode } from "react";

export type TooltipPlacement = "top" | "bottom" | "left" | "right";

type Props = {
  label: ReactNode;
  placement?: TooltipPlacement;
  delay?: number;
  disabled?: boolean;
  triggerClassName?: string;
  contentClassName?: string;
  children: ReactElement;
};

export function Tooltip({
  label,
  placement = "bottom",
  delay = 300,
  disabled,
  triggerClassName = "inline-block max-w-full align-middle",
  contentClassName,
  children,
}: Props) {
  const isDisabled = disabled || !label;
  const { context, floatingStyles, refs } = useFloating({
    open: undefined,
    placement: placement as Placement,
    middleware: [offset(6), flip({ padding: 8 }), shift({ padding: 8 })],
    whileElementsMounted: autoUpdate,
  });
  const hover = useHover(context, {
    enabled: !isDisabled,
    delay: { open: delay, close: 80 },
    mouseOnly: true,
  });
  const role = useRole(context, { role: "tooltip" });
  const { getReferenceProps, getFloatingProps } = useInteractions([hover, role]);
  const { isMounted, styles: transitionStyles } = useTransitionStyles(context, {
    duration: 90,
    initial: { opacity: 0, transform: "translateY(-1px) scale(0.985)" },
    open: { opacity: 1, transform: "translateY(0) scale(1)" },
    close: { opacity: 0, transform: "translateY(-1px) scale(0.985)" },
  });

  if (isDisabled) {
    return children;
  }

  const referenceProps = getReferenceProps({
    ref: refs.setReference,
    className: mergeClassName(triggerClassName, "no-drag"),
  });

  return (
    <>
      <span {...referenceProps}>{children}</span>
      {isMounted && (
        <FloatingPortal preserveTabOrder={false}>
          <div
            ref={refs.setFloating}
            style={{ ...floatingStyles, ...transitionStyles }}
            className={`z-[10050] max-w-[260px] rounded-md border border-line-strong bg-surface-chrome px-2 py-1 text-[11.5px] font-medium text-ink-soft shadow-pop no-drag ${contentClassName ?? ""}`}
            {...getFloatingProps()}
          >
            {label}
          </div>
        </FloatingPortal>
      )}
    </>
  );
}

function mergeClassName(...items: Array<string | undefined>) {
  return items.filter(Boolean).join(" ");
}
