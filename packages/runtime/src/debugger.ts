import type { InputFrame } from './input';

export interface ReplayFrame {
  readonly frame: number;
  readonly input: InputFrame;
  readonly fingerprint: string;
}

export interface ReplayPlan {
  readonly snapshot: unknown;
  readonly snapshotFrame: number;
  readonly frames: readonly ReplayFrame[];
}

export interface ReplayAdapter {
  readonly restore: (snapshot: unknown) => Promise<void>;
  readonly frame: (input: InputFrame) => Promise<unknown>;
}

export interface ReplayResult {
  readonly frame: number;
  readonly divergence?: {
    readonly frame: number;
    readonly expected: string;
    readonly actual: string;
  };
}

/** Bounded deterministic input/snapshot journal. Frame numbers are next-frame cursors. */
export class ReplayJournal {
  private readonly maximumFrames: number;
  private readonly frames = new Map<number, ReplayFrame>();
  private readonly snapshots = new Map<number, unknown>();
  private nextFrame = 0;

  public constructor(maximumFrames = 3_600) {
    if (!Number.isSafeInteger(maximumFrames) || maximumFrames < 1) {
      throw new RangeError('replay history must retain at least one frame');
    }
    this.maximumFrames = maximumFrames;
  }

  public get cursor(): number {
    return this.nextFrame;
  }

  public get oldestFrame(): number {
    return this.frames.keys().next().value ?? this.nextFrame;
  }

  public recordSnapshot(frame: number, snapshot: unknown): void {
    if (!Number.isSafeInteger(frame) || frame < 0 || frame > this.nextFrame) {
      throw new RangeError('snapshot frame is outside recorded replay history');
    }
    this.snapshots.set(frame, structuredClone(snapshot));
    this.prune();
  }

  public recordFrame(frame: number, input: InputFrame, observable: unknown): void {
    if (frame !== this.nextFrame) {
      throw new RangeError(
        `replay frame ${String(frame)} is not contiguous with cursor ${String(this.nextFrame)}`,
      );
    }
    this.frames.set(frame, {
      frame,
      input: structuredClone(input),
      fingerprint: debugFingerprint(observable),
    });
    this.nextFrame += 1;
    this.prune();
  }

  public plan(targetFrame: number): ReplayPlan {
    if (
      !Number.isSafeInteger(targetFrame) ||
      targetFrame < this.oldestFrame ||
      targetFrame > this.nextFrame
    ) {
      throw new RangeError('rewind target is outside recorded replay history');
    }
    const snapshotFrame = [...this.snapshots.keys()]
      .filter((frame) => frame <= targetFrame)
      .sort((left, right) => right - left)[0];
    if (snapshotFrame === undefined) {
      throw new RangeError('rewind target has no retained snapshot');
    }
    const snapshot = this.snapshots.get(snapshotFrame);
    return {
      snapshot: structuredClone(snapshot),
      snapshotFrame,
      frames: [...this.frames.values()]
        .filter((record) => record.frame >= snapshotFrame && record.frame < targetFrame)
        .map((record) => structuredClone(record)),
    };
  }

  public async replay(targetFrame: number, adapter: ReplayAdapter): Promise<ReplayResult> {
    const plan = this.plan(targetFrame);
    await adapter.restore(plan.snapshot);
    for (const expected of plan.frames) {
      const actual = debugFingerprint(await adapter.frame(structuredClone(expected.input)));
      if (actual !== expected.fingerprint) {
        return {
          frame: expected.frame,
          divergence: { frame: expected.frame, expected: expected.fingerprint, actual },
        };
      }
    }
    return { frame: targetFrame };
  }

  public truncate(frame: number): void {
    if (!Number.isSafeInteger(frame) || frame < this.oldestFrame || frame > this.nextFrame) {
      throw new RangeError('replay branch is outside recorded history');
    }
    for (const key of this.frames.keys()) if (key >= frame) this.frames.delete(key);
    for (const key of this.snapshots.keys()) if (key > frame) this.snapshots.delete(key);
    this.nextFrame = frame;
  }

  public timeline(): readonly number[] {
    return [...this.frames.keys()];
  }

