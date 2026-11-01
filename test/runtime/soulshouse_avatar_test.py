"""soulshouse-avatar's multipart body, offline: no server, no credentials."""

from email.parser import BytesParser
from email.policy import default
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest


def load_helper():
    loader = importlib.machinery.SourceFileLoader(
        "soulshouse_avatar", str(Path(__file__).resolve().parents[2] / "agent-runtime" / "soulshouse-avatar")
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


avatar = load_helper()
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00\r\n" * 10


def parts(body, content_type):
    message = BytesParser(policy=default).parsebytes(
        f"Content-Type: {content_type}\r\n\r\n".encode() + body
    )
    return list(message.iter_parts())


class MultipartTests(unittest.TestCase):
    def upload(self, name):
        directory = tempfile.mkdtemp()
        path = os.path.join(directory, name)
        with open(path, "wb") as handle:
            handle.write(PNG)
        return avatar.multipart(path)

    def test_ordinary_file_is_one_avatar_field_with_the_bytes_intact(self):
        body, content_type = self.upload("portrait.png")
        [part] = parts(body, content_type)
        self.assertEqual("avatar", part.get_param("name", header="content-disposition"))
        self.assertEqual("portrait.png", part.get_filename())
        self.assertEqual("image/png", part.get_content_type())
        self.assertEqual(PNG, part.get_payload(decode=True))

    def test_line_breaks_quotes_and_backslashes_in_a_name_cannot_break_the_header(self):
        body, content_type = self.upload('me\r\nX-Injected: 1 "x"\\.png')
        header_block = body.split(b"\r\n\r\n", 1)[0]
        self.assertEqual(2, header_block.count(b"\r\n"))  # boundary, disposition, type: three lines
        [part] = parts(body, content_type)
        self.assertEqual("avatar", part.get_param("name", header="content-disposition"))
        self.assertEqual("meX-Injected: 1 x.png", part.get_filename())
        self.assertEqual(PNG, part.get_payload(decode=True))

    def test_a_name_of_only_unsafe_characters_falls_back(self):
        self.assertEqual("avatar", avatar.header_filename("/tmp/\r\n\"\\"))


if __name__ == "__main__":
    unittest.main()
