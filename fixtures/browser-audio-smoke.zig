const up = @import("unpolished-peas");

pub export fn up_browser_audio_stream_smoke(stream: *up.assets.AudioStream, mixer: *up.assets.AudioMixer) i32 {
    return if (stream.submit(mixer) catch return -1) 0 else -2;
}
