const std = @import("std");

pub export fn up_vorbis_sin(value: f64) f64 {
    return @sin(value);
}
pub export fn up_vorbis_cos(value: f64) f64 {
    return @cos(value);
}
pub export fn up_vorbis_log(value: f64) f64 {
    return @log(value);
}
pub export fn up_vorbis_exp(value: f64) f64 {
    return @exp(value);
}
pub export fn up_vorbis_floor(value: f64) f64 {
    return @floor(value);
}
pub export fn up_vorbis_ldexp(value: f64, exponent: c_int) f64 {
    return std.math.ldexp(value, exponent);
}
