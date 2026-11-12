#!/usr/bin/env python3
"""Original short sine/chirp effects. No sampled or external audio sources."""
import math
from pathlib import Path
import struct
import wave
ROOT=Path(__file__).resolve().parent.parent
SOUNDS={
    'lantern-leap': [('jump',620,1040,.10),('collect',880,1500,.14),('reset',320,100,.16)],
    'neon-siege': [('shot',900,350,.055),('pickup',650,1300,.14),('hurt',180,70,.16),('wave',350,750,.18)],
}
for game,sounds in SOUNDS.items():
    for name,start,end,duration in sounds:
        rate=48000;count=round(duration*rate);phase=0;data=bytearray()
        for index in range(count):
            t=index/count;phase+=2*math.pi*(start+(end-start)*t)/rate
            envelope=min(1,index/120)*(1-t)**2
            data+=struct.pack('<h',round(math.sin(phase)*envelope*10000))
        with wave.open(str(ROOT/'dogfood'/game/'assets'/f'{name}.wav'),'wb') as target:
            target.setparams((1,2,rate,0,'NONE','not compressed'));target.writeframes(data)
