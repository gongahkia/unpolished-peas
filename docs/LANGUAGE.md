# PXCL/1 language contract

PXCL/1 is frozen as the ASCII-only, statically typed, indentation-sensitive cartridge language of
PX-240C Hardware Revision 1. The complete normative syntax, types, name-resolution, initialization,
task, work-accounting, formatting, and diagnostic behavior is maintained in the
[PXCL/1 reference](PXCL.md). This stable entry point exists so cartridge and tool documentation can
refer to the language contract without depending on an older filename.

V1 adds project semantics without changing existing single-file meaning: declarations are public by
default, `pub` is explicit, `private` hides an imported member, and `import src.math as math` exposes
public values as qualified names such as `math.twice`. Modules own separate top-level namespaces;
dependencies initialize deterministically before importers; import cycles and dependency callbacks
are rejected. No classes, inheritance, reflection, macros, packages, host JavaScript, or dynamic
module loading are part of PXCL/1.

Compiler behavior and the checked syntax/type/project fixtures are authoritative if prose and code
ever diverge. `px240c fmt`, native compilation, the Wasm compiler used by Studio, compiler explorer,
and `px240c lsp` all consume the same lexer/parser/type/link pipeline.
