"""WAV validation for the voice-embeddings service. Standard library only, so CI can test it."""
import io
import wave

SAMPLE_RATE = 16000
MAX_SECONDS = 120
MIN_SECONDS = 0.5


def pcm16_mono(data):
    """Returns the PCM bytes of a mono 16 kHz 16-bit WAV of 0.5-120 s, or raises ValueError.

    The duration is checked against the frames actually present, not the
    header's claim: a truncated file whose header advertises more audio than
    it holds is refused, as is one with trailing partial frames.
    """
    try:
        with wave.open(io.BytesIO(data), "rb") as wav:
            if wav.getnchannels() != 1 or wav.getframerate() != SAMPLE_RATE or wav.getsampwidth() != 2:
                raise ValueError("format")
            advertised = wav.getnframes()
            if not MIN_SECONDS * SAMPLE_RATE <= advertised <= MAX_SECONDS * SAMPLE_RATE:
                raise ValueError("length")
            raw = wav.readframes(advertised)
    except (wave.Error, EOFError) as error:
        raise ValueError("format") from error
    if len(raw) != advertised * 2:
        raise ValueError("truncated")
    if not any(raw):
        raise ValueError("silent")
    return raw
