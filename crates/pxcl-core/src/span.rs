use serde::{Deserialize, Serialize};

/// Stable identifier for one source module within a compilation.
#[derive(
    Clone, Copy, Debug, Default, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize,
)]
pub struct FileId(pub u32);

/// Half-open UTF-8 byte range in a source file.
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub struct Span {
    pub file: FileId,
    pub start: u32,
    pub end: u32,
}

impl Span {
    /// Creates a byte span. PXCL source limits make `u32` offsets sufficient.
    #[must_use]
    pub const fn new(file: FileId, start: u32, end: u32) -> Self {
        Self { file, start, end }
    }

    /// Returns a span from the start of `self` through the end of `other`.
    #[must_use]
    pub fn through(self, other: Self) -> Self {
        debug_assert_eq!(self.file, other.file);
        Self::new(
            self.file,
            self.start.min(other.start),
            self.end.max(other.end),
        )
    }

    /// Returns whether this span contains the given byte offset.
    #[must_use]
    pub const fn contains(self, offset: u32) -> bool {
        self.start <= offset && offset < self.end
    }
}

/// A syntax value paired with its exact source range.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Spanned<T> {
    pub value: T,
    pub span: Span,
}

impl<T> Spanned<T> {
    #[must_use]
    pub const fn new(value: T, span: Span) -> Self {
        Self { value, span }
    }
}

/// Human-facing zero-based source position.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LineColumn {
    pub line: u32,
    pub column: u32,
}

/// Immutable source text and its line index.
#[derive(Clone, Debug)]
pub struct SourceFile {
    id: FileId,
    name: String,
    text: String,
    line_starts: Vec<u32>,
}

impl SourceFile {
    /// Indexes a source module for byte-offset and line-column conversion.
    #[must_use]
    pub fn new(id: FileId, name: impl Into<String>, text: impl Into<String>) -> Self {
        let text = text.into();
        let mut line_starts = vec![0];
        for (offset, byte) in text.bytes().enumerate() {
            if byte == b'\n' {
                line_starts.push(u32::try_from(offset + 1).unwrap_or(u32::MAX));
            }
        }
        Self {
            id,
            name: name.into(),
            text,
            line_starts,
        }
    }

    #[must_use]
    pub const fn id(&self) -> FileId {
        self.id
    }

    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    #[must_use]
    pub fn text(&self) -> &str {
        &self.text
    }

    #[must_use]
    pub fn eof_span(&self) -> Span {
        let end = u32::try_from(self.text.len()).unwrap_or(u32::MAX);
        Span::new(self.id, end, end)
    }

    #[must_use]
    pub fn line_column(&self, offset: u32) -> LineColumn {
        let offset = offset.min(u32::try_from(self.text.len()).unwrap_or(u32::MAX));
        let line = self.line_starts.partition_point(|start| *start <= offset) - 1;
        LineColumn {
            line: u32::try_from(line).unwrap_or(u32::MAX),
            column: offset - self.line_starts[line],
        }
    }

    #[must_use]
    pub fn text_for(&self, span: Span) -> Option<&str> {
        if span.file != self.id || span.start > span.end {
            return None;
        }
        self.text
            .get(usize::try_from(span.start).ok()?..usize::try_from(span.end).ok()?)
    }
}

#[cfg(test)]
mod tests {
    use super::{FileId, LineColumn, SourceFile, Span};

    #[test]
    fn converts_offsets_at_line_boundaries() {
        let source = SourceFile::new(FileId(3), "game.pxl", "a\nbc\n");
        assert_eq!(source.line_column(3), LineColumn { line: 1, column: 1 });
        assert_eq!(source.text_for(Span::new(FileId(3), 2, 4)), Some("bc"));
        assert_eq!(source.line_column(99), LineColumn { line: 2, column: 0 });
    }
}
