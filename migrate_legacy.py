"""Explicit, non-destructive import. Never prints a token or overwrites current data."""
import argparse
import ast
from pathlib import Path
import sqlite3
from core import data_dir


def migrate(source):
    destination = data_dir()
    token_path = destination / 'waqi-token'
    if not token_path.exists():
        tree = ast.parse((source / 'app.py').read_text())
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
                if any(isinstance(t, ast.Attribute) and t.attr == 'token' for t in node.targets):
                    with token_path.open('x') as stream:
                        token_path.chmod(0o600)
                        stream.write(node.value.value + '\n')
                    break
    old_db, new_db = source / 'aqi_data.db', destination / 'aqi_data.db'
    if old_db.exists() and not new_db.exists():
        with sqlite3.connect(old_db.as_uri() + '?mode=ro', uri=True) as old:
            with sqlite3.connect(new_db) as new:
                old.backup(new)
        new_db.chmod(0o600)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    migrate(parser.parse_args().source.resolve())
    print('Legacy import finished; existing destination files and all source files preserved.')
