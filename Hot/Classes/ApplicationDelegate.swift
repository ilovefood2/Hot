/*******************************************************************************
 * The MIT License (MIT)
 *
 * Copyright (c) 2023, Jean-David Gadina - www.xs-labs.com
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the Software), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED AS IS, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 ******************************************************************************/

import Cocoa
import GitHubUpdates
import SensorsUI

@NSApplicationMain
class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate
{
    private var statusItem:                    NSStatusItem?
    private var aboutWindowController:         AboutWindowController?
    private var preferencesWindowController:   PreferencesWindowController?
    private var sensorsWindowController:       SensorsWindowController?
    private var selectSensorsWindowController: SelectSensorsWindowController?
    private var sensorViewControllers:         [ SensorViewController  ] = []
    private var graphWindowController:         GraphWindowController?
    private var exiting                      = false
    private var fansMenu:                      NSMenu?
    private var fanStatusItems:                [ NSMenuItem ] = []
    private var fanAutoItem:                   NSMenuItem?
    private var fanPresetItems:                [ NSMenuItem ] = []
    private var fanAutoBoostItem:              NSMenuItem?
    private var fanProfileWindowController:    FanProfileWindowController?
    private var fanApplyInProgress           = false
    private var fanForcedThisSession         = false

    @IBOutlet private var menu:        NSMenu!
    @IBOutlet private var sensorsMenu: NSMenu!
    @IBOutlet private var updater:     GitHubUpdater!

    @objc public private( set ) dynamic var infoViewController: InfoViewController?

    deinit
    {
        UserDefaults.standard.removeObserver( self, forKeyPath: "displayCPUTemperature" )
        UserDefaults.standard.removeObserver( self, forKeyPath: "displaySchedulerLimit" )
        UserDefaults.standard.removeObserver( self, forKeyPath: "displayCPUFrequency" )
        UserDefaults.standard.removeObserver( self, forKeyPath: "colorizeStatusItemText" )
        UserDefaults.standard.removeObserver( self, forKeyPath: "convertToFahrenheit" )
        UserDefaults.standard.removeObserver( self, forKeyPath: "hideStatusIcon" )
    }

    func applicationDidFinishLaunching( _ notification: Notification )
    {
        self.initializePreferences()

        self.aboutWindowController             = AboutWindowController()
        self.preferencesWindowController       = PreferencesWindowController()
        self.selectSensorsWindowController     = SelectSensorsWindowController()
        self.statusItem                        = NSStatusBar.system.statusItem( withLength: NSStatusItem.variableLength )
        self.statusItem?.button?.image         = NSImage( named: "StatusIconTemplate" )
        self.statusItem?.button?.imagePosition = .imageLeading
        self.statusItem?.menu                  = self.menu

        self.updateMenuFont()
        self.setupFansMenu()

        let infoViewController             = InfoViewController()
        self.infoViewController            = infoViewController
        self.menu.item( withTag: 1 )?.view = infoViewController.view
        self.infoViewController?.onUpdate  =
        {
            [ weak self ] in

            self?.updateTitle()
            self?.updateSensors()
            self?.evaluateAutoBoost()
            self?.updateFansMenu()

            self?.graphWindowController?.graphView?.data = self?.infoViewController?.graphView?.data ?? []
            self?.graphWindowController?.schedulerLimit  = self?.infoViewController?.schedulerLimit  ?? 0
            self?.graphWindowController?.availableCPUs   = self?.infoViewController?.availableCPUs   ?? 0
            self?.graphWindowController?.speedLimit      = self?.infoViewController?.speedLimit      ?? 0
            self?.graphWindowController?.temperature     = self?.infoViewController?.temperature     ?? 0
            self?.graphWindowController?.thermalPressure = self?.infoViewController?.thermalPressure ?? 0
        }

        UserDefaults.standard.addObserver( self, forKeyPath: "displayCPUTemperature",  options: [], context: nil )
        UserDefaults.standard.addObserver( self, forKeyPath: "displaySchedulerLimit",  options: [], context: nil )
        UserDefaults.standard.addObserver( self, forKeyPath: "displayCPUFrequency",    options: [], context: nil )
        UserDefaults.standard.addObserver( self, forKeyPath: "colorizeStatusItemText", options: [], context: nil )
        UserDefaults.standard.addObserver( self, forKeyPath: "convertToFahrenheit",    options: [], context: nil )
        UserDefaults.standard.addObserver( self, forKeyPath: "hideStatusIcon",         options: [], context: nil )
        UserDefaults.standard.addObserver( self, forKeyPath: "fontName",               options: [], context: nil )

        if UserDefaults.standard.bool( forKey: "automaticallyCheckForUpdates" )
        {
            DispatchQueue.main.asyncAfter( deadline: .now() + .seconds( 2 ) )
            {
                self.updater.checkForUpdatesInBackground()
            }
        }

        Timer.scheduledTimer( withTimeInterval: 3600, repeats: true )
        {
            _ in

            if UserDefaults.standard.bool( forKey: "automaticallyCheckForUpdates" )
            {
                self.updater.checkForUpdatesInBackground()
            }
        }

        if UserDefaults.standard.bool( forKey: "showGraphPanel" )
        {
            DispatchQueue.main.asyncAfter( deadline: .now() + .seconds( 1 ) )
            {
                self.detachGraph( nil )
            }
        }

        self.handleDemoMenuIfNeeded()
        self.handleDemoPrefsIfNeeded()
        self.handleDemoFanProfileIfNeeded()
    }

