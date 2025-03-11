import objc
from Foundation import NSObject, NSMakeRect, NSUserDefaults
from AppKit import (
    NSWindow,
    NSWindowStyleMaskTitled,
    NSWindowStyleMaskClosable,
    NSBackingStoreBuffered,
    NSScreen,
    NSApp,
    NSFloatingWindowLevel,
    NSColor,
    NSButton,
    NSButtonTypeSwitch,
    NSBezelStyleRounded,
    NSControlStateValueOn,
    NSControlStateValueOff,
)
from aqi_visualization_view import AQIVisualizationView
import logging
from login_item_manager import LoginItemManager

logging.basicConfig(
    filename="detailwindow.log",
    level=logging.DEBUG,
    format="%(asctime)s - %(levelname)s - %(message)s",
)


class DetailWindow(NSObject):
    window = objc.ivar()
    checkbox = objc.ivar()
    done_button = objc.ivar()
    main_app = objc.ivar()
    login_manager = objc.ivar()

    @objc.python_method
    def initWithApp_(self, app):
        self = objc.super(DetailWindow, self).init()
        if self:
            self.window = None
            self.checkbox = None
            self.done_button = None
            self.main_app = app
            self.login_manager = LoginItemManager()
        return self

    @objc.python_method
    def showWindow_withText_andData_andTempUnit_(
        self, title, text, data, temperature_unit
    ):
        logging.info(f"Showing DetailWindow with title: {title}")
        windowWidth = 400
        windowHeight = 600
        padding = 20
        bottomPadding = 60

        try:
            stored_data = self.main_app.get_stored_data()
            logging.info(
                f"Retrieved stored data: {stored_data[:5]}"
            )  # Log first 5 entries
        except Exception as e:
            logging.error(f"Error retrieving stored data: {str(e)}")
            stored_data = []

        if self.window is None:
            screen = NSScreen.mainScreen()
            screenRect = screen.frame()

            windowRect = NSMakeRect(
                (screenRect.size.width - windowWidth) / 2,
                (screenRect.size.height - windowHeight) / 2,
                windowWidth,
                windowHeight,
            )

            styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable

            self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
                windowRect, styleMask, NSBackingStoreBuffered, False
            )

            self.window.setLevel_(NSFloatingWindowLevel)

        # Always set the window size
        self.window.setFrame_display_(
            NSMakeRect(
                self.window.frame().origin.x,
                self.window.frame().origin.y,
                windowWidth,
                windowHeight,
            ),
            True,
        )
        self.window.setMinSize_((windowWidth, windowHeight))
        self.window.setMaxSize_((windowWidth, windowHeight))

        self.window.setTitle_(title)
        self.window.setReleasedWhenClosed_(False)
        self.window.setDelegate_(self)

        # Trying to match
        # self.window.setBackgroundColor_(NSColor.windowBackgroundColor())

        contentView = self.window.contentView()
        for subview in contentView.subviews():
            subview.removeFromSuperview()

        # Create visualization view with padding
        visualizationView = (
            AQIVisualizationView.alloc().initWithFrame_andData_andTempUnit_(
                NSMakeRect(
                    padding,
                    bottomPadding,
                    windowWidth - 2 * padding,
                    windowHeight - bottomPadding - padding,
                ),
                stored_data,
                temperature_unit,
            )
        )
        contentView.addSubview_(visualizationView)

        # LOGIN checkbox
        self.checkbox = NSButton.alloc().initWithFrame_(
            NSMakeRect(padding, 10, 200, 40)
        )
        self.checkbox.setButtonType_(NSButtonTypeSwitch)
        self.checkbox.setTitle_("Start OpenAir at login")

        # Set initial state once, with proper error handling
        try:
            is_enabled = self.login_manager.isLoginItemEnabled()
            logging.info(f"Setting initial checkbox state to: {is_enabled}")
            self.checkbox.setState_(
                NSControlStateValueOn if is_enabled else NSControlStateValueOff
            )
        except Exception as e:
            logging.error(f"Error setting initial checkbox state: {e}")
            self.checkbox.setState_(NSControlStateValueOff)

        self.checkbox.setTarget_(self)
        self.checkbox.setAction_(objc.selector(self.toggleLoginItem_, signature=b"v@:"))
        contentView.addSubview_(self.checkbox)

        # DONE button
        self.done_button = NSButton.alloc().initWithFrame_(
            NSMakeRect(windowWidth - padding - 80, 10, 80, 40)
        )
        self.done_button.setTitle_("Done")
        self.done_button.setBezelStyle_(NSBezelStyleRounded)
        self.done_button.setTarget_(self)
        self.done_button.setAction_(self.closeWindow_)
        contentView.addSubview_(self.done_button)

        self.window.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)

    def isLoginItemEnabled(self):
        return LoginItemManager.isLoginItemEnabled(self)

    def toggleLoginItem_(self, sender):
        """Handle the login item toggle."""
        try:
            # Get the new requested state from the checkbox
            new_state = sender.state()  # This is the state the user just clicked to
            logging.info(f"Toggle requested. New state: {new_state}")

            if new_state:
                self.login_manager._create_and_load_launch_agent()
            else:
                self.login_manager._unload_and_remove_launch_agent()

            # Verify the change was successful
            actual_state = self.login_manager.isLoginItemEnabled()
            logging.info(f"Toggle completed. Actual state: {actual_state}")

            # Update checkbox to reflect actual state
            self.checkbox.setState_(
                NSControlStateValueOn if actual_state else NSControlStateValueOff
            )

        except Exception as e:
            logging.error(f"Error in toggleLoginItem_: {e}")
            # Reset checkbox to actual state in case of error
            self.checkbox.setState_(
                NSControlStateValueOn
                if self.login_manager.isLoginItemEnabled()
                else NSControlStateValueOff
            )

    def closeWindow_(self, sender):
        logging.info("closeWindow: method called")
        if self.window:
            if NSApp.modalWindow() == self.window:
                NSApp.stopModal()
            self.window.orderOut_(None)
            self.window.close()
            self.window = None
            NSApp.updateWindows()
            NSApp.sendEvent_(NSApp.currentEvent())
            logging.info("Window closed successfully")
        else:
            logging.warning("Window is None, cannot close")

    def windowDidBecomeKey_(self, notification):
        logging.info("Window did become key")

    def windowDidResignKey_(self, notification):
        logging.info("Window did resign key")

    def windowWillClose_(self, notification):
        logging.info("windowWillClose_ method called")
        NSApp.stopModal()
        self.window = None
        logging.debug("Window set to None in windowWillClose_")

    def windowShouldClose_(self, sender):
        logging.info(f"windowShouldClose_ called for window: {sender}")
        return True

    def testButtonAction_(self, sender):
        logging.info("Test button action called")
        print("Test button action called")

        # In showWindow_withText_andData_ method:
        self.done_button.setAction_(
            objc.selector("testButtonAction:", signature=b"v@:")
        )

    # Add a new method as a fallback
    @objc.python_method
    def fallbackCloseWindow_(self, sender):
        logging.info("fallbackCloseWindow_ method called")
        if self.window:
            self.window.close()
        self.window = None
        logging.info("Window closed using fallback method")

    def dealloc(self):
        logging.info("dealloc method called")
        if self.window:
            logging.debug("Window exists, closing and releasing it")
            self.window.setDelegate_(None)
            self.window.close()
            self.window.release()
        self.window = None
        logging.debug("Window set to None in dealloc")
        objc.super(DetailWindow, self).dealloc()
