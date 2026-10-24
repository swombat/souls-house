"""services/voice-embeddings/wav.py: what the voice service accepts as audio."""
import importlib.util
import io
import struct
import unittest
import wave
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "voice_wav", Path(__file__).resolve().parent.parent / "services/voice-embeddings/wav.py")
wav = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(wav)


def make(seconds, rate=16000, channels=1, width=2, value=1000):
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as out:
        out.setnchannels(channels)
        out.setsampwidth(width)
        out.setframerate(rate)
        frames = int(seconds * rate)
        sample = struct.pack("<h", value) if width == 2 else bytes([128])
        out.writeframes(sample * frames * channels)
    return buffer.getvalue()


class VoiceEmbeddingsWavTest(unittest.TestCase):

    def test_accepts_mono_16k_16bit_and_returns_every_frame(self):
        raw = wav.pcm16_mono(make(3))
        self.assertEqual(3 * 16000 * 2, len(raw))

    def test_refuses_truncated_audio_whose_header_claims_more(self):
        data = make(30)
        for keep in (len(data) // 2, len(data) - 1, 44 + 16000 * 2):
            with self.subTest(keep=keep), self.assertRaises(ValueError):
                wav.pcm16_mono(data[:keep])

    def test_refuses_other_formats_lengths_and_silence(self):
        bad = [make(3, rate=8000), make(3, channels=2), make(3, width=1),
               make(0.4), make(120.5), make(3, value=0), b"RIFFnonsense", b""]
        for data in bad:
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                wav.pcm16_mono(data)

    def test_accepts_the_bounds(self):
        self.assertEqual(8000 * 2, len(wav.pcm16_mono(make(0.5))))
        self.assertEqual(120 * 16000 * 2, len(wav.pcm16_mono(make(120))))


if __name__ == "__main__":
    unittest.main()
