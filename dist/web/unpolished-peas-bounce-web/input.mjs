export const InputAbi = Object.freeze({version: 1, byteLength: 376});

export const InputKey = Object.freeze({up: 0, down: 1, left: 2, right: 3, action: 4, cancel: 5, start: 6, select: 7, debug: 8, screenshot: 9});
export const PointerButton = Object.freeze({left: 0, middle: 1, right: 2, back: 3, forward: 4});
export const GamepadButton = Object.freeze({south: 0, east: 1, west: 2, north: 3, back: 4, start: 5, left_stick: 6, right_stick: 7, left_shoulder: 8, right_shoulder: 9, dpad_up: 10, dpad_down: 11, dpad_left: 12, dpad_right: 13});
export const GamepadAxis = Object.freeze({left_x: 0, left_y: 1, right_x: 2, right_y: 3, left_trigger: 4, right_trigger: 5});

const codeToKey = new Map([
  ["ArrowUp", InputKey.up], ["KeyW", InputKey.up], ["ArrowDown", InputKey.down], ["KeyS", InputKey.down],
  ["ArrowLeft", InputKey.left], ["KeyA", InputKey.left], ["ArrowRight", InputKey.right], ["KeyD", InputKey.right],
  ["Space", InputKey.action], ["KeyZ", InputKey.action], ["KeyJ", InputKey.action],
  ["Escape", InputKey.cancel], ["Backspace", InputKey.cancel], ["KeyX", InputKey.cancel], ["KeyK", InputKey.cancel],
  ["Enter", InputKey.start], ["NumpadEnter", InputKey.start], ["ShiftLeft", InputKey.select], ["ShiftRight", InputKey.select], ["Tab", InputKey.select],
  ["Backquote", InputKey.debug], ["F3", InputKey.debug], ["PrintScreen", InputKey.screenshot], ["F2", InputKey.screenshot],
]);
const domButtons = new Map([[0, PointerButton.left], [1, PointerButton.middle], [2, PointerButton.right], [3, PointerButton.back], [4, PointerButton.forward]]);
const domGamepadButtons = [0, 1, 2, 3, 8, 9, 10, 11, 4, 5, 12, 13, 14, 15];

function mask(values) {
  let value = 0;
  for (let index = 0; index < values.length; index += 1) if (values[index]) value |= 1 << index;
  return value >>> 0;
}

function finite(value) {
  return Number.isFinite(value) ? value : 0;
}

function actionBindingValue(binding, state) {
  if (!binding || typeof binding !== "object") return 0;
  if (typeof binding.key === "string") return state.down[InputKey[binding.key]] ? 1 : 0;
  if (typeof binding.pointer_button === "string") return state.pointerDown[PointerButton[binding.pointer_button]] ? 1 : 0;
  if (typeof binding.gamepad_button === "string") return state.gamepads.some((gamepad) => gamepad.buttons[GamepadButton[binding.gamepad_button]]) ? 1 : 0;
  if (binding.gamepad_axis && typeof binding.gamepad_axis === "object") {
    const axis = GamepadAxis[binding.gamepad_axis.axis];
    const sign = binding.gamepad_axis.sign ?? 1;
    const threshold = binding.gamepad_axis.threshold ?? 0.5;
    if (axis === undefined || (sign !== -1 && sign !== 1) || !(threshold > 0 && threshold <= 1)) return 0;
    for (const gamepad of state.gamepads) {
      const value = gamepad.axes[axis] * sign;
      if (value >= threshold) return value;
    }
  }
  return 0;
}

function validActionBinding(binding) {
  if (!binding || typeof binding !== "object") return false;
  if (typeof binding.key === "string") return InputKey[binding.key] !== undefined;
  if (typeof binding.pointer_button === "string") return PointerButton[binding.pointer_button] !== undefined;
  if (typeof binding.gamepad_button === "string") return GamepadButton[binding.gamepad_button] !== undefined;
  if (!binding.gamepad_axis || typeof binding.gamepad_axis !== "object") return false;
  const {axis, sign = 1, threshold = 0.5} = binding.gamepad_axis;
  return GamepadAxis[axis] !== undefined && (sign === -1 || sign === 1) && threshold > 0 && threshold <= 1;
}

