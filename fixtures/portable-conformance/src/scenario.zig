const up = @import("unpolished-peas");
pub const ticks = 10;

pub fn input(tick: usize) !up.input.Input {
    var result = up.input.Input{};
    switch (tick) {
        0 => result.setPhysical(.digit_1, true, false),
        1 => result.setPhysical(.digit_2, true, false),
        2 => result.setPhysical(.f5, true, false),
        3 => result.setPhysical(.r, true, false),
        4, 7 => result.setPhysical(.f4, true, false),
        5 => {
            result.setTextInputActive(true);
            try result.updateComposition("Zo", -1, -1);
        },
        6 => {
            result.setTextInputActive(true);
            try result.commitText("Zoë你好");
            result.extended.endComposition();
        },
        8 => result.setPhysical(.space, true, false),
        else => {},
    }
    return result;
}
