import objc
from AppKit import (NSView, NSColor, NSBezierPath, NSFont, NSFontAttributeName,
                    NSForegroundColorAttributeName, NSString, NSMakePoint, NSMakeRect,
                    NSTextAlignmentCenter, NSParagraphStyleAttributeName, NSLineBreakByWordWrapping)

from Foundation import NSMutableParagraphStyle
from datetime import datetime

class AQIVisualizationView(NSView):
    @objc.python_method
    def initWithFrame_andData_andTempUnit_(self, frame, data, temperature_unit):
        self = objc.super(AQIVisualizationView, self).initWithFrame_(frame)
        if self:
            self.data = list(reversed(data[-24:]))  # Last 24 hours, most recent last
            self.temperature_unit = temperature_unit
            self.setup()
        return self

    @objc.python_method
    def setup(self):
        self.textColor = NSColor.labelColor()
        self.headerHeight = 150  # Space for header

        self.pollutant_levels = {
            'pm25': [
                (0, 50, NSColor.systemGreenColor()),
                (51, 100, NSColor.yellowColor()),
                (101, 150, NSColor.orangeColor()),
                (151, 200, NSColor.redColor()),
                (201, 300, NSColor.purpleColor()),
                (301, 500, NSColor.darkGrayColor())
            ],
            'pm10': [
                (0, 50, NSColor.systemGreenColor()),
                (51, 100, NSColor.yellowColor()),
                (101, 150, NSColor.orangeColor()),
                (151, 200, NSColor.redColor()),
                (201, 300, NSColor.purpleColor()),
                (301, 500, NSColor.darkGrayColor())
            ],
            # For gases that typically stay under 50, we'll use a gradient approach
            'o3': [(0, 50, None)],  # Will use interpolation
            'no2': [(0, 50, None)],  # Will use interpolation
            'so2': [(0, 50, None)],  # Will use interpolation
            'co': [(0, 50, None)],   # Will use interpolation
        }
        self.pressure_range = {
            'min': 965.1,  # Yellow
            'max': 1040.0  # Orange
        }
        # Static colors for non-pollutant metrics
        self.static_colors = {
            'temperature': NSColor.orangeColor(),
            'humidity': NSColor.magentaColor(),
            'wind': NSColor.lightGrayColor()
        }

        self.metric_labels = {
            'pm25': 'PM2.5', 'pm10': 'PM10', 'o3': 'O3', 'no2': 'NO2', 'so2': 'SO2',
            'co': 'CO', 'temperature': 'Temp.', 'pressure': 'Pressure',
            'humidity': 'Humidity', 'wind': 'Wind'
        }


        self.metrics = ['pm25', 'pm10', 'o3', 'no2', 'so2', 'co', 'temperature', 'pressure', 'humidity', 'wind']
        self.chartPadding = 5
        self.labelWidth = 55
        self.currentValueWidth = 35
        self.minMaxWidth = 55
        self.aqi_levels = [
            (0, 50, "Good", NSColor.systemGreenColor()),
            (51, 100, "Moderate", NSColor.yellowColor()),
            (101, 150, "Unhealthy for Sensitive Groups", NSColor.orangeColor()),
            (151, 200, "Unhealthy", NSColor.redColor()),
            (201, 300, "Very Unhealthy", NSColor.purpleColor()),
            (301, 500, "Hazardous", NSColor.darkGrayColor())
        ]

    def drawRect_(self, dirtyRect):
        NSColor.windowBackgroundColor().setFill()
        NSBezierPath.fillRect_(dirtyRect)

        # Draw main sections
        self.drawHeader()
        self.drawCharts()

    @objc.python_method
    def get_aqi_info(self, aqi):
        if aqi > 500:
            return NSColor.darkGrayColor(), "Hazardous"
        for low, high, text, color in self.aqi_levels:
            if low <= aqi <= high:
                return color, text
        return NSColor.labelColor(), "Unknown"

    @objc.python_method
    def drawHeader(self):
        if not self.data:
            return

        headerRect = NSMakeRect(0, self.bounds().size.height - self.headerHeight,
                            self.bounds().size.width, self.headerHeight)

        # Get latest data point
        latest_data = self.data[0]
        city_name = latest_data[1]  # City is index 1 in the tuple
        aqi_value = latest_data[2]  # AQI is index 2 in the tuple
        timestamp = latest_data[0]  # Timestamp is index 0

        # Parse and format the timestamp
        dt = datetime.fromisoformat(timestamp)
        formatted_time = dt.strftime("%A %I:%M%p").replace("AM", "am").replace("PM", "pm")
        # Remove leading zero from hour if present
        formatted_time = formatted_time.lstrip("0")

        # Draw city name - increased vertical space and moved up
        cityAttrs = {
            NSFontAttributeName: NSFont.boldSystemFontOfSize_(16),
            NSForegroundColorAttributeName: NSColor.labelColor(),
        }
        # Increased height from 30 to 50 for two lines, and adjusted y position
        cityRect = NSMakeRect(10, headerRect.origin.y + 65,
                            headerRect.size.width - 20, 50)

        # Create paragraph style for city name to handle wrapping
        cityParagraph = NSMutableParagraphStyle.alloc().init()
        cityParagraph.setLineBreakMode_(NSLineBreakByWordWrapping)
        cityAttrs[NSParagraphStyleAttributeName] = cityParagraph

        NSString.stringWithString_(city_name).drawInRect_withAttributes_(cityRect, cityAttrs)

        # Draw AQI box and text
        aqi_color, aqi_text = self.get_aqi_info(aqi_value)

        # Rounded corners for my friends
        aqiBoxRect = NSMakeRect(10, headerRect.origin.y + 15, 80, 60)
        roundedPath = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(aqiBoxRect, 10.0, 10.0)
        aqi_color.setFill()
        roundedPath.fill()

        # if you change this you HAVE to change aqiTextRect
        aqiAttrs = {
            NSFontAttributeName: NSFont.boldSystemFontOfSize_(32),
            NSForegroundColorAttributeName: NSColor.whiteColor(),
        }
        paragraph = NSMutableParagraphStyle.alloc().init()
        paragraph.setAlignment_(NSTextAlignmentCenter)
        aqiAttrs[NSParagraphStyleAttributeName] = paragraph

        # origin.y + 10 and width,40 is as close as it gets to center do not FUCK this
        aqiTextRect = NSMakeRect(aqiBoxRect.origin.x,
                                 aqiBoxRect.origin.y + 10,
                                aqiBoxRect.size.width, 40)

        NSString.stringWithString_(str(aqi_value)).drawInRect_withAttributes_(
            aqiTextRect, aqiAttrs)

        # Higher makes text go higher "AQI QUALITIATIVE READING"
        qualTextRect = NSMakeRect(100, headerRect.origin.y + 45,
                                headerRect.size.width - 110, 30)
        qualAttrs = {
            NSFontAttributeName: NSFont.boldSystemFontOfSize_(20),
            NSForegroundColorAttributeName: aqi_color,
        }
        NSString.stringWithString_(aqi_text).drawInRect_withAttributes_(
            qualTextRect, qualAttrs)

        # Last updated time - adjusted position
        timestamp = latest_data[0]  # Timestamp is index 0
        updateAttrs = {
            NSFontAttributeName: NSFont.systemFontOfSize_(12),
            NSForegroundColorAttributeName: NSColor.grayColor(),
        }
        ## +15 is the rectangle height so YLOCish, +35 is the size of the rectangle
        updateRect = NSMakeRect(100, headerRect.origin.y + 15,
                            headerRect.size.width - 110, 35)
        NSString.stringWithString_(f"Updated: {formatted_time}").drawInRect_withAttributes_(
        updateRect, updateAttrs)

    def interpolate_colors(self, color1, color2, progress):
        """Helper method to interpolate between two NSColors"""
        # Convert colors to RGB color space
        color1_rgb = color1.colorUsingColorSpaceName_("NSCalibratedRGBColorSpace")
        color2_rgb = color2.colorUsingColorSpaceName_("NSCalibratedRGBColorSpace")

        # Interpolate between colors
        r = color1_rgb.redComponent() + (color2_rgb.redComponent() - color1_rgb.redComponent()) * progress
        g = color1_rgb.greenComponent() + (color2_rgb.greenComponent() - color1_rgb.greenComponent()) * progress
        b = color1_rgb.blueComponent() + (color2_rgb.blueComponent() - color1_rgb.blueComponent()) * progress

        return NSColor.colorWithRed_green_blue_alpha_(r, g, b, 1.0)

    @objc.python_method
    def get_pressure_color(self, value):
        """Get color for pressure value based on the defined range"""
        min_pressure = self.pressure_range['min']
        max_pressure = self.pressure_range['max']

        # Clamp value to our range
        value = max(min_pressure, min(max_pressure, value))

        # Calculate progress through the range
        progress = (value - min_pressure) / (max_pressure - min_pressure)

        # Interpolate between yellow and orange
        return self.interpolate_colors(NSColor.systemBlueColor(), NSColor.blueColor(), progress)

    @objc.python_method
    def get_color_for_metric(self, metric, value):
        # Special handling for pressure
        if metric == 'pressure':
            return self.get_pressure_color(value)

        if metric in self.static_colors:
            return self.static_colors[metric]

        if metric in self.pollutant_levels:
            if metric in ['o3', 'no2', 'so2', 'co']:
                # For gases that typically stay under 50, interpolate between green and yellow
                if value > 50:
                    return NSColor.yellowColor()
                # Interpolate between green and yellow based on the value
                progress = value / 50.0
                return self.interpolate_colors(NSColor.systemGreenColor(), NSColor.yellowColor(), progress)
            else:
                # For PM2.5 and PM10, use their defined levels
                levels = self.pollutant_levels[metric]
                for low, high, color in levels:
                    if low <= value <= high:
                        return color
                return NSColor.darkGrayColor()  # Default color if out of all ranges

        return NSColor.grayColor()  # Default color for unknown metrics

    @objc.python_method
    def convert_temperature(self, celsius_value):
        """Convert temperature based on unit preference"""
        if self.temperature_unit == "°F":
            return (celsius_value * 9/5) + 32
        return celsius_value

    @objc.python_method
    def format_temperature(self, value):
        """Format temperature with appropriate unit"""
        converted_value = self.convert_temperature(value)
        return f"{converted_value:.0f}{self.temperature_unit}"


    @objc.python_method
    def drawCharts(self):
        if not self.data:
            self.drawNoDataAvailable()
            return

        # Adjust available height to account for header
        availableHeight = self.bounds().size.height - self.headerHeight
        chart_height = (availableHeight / len(self.metrics)) - self.chartPadding

        for i, metric in enumerate(reversed(self.metrics)):
            y_position = i * (chart_height + self.chartPadding)
            self.drawChart(metric, NSMakeRect(0, y_position, self.bounds().size.width, chart_height))

    @objc.python_method
    def get_pollutant_range(self, current_value):
        """Determine the appropriate range based on current value for pollutants"""
        if current_value <= 50:
            return 0, 50
        elif current_value <= 100:
            return 0, 100
        elif current_value <= 150:
            return 0, 150
        elif current_value <= 200:
            return 0, 200
        elif current_value <= 300:
            return 0, 300
        else:
            return 0, 500

    @objc.python_method
    def is_pollutant(self, metric):
        """Check if the metric is a pollutant"""
        return metric in ['pm25', 'pm10', 'o3', 'no2', 'so2', 'co']


    @objc.python_method
    def drawChart(self, metric, rect):
        def adjust_histogram_bounds(min_value, max_value, metric, current_value=None):
            if metric == 'pressure':
                # Use the actual min/max within our fixed bounds
                return (min(min_value, self.pressure_range['min']),
                       max(max_value, self.pressure_range['max']))
            elif metric == 'temperature':
                # No need to convert here since values are already converted
                padding = max((max_value - min_value) * 0.15, 1)
                adjusted_min = min_value - padding
                adjusted_max = max_value + padding
                return adjusted_min, adjusted_max
            elif self.is_pollutant(metric) and current_value is not None:
                return self.get_pollutant_range(current_value)
            else:
                padding = max((max_value - min_value) * 0.15, 1)
                adjusted_min = min_value - padding
                adjusted_max = max_value + padding
                return adjusted_min, adjusted_max

        data_index_map = {
            'timestamp': 0, 'city': 1, 'aqi': 2, 'pm25': 3, 'pm10': 4,
            'o3': 5, 'no2': 6, 'so2': 7, 'co': 8, 'temperature': 9,
            'pressure': 10, 'humidity': 11, 'wind': 12
        }
        metric_index = data_index_map[metric]

        metric_data = [row[metric_index] if row[metric_index] is not None else None for row in self.data]

        if metric == 'temperature':
            valid_data = [self.convert_temperature(float(value)) for value in metric_data if value is not None]
            # Store converted values for plotting
            converted_metric_data = [self.convert_temperature(float(value)) if value is not None else None for value in metric_data]
        else:
            valid_data = [float(value) for value in metric_data if value is not None]
            converted_metric_data = metric_data

        # Draw metric name
        label_attrs = {
            NSFontAttributeName: NSFont.boldSystemFontOfSize_(10),
            NSForegroundColorAttributeName: self.textColor
        }

        # Add temperature unit to the label if it's temperature
        label_text = self.metric_labels[metric]
        if metric == 'temperature':
            label_text = f"{label_text} ({self.temperature_unit})"


        NSString.stringWithString_(self.metric_labels[metric]).drawAtPoint_withAttributes_(
            NSMakePoint(5, rect.origin.y + rect.size.height - 25), label_attrs)

        # Draw current reading
        current_value = metric_data[0] if metric_data and metric_data[0] is not None else '-'
        if current_value != '-':
            if metric == 'pressure':
                current_value = f"{float(current_value):.0f}"
            elif metric == 'temperature':
                current_value = self.format_temperature(float(current_value))
            elif metric == 'humidity':
                current_value = f"{float(current_value):.0f}%"
            elif metric == 'wind':
                current_value = f"{float(current_value):.0f} m/s"
            else:
                current_value = f"{str(round(float(current_value)))}"
        NSString.stringWithString_(current_value).drawAtPoint_withAttributes_(
            NSMakePoint(self.labelWidth, rect.origin.y + rect.size.height - 25), label_attrs)

        # Draw histogram
        if valid_data:
            # Calculate min/max from valid_data (which is already converted for temperature)
            if metric == 'pressure':
                # For pressure, find actual min/max within our bounds
                min_value = max(self.pressure_range['min'], min(valid_data))
                max_value = min(self.pressure_range['max'], max(valid_data))
            else:
                max_value = max(valid_data)
                min_value = min(valid_data)

            # Get current value for range calculation
            current_val = float(metric_data[0]) if metric_data[0] is not None else None
            if metric == 'temperature' and current_val is not None:
                current_val = self.convert_temperature(current_val)

            adjusted_min, adjusted_max = adjust_histogram_bounds(min_value, max_value, metric, current_val)
            value_range = adjusted_max - adjusted_min

            histogram_rect = NSMakeRect(
                self.labelWidth + self.currentValueWidth,
                rect.origin.y,
                self.bounds().size.width - self.labelWidth - self.currentValueWidth - self.minMaxWidth,
                rect.size.height
            )
            bar_width = histogram_rect.size.width / len(self.data)

            for i, value in enumerate(reversed(converted_metric_data)):
                if value is not None:
                    value = float(value)

                    if value_range == 0:
                        height = histogram_rect.size.height * 0.5
                    else:
                        if self.is_pollutant(metric) or metric == 'pressure':
                            value = max(adjusted_min, min(value, adjusted_max))
                        normalized_value = (value - adjusted_min) / value_range
                        height = normalized_value * histogram_rect.size.height

                    x_position = histogram_rect.origin.x + i * bar_width
                    bar_rect = NSMakeRect(x_position, rect.origin.y, bar_width - 1, height)

                    color = self.get_color_for_metric(metric, value)
                    color.setFill()
                    NSBezierPath.fillRect_(bar_rect)

            # Draw min and max values
            value_attrs = {
                NSFontAttributeName: NSFont.systemFontOfSize_(10),
                NSForegroundColorAttributeName: self.textColor
            }
            min_x = self.bounds().size.width - self.minMaxWidth + 5
            max_x = self.bounds().size.width - self.minMaxWidth / 2 + 5

            if metric == 'pressure':
                # Use fixed values for pressure with one decimal place
                min_text = f"{adjusted_min:.0f}"
                max_text = f"{adjusted_max:.0f}"

            else:
                # For other metrics, use actual min/max with rounding
                min_text = f"{min_value:.0f}"
                max_text = f"{max_value:.0f}"

            NSString.stringWithString_(min_text).drawAtPoint_withAttributes_(
                NSMakePoint(min_x, rect.origin.y + rect.size.height - 25), value_attrs)
            NSString.stringWithString_(max_text).drawAtPoint_withAttributes_(
                NSMakePoint(max_x, rect.origin.y + rect.size.height - 25), value_attrs)
        else:
            no_data_attrs = {
                NSFontAttributeName: NSFont.systemFontOfSize_(10),
                NSForegroundColorAttributeName: NSColor.grayColor()
            }
            NSString.stringWithString_("No Data").drawAtPoint_withAttributes_(
                NSMakePoint(self.labelWidth + self.currentValueWidth, rect.origin.y + rect.size.height / 2), no_data_attrs)

    @objc.python_method
    def drawNoDataAvailable(self):
        attrs = {
            NSFontAttributeName: NSFont.systemFontOfSize_(14),
            NSForegroundColorAttributeName: self.textColor
        }
        message = "No data available"
        NSString.stringWithString_(message).drawAtPoint_withAttributes_(
            NSMakePoint(self.bounds().size.width / 2 - 50, self.bounds().size.height / 2), attrs)
