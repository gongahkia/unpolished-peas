use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::span::Span;

/// Public asset categories, each represented by a distinct PXCL handle type.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AssetKind {
    Sprite,
    Animation,
    TileSet,
    Map,
    Font,
    Sound,
    Music,
}

impl AssetKind {
    #[must_use]
    pub const fn type_name(self) -> &'static str {
        match self {
            Self::Sprite => "Sprite",
            Self::Animation => "Animation",
            Self::TileSet => "TileSet",
            Self::Map => "Map",
            Self::Font => "Font",
            Self::Sound => "Sound",
            Self::Music => "Music",
        }
    }
}

/// Asset declaration supplied by a project manifest.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AssetDefinition {
    pub kind: AssetKind,
    pub declared_at: Option<Span>,
}

/// Deterministically ordered named assets visible during analysis.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct AssetCatalog {
    entries: BTreeMap<String, AssetDefinition>,
}

impl AssetCatalog {
    pub fn insert(&mut self, name: impl Into<String>, kind: AssetKind) -> Option<AssetDefinition> {
        self.entries.insert(
            name.into(),
            AssetDefinition {
                kind,
                declared_at: None,
            },
        )
    }

    #[must_use]
    pub fn get(&self, name: &str) -> Option<&AssetDefinition> {
        self.entries.get(name)
    }

    #[must_use]
    pub fn iter(&self) -> impl Iterator<Item = (&str, &AssetDefinition)> {
        self.entries
            .iter()
            .map(|(name, definition)| (name.as_str(), definition))
    }
}

/// Stable identifier assigned during name resolution.
#[derive(
    Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize,
)]
pub struct SymbolId(pub u32);

/// Fully resolved PXCL value type used by typed IR and debugger metadata.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", content = "data")]
pub enum Type {
    Unit,
    Num,
    Int,
    Bool,
    Text,
    Color,
    Vec2,
    Rect,
    Controller,
    Button,
    Duration,
    Asset(AssetKind),
    Option(Box<Self>),
    Array { element: Box<Self>, length: u32 },
    List { element: Box<Self>, capacity: u32 },
    Record(SymbolId),
    Enum(SymbolId),
    Function(FunctionType),
    Range,
    Module,
    Unknown,
    Error,
}

impl Type {
    #[must_use]
    pub const fn is_numeric(&self) -> bool {
        matches!(self, Self::Int | Self::Num)
    }

    #[must_use]
    pub const fn is_error(&self) -> bool {
        matches!(self, Self::Error)
    }
}

/// Non-capturing callable signature.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct FunctionType {
    pub parameters: Vec<Type>,
    pub return_type: Box<Type>,
    pub task: bool,
}
