# AQIDisplay

A native macOS menu bar application for real-time air quality monitoring, developed as part of my coursework.

[Download Pre-built App (MacOS arm64](https://website-ripl.onrender.com/downloads/AQIDisplay.zip)

![Screenshot 2024-10-24 at 7 57 52 PM](https://github.com/user-attachments/assets/1480b648-f9c1-4c6b-8dbf-dcbb362f96cf)



## Project Overview

AQIDisplay is an AQI API wrapper for macOS using PyObjc.

## Core Components

### Menu Bar Application (`app.py`)
- Main application entry point
- Manages menu bar interface and updates
- Handles API communication with WAQI
- Implements SQLite database operations for historical data

### Data Visualization (`aqi_visualization_view.py`)
- Custom visualization system for air quality metrics
- 24-hour historical data charts
- Dynamic color coding based on AQI levels
- Temperature unit conversion support

### Detail Window (`detail_window.py`)
- Comprehensive view of air quality metrics
- Historical data visualization
- System preferences management

### Search Window (`search_city_window.py`)
- Location search functionality
- Table view for search results
- City selection and data updates

### System Integration (`login_item_manager.py`)
- macOS login item management
- System preferences integration
- Launch-at-login functionality

## Dependencies

The project uses several key libraries and frameworks:
- PyObjC for macOS integration
- rumps for menu bar functionality
- requests for API communication
- SQLite3 for data storage

## Stuff that's still broken

- [ ] Fix 'Search City'
- [ ] Implement 'About'
- [ ] Implement Start at Login
