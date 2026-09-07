import type { SourceSpan } from './protocol';

export class RuntimeFault extends Error {
  public readonly code: string;
  public readonly sourceSpan: SourceSpan;

  public constructor(code: string, message: string, sourceSpan: SourceSpan) {
    super(message);
    this.name = 'RuntimeFault';
    this.code = code;
    this.sourceSpan = sourceSpan;
  }
}

export class BudgetExceeded extends RuntimeFault {
  public readonly used: number;
  public readonly limit: number;

  public constructor(used: number, limit: number, sourceSpan: SourceSpan) {
    super(
      'PX9001',
      `frame used ${String(used)} synthetic work units; limit is ${String(limit)}`,
      sourceSpan,
    );
    this.name = 'BudgetExceeded';
    this.used = used;
    this.limit = limit;
  }
}