  private prune(): void {
    const keepFrom = Math.max(0, this.nextFrame - this.maximumFrames);
    const retainedSnapshots = [...this.snapshots.keys()].sort((left, right) => left - right);
    const anchor = retainedSnapshots.filter((frame) => frame <= keepFrom).at(-1);
    const cutoff = anchor ?? keepFrom;
    for (const frame of this.frames.keys()) if (frame < cutoff) this.frames.delete(frame);
    for (const frame of retainedSnapshots) {
      if (frame < keepFrom && frame !== anchor) this.snapshots.delete(frame);
    }
  }
}

export function debugFingerprint(value: unknown): string {
  const text = canonicalDebugValue(value, new Set());
  let hash = 0x811c9dc5;
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, '0');
}

/** Evaluates a non-mutating PXCL-like watch subset without dynamic JavaScript execution. */
export function evaluateWatch(
  source: string,
  environment: Readonly<Record<string, unknown>>,
): unknown {
  const parser = new WatchParser(tokenizeWatch(source), environment);
  const value = parser.expression();
  parser.finish();
  return value;
}

interface WatchToken {
  readonly kind: 'number' | 'text' | 'name' | 'operator' | 'eof';
  readonly text: string;
}

class WatchParser {
  private cursor = 0;

  public constructor(
    private readonly tokens: readonly WatchToken[],
    private readonly environment: Readonly<Record<string, unknown>>,
  ) {}

  public expression(minimumPrecedence = 0): unknown {
    let left = this.prefix();
    for (;;) {
      const operator = this.peek().text;
      const precedence = BINARY_PRECEDENCE[operator];
      if (precedence === undefined || precedence < minimumPrecedence) break;
      this.cursor += 1;
      const right = this.expression(precedence + 1);
      left = binaryWatch(operator, left, right);
    }
    return left;
  }

  public finish(): void {
    if (this.peek().kind !== 'eof') {
      throw new SyntaxError(`unexpected '${this.peek().text}' in watch expression`);
    }
  }

  private prefix(): unknown {
    const token = this.take();
    let value: unknown;
    if (token.kind === 'number') {
      value = Number(token.text);
    } else if (token.kind === 'text') {
      value = JSON.parse(token.text) as unknown;
    } else if (token.kind === 'name') {
      if (token.text === 'true' || token.text === 'false') value = token.text === 'true';
      else if (token.text === 'none') value = null;
      else if (token.text === 'not') value = !truthy(this.expression(7));
      else if (Object.hasOwn(this.environment, token.text)) value = this.environment[token.text];
      else throw new ReferenceError(`unknown watch name '${token.text}'`);
    } else if (token.text === '-' || token.text === '+') {
      const number = watchNumber(this.expression(7));
      value = token.text === '-' ? -number : number;
    } else if (token.text === '(') {
      value = this.expression();
      this.expect(')');
    } else {
      throw new SyntaxError(`expected a watch value, received '${token.text}'`);
    }
    while (this.peek().text === '.' || this.peek().text === '[') {
      if (this.take().text === '.') {
        const property = this.take();
        if (property.kind !== 'name') throw new SyntaxError('expected a field name after dot');
        value = readWatchProperty(value, property.text);
      } else {
        const key = this.expression();
        this.expect(']');
        value = readWatchProperty(value, key);
      }
    }
    return value;
  }

  private expect(text: string): void {
    if (this.take().text !== text) throw new SyntaxError(`expected '${text}' in watch expression`);
  }

  private peek(): WatchToken {
    return this.tokens[this.cursor] ?? { kind: 'eof', text: '' };
  }

  private take(): WatchToken {
    const token = this.peek();
    this.cursor += 1;
    return token;
  }
}

const BINARY_PRECEDENCE: Readonly<Record<string, number>> = {
  or: 1,
  and: 2,
  '==': 3,
  '!=': 3,
  '<': 4,
  '<=': 4,
  '>': 4,
  '>=': 4,
  '+': 5,
  '-': 5,
  '*': 6,
  '/': 6,
  '%': 6,
};

