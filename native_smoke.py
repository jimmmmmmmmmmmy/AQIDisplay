from datetime import datetime, timedelta
from unittest.mock import Mock
from AppKit import NSApplication
from Foundation import NSMakeRect
from aqi_visualization_view import AQIVisualizationView
from detail_window import DetailWindow
from search_city_window import SearchCityWindow
NSApplication.sharedApplication()
rows=[((datetime.now()-timedelta(hours=i)).isoformat(),'Test City',42,42,None,None,None,None,None,-10,1060,50,0) for i in reversed(range(24))]
app=Mock()
app.get_stored_data.return_value=rows
view=AQIVisualizationView.alloc().initWithFrame_andData_andTempUnit_(NSMakeRect(0,0,360,520), rows,'°F')
bitmap=view.bitmapImageRepForCachingDisplayInRect_(view.bounds())
view.cacheDisplayInRect_toBitmapImageRep_(view.bounds(),bitmap)
print('Chart drawing passed (missing pollutants, negative temperatures, high pressure)')
detail=DetailWindow.alloc().initWithApp_(app)
detail.showWindow_withText_andData_andTempUnit_('OpenAir smoke test','',{},'°F')
detail.closeWindow_(None)
print('Details window creation and close passed')
search=SearchCityWindow.alloc().initWithApp_(app)
search.showWindow()
search.window.close()
print('Search window creation and close passed')
