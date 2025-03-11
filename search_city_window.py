import objc
from Foundation import NSObject, NSMakeRect
from AppKit import (
    NSWindow, NSWindowStyleMaskTitled, NSWindowStyleMaskClosable, NSWindowStyleMaskMiniaturizable,
    NSWindowStyleMaskResizable, NSBackingStoreBuffered, NSScreen, NSTextField, NSFont,
    NSApplication, NSButton, NSScrollView, NSTableView, NSTableColumn,
    NSBezelBorder, NSTextFieldCell
)
import requests

class SearchCityWindow(NSObject):
    window = objc.ivar()
    location_input = objc.ivar()
    search_button = objc.ivar()
    result_table = objc.ivar()
    app = objc.ivar()
    results = objc.ivar()

    def initWithApp_(self, app):
        self = objc.super(SearchCityWindow, self).init()
        if self is None:
            return None
        self.window = None
        self.app = app
        self.results = []  # Initialize as an empty list
        return self

    def showWindow(self):
        if self.window is None:
            screen = NSScreen.mainScreen()
            screenRect = screen.frame()
            windowWidth = 600
            windowHeight = 300
            windowRect = NSMakeRect((screenRect.size.width - windowWidth) / 2,
                                    (screenRect.size.height - windowHeight) / 2,
                                    windowWidth, windowHeight)
            styleMask = (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                         NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
            self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
                windowRect, styleMask, NSBackingStoreBuffered, False)
            self.window.setTitle_("Search City")
            self.window.setReleasedWhenClosed_(False)
            self.setupUI()
            self.window.setDelegate_(self)

        self.window.makeKeyAndOrderFront_(None)
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)


    def setupUI(self):
        contentView = self.window.contentView()

        # Location input
        self.location_input = NSTextField.alloc().initWithFrame_(NSMakeRect(20, 260, 260, 24))
        self.location_input.setPlaceholderString_("Enter location")
        contentView.addSubview_(self.location_input)

        # Search button
        self.search_button = NSButton.alloc().initWithFrame_(NSMakeRect(290, 260, 90, 24))
        self.search_button.setTitle_("Search")
        self.search_button.setTarget_(self)
        self.search_button.setAction_(objc.selector(self.performSearch_, signature=b'v@:'))
        contentView.addSubview_(self.search_button)

        # Results table
        scrollView = NSScrollView.alloc().initWithFrame_(NSMakeRect(20, 20, 560, 220))
        scrollView.setBorderType_(NSBezelBorder)
        scrollView.setHasVerticalScroller_(True)
        scrollView.setHasHorizontalScroller_(True)
        scrollView.setAutohidesScrollers_(True)


        self.result_table = NSTableView.alloc().initWithFrame_(scrollView.bounds())
        self.result_table.setDataSource_(self)
        self.result_table.setDelegate_(self)
        columns = [
            ("City", 280),
            ("AQI", 60),
            ("Time", 200)
        ]
        for title, width in columns:
            column = NSTableColumn.alloc().initWithIdentifier_(title)
            column.setWidth_(width)
            column.headerCell().setStringValue_(title)
            self.result_table.addTableColumn_(column)

        scrollView.setDocumentView_(self.result_table)
        self.window.contentView().addSubview_(scrollView)

    def performSearch_(self, sender):
        location = self.location_input.stringValue()
        url = f"{self.app.base_url}/search/?token={self.app.token}&keyword={location}"
        response = requests.get(url)
        if response.status_code == 200:
            data = response.json()
            if data['status'] == 'ok':
                self.results = data['data']
                self.result_table.reloadData()
            else:
                print(f"Error: {data['data']}")
                self.results = []  # Clear results on error
        else:
            print(f"Error: Unable to fetch data. Status code: {response.status_code}")
            self.results = []  # Clear results on error
        self.result_table.reloadData()

    def numberOfRowsInTableView_(self, tableView):
        return len(self.results) if self.results else 0

    def tableView_objectValueForTableColumn_row_(self, tableView, column, row):
        if not self.results or row < 0 or row >= len(self.results):
            return None
        result = self.results[row]
        column_id = column.identifier()
        if column_id == "City":
            return result['station']['name']
        elif column_id == "AQI":
            return str(result['aqi'])
        elif column_id == "Time":
            return str(result['time']['stime'])


    def tableViewSelectionDidChange_(self, notification):
        selected_row = self.result_table.selectedRow()
        if selected_row >= 0 and selected_row < len(self.results):
            result = self.results[selected_row]
            if 'uid' in result:
                self.app.current_city = f"@{result['uid']}"
                self.app.current_city_name = result['station']['name']
                self.app.update(None, force=True)
                if self.app.cached_data:  # Only close if update succeeds
                    self.window.close()
                else:
                    logging.error("Update failed, keeping window open")
            else:
                logging.error("No UID found in result")

    def performSearch_(self, sender):
        location = self.location_input.stringValue()
        url = f"{self.app.base_url}/search/?token={self.app.token}&keyword={location}"
        response = requests.get(url)
        if response.status_code == 200:
            data = response.json()
            if data['status'] == 'ok':
                self.results = data['data']
                print(self.results)
            else:
                print(f"Error: {data['data']}")
                self.results = []
        else:
            print(f"Error: Unable to fetch data. Status code: {response.status_code}")
            self.results = []
        self.result_table.reloadData()

    def windowShouldClose_(self, sender):
        return True
    
    def windowWillClose_(self, notification):
        self.window = None  # Reset the window reference
        if self.app and hasattr(self.app, 'search_window'):
            self.app.search_window = None  # Reset the reference in the main app