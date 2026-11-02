"""10/26 exact-text edits that keep a file's line endings (CRLF or LF) and encoding.

Usage from Python:  from edit_keep_eol import Editor
    e = Editor(path); e.rep(old, new[, count]); e.save()
Every `old` must occur exactly `count` times (default 1), otherwise nothing is written.
"""
from pathlib import Path


class Editor:
    def __init__(self, path):
        self.path = Path(path)
        raw = self.path.read_bytes()
        self.bom = raw.startswith(b'\xef\xbb\xbf')
        text = raw.decode('utf-8-sig')
        self.crlf = '\r\n' in text
        self.text = text.replace('\r\n', '\n')

    def rep(self, old, new, count=1):
        n = self.text.count(old)
        assert n == count, f'{self.path.name}: expected {count} match(es), found {n}:\n{old[:200]}'
        self.text = self.text.replace(old, new)

    def save(self):
        t = self.text.replace('\n', '\r\n') if self.crlf else self.text
        self.path.write_bytes((b'\xef\xbb\xbf' if self.bom else b'') + t.encode('utf-8'))
