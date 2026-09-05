# Python implementation

The earlier Python app is retained for development. The primary macOS app uses Swift.

## Run

Python 3.11 is required.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python configure_token.py
.venv/bin/python app.py
```

Configuration and history use `~/Library/Application Support/OpenAir/`. Set `OPENAIR_DATA_DIR` to isolate development data.

## Test and build

```sh
.venv/bin/python -m unittest -v
.venv/bin/python -m PyInstaller OpenAir.spec
```

The generated app is written to `dist/OpenAir.app`.
