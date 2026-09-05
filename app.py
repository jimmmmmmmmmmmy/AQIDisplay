"""OpenAir macOS menu-bar application."""
import logging
from logging.handlers import RotatingFileHandler
from concurrent.futures import ThreadPoolExecutor
import time
import webbrowser
import subprocess
import rumps
from AppKit import NSApplication
from detail_window import DetailWindow
from search_city_window import SearchCityWindow
from core import Client, APIError, History, SingleInstance, data_dir, load_settings, save_settings, Redact


class AQIDisplay(rumps.App):
    def __init__(self):
        super().__init__("OpenAir", title="OpenAir · Loading")
        self.quit_button = "Quit OpenAir"
        settings = load_settings()
        self.current_city = settings.get('city', 'here')
        if not isinstance(self.current_city, str) or not self.current_city:
            self.current_city = 'here'
        self.current_city_name = self.current_city
        self.temperature_unit = settings.get('temperature_unit', '°F')
        if self.temperature_unit not in ('°F', '°C'):
            self.temperature_unit = '°F'
        self.format_options = {"City": False, "AQI": True, "PM2.5": False,
            "PM10": False, "O₃": False, "NO₂": False, "SO₂": False, "CO": False,
            "Temperature": True, "Humidity": False, "Wind": False}
        saved_format = settings.get('format_options', {})
        if isinstance(saved_format, dict):
            self.format_options.update({k: v for k, v in saved_format.items()
                if k in self.format_options and isinstance(v, bool)})
        self.client = Client()
        self.cached_data = None
        self.error = None
        self.last_update_time = 0
        self.update_interval = 300
        self.executor = ThreadPoolExecutor(max_workers=2)
        self.pending = None
        self.pending_city = None
        self.history = History(data_dir() / 'aqi_data.db')
        self.setup_menu()
        self.detail_window = DetailWindow.alloc().initWithApp_(self)
        self.search_window = None
        self.timer = rumps.Timer(self.update, 0.5)
        self.timer.start()
        self.update(None, force=True)

    def save_preferences(self):
        settings = load_settings()
        settings.update(city=self.current_city, temperature_unit=self.temperature_unit,
                        format_options=self.format_options)
        save_settings(settings)

    @rumps.clicked("Open settings folder")
    def open_settings(self, _):
        subprocess.run(['open', str(data_dir())], check=False)

    def open_source(self, _):
        webbrowser.open('https://aqicn.org/')

    @rumps.clicked("Refresh now")
    def refresh(self, _):
        self.update(None, force=True)

    def select_city(self, city, name):
        self.current_city = city
        self.current_city_name = name
        self.cached_data = None
        self.error = None
        self.update_title()
        self.last_update_time = 0
        self.save_preferences()
        self.update(None, force=True)

    def update(self, _, force=False):
        if self.search_window:
            self.search_window.poll_search()
        if self.pending and self.pending.done():
            future, city = self.pending, self.pending_city
            self.pending = None
            if city == self.current_city:
                try:
                    data = future.result()
                    self.cached_data = data
                    self.current_city_name = data['city']['name']
                    self.error = None
                    self.status_item.title = 'Fetched ' + time.strftime('%H:%M')
                    observed = data.get('time', {})
                    self.observed_item.title = 'Station time: ' + str(observed.get('s', 'unavailable') if isinstance(observed, dict) else 'unavailable')
                    self.history.store(data)
                    providers = ', '.join(x.get('name', '') for x in data.get('attributions', []) if isinstance(x, dict))
                    self.source_item.title = 'Data: WAQI' + (' / ' + providers if providers else '')
                except APIError as error:
                    self.error = str(error)
                    self.status_item.title = self.error
                except Exception:
                    self.error = 'Could not save or display reading'
                    self.status_item.title = self.error
                    logging.error('Reading processing failed')
                self.update_title()
        if not self.pending and (force or time.monotonic() - self.last_update_time >= self.update_interval):
            self.client = Client()
            self.pending_city = self.current_city
            self.pending = self.executor.submit(self.client.feed, self.current_city)
            self.last_update_time = time.monotonic()
            self.status_item.title = 'Refreshing…'

    def get_stored_data(self):
        return self.history.recent(self.current_city_name)

    def setup_menu(self):
        format_menu = rumps.MenuItem("Format Options")
        for option in self.format_options:
            if option == "Temperature":
                temp_menu = rumps.MenuItem(
                    "Temperature", callback=self.toggle_format_option
                )
                temp_menu.add(rumps.MenuItem("°F", callback=self.set_temperature_unit))
                temp_menu.add(rumps.MenuItem("°C", callback=self.set_temperature_unit))

                format_menu.add(temp_menu)
            else:
                item = rumps.MenuItem(option, callback=self.toggle_format_option)
                format_menu.add(item)

        format_menu.add(None)  # Separator
        format_menu.add(rumps.MenuItem("Reset", callback=self.reset_format_options))

        self.status_item = rumps.MenuItem("Starting…")
        self.observed_item = rumps.MenuItem("Station time: waiting for data")
        self.source_item = rumps.MenuItem("Data: WAQI / station providers", callback=self.open_source)
        self.menu = [self.status_item, self.observed_item, "Refresh now", "Search City", format_menu, "Details...",
                     "Open settings folder", self.source_item, None]
        self.update_format_menu()  # Call this to set initial states

    def toggle_format_option(self, sender):
        self.format_options[sender.title] = not sender.state
        self.update_format_menu()
        self.save_preferences()
        self.update_title()

    def reset_format_options(self, _):
        for option in self.format_options:
            self.format_options[option] = option in ["AQI", "Temperature", "Humidity"]
        self.temperature_unit = "°F"
        self.update_format_menu()
        self.save_preferences()
        self.update_title()

    def update_format_menu(self):
        format_menu = self.menu["Format Options"]
        for item in format_menu.values():
            if isinstance(item, rumps.MenuItem):
                if item.title in self.format_options:
                    item.state = self.format_options[item.title]
                    if item.title == "Temperature":
                        for subitem in item.values():
                            subitem.state = subitem.title == self.temperature_unit

    def parse_api_data(self, data):
        iaqi = data.get("iaqi", {})
        forecast = data.get("forecast", {}).get("daily", {})

        visualization_data = {
            "PM2.5": {
                "current": iaqi.get("pm25", {}).get("v", 0),
                "forecast": forecast.get("pm25", []),
            },
            "PM10": {
                "current": iaqi.get("pm10", {}).get("v", 0),
                "forecast": forecast.get("pm10", []),
            },
            "O3": {
                "current": iaqi.get("o3", {}).get("v", 0),
                "forecast": forecast.get("o3", []),
            },
            "NO2": {"current": iaqi.get("no2", {}).get("v", 0), "forecast": []},
            "SO2": {"current": iaqi.get("so2", {}).get("v", 0), "forecast": []},
            "CO": {"current": iaqi.get("co", {}).get("v", 0), "forecast": []},
            "Temp.": {"current": iaqi.get("t", {}).get("v", 0), "forecast": []},
            "Pressure": {"current": iaqi.get("p", {}).get("v", 0), "forecast": []},
            "Humidity": {"current": iaqi.get("h", {}).get("v", 0), "forecast": []},
            "Wind": {"current": iaqi.get("w", {}).get("v", 0), "forecast": []},
            "UVI": {
                "current": iaqi.get("uvi", {}).get("v", 0),
                "forecast": forecast.get("uvi", []),
            },
        }

        return {
            "aqi": data.get("aqi", 0),
            "iaqi": iaqi,
            "city": data.get("city", {}),
            "visualization_data": visualization_data,
            "raw_data": data,  # Include the full raw data for potential future use
        }

    def update_title(self):
        if not self.cached_data:
            self.title = "OpenAir · Setup" if not self.client.token else "OpenAir · Offline"
            return
        title_parts = []
        data = self.cached_data
        iaqi = data.get("iaqi", {})

        if self.format_options["City"]:
            title_parts.append(self.current_city_name)
        if self.format_options["AQI"]:
            title_parts.append(f"AQI: {data['aqi']}")
        if self.format_options["PM2.5"]:
            title_parts.append(f"PM2.5: {iaqi.get('pm25', {}).get('v', 'N/A')}")
        if self.format_options["PM10"]:
            title_parts.append(f"PM10: {iaqi.get('pm10', {}).get('v', 'N/A')}")
        if self.format_options["O\u2083"]:
            title_parts.append(f"O\u2083: {iaqi.get('o3', {}).get('v', 'N/A')}")
        if self.format_options["NO\u2082"]:
            title_parts.append(f"NO\u2082 {iaqi.get('no2', {}).get('v', 'N/A')}")
        if self.format_options["SO\u2082"]:
            title_parts.append(f"SO\u2082 {iaqi.get('so2', {}).get('v', 'N/A')}")
        if self.format_options["CO"]:
            title_parts.append(f"CO {iaqi.get('co', {}).get('v', 'N/A')}")
        if self.format_options["Temperature"]:
            temp_c = iaqi.get("t", {}).get("v", "N/A")
            if temp_c != "N/A":
                if self.temperature_unit == "°C":
                    temp_display = f"{temp_c}°C"
                else:
                    temp_f = (temp_c * 9 / 5) + 32
                    temp_display = f"{temp_f:.1f}°F"
            else:
                temp_display = "N/A"
            title_parts.append(temp_display)
        if self.format_options["Humidity"]:
            title_parts.append(f"RH: {iaqi.get('h', {}).get('v', 'N/A')}%")
        if self.format_options["Wind"]:
            title_parts.append(f"{iaqi.get('w', {}).get('v', 'N/A')}m/s")

        self.title = (" | ".join(title_parts) or "OpenAir") + (" · Stale" if self.error else "")

    @rumps.clicked("Search City")
    def search_city(self, _):
        if self.search_window is None or not self.search_window.window:
            # Check if window exists
            self.search_window = SearchCityWindow.alloc().initWithApp_(self)
        self.search_window.showWindow()

    @rumps.clicked("Format Options", "Temperature", "°C")
    @rumps.clicked("Format Options", "Temperature", "°F")
    def set_temperature_unit(self, sender):
        self.temperature_unit = sender.title
        self.update_format_menu()
        self.save_preferences()
        self.update_title()

    @rumps.clicked("Details...")
    def show_details(self, _):
        if self.cached_data:
            parsed_data = self.parse_api_data(self.cached_data)
            aqi = parsed_data["aqi"]
            iaqi = parsed_data["iaqi"]
            details = f"City: {self.current_city}\nAQI: {self.cached_data['aqi']}\n"
            details += f"AQI: {aqi}\n"
            details += f"PM2.5: {iaqi.get('pm25', {}).get('v', 'N/A')}\n"
            details += f"PM10: {iaqi.get('pm10', {}).get('v', 'N/A')}\n"
            details += f"O\u2083: {iaqi.get('o3', {}).get('v', 'N/A')}\n"
            details += f"NO\u2082: {iaqi.get('no2', {}).get('v', 'N/A')}\n"
            details += f"SO\u2082: {iaqi.get('so2', {}).get('v', 'N/A')}\n"
            details += f"CO: {iaqi.get('co', {}).get('v', 'N/A')}\n"
            details += f"Temperature: {iaqi.get('t', {}).get('v', 'N/A')}°C\n"
            details += f"Humidity: {iaqi.get('h', {}).get('v', 'N/A')}%\n"
            details += f"Wind: {iaqi.get('w', {}).get('v', 'N/A')} m/s"

            # Is it possible to pass temperature_unit to details?
            self.detail_window.showWindow_withText_andData_andTempUnit_(
                "AQI Details", details, self.cached_data, self.temperature_unit
            )
        else:
            rumps.notification("Error", "Failed to fetch AQI data", "")



def main():
    handler = RotatingFileHandler(data_dir() / 'openair.log', maxBytes=1_000_000, backupCount=2)
    handler.addFilter(Redact())
    logging.basicConfig(handlers=[handler], level=logging.INFO, force=True)
    instance = SingleInstance()
    if instance.is_running():
        return
    app = None
    try:
        NSApplication.sharedApplication().setActivationPolicy_(1)
        app = AQIDisplay()
        app.run()
    finally:
        if app:
            app.timer.stop()
            app.executor.shutdown(wait=False, cancel_futures=True)
            app.history.connection.close()
        instance.cleanup()


if __name__ == '__main__':
    main()
