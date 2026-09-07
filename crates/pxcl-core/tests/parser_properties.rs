use pxcl_core::{FileId, SourceFile, TokenKind, parse};

#[test]
fn bounded_ascii_inputs_always_terminate_with_eof() {
    let alphabet = b"abc_012 :()[]+-*/%=<>.,#\"\n\t";
    let mut state = 0x240c_1999_u64;
    for case in 0..512_u32 {
        state = state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1);
        let length = usize::try_from((state >> 24) % 96).expect("bounded length");
        let mut input = String::with_capacity(length);
        for _ in 0..length {
            state = state
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1);
            let index =
                usize::try_from(state % u64::try_from(alphabet.len()).expect("small alphabet"))
                    .expect("index is bounded");
            input.push(char::from(alphabet[index]));
        }
        let source = SourceFile::new(FileId(case), format!("generated-{case}.pxl"), input);
        let output = parse(&source);
        assert!(
            matches!(
                output.tokens.last().map(|token| &token.kind),
                Some(TokenKind::Eof)
            ),
            "case {case} did not terminate with EOF"
        );
    }
}
