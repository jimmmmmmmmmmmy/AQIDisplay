import unittest
import mock
from datetime import datetime, timedelta
import tempfile
import os
import sqlite3
from app import AQIDisplay
from aqi_visualization_view import AQIVisualizationView
from detail_window import DetailWindow
from search_city_window import SearchCityWindow
from Foundation import NSMakeRect, NSColor  # For mocking NSRect and NSColor

class TestAQIDisplay(unittest.TestCase):
    def setUp(self):
        self.app = AQIDisplay()
        self.app.db_connection = sqlite3.connect(':memory:')
        self.app.create_table()

    def tearDown(self):
        if hasattr(self, 'app') and self.app.db_connection:
            self.app.db_connection.close()

    def test_parse_api_data(self):
        """Test parsing of API data"""
        test_data = {
            'aqi': 50,
            'iaqi': {
                'pm25': {'v': 20},
                'pm10': {'v': 30},
                't': {'v': 25},
                'h': {'v': 60}
            },
            'city': {'name': 'Test City'},
            'forecast': {'daily': {}}
        }
        result = self.app.parse_api_data(test_data)
        self.assertEqual(result['aqi'], 50)
        self.assertEqual(result['visualization_data']['PM2.5']['current'], 20)
        self.assertEqual(result['visualization_data']['PM10']['current'], 30)
        self.assertEqual(result['visualization_data']['Temp.']['current'], 25)
        self.assertEqual(result['visualization_data']['Humidity']['current'], 60)

    def test_title_formatting(self):
        """Test menu bar title formatting"""
        test_data = {
            'aqi': 50,
            'iaqi': {
                'pm25': {'v': 20},
                't': {'v': 25},
                'h': {'v': 60}
            }
        }
        self.app.cached_data = test_data
        self.app.current_city_name = "Test City"
        
        # Test with only AQI shown
        self.app.format_options = {key: False for key in self.app.format_options}
        self.app.format_options['AQI'] = True
        self.app.update_title()
        self.assertEqual(self.app.title, "AQI: 50")

        # Test with AQI and temperature (°F)
        self.app.format_options['Temperature'] = True
        self.app.temperature_unit = "°F"
        self.app.update_title()
        self.assertEqual(self.app.title, "AQI: 50 | 77.0°F")

        # Test with AQI and temperature (°C)
        self.app.temperature_unit = "°C"
        self.app.update_title()
        self.assertEqual(self.app.title, "AQI: 50 | 25°C")

    @mock.patch('requests.get')
    def test_get_aqi_data(self, mock_get):
        """Test fetching AQI data"""
        mock_response = mock.Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            'status': 'ok',
            'data': {
                'aqi': 50,
                'city': {'name': 'Greatest City'},
                'iaqi': {
                    'pm25': {'v': 20},
                    't': {'v': 25},
                    'h': {'v': 60}
                }
            }
        }
        mock_get.return_value = mock_response
        result = self.app.get_aqi_data("37.7749;-122.4194")
        self.assertIsNotNone(result)
        self.assertEqual(result['aqi'], 50)
        self.assertEqual(result['city']['name'], 'Greatest City')

    def test_store_aqi_data(self):
        """Test storing AQI data in the database"""
        test_data = {
            'aqi': 75,
            'city': {'name': 'Stored City'},
            'iaqi': {
                'pm25': {'v': 25},
                't': {'v': 20},
                'h': {'v': 50}
            }
        }
        self.app.store_aqi_data(test_data)
        cursor = self.app.db_connection.cursor()
        cursor.execute("SELECT aqi, city, pm25, temperature, humidity FROM aqi_data")
        result = cursor.fetchone()
        self.assertEqual(result, (75, 'Stored City', 25.0, 20.0, 50.0))


class TestAQIVisualizationView(unittest.TestCase):
    def setUp(self):
        # Mock frame and sample data for the last 24 hours
        self.frame = NSMakeRect(0, 0, 400, 600)
        sample_data = [
            (
                (datetime.now() - timedelta(hours=i)).isoformat(),  # timestamp
                'Test City',  # city
                50 + i,      # aqi
                20.0 + i,    # pm25
                30.0,        # pm10
                10.0,        # o3
                5.0,         # no2
                2.0,         # so2
                1.0,         # co
                25.0,        # temperature
                1013.0,      # pressure
                60.0,        # humidity
                5.0          # wind
            )
            for i in range(24)
        ]
        self.view = AQIVisualizationView.alloc().initWithFrame_andData_andTempUnit_(self.frame, sample_data, "°F")
        self.view.setup()

    def test_get_aqi_info(self):
        """Test AQI level and color determination"""
        color, text = self.view.get_aqi_info(50)
        self.assertEqual(text, "Healthy")
        self.assertEqual(color, NSColor.systemGreenColor())

        color, text = self.view.get_aqi_info(150)
        self.assertEqual(text, "Unhealthy for Sensitive Groups")
        self.assertEqual(color, NSColor.orangeColor())

    def test_get_pressure_color(self):
        """Test pressure color interpolation"""
        min_pressure = self.view.pressure_range['min']
        max_pressure = self.view.pressure_range['max']
        normal_pressure = (min_pressure + max_pressure) / 2
        color = self.view.get_pressure_color(normal_pressure)
        # Since it's an interpolation, we check it's not None and assume it's between systemBlue and blue
        self.assertIsNotNone(color)

    def test_get_color_for_metric(self):
        """Test color assignment for different metrics"""
        self.assertEqual(self.view.get_color_for_metric('pm25', 25), NSColor.systemGreenColor())
        self.assertEqual(self.view.get_color_for_metric('temperature', 25), NSColor.orangeColor())
        self.assertEqual(self.view.get_color_for_metric('o3', 40), self.view.interpolate_colors(NSColor.systemGreenColor(), NSColor.yellowColor(), 0.8))

class TestSearchCityWindow(unittest.TestCase):
    def setUp(self):
        self.app = mock.Mock()
        self.app.base_url = "https://api.waqi.info"
        self.app.token = "test_token"
        self.window = SearchCityWindow.alloc().initWithApp_(self.app)
        self.window.location_input = mock.Mock()
        self.window.result_table = mock.Mock()
        self.window.window = mock.Mock()
        self.window.results = []

    @mock.patch('requests.get')
    def test_performSearch_(self, mock_get):
        """Test performing a city search"""
        self.window.location_input.stringValue.return_value = "San Francisco"
        mock_response = mock.Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = {
            'status': 'ok',
            'data': [
                {'station': {'name': 'San Francisco'}, 'aqi': '45', 'time': {'stime': '2023-10-10 12:00'}, 'uid': 123}
            ]
        }
        mock_get.return_value = mock_response
        self.window.performSearch_(None)
        mock_get.assert_called_with("https://api.waqi.info/search/?token=test_token&keyword=San Francisco")
        self.assertEqual(len(self.window.results), 1)
        self.assertEqual(self.window.results[0]['station']['name'], 'San Francisco')
        self.window.result_table.reloadData.assert_called_once()

    def test_tableViewSelectionDidChange_(self):
        """Test selecting a city from the table"""
        self.window.results = [{'station': {'name': 'San Francisco'}, 'aqi': '45', 'uid': 123}]
        self.window.result_table.selectedRow.return_value = 0
        self.window.tableViewSelectionDidChange_(None)
        self.assertEqual(self.app.current_city, "@123")
        self.assertEqual(self.app.current_city_name, "San Francisco")
        self.app.update.assert_called_with(None, force=True)
        self.window.window.close.assert_called_once()


if __name__ == '__main__':
    unittest.main()