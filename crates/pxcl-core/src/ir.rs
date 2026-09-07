use serde::{Deserialize, Serialize};

use crate::{
    ast::{AssignmentOperator, BinaryOperator, CallbackKind, Literal, UnaryOperator},
    span::Span,
    types::{AssetKind, SymbolId, Type},
};

/// Resolved symbol category exposed to the compiler explorer and language server.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SymbolKind {
    Import,
    Constant,
    State,
    Function,
    Task,
    Parameter,
    Local,
    Record,
    Enum,
    Variant,
    Builtin,
}

/// One definition in the resolved module symbol table.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Symbol {
    pub id: SymbolId,
    pub name: String,
    pub kind: SymbolKind,
    pub r#type: Type,
    pub mutable: bool,
    pub defined_at: Option<Span>,
}

/// Typed IR module consumed by both debug and release lowering.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct IrModule {
    pub globals: Vec<IrGlobal>,
    pub records: Vec<IrRecord>,
    pub enums: Vec<IrEnum>,
    pub routines: Vec<IrRoutine>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct IrGlobal {
    pub symbol: SymbolId,
    pub mutable: bool,
    pub initializer: IrExpression,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct IrRecord {
    pub symbol: SymbolId,
    pub fields: Vec<IrField>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct IrField {
    pub name: String,
    pub r#type: Type,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct IrEnum {
    pub symbol: SymbolId,
    pub variants: Vec<IrVariant>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct IrVariant {
    pub symbol: SymbolId,
    pub fields: Vec<Type>,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", content = "data")]
pub enum RoutineKind {
    Function,
    Task,
    Callback(CallbackKind),
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct IrRoutine {
    pub symbol: Option<SymbolId>,
    pub name: String,
    pub kind: RoutineKind,
    pub parameters: Vec<SymbolId>,
    pub return_type: Type,
    pub body: Vec<IrStatement>,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct IrStatement {
    pub kind: IrStatementKind,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "kind", content = "data")]
pub enum IrStatementKind {
    Let {
        symbol: SymbolId,
        mutable: bool,
        value: IrExpression,
    },
    Store {
        target: IrPlace,
        operator: AssignmentOperator,
        value: IrExpression,
    },
    Expression(IrExpression),
    Return(Option<IrExpression>),
    Break,
    Continue,
    Wait(IrExpression),
    Start(IrExpression),
    Assert {
        condition: IrExpression,
        message: Option<IrExpression>,
    },
    If {
        branches: Vec<IrBranch>,
        else_body: Option<Vec<IrStatement>>,
    },
    While {
        condition: IrExpression,
        body: Vec<IrStatement>,
    },
    For {
        binding: SymbolId,
        iterable: IrExpression,
        body: Vec<IrStatement>,
    },
    Match {
        subject: IrExpression,
        arms: Vec<IrMatchArm>,
    },
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct IrBranch {
    pub condition: IrExpression,
    pub body: Vec<IrStatement>,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct IrMatchArm {
    pub pattern: IrPattern,
    pub body: Vec<IrStatement>,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", content = "data")]
pub enum IrPattern {
    Wildcard,
    Binding(SymbolId),
    Variant {
        symbol: SymbolId,
        bindings: Vec<SymbolId>,
    },
    Literal(Literal),
    Error,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct IrExpression {
    pub kind: IrExpressionKind,
    pub r#type: Type,
    pub span: Span,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "kind", content = "data")]
pub enum IrExpressionKind {
    Literal(Literal),
    Load(SymbolId),
    Asset { name: String, kind: AssetKind },
    Array(Vec<IrExpression>),
    Unary {
        operator: UnaryOperator,
        operand: Box<IrExpression>,
    },
    Binary {
        left: Box<IrExpression>,
        operator: BinaryOperator,
        right: Box<IrExpression>,
    },
    Call {
        callee: SymbolId,
        arguments: Vec<IrExpression>,
    },
    Field {
        subject: Box<IrExpression>,
        field: String,
    },
    Index {
        subject: Box<IrExpression>,
        index: Box<IrExpression>,
    },
    Error,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "kind", content = "data")]
pub enum IrPlace {
    Symbol(SymbolId),
    Field {
        subject: Box<IrExpression>,
        field: String,
    },
    Index {
        subject: Box<IrExpression>,
        index: Box<IrExpression>,
    },
    Error,
}