function tokenizeWatch(source: string): readonly WatchToken[] {
  const tokens: WatchToken[] = [];
  let cursor = 0;
  while (cursor < source.length) {
    const character = source[cursor] ?? '';
    if (/\s/u.test(character)) {
      cursor += 1;
      continue;
    }
    const rest = source.slice(cursor);
    const number = /^(?:\d+(?:\.\d+)?|\.\d+)/u.exec(rest)?.[0];
    if (number !== undefined) {
      tokens.push({ kind: 'number', text: number });
      cursor += number.length;
      continue;
    }
    const name = /^[A-Za-z_][A-Za-z0-9_]*/u.exec(rest)?.[0];
    if (name !== undefined) {
      tokens.push({ kind: 'name', text: name });
      cursor += name.length;
      continue;
    }
    if (character === '"') {
      let end = cursor + 1;
      while (end < source.length) {
        if (source[end] === '\\') end += 2;
        else if (source[end] === '"') break;
        else end += 1;
      }
      if (source[end] !== '"') throw new SyntaxError('unterminated watch text');
      tokens.push({ kind: 'text', text: source.slice(cursor, end + 1) });
      cursor = end + 1;
      continue;
    }
    const pair = rest.slice(0, 2);
    const operator = ['==', '!=', '<=', '>='].includes(pair)
      ? pair
      : '+-*/%<>().[]'.includes(character)
        ? character
        : undefined;
    if (operator === undefined) throw new SyntaxError(`unsupported watch token '${character}'`);
    tokens.push({ kind: 'operator', text: operator });
    cursor += operator.length;
  }
  tokens.push({ kind: 'eof', text: '' });
  return tokens;
}

function binaryWatch(operator: string, left: unknown, right: unknown): unknown {
  switch (operator) {
    case 'or':
      return truthy(left) || truthy(right);
    case 'and':
      return truthy(left) && truthy(right);
    case '==':
      return Object.is(left, right);
    case '!=':
      return !Object.is(left, right);
    case '<':
      return watchNumber(left) < watchNumber(right);
    case '<=':
      return watchNumber(left) <= watchNumber(right);
    case '>':
      return watchNumber(left) > watchNumber(right);
    case '>=':
      return watchNumber(left) >= watchNumber(right);
    case '+':
      return typeof left === 'string' && typeof right === 'string'
        ? left + right
        : watchNumber(left) + watchNumber(right);
    case '-':
      return watchNumber(left) - watchNumber(right);
    case '*':
      return watchNumber(left) * watchNumber(right);
    case '/':
      return watchNumber(left) / watchNumber(right);
    case '%':
      return watchNumber(left) % watchNumber(right);
    default:
      throw new SyntaxError(`unsupported watch operator '${operator}'`);
  }
}

function readWatchProperty(value: unknown, key: unknown): unknown {
  if (typeof key !== 'string' && typeof key !== 'number') {
    throw new TypeError('watch index must be a number or field name');
  }
  if (key === '__proto__' || key === 'prototype' || key === 'constructor') {
    throw new TypeError('watch access to host prototype fields is unavailable');
  }
  if ((typeof value !== 'object' && typeof value !== 'string') || value === null) {
    throw new TypeError('watch field access requires a record, collection, or text');
  }
  if (typeof value === 'string') {
    if (key === 'length') return value.length;
    if (typeof key === 'number' && Number.isSafeInteger(key)) return value[key];
    throw new TypeError(`watch field '${String(key)}' is unavailable`);
  }
  if (!Object.hasOwn(value, key))
    throw new TypeError(`watch field '${String(key)}' is unavailable`);
  return (value as Record<string | number, unknown>)[key];
}

function watchNumber(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new TypeError('watch arithmetic requires finite numbers');
  }
  return value;
}

function truthy(value: unknown): boolean {
  if (typeof value !== 'boolean') throw new TypeError('watch logic requires Bool values');
  return value;
}

function canonicalDebugValue(value: unknown, seen: Set<object>): string {
  if (value === null) return 'null';
  if (value === undefined) return 'undefined';
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new TypeError('debug values must contain finite numbers');
    return Object.is(value, -0) ? '-0' : String(value);
  }
  if (typeof value === 'string' || typeof value === 'boolean') return JSON.stringify(value);
  if (value instanceof Uint8Array) return `[u8:${[...value].join(',')}]`;
  if (Array.isArray(value)) {
    if (seen.has(value)) throw new TypeError('debug value contains a cycle');
    seen.add(value);
    const encoded = `[${value.map((item) => canonicalDebugValue(item, seen)).join(',')}]`;
    seen.delete(value);
    return encoded;
  }
  if (typeof value !== 'object') throw new TypeError('debug value is not serializable');
  if (seen.has(value)) throw new TypeError('debug value contains a cycle');
  seen.add(value);
  const record = value as Record<string, unknown>;
  const encoded = `{${Object.keys(record)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${canonicalDebugValue(record[key], seen)}`)
    .join(',')}}`;
  seen.delete(value);
  return encoded;
}
