"""Network, configuration and history; no Cocoa imports or startup side effects."""
from pathlib import Path
from datetime import datetime, timedelta
from urllib.parse import quote
import fcntl
import json
import logging
import math
import os
import re
import sqlite3
import requests


def data_dir():
    path = Path(os.environ.get('OPENAIR_DATA_DIR', Path.home() / 'Library/Application Support/OpenAir'))
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def load_settings():
    try:
        value = json.loads((data_dir() / 'settings.json').read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def save_settings(settings):
    path = data_dir() / 'settings.json'
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(settings, indent=2))
    temporary.chmod(0o600)
    temporary.replace(path)


def load_token():
    if os.environ.get('WAQI_API_TOKEN'):
        return os.environ['WAQI_API_TOKEN'].strip()
    try:
        return (data_dir() / 'waqi-token').read_text().strip()
    except OSError:
        return ''


class Redact(logging.Filter):
    def filter(self, record):
        message = record.getMessage()
        token = load_token()
        if token:
            message = message.replace(token, '<redacted>')
        record.msg = re.sub(r'(?i)(token=)[^&\s]+', r'\1<redacted>', message)
        record.args = ()
        # Exception strings can contain request URLs; log safe error messages instead.
        record.exc_info = None
        record.exc_text = None
        return True


class SingleInstance:
    def __init__(self):
        self.handle = None

    def is_running(self):
        if self.handle is not None:
            return False
        handle = (data_dir() / 'openair.lock').open('a+')
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.close()
            return True
        self.handle = handle
        return False

    def cleanup(self):
        if self.handle:
            self.handle.close()
            self.handle = None


def number(value):
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (TypeError, ValueError):
        return None


class APIError(Exception):
    pass


class Client:
    def __init__(self, token=None):
        self.token = load_token() if token is None else token

    def request(self, path, **params):
        if not self.token:
            raise APIError('Set your WAQI token, then refresh')
        try:
            response = requests.get('https://api.waqi.info' + path,
                                    params={'token': self.token, **params}, timeout=(5, 15))
            response.raise_for_status()
            payload = response.json()
        except (requests.RequestException, ValueError):
            raise APIError('Connection failed — try Refresh now') from None
        if not isinstance(payload, dict) or payload.get('status') != 'ok':
            raise APIError('WAQI could not return data; check token or station')
        return payload.get('data')

    def feed(self, location):
        if ';' in location and not location.startswith('geo:'):
            location = 'geo:' + location
        data = self.request('/feed/' + quote(location, safe='@:;') + '/')
        if not isinstance(data, dict) or number(data.get('aqi')) is None or number(data['aqi']) < 0:
            raise APIError('Station has no current AQI reading')
        if not isinstance(data.get('city'), dict) or not data['city'].get('name'):
            raise APIError('Station response is incomplete')
        data['aqi'] = round(float(data['aqi']))
        raw = data.get('iaqi')
        data['iaqi'] = {key: {'v': n} for key, value in (raw.items() if isinstance(raw, dict) else [])
                        if isinstance(value, dict) and (n := number(value.get('v'))) is not None}
        return data

    def search(self, keyword):
        if not keyword.strip():
            return []
        data = self.request('/search/', keyword=keyword.strip())
        if not isinstance(data, list):
            raise APIError('Search response is incomplete')
        return [item for item in data if isinstance(item, dict)
                and isinstance(item.get('uid'), int)
                and isinstance(item.get('station'), dict) and item['station'].get('name')]


class History:
    def __init__(self, path):
        self.connection = sqlite3.connect(path)
        self.connection.execute('''CREATE TABLE IF NOT EXISTS aqi_data (
            timestamp TEXT PRIMARY KEY, city TEXT, aqi INTEGER, pm25 REAL, pm10 REAL,
            o3 REAL, no2 REAL, so2 REAL, co REAL, temperature REAL, pressure REAL,
            humidity REAL, wind REAL)''')
        self.connection.commit()

    def store(self, data, now=None):
        values = [number(data.get('iaqi', {}).get(key, {}).get('v'))
                  for key in ('pm25','pm10','o3','no2','so2','co','t','p','h','w')]
        timestamp = now or datetime.now()
        with self.connection:
            while self.connection.execute('SELECT 1 FROM aqi_data WHERE timestamp = ?', (timestamp.isoformat(),)).fetchone():
                timestamp += timedelta(microseconds=1)
            self.connection.execute('INSERT INTO aqi_data VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
                [timestamp.isoformat(), data['city']['name'], data['aqi'], *values])

    def recent(self, city):
        return self.connection.execute('''WITH readings AS (
            SELECT *, ROW_NUMBER() OVER (
              PARTITION BY strftime('%Y-%m-%d %H', timestamp) ORDER BY timestamp DESC) AS rn
            FROM aqi_data WHERE city = ? AND timestamp > ?)
            SELECT timestamp, city, aqi, pm25, pm10, o3, no2, so2, co,
                   temperature, pressure, humidity, wind
            FROM readings WHERE rn = 1 ORDER BY timestamp ASC''',
            (city, (datetime.now()-timedelta(hours=24)).isoformat())).fetchall()
