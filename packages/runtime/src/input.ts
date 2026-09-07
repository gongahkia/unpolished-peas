export const BUTTONS = [
  'up',
  'down',
  'left',
  'right',
  'a',
  'b',
  'x',
  'y',
  'l',
  'r',
  'start',
  'menu',
] as const;

export type Button = (typeof BUTTONS)[number];

export interface PointerState {
  readonly x: number;
  readonly y: number;
  readonly primary: boolean;
  readonly secondary: boolean;
  readonly inside: boolean;
}

export interface ControllerState {
  readonly buttons: Readonly<Record<Button, boolean>>;
}

export interface InputFrame {
  readonly controllers: readonly [
    ControllerState,
    ControllerState,
    ControllerState,
    ControllerState,
  ];
  readonly pointer: PointerState;
}

export function emptyInputFrame(): InputFrame {
  const controller = (): ControllerState => ({
    buttons: Object.fromEntries(BUTTONS.map((button) => [button, false])) as Record<Button, boolean>,
  });
  return {
    controllers: [controller(), controller(), controller(), controller()],
    pointer: { x: 0, y: 0, primary: false, secondary: false, inside: false },
  };
}

export function isButton(value: unknown): value is Button {
  return typeof value === 'string' && (BUTTONS as readonly string[]).includes(value);
}

export function isInputFrame(value: unknown): value is InputFrame {
  if (!isRecord(value) || !Array.isArray(value.controllers) || value.controllers.length !== 4) {
    return false;
  }
  if (!value.controllers.every(isControllerState) || !isRecord(value.pointer)) {
    return false;
  }
  const pointer = value.pointer;
  return (
    typeof pointer.x === 'number' &&
    Number.isFinite(pointer.x) &&
    typeof pointer.y === 'number' &&
    Number.isFinite(pointer.y) &&
    typeof pointer.primary === 'boolean' &&
    typeof pointer.secondary === 'boolean' &&
    typeof pointer.inside === 'boolean'
  );
}

function isControllerState(value: unknown): value is ControllerState {
  if (!isRecord(value) || !isRecord(value.buttons)) {
    return false;
  }
  const buttons = value.buttons;
  return BUTTONS.every((button) => typeof buttons[button] === 'boolean');
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}
