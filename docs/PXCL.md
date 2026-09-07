# PXCL/1 language reference

PXCL/1 (PX Cartridge Language, Revision 1) is an ASCII-only, statically typed language for
deterministic PX-240C cartridges. Newlines terminate statements and indentation defines blocks.
Keywords are lowercase, identifiers are case-sensitive, and indexes and half-open ranges are
zero-based. The compiler and its conformance fixtures are authoritative when this document differs.

This reference currently describes the implemented syntax front end. Static semantics, standard
modules, tasks, and runtime APIs will be extended alongside their verified compiler phases.

## Lexical rules

- Indentation uses spaces. The formatter emits two spaces per level; tabs are an error (`PX1002`).
- `//` begins a comment. Strings use double quotes and support `\n`, `\t`, `\"`, and `\\` escapes.
- Decimal `Num` literals contain a decimal point. `Int` literals do not.
- Durations use `2f` for frames and `0.5s` for deterministic cartridge seconds.
- `#hero` is a named asset reference, not a string.
- Operators are `+ - * / %`, comparisons, `and or not`, assignment and compound assignment.
- `0..10` is a half-open range. The end value is excluded.

## Declarations

Persistent mutable state always has an explicit type:

```pxl
const MAX_SPEED: Num = 4.5
state score: Int = 0
state recent: List[Int, 16] = []
state ports: [Int, 4] = [0, 0, 0, 0]
```

Locals use inferred types. `let` is immutable and `var` is mutable. Functions declare parameter and
return types. Tasks have typed parameters but no return value and may suspend with `wait`.

```pxl
fn add(left: Int, right: Int) -> Int:
  return left + right

task flash(color: Color):
  pal(1, color)
  wait 2f
```

System callbacks are `on start:`, `on update:`, `on draw:`, and
`on raster(line: Int):`. A task begins only through `start task_name(arguments)`.

Records contain typed fields and optional defaults. Enum variants may have typed payloads. `match`
arms begin with `case`; `else` is the wildcard arm.

```pxl
record Player:
  pos: Vec2
  lives: Int = 3

enum Mode:
  Title
  Play
  Win(Int)
```

## Grammar

The following EBNF specifies the accepted syntax. Whitespace between tokens is omitted; `NEWLINE`,
`INDENT`, and `DEDENT` are structural lexer tokens.

```ebnf
module       = { NEWLINE | item }, EOF ;
item         = import | constant | state | function | task | callback
             | record | enum | assertion ;
import       = "import", path, [ "as", identifier ], line-end ;
constant     = "const", identifier, [ ":", type ], "=", expression, line-end ;
state        = "state", identifier, ":", type, "=", expression, line-end ;
function     = "fn", identifier, parameters, "->", type, ":", block ;
task         = "task", identifier, parameters, ":", block ;
callback     = "on", ( "start" | "update" | "draw" | "raster" ),
               [ parameters ], ":", block ;
parameters   = "(", [ parameter, { ",", parameter } ], ")" ;
parameter    = identifier, ":", type ;
record       = "record", identifier, ":", NEWLINE, INDENT,
               { identifier, ":", type, [ "=", expression ], line-end }, DEDENT ;
enum         = "enum", identifier, ":", NEWLINE, INDENT,
               { identifier, [ "(", type, { ",", type }, ")" ], line-end }, DEDENT ;
type         = path, [ "[", type-arg, { ",", type-arg }, "]" ]
             | "[", type, ",", integer, "]" ;
type-arg     = type | integer ;
block        = NEWLINE, INDENT, { NEWLINE | statement }, DEDENT ;
statement    = ( "let" | "var" ), identifier, "=", expression, line-end
             | assignable, assign-op, expression, line-end
             | "return", [ expression ], line-end
             | ( "break" | "continue" ), line-end
             | "wait", expression, line-end
             | "start", expression, line-end
             | assertion | if | while | for | match | expression, line-end ;
if           = "if", expression, ":", block,
               { "elif", expression, ":", block }, [ "else", ":", block ] ;
while        = "while", expression, ":", block ;
for          = "for", identifier, "in", expression, ":", block ;
match        = "match", expression, ":", NEWLINE, INDENT,
               { ( "case", pattern | "else" ), ":", block }, DEDENT ;
assertion     = "assert", expression, [ ",", expression ], line-end ;
expression   = literal | path | asset | array | unary | binary | call | field | index | grouped ;
array        = "[", [ expression, { ",", expression } ], "]" ;
path         = identifier, { ".", identifier } ;
line-end     = [ comment ], NEWLINE ;
```

## Diagnostics and formatting

Diagnostics carry stable codes, exact half-open UTF-8 byte spans, primary and secondary labels, and
notes. `PX1xxx` identifies lexical errors and `PX2xxx` identifies parsing errors. Tooling consumes the
structured representation rather than scraping prose.

`px240c fmt` writes canonical two-space indentation and token spacing. `px240c fmt --check` reports
drift without writing. The formatter refuses invalid syntax so it cannot silently reinterpret a
broken module.
