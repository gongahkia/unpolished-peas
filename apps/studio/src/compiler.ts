import initWasm, {
  analyze as wasmAnalyze,
  compileProject as wasmCompileProject,
  compiler_version as wasmCompilerVersion,
  decodeCartridge as wasmDecodeCartridge,
  exportHtml as wasmExportHtml,
  format as wasmFormat,
  language_revision as wasmLanguageRevision,
  packProject as wasmPackProject,
  parseProjectManifest as wasmParseProjectManifest,
  unpackCartridge as wasmUnpackCartridge,
} from '../../../crates/pxcl-wasm/pkg/pxcl_wasm';

export interface SourceSpan {
  readonly file: number;
  readonly start: number;
  readonly end: number;
}

export interface CompilerDiagnostic {
  readonly code: string;
  readonly severity: 'error' | 'warning';
  readonly message: string;
  readonly primary: { readonly span: SourceSpan; readonly message: string };
  readonly secondary: readonly { readonly span: SourceSpan; readonly message: string }[];
  readonly notes: readonly string[];
}

export interface CompilerSymbol {
  readonly id: number;
  readonly name: string;
  readonly kind: string;
  readonly type: unknown;
  readonly mutable: boolean;
  readonly defined_at?: SourceSpan;
}

export interface CompilationResult {
  readonly analysis: {
    readonly tokens: readonly unknown[];
    readonly module: unknown;
    readonly symbols: readonly CompilerSymbol[];
    readonly ir: unknown;
    readonly diagnostics: readonly CompilerDiagnostic[];
  };
  readonly generated?: {
    readonly mode: 'release' | 'debug';
    readonly javascript: string;
    readonly source_map_json: string;
    readonly relationships: readonly unknown[];
    readonly generated_bytes: number;
    readonly probe_count: number;
    readonly work_model: Readonly<Record<string, number>>;
  };
}

export interface DecodedCartridge {
  readonly manifest: Readonly<Record<string, unknown>>;
  readonly entries: Readonly<Record<string, readonly number[]>>;
}

export interface ProjectManifest {
  readonly format_revision: number;
  readonly language_revision: string;
  readonly id: string;
  readonly title: string;
  readonly author: string;
  readonly version: string;
  readonly entry: string;
  readonly update_rate: 30 | 60;
  readonly compile_on_load?: boolean;
  readonly label: string | null;
  readonly thumbnail: string | null;
  readonly display: string | null;
  readonly assets: Readonly<
    Record<
      string,
      {
        readonly kind: 'sprite' | 'animation' | 'tile_set' | 'map' | 'font' | 'sound' | 'music';
        readonly path: string;
      }
    >
  >;
}

export interface UnpackedProject {
  readonly manifest: string;
  readonly files: Readonly<Record<string, readonly number[]>>;
}

/** Lazy WebAssembly bridge over the repository's authoritative Rust compiler and packer. */
export class BrowserCompiler {
  private readonly initialized: Promise<void>;

  public constructor() {
    this.initialized = initWasm().then(() => undefined);
  }

  public async identity(): Promise<{ readonly compiler: string; readonly language: string }> {
    await this.initialized;
    return { compiler: wasmCompilerVersion(), language: wasmLanguageRevision() };
  }

  public async analyze(fileName: string, source: string): Promise<CompilationResult['analysis']> {
    await this.initialized;
    return JSON.parse(wasmAnalyze(fileName, source)) as CompilationResult['analysis'];
  }

  public async compileProject(
    manifest: string,
    files: Readonly<Record<string, Uint8Array>>,
    debug: boolean,
  ): Promise<CompilationResult> {
    await this.initialized;
    return JSON.parse(
      wasmCompileProject(manifest, encodeProjectFiles(files), debug),
    ) as CompilationResult;
  }

  public async format(fileName: string, source: string): Promise<string> {
    await this.initialized;
    return wasmFormat(fileName, source);
  }

  public async packProject(
    manifest: string,
    files: Readonly<Record<string, Uint8Array>>,
  ): Promise<Uint8Array> {
    await this.initialized;
    return wasmPackProject(manifest, encodeProjectFiles(files));
  }

  public async decodeCartridge(bytes: Uint8Array): Promise<DecodedCartridge> {
    await this.initialized;
    return JSON.parse(wasmDecodeCartridge(bytes)) as DecodedCartridge;
  }

  public async unpackCartridge(bytes: Uint8Array): Promise<UnpackedProject> {
    await this.initialized;
    return JSON.parse(wasmUnpackCartridge(bytes)) as UnpackedProject;
  }

  public async exportHtml(
    manifest: string,
    files: Readonly<Record<string, Uint8Array>>,
  ): Promise<string> {
    await this.initialized;
    return wasmExportHtml(manifest, encodeProjectFiles(files));
  }

  public async parseManifest(source: string): Promise<ProjectManifest> {
    await this.initialized;
    return JSON.parse(wasmParseProjectManifest(source)) as ProjectManifest;
  }
}

function encodeProjectFiles(files: Readonly<Record<string, Uint8Array>>): string {
  return JSON.stringify(
    Object.fromEntries(
      Object.entries(files)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([path, bytes]) => [path, [...bytes]]),
    ),
  );
}
