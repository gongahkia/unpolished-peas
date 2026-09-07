import { describe, expect, it } from 'vitest';

import { BUTTONS, emptyInputFrame, isInputFrame, standardGamepadButtons } from './input';

describe('four-port input model', () => {
  it('maps standard gamepad face, shoulder, menu, d-pad, and axis inputs', () => {
    const buttons = Array.from({ length: 16 }, () => ({ pressed: false }));
    buttons[0] = { pressed: true };
    buttons[5] = { pressed: true };
    buttons[9] = { pressed: true };
    buttons[12] = { pressed: true };
    const mapped = standardGamepadButtons({ index: 2, buttons, axes: [-0.75, 0.8] });
    expect(mapped).toMatchObject({
      a: true,
      r: true,
      start: true,
      up: true,
      left: true,
      down: true,
    });
    expect(mapped.b).toBe(false);
  });

  it('constructs and validates complete independent four-port frames', () => {
    const frame = emptyInputFrame();
    expect(frame.controllers).toHaveLength(4);
    expect(Object.keys(frame.controllers[0].buttons)).toEqual(BUTTONS);
    expect(frame.controllers[0]).not.toBe(frame.controllers[1]);
    expect(isInputFrame(frame)).toBe(true);
    expect(isInputFrame({ ...frame, controllers: frame.controllers.slice(0, 3) })).toBe(false);
    expect(isInputFrame({ ...frame, pointer: { ...frame.pointer, x: 0.5 } })).toBe(false);
    expect(isInputFrame({ ...frame, extra: true })).toBe(false);
  });
});
