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
    buttons: Object.fromEntries(BUTTONS.map((button) => [button, false])) as Record<
      Button,
      boolean
    >,
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

const KEY_BINDINGS: Readonly<Record<string, readonly [number, Button]>> = Object.freeze({
  ArrowUp: [0, 'up'],
  ArrowDown: [0, 'down'],
  ArrowLeft: [0, 'left'],
  ArrowRight: [0, 'right'],
  KeyZ: [0, 'a'],
  KeyX: [0, 'b'],
  KeyA: [0, 'x'],
  KeyS: [0, 'y'],
  KeyQ: [0, 'l'],
  KeyW: [0, 'r'],
  Enter: [0, 'start'],
  Escape: [0, 'menu'],
  KeyI: [1, 'up'],
  KeyK: [1, 'down'],
  KeyJ: [1, 'left'],
  KeyL: [1, 'right'],
  KeyF: [1, 'a'],
  KeyG: [1, 'b'],
  KeyR: [1, 'x'],
  KeyT: [1, 'y'],
  KeyV: [1, 'l'],
  KeyB: [1, 'r'],
  Digit1: [1, 'start'],
  Backquote: [1, 'menu'],
});

const GAMEPAD_BUTTONS: Readonly<Record<Button, number>> = Object.freeze({
  up: 12,
  down: 13,
  left: 14,
  right: 15,
  a: 0,
  b: 1,
  x: 2,
  y: 3,
  l: 4,
  r: 5,
  start: 9,
  menu: 8,
});

export interface StandardGamepad {
  readonly index: number;
  readonly buttons: readonly { readonly pressed: boolean }[];
  readonly axes: readonly number[];
}

export type GamepadProvider = () => readonly (StandardGamepad | null)[];

/** Main-thread keyboard, pointer/touch, and standard-gamepad adapter for four controller ports. */
export class BrowserInput {
  private readonly surface: HTMLCanvasElement;
  private readonly gamepads: GamepadProvider;
  private readonly keys = new Set<string>();
  private pointer: PointerState = {
    x: 0,
    y: 0,
    primary: false,
    secondary: false,
    inside: false,
  };

  public constructor(
    surface: HTMLCanvasElement,
    gamepads: GamepadProvider = () => navigator.getGamepads(),
  ) {
    this.surface = surface;
    this.gamepads = gamepads;
    globalThis.addEventListener('keydown', this.handleKeyDown);
    globalThis.addEventListener('keyup', this.handleKeyUp);
    globalThis.addEventListener('blur', this.handleBlur);
    surface.addEventListener('pointermove', this.handlePointerMove);
    surface.addEventListener('pointerdown', this.handlePointerDown);
    surface.addEventListener('pointerup', this.handlePointerUp);
    surface.addEventListener('pointercancel', this.handlePointerCancel);
    surface.addEventListener('pointerenter', this.handlePointerEnter);
    surface.addEventListener('pointerleave', this.handlePointerLeave);
    surface.addEventListener('contextmenu', this.handleContextMenu);
  }

  public poll(): InputFrame {
    const buttons = Array.from({ length: 4 }, () => emptyButtons());
    for (const code of this.keys) {
      const binding = KEY_BINDINGS[code];
      if (binding !== undefined) {
        const [port, button] = binding;
        const controller = buttons[port];
        if (controller !== undefined) {
          controller[button] = true;
        }
      }
    }
    for (const gamepad of this.gamepads()) {
      if (gamepad === null || gamepad.index < 0 || gamepad.index >= buttons.length) {
        continue;
      }
      const controller = buttons[gamepad.index];
      if (controller !== undefined) {
        applyStandardGamepad(controller, gamepad);
      }
    }
    return {
      controllers: [
        { buttons: buttons[0] as Record<Button, boolean> },
        { buttons: buttons[1] as Record<Button, boolean> },
        { buttons: buttons[2] as Record<Button, boolean> },
        { buttons: buttons[3] as Record<Button, boolean> },
      ],
      pointer: { ...this.pointer },
    };
  }