    /* Hidden flag: `Hot --demo-fanprofile <output.png>` captures the Fan Profile window. */
    private func handleDemoFanProfileIfNeeded()
    {
        let args = ProcessInfo.processInfo.arguments

        guard let index = args.firstIndex( of: "--demo-fanprofile" ), index + 1 < args.count
        else
        {
            return
        }

        let path = args[ index + 1 ]

        DispatchQueue.main.asyncAfter( deadline: .now() + .seconds( 3 ) )
        {
            self.showFanProfileWindow( nil )

            DispatchQueue.main.asyncAfter( deadline: .now() + .seconds( 2 ) )
            {
                let captured = ( self.fanProfileWindowController?.window?.windowNumber )
                    .map { HotDemoCaptureWindow( UInt32( truncatingIfNeeded: $0 ), path ) } ?? false

                exit( captured ? 0 : 1 )
            }
        }
    }

    /* Hidden flag: `Hot --demo-prefs <output.png>` captures the Preferences window. */
    private func handleDemoPrefsIfNeeded()
    {
        let args = ProcessInfo.processInfo.arguments

        guard let index = args.firstIndex( of: "--demo-prefs" ), index + 1 < args.count
        else
        {
            return
        }

        let path = args[ index + 1 ]

        DispatchQueue.main.asyncAfter( deadline: .now() + .seconds( 3 ) )
        {
            self.showPreferencesWindow( nil )

            DispatchQueue.main.asyncAfter( deadline: .now() + .seconds( 2 ) )
            {
                let captured = ( self.preferencesWindowController?.window?.windowNumber )
                    .map { HotDemoCaptureWindow( UInt32( truncatingIfNeeded: $0 ), path ) } ?? false

                exit( captured ? 0 : 1 )
            }
        }
    }