export function createBrowserInput({
  canvas,
  document: documentRef = globalThis.document,
  window: windowRef = globalThis.window,
  navigator: navigatorRef = globalThis.navigator,
  ResizeObserver: ResizeObserverImpl = globalThis.ResizeObserver,
  mapCanvas = () => null,
} = {}) {
  const down = new Array(10).fill(false);
  const pressed = new Array(10).fill(false);
  const released = new Array(10).fill(false);
  const pointerDown = new Array(5).fill(false);
  const pointerPressed = new Array(5).fill(false);
  const pointerReleased = new Array(5).fill(false);
  const pointer = {windowX: 0, windowY: 0, framebufferX: 0, framebufferY: 0, canvasX: Number.NaN, canvasY: Number.NaN, deltaX: 0, deltaY: 0, wheelX: 0, wheelY: 0};
  const gamepads = new Map();
  const actions = [];
  const listeners = [];
  let focused = documentRef?.activeElement === canvas;
  let visible = documentRef?.visibilityState !== "hidden";
  let resizeEpoch = 0;
  let observer = null;

  function listen(target, type, callback, options) {
    target?.addEventListener?.(type, callback, options);
    listeners.push([target, type, callback, options]);
  }

  function setKey(key, value) {
    if (down[key] === value) return;
    down[key] = value;
    if (value) pressed[key] = true;
    else released[key] = true;
  }

  function setPointerButton(button, value) {
    if (pointerDown[button] === value) return;
    pointerDown[button] = value;
    if (value) pointerPressed[button] = true;
    else pointerReleased[button] = true;
  }

  function releaseAll() {
    for (let index = 0; index < down.length; index += 1) setKey(index, false);
    for (let index = 0; index < pointerDown.length; index += 1) setPointerButton(index, false);
  }

  function updatePointer(event) {
    const rect = canvas?.getBoundingClientRect?.();
    const windowX = finite(event.clientX);
    const windowY = finite(event.clientY);
    const width = rect?.width ?? canvas?.width ?? 0;
    const height = rect?.height ?? canvas?.height ?? 0;
    const framebufferX = width > 0 ? (windowX - finite(rect?.left)) * (canvas.width / width) : 0;
    const framebufferY = height > 0 ? (windowY - finite(rect?.top)) * (canvas.height / height) : 0;
    pointer.deltaX = framebufferX - pointer.framebufferX;
    pointer.deltaY = framebufferY - pointer.framebufferY;
    pointer.windowX = windowX;
    pointer.windowY = windowY;
    pointer.framebufferX = framebufferX;
    pointer.framebufferY = framebufferY;
    const point = mapCanvas(framebufferX, framebufferY);
    pointer.canvasX = point ? point.x : Number.NaN;
    pointer.canvasY = point ? point.y : Number.NaN;
  }

  function updateGamepads() {
    const pads = navigatorRef?.getGamepads?.() ?? [];
    const active = [];
    for (const pad of pads) if (pad?.connected) active.push(pad);
    active.sort((a, b) => a.index - b.index);
    const selected = active.slice(0, 4);
    const selectedIds = new Set(selected.map((pad) => pad.index));
    for (const id of gamepads.keys()) if (!selectedIds.has(id)) gamepads.delete(id);
    for (const pad of selected) {
      let state = gamepads.get(pad.index);
      if (!state) {
        state = {id: pad.index, buttons: new Array(14).fill(false), pressed: new Array(14).fill(false), released: new Array(14).fill(false), axes: new Array(6).fill(0), previousAxes: new Array(6).fill(0)};
        gamepads.set(pad.index, state);
      }
      for (let index = 0; index < domGamepadButtons.length; index += 1) {
        const isDown = Boolean(pad.buttons?.[domGamepadButtons[index]]?.pressed ?? (pad.buttons?.[domGamepadButtons[index]]?.value > 0.5));
        if (state.buttons[index] === isDown) continue;
        state.buttons[index] = isDown;
        if (isDown) state.pressed[index] = true;
        else state.released[index] = true;
      }
      for (let index = 0; index < state.axes.length; index += 1) state.axes[index] = finite(pad.axes?.[index]);
    }
  }

  function beginFrame() {
    pressed.fill(false);
    released.fill(false);
    pointerPressed.fill(false);
    pointerReleased.fill(false);
    pointer.deltaX = 0;
    pointer.deltaY = 0;
    pointer.wheelX = 0;
    pointer.wheelY = 0;
    for (const gamepad of gamepads.values()) {
      gamepad.pressed.fill(false);
      gamepad.released.fill(false);
      gamepad.previousAxes = [...gamepad.axes];
    }
  }

  function snapshot() {
    updateGamepads();
    const pads = [...gamepads.values()].sort((a, b) => a.id - b.id);
    return {down: [...down], pressed: [...pressed], released: [...released], pointerDown: [...pointerDown], pointerPressed: [...pointerPressed], pointerReleased: [...pointerReleased], pointer: {...pointer}, gamepads: pads.map((gamepad) => ({id: gamepad.id, buttons: [...gamepad.buttons], pressed: [...gamepad.pressed], released: [...gamepad.released], axes: [...gamepad.axes], previousAxes: [...gamepad.previousAxes]})), focused, visible, resizeEpoch, framebufferWidth: canvas?.width ?? 0, framebufferHeight: canvas?.height ?? 0};
  }

  function write(destination, capacity, memory) {
    if (!Number.isInteger(destination) || !Number.isInteger(capacity) || destination < 0 || capacity < InputAbi.byteLength || destination > memory.buffer.byteLength - InputAbi.byteLength) return capacity < InputAbi.byteLength ? InputAbi.byteLength : 0;
    const state = snapshot();
    const bytes = new Uint8Array(memory.buffer, destination, InputAbi.byteLength);
    bytes.fill(0);
    const view = new DataView(memory.buffer, destination, InputAbi.byteLength);
    view.setUint32(0, InputAbi.version, true);
    view.setUint32(4, (state.focused ? 1 : 0) | (state.visible ? 2 : 0) | (Number.isFinite(state.pointer.canvasX) ? 4 : 0), true);
    view.setUint32(8, state.resizeEpoch, true);
    view.setUint32(12, state.framebufferWidth, true);
    view.setUint32(16, state.framebufferHeight, true);
    view.setUint32(20, mask(state.down), true);
    view.setUint32(24, mask(state.pressed), true);
    view.setUint32(28, mask(state.released), true);
    view.setUint32(32, mask(state.pointerDown), true);
    view.setUint32(36, mask(state.pointerPressed), true);
    view.setUint32(40, mask(state.pointerReleased), true);
    view.setFloat32(44, state.pointer.windowX, true);
    view.setFloat32(48, state.pointer.windowY, true);
    view.setFloat32(52, state.pointer.framebufferX, true);
    view.setFloat32(56, state.pointer.framebufferY, true);
    view.setFloat32(60, state.pointer.canvasX, true);
    view.setFloat32(64, state.pointer.canvasY, true);
    view.setFloat32(68, state.pointer.deltaX, true);
    view.setFloat32(72, state.pointer.deltaY, true);
    view.setFloat32(76, state.pointer.wheelX, true);
    view.setFloat32(80, state.pointer.wheelY, true);
    view.setUint32(84, state.gamepads.length, true);
    for (const [index, gamepad] of state.gamepads.entries()) {
      const offset = 88 + index * 72;
      view.setInt32(offset, gamepad.id, true);
      view.setUint32(offset + 4, 1, true);
      view.setUint32(offset + 8, mask(gamepad.buttons), true);
      view.setUint32(offset + 12, mask(gamepad.pressed), true);
      view.setUint32(offset + 16, mask(gamepad.released), true);
      for (let axis = 0; axis < 6; axis += 1) view.setFloat32(offset + 20 + axis * 4, gamepad.axes[axis], true);
      for (let axis = 0; axis < 6; axis += 1) view.setFloat32(offset + 44 + axis * 4, gamepad.previousAxes[axis], true);
    }
    beginFrame();
    return InputAbi.byteLength;
  }

  function actionValues() {
    const state = snapshot();
    return actions.map(({context, name, binding}) => ({context, name, value: actionBindingValue(binding, state)}));
  }

  function setActions(definitions) {
    if (!Array.isArray(definitions)) return false;
    const next = [];
    for (const definition of definitions) {
      if (!definition || typeof definition.name !== "string" || definition.name.length === 0 || typeof definition.context !== "undefined" && (typeof definition.context !== "string" || definition.context.length === 0) || !validActionBinding(definition.binding)) return false;
      next.push({context: definition.context ?? "game", name: definition.name, binding: definition.binding});
    }
    actions.splice(0, actions.length, ...next);
    return true;
  }

  function resize() {
    resizeEpoch += 1;
  }

  if (canvas && canvas.tabIndex < 0) canvas.tabIndex = 0;
  listen(canvas, "focus", () => { focused = true; });
  listen(canvas, "blur", () => { focused = false; releaseAll(); });
  listen(canvas, "pointerdown", (event) => {
    canvas.focus?.({preventScroll: true});
    focused = true;
    updatePointer(event);
    const button = domButtons.get(event.button);
    if (button !== undefined) setPointerButton(button, true);
  });
  listen(canvas, "pointermove", updatePointer);
  listen(canvas, "pointerup", (event) => {
    updatePointer(event);
    const button = domButtons.get(event.button);
    if (button !== undefined) setPointerButton(button, false);
  });
  listen(canvas, "pointercancel", () => {
    for (let index = 0; index < pointerDown.length; index += 1) setPointerButton(index, false);
  });
  listen(canvas, "wheel", (event) => {
    updatePointer(event);
    pointer.wheelX += finite(event.deltaX);
    pointer.wheelY += finite(event.deltaY);
    if (focused) event.preventDefault?.();
  }, {passive: false});
  listen(windowRef, "pointerup", (event) => {
    const button = domButtons.get(event.button);
    if (button !== undefined) setPointerButton(button, false);
  });
  listen(windowRef, "keydown", (event) => {
    if (!focused) return;
    const key = codeToKey.get(event.code);
    if (key === undefined) return;
    setKey(key, true);
    event.preventDefault?.();
  });
  listen(windowRef, "keyup", (event) => {
    const key = codeToKey.get(event.code);
    if (key === undefined) return;
    setKey(key, false);
    if (focused) event.preventDefault?.();
  });
  listen(windowRef, "blur", () => { focused = false; releaseAll(); });
  listen(windowRef, "resize", resize);
  listen(windowRef, "gamepadconnected", updateGamepads);
  listen(windowRef, "gamepaddisconnected", updateGamepads);
  listen(documentRef, "visibilitychange", () => {
    visible = documentRef.visibilityState !== "hidden";
    if (!visible) releaseAll();
  });
  if (ResizeObserverImpl && canvas) {
    observer = new ResizeObserverImpl(resize);
    observer.observe(canvas);
  }

  return {
    poll: () => {
      updateGamepads();
      return InputAbi.byteLength;
    },
    read: write,
    snapshot,
    setActions,
    actionValues,
    resize,
    teardown: () => {
      for (const [target, type, callback, options] of listeners) target?.removeEventListener?.(type, callback, options);
      observer?.disconnect?.();
      observer = null;
    },
  };
}
