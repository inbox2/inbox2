#!/usr/bin/env python3
"""Generate the meeting-alarm notification sound (ui/ios/Resources/meeting-alarm.caf).

A traditional digital-alarm-clock buzzer at an unhurried pace: three square-wave
beeps, then a beat of silence, repeating. Square, not sine — that's the whole
character of a piezo clock buzzer.

iOS caps a custom notification sound at 30 seconds and only accepts linear PCM /
IMA4 / uLaw / aLaw in .caf, .aiff or .wav. Linear PCM (LEI16) deliberately: IMA4 is
a quarter of the size and decodes fine in afplay, but a device build with it
delivered the banner silently. Size is not worth re-litigating that.

Tune the constants below and re-run; there is no other source for the file.

    python3 bin/gen-alarm-sound.py
"""

import math
import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

RATE = 44100             # square waves need the headroom; 22k aliases audibly
DURATION = 25.0          # seconds — iOS ignores custom sounds longer than 30
PEAK = 0.62              # square waves are far louder than sines at equal peak

TONE = 3000.0            # piezo-buzzer pitch
BEEPS = 3                # beeps per group
ON, OFF = 0.15, 0.28     # beep length / gap inside a group
PAUSE = 1.50             # silence after each group

GROUP = BEEPS * (ON + OFF)
CYCLE = GROUP + PAUSE


def square(freq: float, t: float) -> float:
    """Band-limited square — odd harmonics up to 15 kHz, so it stays harsh
    without aliasing into grit."""
    out = 0.0
    h = 1
    while freq * h <= 15000:
        out += math.sin(2 * math.pi * freq * h * t) / h
        h += 2
    return out * 4 / math.pi


def sample(t: float) -> float:
    pos = t % CYCLE
    if pos >= GROUP:
        return 0.0
    local = pos % (ON + OFF)
    if local >= ON:
        return 0.0
    # 3 ms attack/release — a square edge without it clicks on top of the beep.
    env = min(1.0, min(local, ON - local) / 0.003)
    return PEAK * env * max(-1.0, min(1.0, square(TONE, local) / 1.2))


def main() -> int:
    out = Path(__file__).resolve().parent.parent / "ui/ios/Resources/meeting-alarm.caf"
    frames = int(RATE * DURATION)
    values = [max(-32767, min(32767, int(sample(n / RATE) * 32767))) for n in range(frames)]
    # A silent or clipped alarm is the one failure that looks like success.
    peak = max(abs(v) for v in values)
    assert 16000 < peak <= 32767, f"alarm peak out of range: {peak}"
    pcm = b"".join(struct.pack("<h", v) for v in values)

    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        with wave.open(tmp.name, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(pcm)
        out.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", tmp.name, str(out)], check=True)
    print(f"wrote {out} ({out.stat().st_size // 1024} KB, {DURATION:g}s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