    /*
     * Hidden flag used to produce the README screenshots:
     * `Hot --demo-menu <main|fans> <output.png>` opens the requested menu,
     * captures it to the given path, and exits.
     */
    private func handleDemoMenuIfNeeded()
    {
        let args = ProcessInfo.processInfo.arguments

        guard let index = args.firstIndex( of: "--demo-menu" ), index + 2 < args.count
        else
        {
            return
        }

        let which = args[ index + 1 ]
        let path  = args[ index + 2 ]

        DispatchQueue.main.asyncAfter( deadline: .now() + .seconds( 8 ) )
        {
            guard let menu = which == "fans" ? self.fansMenu : self.menu
            else
            {
                exit( 1 )
            }

            let timer = Timer( timeInterval: 2, repeats: false )
            {
                _ in

                let windows = NSApp.windows.filter
                {
                    $0.isVisible && $0.className.lowercased().contains( "menu" )
                }

                let captured = windows.map
                {
                    HotDemoCaptureWindow( UInt32( truncatingIfNeeded: $0.windowNumber ), path )
                }
                .contains( true )

                menu.cancelTracking()
                exit( captured ? 0 : 1 )
            }

            RunLoop.main.add( timer, forMode: .common )

            let origin = NSPoint( x: 200, y: ( NSScreen.main?.visibleFrame.maxY ?? 800 ) - 4 )

            menu.popUp( positioning: nil, at: origin, in: nil )
        }
    }

    func applicationWillTerminate( _ notification: Notification )
    {
        self.exiting = true

        /*
         * If manual fan control was enabled during this session, offer to
         * restore automatic fan management on the way out, so the fans are
         * not left pinned at a fixed speed with nobody watching them.
         */
        if self.fanForcedThisSession, FanControl.fans().contains( where: { $0.manual } )
        {
            _ = FanControl.applySynchronously( percent: nil )
        }
    }

