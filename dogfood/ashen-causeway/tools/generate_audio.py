"""Original Ashen Causeway PCM score and effects. Python standard library only.

No sampled recordings or third-party compositions. Re-run from any directory.
22050 Hz mono, signed PCM16; deliberately quiet, soft attack/release envelopes.
"""
from pathlib import Path
import math
import struct
import wave

ROOT = Path(__file__).resolve().parents[1] / 'src' / 'assets' / 'audio'
ROOT.mkdir(parents=True, exist_ok=True)
RATE = 22050

def write(name, duration, sample):
    with wave.open(str(ROOT / (name + '.wav')), 'wb') as out:
        out.setparams((1, 2, RATE, 0, 'NONE', 'not compressed'))
        out.writeframes(b''.join(struct.pack('<h', round(max(-1, min(1, sample(i / RATE, i))) * 32767)) for i in range(round(duration * RATE))))

def tone(t, hz):
    return math.sin(math.tau * hz * t)

def envelope(t, duration):
    return min(1, t / .012) * min(1, (duration - t) / .025)

for name, hz, duration in [('swing', 185, .14), ('hit', 520, .17), ('hurt', 92, .24), ('heal', 440, .45), ('reject', 110, .08), ('bell', 330, .7), ('menu', 660, .06)]:
    def effect(t, i, hz=hz, d=duration, name=name):
        freq = hz * (1 - .35 * t / d) if name in ('swing', 'hurt') else hz
        voice = tone(t, freq) + .28 * tone(t, freq * 2.01)
        if name in ('hit', 'swing'):
            noise = (((i * 1103515245 + 12345) & 65535) / 32768 - 1)
            voice = .35 * voice + .4 * noise
        return .24 * envelope(t, d) * math.exp(-4 * t / d) * voice
    write(name, duration, effect)

# Eight seconds of slowly breathing D/A drone and two inharmonic bell tones.
# The sine-squared envelope reaches zero at the loop boundary without a click.
def score(t, i):
    breath = math.sin(math.pi * t / 8) ** 2
    drone = .08 * (tone(t, 110) + .45 * tone(t, 165))
    bells = 0
    for start, hz in [(0.5, 440), (4.5, 330)]:
        u = t - start
        if u >= 0:
            bells += .13 * min(1, u / .02) * math.exp(-2.6 * u) * (tone(u, hz) + .25 * tone(u, hz * 2.01))
    return breath * (drone + bells)
write('causeway', 8, score)
