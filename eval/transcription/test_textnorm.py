import unittest
from textnorm import normalise, wer


class TextnormTest(unittest.TestCase):
    def test_fillers_punctuation_and_contractions_do_not_count(self):
        self.assertEqual(0, wer("Um, okay -- we'll merge it.", "okay we will merge it")["errors"])

    def test_curly_apostrophes_fold(self):
        self.assertEqual(normalise("we’ll"), normalise("we'll"))

    def test_the_merge_example_is_two_errors(self):
        r = wer("okay so we can merge this", "okay so we came urge this")
        self.assertEqual(2, r["errors"])
        self.assertAlmostEqual(2 / 6, r["wer"])

    def test_dropped_not_is_counted(self):
        self.assertEqual(1, wer("do not merge this", "do merge this")["errors"])

    def test_empty_reference(self):
        self.assertEqual(0.0, wer("", "")["wer"])
        self.assertEqual(1.0, wer("", "hello")["wer"])


if __name__ == "__main__":
    unittest.main()