    private func setupFansMenu()
    {
        let fans = FanControl.fans()

        guard fans.isEmpty == false
        else
        {
            return
        }

        let submenu = NSMenu( title: NSLocalizedString( "Fans", comment: "" ) )

        self.fanStatusItems = fans.map
        {
            fan in

            let item       = NSMenuItem( title: "Fan \( fan.index + 1 ): --", action: nil, keyEquivalent: "" )
            item.isEnabled = false

            submenu.addItem( item )

            return item
        }

        submenu.addItem( .separator() )

        let auto              = NSMenuItem( title: NSLocalizedString( "Automatic (Recommended)", comment: "" ), action: #selector( self.setFansAuto( _: ) ), keyEquivalent: "" )
        auto.target           = self
        self.fanAutoItem      = auto

        submenu.addItem( auto )

        self.fanPresetItems = [ ( 25, "25%" ), ( 50, "50%" ), ( 75, "75%" ), ( 100, NSLocalizedString( "Full Speed", comment: "" ) ) ].map
        {
            percent, title in

            let item    = NSMenuItem( title: title, action: #selector( self.setFansPreset( _: ) ), keyEquivalent: "" )
            item.target = self
            item.tag    = percent

            submenu.addItem( item )

            return item
        }

        submenu.addItem( .separator() )

        let autoBoost         = NSMenuItem( title: NSLocalizedString( "Auto Boost", comment: "" ), action: #selector( self.toggleAutoBoost( _: ) ), keyEquivalent: "" )
        autoBoost.target      = self
        self.fanAutoBoostItem = autoBoost

        submenu.addItem( autoBoost )

        let profile        = NSMenuItem( title: NSLocalizedString( "Fan Profile…", comment: "" ), action: #selector( self.showFanProfileWindow( _: ) ), keyEquivalent: "" )
        profile.target     = self

        submenu.addItem( profile )

        let fansItem     = NSMenuItem( title: NSLocalizedString( "Fans", comment: "" ), action: nil, keyEquivalent: "" )
        fansItem.submenu = submenu
        self.fansMenu    = submenu

        let index = self.menu.items.firstIndex { $0.submenu == self.sensorsMenu } ?? 1

        self.menu.insertItem( fansItem, at: index )

        /* If Auto Boost was left enabled and the helper is authorized, resume
         * driving the fans right away rather than waiting for the first edit. */
        if FanCurve.load().enabled, FanControl.isHelperInstalled
        {
            self.fanForcedThisSession = true
        }
    }

    private func updateFansMenu()
    {
        guard self.fansMenu != nil
        else
        {
            return
        }

        let fans = FanControl.fans()

        fans.enumerated().forEach
        {
            index, fan in

            guard index < self.fanStatusItems.count
            else
            {
                return
            }

            let mode = fan.manual
                     ? String( format: NSLocalizedString( "Manual: %.0f RPM", comment: "" ), fan.target )
                     : NSLocalizedString( "Automatic", comment: "" )

            self.fanStatusItems[ index ].title = "Fan \( fan.index + 1 ): \( Int( fan.rpm ) ) RPM — \( mode )"
        }

        let anyManual  = fans.contains { $0.manual }
        let percent    = UserDefaults.standard.integer( forKey: "fanControlPercent" )
        let autoBoost  = FanCurve.load().enabled

        self.fanAutoBoostItem?.state = autoBoost ? .on : .off

        if autoBoost
        {
            let target = FanCurveController.shared.lastTarget

            self.fanAutoBoostItem?.title = target.map
            {
                String( format: NSLocalizedString( "Auto Boost — %d%%", comment: "" ), $0 )
            }
            ?? NSLocalizedString( "Auto Boost — Automatic", comment: "" )
        }
        else
        {
            self.fanAutoBoostItem?.title = NSLocalizedString( "Auto Boost", comment: "" )
        }

        /* While Auto Boost is driving the fans, the manual controls don't apply. */
        self.fanAutoItem?.isEnabled = autoBoost == false
        self.fanPresetItems.forEach { $0.isEnabled = autoBoost == false }

        self.fanAutoItem?.state = ( anyManual || autoBoost ) ? .off : .on

        self.fanPresetItems.forEach
        {
            $0.state = autoBoost == false && anyManual && $0.tag == percent ? .on : .off
        }
    }

    private func evaluateAutoBoost()
    {
        guard FanCurve.load().enabled
        else
        {
            return
        }

        let sensors = self.infoViewController?.log.sensors                 ?? [ : ]
        let cpu      = Double( self.infoViewController?.temperature ?? 0 )

        FanCurveController.shared.evaluate( sensors: sensors, cpuTemperature: cpu )
    }

    private func currentSensorData() -> ( sensors: [ String: Double ], cpu: Double )
    {
        ( self.infoViewController?.log.sensors ?? [ : ], Double( self.infoViewController?.temperature ?? 0 ) )
    }

    @objc
    private func toggleAutoBoost( _ sender: Any? )
    {
        var curve = FanCurve.load()

        if curve.enabled
        {
            curve.enabled = false
            curve.save()

            FanCurveController.shared.stop()
            self.updateFansMenu()

            return
        }

        /* Enabling: make sure the helper is authorized (one-time password),
         * then start the engine so the fans respond immediately. */
        if self.fanApplyInProgress
        {
            NSSound.beep()

            return
        }

        self.fanApplyInProgress = true

        FanControl.apply( percent: FanCurveController.shared.lastTarget ?? 0 )
        {
            [ weak self ] error in

            guard let self = self
            else
            {
                return
            }

            self.fanApplyInProgress = false

            if let error = error
            {
                if case FanControl.FanControlError.cancelled = error
                {
                    return
                }

                let alert             = NSAlert()
                alert.messageText     = NSLocalizedString( "Cannot Enable Auto Boost", comment: "" )
                alert.informativeText = error.localizedDescription

                NSApp.activate( ignoringOtherApps: true )
                alert.runModal()

                return
            }

            var curve                 = FanCurve.load()
            curve.enabled             = true
            curve.save()
            self.fanForcedThisSession = true

            let data = self.currentSensorData()

            FanCurveController.shared.start( sensors: data.sensors, cpuTemperature: data.cpu )
            self.updateFansMenu()
        }
    }

    @objc
    private func showFanProfileWindow( _ sender: Any? )
    {
        if self.fanProfileWindowController == nil
        {
            let controller = FanProfileWindowController()

            controller.sensorProvider = {
                [ weak self ] in self?.currentSensorData() ?? ( [ : ], 0 )
            }

            controller.onEnableRequested =
            {
                [ weak self ] completion in

                self?.authorizeAutoBoost( completion: completion )
            }

            self.fanProfileWindowController = controller
        }

        guard let window = self.fanProfileWindowController?.window
        else
        {
            NSSound.beep()

            return
        }

        if window.isVisible == false
        {
            window.center()
        }

        NSApp.activate( ignoringOtherApps: true )
        self.fanProfileWindowController?.showWindow( sender )
        window.makeKeyAndOrderFront( sender )
    }

    /* Ensures the helper is authorized before the profile window enables Auto
     * Boost; reports success so the window can revert the toggle if declined. */
    private func authorizeAutoBoost( completion: @escaping ( Bool ) -> Void )
    {
        if FanControl.isHelperInstalled
        {
            self.fanForcedThisSession = true

            completion( true )

            return
        }

        FanControl.apply( percent: 0 )
        {
            error in

            if let error = error, case FanControl.FanControlError.cancelled = error
            {
                completion( false )

                return
            }

            if error != nil
            {
                completion( false )

                return
            }

            self.fanForcedThisSession = true

            completion( true )
        }
    }

    @objc
    private func setFansAuto( _ sender: Any? )
    {
        self.applyFans( percent: nil )
    }

    @objc
    private func setFansPreset( _ sender: NSMenuItem )
    {
        self.applyFans( percent: sender.tag )
    }

    private func applyFans( percent: Int? )
    {
        if self.fanApplyInProgress
        {
            NSSound.beep()

            return
        }

        self.fanApplyInProgress = true

        FanControl.apply( percent: percent )
        {
            [ weak self ] error in

            guard let self = self
            else
            {
                return
            }

            self.fanApplyInProgress = false

            if let error = error
            {
                if case FanControl.FanControlError.cancelled = error
                {
                    return
                }

                let alert             = NSAlert()
                alert.messageText     = NSLocalizedString( "Cannot Change Fan Settings", comment: "" )
                alert.informativeText = error.localizedDescription

                NSApp.activate( ignoringOtherApps: true )
                alert.runModal()

                return
            }

            if let percent = percent
            {
                self.fanForcedThisSession = true

                UserDefaults.standard.set( percent, forKey: "fanControlPercent" )
            }

            self.updateFansMenu()
        }
    }

    private func initializePreferences()
    {
        if UserDefaults.standard.object( forKey: "LastLaunch" ) == nil
        {
            UserDefaults.standard.setValue( true,     forKey: "automaticallyCheckForUpdates" )
            UserDefaults.standard.setValue( true,     forKey: "displayCPUTemperature" )
            UserDefaults.standard.setValue( true,     forKey: "displaySchedulerLimit" )
            UserDefaults.standard.setValue( true,     forKey: "colorizeStatusItemText" )
            UserDefaults.standard.setValue( NSDate(), forKey: "LastLaunch" )
        }

        if UserDefaults.standard.object( forKey: "refreshInterval" ) == nil
        {
            UserDefaults.standard.setValue( 2, forKey: "refreshInterval" )
        }

        if UserDefaults.standard.object( forKey: "sensorsWindowShowTemperature" ) == nil
        {
            UserDefaults.standard.setValue( true, forKey: "sensorsWindowShowTemperature" )
        }

        if UserDefaults.standard.object( forKey: "sensorsWindowShowVoltage" ) == nil
        {
            UserDefaults.standard.setValue( true, forKey: "sensorsWindowShowVoltage" )
        }

        if UserDefaults.standard.object( forKey: "sensorsWindowShowCurrent" ) == nil
        {
            UserDefaults.standard.setValue( true, forKey: "sensorsWindowShowCurrent" )
        }

        if UserDefaults.standard.object( forKey: "displaySchedulerLimit" ) == nil
        {
            // Added in 1.8.0
            UserDefaults.standard.setValue( true, forKey: "displaySchedulerLimit" )
        }
    }

    private func updateMenuFont()
    {
        let system = NSFont.monospacedDigitSystemFont( ofSize: NSFont.smallSystemFontSize, weight: .light )

        guard let fontName = UserDefaults.standard.string( forKey: "fontName" )
        else
        {
            self.statusItem?.button?.font = system

            return
        }

        let parts = fontName.split( separator: " " )

        guard parts.count >= 2, let last = parts.last, let size = Int( String( last ) )
        else
        {
            self.statusItem?.button?.font = system

            return
        }

        let name                      = parts.dropLast().joined( separator: " " )
        self.statusItem?.button?.font = NSFont( name: name, size: CGFloat( size ) ) ?? system
    }

    override func observeValue( forKeyPath keyPath: String?, of object: Any?, change: [ NSKeyValueChangeKey: Any ]?, context: UnsafeMutableRawPointer? )
    {
        let keyPaths =
            [
                "displayCPUTemperature",
                "displaySchedulerLimit",
                "displayCPUFrequency",
                "colorizeStatusItemText",
                "convertToFahrenheit",
                "hideStatusIcon",
                "fontName",
            ]

        if let keyPath = keyPath, let object = object as? NSObject, object == UserDefaults.standard, keyPaths.contains( keyPath )
        {
            self.updateMenuFont()
            self.updateTitle()
            self.updateSensors()
        }
        else
        {
            super.observeValue( forKeyPath: keyPath, of: object, change: change, context: context )
        }
    }

    @IBAction
    public func showAboutWindow( _ sender: Any? )
    {
        guard let window = self.aboutWindowController?.window
        else
        {
            NSSound.beep()

            return
        }

        if window.isVisible == false
        {
            window.layoutIfNeeded()
            window.center()
        }

        NSApp.activate( ignoringOtherApps: true )
        window.makeKeyAndOrderFront( nil )
    }

    @IBAction
    public func showPreferencesWindow( _ sender: Any? )
    {
        guard let window = self.preferencesWindowController?.window
        else
        {
            NSSound.beep()

            return
        }

        if window.isVisible == false
        {
            window.layoutIfNeeded()
            window.center()
        }

        NSApp.activate( ignoringOtherApps: true )
        window.makeKeyAndOrderFront( nil )
    }

    @IBAction
    public func showSelectSensorsWindow( _ sender: Any? )
    {
        guard let window = self.selectSensorsWindowController?.window
        else
        {
            NSSound.beep()

            return
        }

        if window.isVisible == false
        {
            window.layoutIfNeeded()
            window.center()
        }

        NSApp.activate( ignoringOtherApps: true )
        window.makeKeyAndOrderFront( nil )
    }

    @IBAction
    public func checkForUpdates( _ sender: Any? )
    {
        self.updater.checkForUpdates( sender )
    }

    private func updateTitle()
    {
        var title       = ""
        let transformer = TemperatureToString()

        if let n1 = self.infoViewController?.speedLimit,
           let n2 = self.infoViewController?.temperature,
           UserDefaults.standard.bool( forKey: "displaySchedulerLimit" ),
           UserDefaults.standard.bool( forKey: "displayCPUTemperature" ),
           n1 > 0,
           n2 > 0
        {
            let temp = transformer.transformedValue( n2 ) as? String ?? "--"
            title    = "\( n1 )% \( temp )"
        }
        else if let n = self.infoViewController?.speedLimit, n > 0,
                UserDefaults.standard.bool( forKey: "displaySchedulerLimit" )
        {
            title = "\( n )%"
        }
        else if let n = self.infoViewController?.temperature,
                UserDefaults.standard.bool( forKey: "displayCPUTemperature" ),
                n > 0
        {
            title = transformer.transformedValue( n ) as? String ?? "--"
        }

        if UserDefaults.standard.bool( forKey: "displayCPUFrequency" ),
           let mhz = self.infoViewController?.cpuFrequency,
           mhz > 0
        {
            let frequency = CPUFrequencyToString().transformedValue( mhz ) as? String ?? "--"
            title         = title.isEmpty ? frequency : "\( title ) \( frequency )"
        }

        if title.count == 0
        {
            self.statusItem?.button?.title = ""
        }
        else
        {
            let color: NSColor =
            {
                if UserDefaults.standard.bool( forKey: "colorizeStatusItemText" ) == false
                {
                    return .controlTextColor
                }

                let limit = self.infoViewController?.speedLimit ?? 100

                if limit > 0, limit < 60
                {
                    return .orange
                }

                if let rawPressure = self.infoViewController?.thermalPressure,
                   let pressure    = ProcessInfo.ThermalState( rawValue: rawPressure ),
                   pressure       != .nominal
                {
                    return .orange
                }

                return .controlTextColor
            }()

            self.statusItem?.button?.attributedTitle = NSAttributedString( string: title, attributes: [ .foregroundColor: color ] )
        }

        if UserDefaults.standard.bool( forKey: "hideStatusIcon" ), title.count > 0
        {
            self.statusItem?.button?.image = nil
        }
        else
        {
            self.statusItem?.button?.image = NSImage( named: "StatusIconTemplate" )
        }
    }

    private func updateSensors()
    {
        if self.sensorViewControllers.isEmpty
        {
            self.sensorsMenu.removeAllItems()
        }

        guard let sensors = self.infoViewController?.log.sensors
        else
        {
            return
        }

        var controllers = self.sensorViewControllers
        var items       = self.sensorsMenu.items

        controllers.removeAll { item in sensors.contains { $0.key == item.name  } == false }
        items.removeAll       { item in sensors.contains { $0.key == item.title } == false }

        sensors.forEach
        {
            sensor in

            if let controller = self.sensorViewControllers.first( where: { $0.name  == sensor.key } )
            {
                controller.value = Int( sensor.value )
            }
            else
            {
                let controller   = SensorViewController()
                controller.name  = sensor.key
                controller.value = Int( sensor.value )
                let item         = NSMenuItem( title: sensor.key, action: nil, keyEquivalent: "" )
                item.view        = controller.view

                items.append( item )
                controllers.append( controller )
            }
        }

        self.sensorViewControllers = controllers

        self.sensorsMenu.removeAllItems()

        items.sorted
        {
            $0.title.compare( $1.title, options: [ .numeric, .caseInsensitive ], range: nil, locale: nil ) == .orderedAscending
        }
        .forEach
        {
            self.sensorsMenu.addItem( $0 )
        }
    }

    @IBAction
    public func viewAllSensors( _ sender: Any? )
    {
        if self.sensorsWindowController == nil
        {
            self.sensorsWindowController = SensorsWindowController()
        }

        guard let window = self.sensorsWindowController?.window
        else
        {
            NSSound.beep()

            return
        }

        window.delegate = self

        if window.isVisible == false
        {
            window.layoutIfNeeded()
            window.center()
        }

        NSApp.activate( ignoringOtherApps: true )
        window.makeKeyAndOrderFront( nil )
    }

    func windowWillClose( _ notification: Notification )
    {
        guard let window = notification.object as? NSWindow
        else
        {
            return
        }

        if window == self.sensorsWindowController?.window
        {
            self.sensorsWindowController?.stop( completion: nil )

            self.sensorsWindowController = nil
        }
        else if window == self.graphWindowController?.window
        {
            self.graphWindowController = nil

            if self.exiting == false
            {
                UserDefaults.standard.set( false, forKey: "showGraphPanel" )
            }
        }
    }

    @IBAction
    public func detachGraph( _ sender: Any? )
    {
        if self.graphWindowController == nil
        {
            self.graphWindowController                  = GraphWindowController()
            self.graphWindowController?.graphView?.data = self.infoViewController?.graphView?.data ?? []
        }

        guard let window = self.graphWindowController?.window
        else
        {
            NSSound.beep()

            return
        }

        window.delegate = self

        if UserDefaults.standard.object( forKey: "NSWindow Frame GraphPanel" ) == nil
        {
            window.layoutIfNeeded()
            window.center()
        }

        NSApp.activate( ignoringOtherApps: true )
        window.makeKeyAndOrderFront( nil )
        UserDefaults.standard.set( true, forKey: "showGraphPanel" )
    }
}
