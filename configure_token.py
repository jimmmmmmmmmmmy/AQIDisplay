"""Store a WAQI token locally without echoing it or adding it to shell history."""
from getpass import getpass
import os
from core import data_dir

if __name__ == '__main__':
    token = getpass('WAQI token (hidden): ').strip()
    if not token:
        raise SystemExit('No token entered; existing configuration preserved.')
    path = data_dir() / 'waqi-token'
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(token + '\n')
    print('Token saved. Choose Refresh now in OpenAir.')
