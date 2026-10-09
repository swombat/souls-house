"""Text normalisation and word error rate, no dependencies.

WER is computed on normalised words: lowercase, punctuation stripped,
fillers removed, and a few contractions/spellings folded together, so that
"Um, okay -- we'll merge it." and "okay we will merge it" score as equal.
What's left is the error a reader would notice.
"""
import re
import unicodedata

FILLERS = {"um", "uh", "erm", "er", "uhm", "hmm", "mm", "ah", "eh"}

FOLDS = {
    "ok": "okay", "gonna": "going to", "wanna": "want to", "gotta": "got to",
    "won't": "will not", "can't": "cannot", "n't": " not", "i'm": "i am",
    "it's": "it is", "that's": "that is", "we'll": "we will", "i'll": "i will",
    "you're": "you are", "we're": "we are", "they're": "they are",
    "i've": "i have", "we've": "we have", "don't": "do not", "doesn't": "does not",
    "didn't": "did not", "isn't": "is not", "let's": "let us",
}


def normalise(text: str) -> list[str]:
    text = unicodedata.normalize("NFKC", text or "").lower()
    text = text.replace("’", "'").replace("‘", "'")
    words = []
    for raw in re.split(r"\s+", text):
        word = re.sub(r"[^\w']+", " ", raw).strip(" '")
        for piece in word.split():
            piece = FOLDS.get(piece, piece)
            words.extend(p for p in piece.split() if p not in FILLERS)
    return words


def align(ref: list[str], hyp: list[str]):
    """Levenshtein alignment. Returns (substitutions, deletions, insertions, ops)."""
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost = 0 if ref[i - 1] == hyp[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
    ops, i, j = [], n, m
    s = de = ins = 0
    while i > 0 or j > 0:
        if i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]):
            if ref[i - 1] != hyp[j - 1]:
                s += 1
                ops.append(("sub", ref[i - 1], hyp[j - 1]))
            i, j = i - 1, j - 1
        elif i > 0 and d[i][j] == d[i - 1][j] + 1:
            de += 1
            ops.append(("del", ref[i - 1], None))
            i -= 1
        else:
            ins += 1
            ops.append(("ins", None, hyp[j - 1]))
            j -= 1
    return s, de, ins, list(reversed(ops))


def wer(ref_text: str, hyp_text: str) -> dict:
    ref, hyp = normalise(ref_text), normalise(hyp_text)
    s, de, ins, ops = align(ref, hyp)
    errors = s + de + ins
    return {
        "ref_words": len(ref),
        "errors": errors,
        "wer": errors / len(ref) if ref else (0.0 if not hyp else 1.0),
        "ops": ops,
    }
