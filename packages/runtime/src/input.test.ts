import { describe, expect, it } from 'vitest';

import {
  BUTTONS,
  emptyInputFrame,
  defaultControllerProfile,
  inputRegisterByte,
  isControllerProfile,
  isInputFrame,
  profiledControllerButtons,
  remapControllerKey,
  standardGamepadButtons,
} from './input';

describe('four-port input model', () => {
  it('encodes every controller bit and pointer transition as little-endian register bytes', () => {
    const previous = emptyInputFrame();
    const current = {
      ...emptyInputFrame(),
      pointer: { x: 239, y: 143, primary: true, secondary: true, inside: true },
    };
    const masks = [0x555, 0xaaa, 0xfff, 0x801];
    for (const [port, controller] of current.controllers.entries())
      for (const [bit, button] of BUTTONS.entries())
        Object.assign(controller.buttons, { [button]: ((masks[port] ?? 0) & (1 << bit)) !== 0 });
    expect(
      Array.from({ length: 48 }, (_, offset) => inputRegisterByte(current, previous, offset)),
    ).toEqual([
      0x55, 0x05, 0, 0, 0x55, 0x05, 0, 0, 0xaa, 0x0a, 0, 0, 0xaa, 0x0a, 0, 0, 0xff, 0x0f, 0, 0,
      0xff, 0x0f, 0, 0, 0x01, 0x08, 0, 0, 0x01, 0x08, 0, 0, 239, 0, 143, 0, 0, 0, 0, 0, 7, 0, 7, 0,
      0, 0, 0, 0,
    ]);
    for (const [port, mask] of masks.entries()) {
      expect(inputRegisterByte(current, current, port * 8 + 4)).toBe(0);
      expect(inputRegisterByte(previous, current, port * 8 + 6)).toBe(mask & 255);
      expect(inputRegisterByte(previous, current, port * 8 + 7)).toBe(mask >>> 8);
    }
    expect(inputRegisterByte(previous, current, 43)).toBe(7);
    expect(inputRegisterByte(current, current, 42)).toBe(0);
    for (const offset of [-1, 0.5, 48, Infinity])
      expect(inputRegisterByte(current, previous, offset)).toBe(0);
  });

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
    expect(isInputFrame({ ...frame, controllers: Array(4) as unknown[] })).toBe(false);
    expect(isInputFrame({ ...frame, pointer: { ...frame.pointer, x: 0.5 } })).toBe(false);
    expect(isInputFrame({ ...frame, extra: true })).toBe(false);
  });

  it('validates four-port profiles, remaps conflicts atomically, and preserves gamepad slots', () => {
    const profile = defaultControllerProfile();
    expect(isControllerProfile(profile)).toBe(true);
    expect(Object.values(profile.keyboard).some(([port]) => port === 3)).toBe(true);
    const remapped = remapControllerKey(profile, 'KeyZ', 3, 'a');
    expect(remapped.keyboard.KeyZ).toEqual([3, 'a']);
    expect(Object.entries(remapped.keyboard)).not.toContainEqual(['KeyC', [3, 'a']]);
    expect(profile.keyboard.KeyZ).toEqual([0, 'a']);
    expect(isControllerProfile({ ...profile, gamepads: [0, 0, 2, 3] })).toBe(false);
    expect(isControllerProfile({ ...profile, keyboard: { KeyA: [0, 'a'], KeyB: [0, 'a'] } })).toBe(
      false,
    );
  });

  it('keeps physical gamepad assignment stable across disconnect and reconnect', () => {
    const profile = { ...defaultControllerProfile(), gamepads: [2, 0, null, 3] } as const;
    const pad = {
      index: 2,
      buttons: [{ pressed: true }],
      axes: [],
    };
    expect(profiledControllerButtons(profile, [], [null])[0].a).toBe(false);
    expect(profiledControllerButtons(profile, [], [pad])[0].a).toBe(true);
    expect(profiledControllerButtons(profile, ['KeyC'], [pad])[3].a).toBe(true);
    expect(profiledControllerButtons(profile, [], [null])[0].a).toBe(false);
  });
});
