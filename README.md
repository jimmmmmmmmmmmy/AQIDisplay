# OpenAir

A native macOS menu bar app for air quality, station history, and weather.

## Features

- Compact menu bar readings with a color-coded air quality indicator
- Location search and automatic refresh every five minutes
- A 24-hour chart with available historical station readings
- Visible pollutant readings and local weather

## Requirements

macOS Tahoe 26 or later. Building requires Swift 6.2 or later and the macOS 26 SDK.

## Build and run

```sh
python3 build_native.py
open dist-native/OpenAir.app
```

Add a [WAQI API key](https://aqicn.org/data-platform/token/) in Settings. Automatic Location finds a nearby station using your internet connection.

## Data

Readings come from [WAQI](https://aqicn.org/). Current readings must be from the station's local day and within three hours. Earlier observations are imported from the station's public chart when available. Missing hours remain empty.

Settings, the API key, and saved history stay in `~/Library/Application Support/OpenAir/`.

## Development

```sh
swift run OpenAirChecks
```

The suite covers data validation, observation freshness, station history, and backfill. Builds are locally signed and are not notarized.

The earlier Python implementation is retained. See [Python setup](PYTHON-REPAIR.md).
