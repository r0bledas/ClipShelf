#!/usr/bin/env python3
"""
Synthesizes original, royalty-free tactile UI sound effects (Copy.aiff, Paste.aiff)
for ClipShelf using pure Python standard library (math, struct, aifc).
"""
import math
import os
import struct
import wave

SAMPLE_RATE = 44100


def write_aiff(path: str, samples: list[float]) -> None:
    """Write 16-bit big-endian mono PCM AIFF file without external dependencies."""
    num_frames = len(samples)
    pcm = bytearray()
    for s in samples:
        clamped = max(-1.0, min(1.0, s))
        pcm.extend(struct.pack(">h", int(clamped * 32767)))

    # Convert sample rate to 80-bit IEEE 754 extended float (44100.0)
    # 44100 = 0xAC44 -> exponent 15 + 16383 = 16398 = 0x400E, mantissa 0xAC44000000000000
    sr_ext = struct.pack(">H", 0x400E) + struct.pack(">Q", 0xAC44000000000000)

    comm_data = struct.pack(">hIh", 1, num_frames, 16) + sr_ext
    ssnd_data = struct.pack(">II", 0, 0) + bytes(pcm)

    form_size = 4 + (8 + len(comm_data)) + (8 + len(ssnd_data))
    with open(path, "wb") as f:
        f.write(b"FORM")
        f.write(struct.pack(">I", form_size))
        f.write(b"AIFF")
        f.write(b"COMM")
        f.write(struct.pack(">I", len(comm_data)))
        f.write(comm_data)
        f.write(b"SSND")
        f.write(struct.pack(">I", len(ssnd_data)))
        f.write(ssnd_data)


def synth_copy() -> list[float]:
    """Crisp upward tactile pop (~75ms) for clipboard capture."""
    duration = 0.075
    n = int(SAMPLE_RATE * duration)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / SAMPLE_RATE
        # Subtle upward pitch chirp from 680 Hz to 1180 Hz
        freq = 680.0 + 500.0 * (1.0 - math.exp(-t / 0.018))
        phase += 2.0 * math.pi * freq / SAMPLE_RATE
        attack = min(1.0, t / 0.0025)
        decay = math.exp(-t / 0.016)
        body = math.sin(phase) * 0.55 + math.sin(phase * 2.02) * 0.18
        click = math.exp(-t / 0.002) * math.sin(2.0 * math.pi * 2400.0 * t) * 0.22
        out.append((body + click) * attack * decay * 0.65)
    return out


def synth_paste() -> list[float]:
    """Soft, grounded downward tactile click (~80ms) for pasting."""
    duration = 0.080
    n = int(SAMPLE_RATE * duration)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / SAMPLE_RATE
        # Gentle downward pitch drop from 920 Hz to 520 Hz
        freq = 520.0 + 400.0 * math.exp(-t / 0.016)
        phase += 2.0 * math.pi * freq / SAMPLE_RATE
        attack = min(1.0, t / 0.002)
        decay = math.exp(-t / 0.018)
        body = math.sin(phase) * 0.62 + math.sin(phase * 1.5) * 0.16
        tap = math.exp(-t / 0.0025) * math.sin(2.0 * math.pi * 1900.0 * t) * 0.18
        out.append((body + tap) * attack * decay * 0.70)
    return out


def main() -> None:
    out_dir = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "Sources",
        "ClipShelf",
        "Resources",
        "Sounds",
    )
    os.makedirs(out_dir, exist_ok=True)
    copy_path = os.path.join(out_dir, "Copy.aiff")
    paste_path = os.path.join(out_dir, "Paste.aiff")
    write_aiff(copy_path, synth_copy())
    write_aiff(paste_path, synth_paste())
    print(f"Generated:\n  {copy_path}\n  {paste_path}")


if __name__ == "__main__":
    main()