  public destroy(): void {
    globalThis.removeEventListener('keydown', this.handleKeyDown);
    globalThis.removeEventListener('keyup', this.handleKeyUp);
    globalThis.removeEventListener('blur', this.handleBlur);
    this.surface.removeEventListener('pointermove', this.handlePointerMove);
    this.surface.removeEventListener('pointerdown', this.handlePointerDown);
    this.surface.removeEventListener('pointerup', this.handlePointerUp);
    this.surface.removeEventListener('pointercancel', this.handlePointerCancel);
    this.surface.removeEventListener('pointerenter', this.handlePointerEnter);
    this.surface.removeEventListener('pointerleave', this.handlePointerLeave);
    this.surface.removeEventListener('contextmenu', this.handleContextMenu);
  }

  private readonly handleKeyDown = (event: KeyboardEvent): void => {
    if (KEY_BINDINGS[event.code] !== undefined) {
      event.preventDefault();
      this.keys.add(event.code);
    }
  };

  private readonly handleKeyUp = (event: KeyboardEvent): void => {
    if (KEY_BINDINGS[event.code] !== undefined) {
      event.preventDefault();
      this.keys.delete(event.code);
    }
  };

  private readonly handleBlur = (): void => {
    this.keys.clear();
    this.pointer = { ...this.pointer, primary: false, secondary: false };
  };

  private readonly handlePointerMove = (event: PointerEvent): void => {
    this.updatePointerPosition(event);
  };

  private readonly handlePointerDown = (event: PointerEvent): void => {
    this.surface.setPointerCapture(event.pointerId);
    this.updatePointerPosition(event);
    this.pointer = {
      ...this.pointer,
      primary: this.pointer.primary || event.button === 0,
      secondary: this.pointer.secondary || event.button === 2,
    };
  };

  private readonly handlePointerUp = (event: PointerEvent): void => {
    this.updatePointerPosition(event);
    this.pointer = {
      ...this.pointer,
      primary: event.button === 0 ? false : this.pointer.primary,
      secondary: event.button === 2 ? false : this.pointer.secondary,
    };
  };

  private readonly handlePointerCancel = (): void => {
    this.pointer = { ...this.pointer, primary: false, secondary: false, inside: false };
  };

  private readonly handlePointerEnter = (): void => {
    this.pointer = { ...this.pointer, inside: true };
  };

  private readonly handlePointerLeave = (): void => {
    this.pointer = { ...this.pointer, inside: false };
  };

  private readonly handleContextMenu = (event: MouseEvent): void => {
    event.preventDefault();
  };

  private updatePointerPosition(event: PointerEvent): void {
    const bounds = this.surface.getBoundingClientRect();
    const x = Math.floor(((event.clientX - bounds.left) * HARDWARE.width) / bounds.width);
    const y = Math.floor(((event.clientY - bounds.top) * HARDWARE.height) / bounds.height);
    this.pointer = {
      ...this.pointer,
      x: Math.max(0, Math.min(HARDWARE.width - 1, x)),
      y: Math.max(0, Math.min(HARDWARE.height - 1, y)),
      inside: x >= 0 && x < HARDWARE.width && y >= 0 && y < HARDWARE.height,
    };
  }
}

export function standardGamepadButtons(
  gamepad: StandardGamepad,
): Readonly<Record<Button, boolean>> {
  const result = emptyButtons();
  applyStandardGamepad(result, gamepad);
  return result;
}

function emptyButtons(): Record<Button, boolean> {
  return Object.fromEntries(BUTTONS.map((button) => [button, false])) as Record<Button, boolean>;
}

function applyStandardGamepad(buttons: Record<Button, boolean>, gamepad: StandardGamepad): void {
  for (const button of BUTTONS) {
    buttons[button] ||= gamepad.buttons[GAMEPAD_BUTTONS[button]]?.pressed ?? false;
  }
  const horizontal = gamepad.axes[0] ?? 0;
  const vertical = gamepad.axes[1] ?? 0;
  buttons.left ||= horizontal < -0.5;
  buttons.right ||= horizontal > 0.5;
  buttons.up ||= vertical < -0.5;
  buttons.down ||= vertical > 0.5;
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
import { HARDWARE } from './hardware';
