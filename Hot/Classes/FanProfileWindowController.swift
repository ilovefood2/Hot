/*******************************************************************************
 * The MIT License (MIT)
 *
 * Copyright (c) 2026, Jean-David Gadina - www.xs-labs.com
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

/*
 * Programmatic editor for the Auto Boost fan curve. Lets the user enable Auto
 * Boost, pick the sensor it reacts to, and set the four temperature thresholds
 * and their fan percentages. Shows the live reading and resulting target.
 */
public class FanProfileWindowController: NSWindowController, NSWindowDelegate
{
    private let labels        = [ "Start boost", "Medium", "High", "Max" ]
    private var enableButton:  NSButton!
    private var sensorPopUp:   NSPopUpButton!
    private var readingLabel:  NSTextField!
    private var tempSteppers:  [ NSStepper ]   = []
    private var tempValues:    [ NSTextField ] = []
    private var pctSteppers:   [ NSStepper ]   = []
    private var pctValues:     [ NSTextField ] = []
    private var timer:         Timer?

    /* Supplies the live sensor readings so the window can show the current
     * temperature and target, and re-evaluate immediately after an edit. */
    public var sensorProvider: ( () -> ( sensors: [ String: Double ], cpu: Double ) )?

    /* Called when Auto Boost is toggled on, so the app can ensure the helper is
     * authorized (one-time password) before the engine starts driving fans. */
    public var onEnableRequested: ( ( @escaping ( Bool ) -> Void ) -> Void )?

    public convenience init()
    {
        let window = NSWindow(
            contentRect: NSRect( x: 0, y: 0, width: 440, height: 360 ),
            styleMask:   [ .titled, .closable ],
            backing:     .buffered,
            defer:       true
        )

        window.title = "Fan Profile"

        self.init( window: window )

        window.delegate = self

        self.buildUI()
        self.loadFromCurve()
    }

    private func buildUI()
    {
        guard let content = self.window?.contentView
        else
        {
            return
        }

        let stack               = NSStackView()
        stack.orientation        = .vertical
        stack.alignment          = .leading
        stack.spacing            = 12
        stack.edgeInsets         = NSEdgeInsets( top: 20, left: 20, bottom: 20, right: 20 )
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview( stack )

        NSLayoutConstraint.activate(
        [
            stack.leadingAnchor.constraint(  equalTo: content.leadingAnchor ),
            stack.trailingAnchor.constraint( equalTo: content.trailingAnchor ),
            stack.topAnchor.constraint(      equalTo: content.topAnchor ),
            stack.bottomAnchor.constraint(   equalTo: content.bottomAnchor ),
        ] )

        self.enableButton        = NSButton( checkboxWithTitle: "Enable Auto Boost", target: self, action: #selector( self.enableChanged( _: ) ) )
        stack.addArrangedSubview( self.enableButton )

        let sensorRow            = NSStackView()
        sensorRow.orientation    = .horizontal
        sensorRow.spacing        = 8

        let sensorLabel          = self.makeLabel( "Boost sensor:" )
        self.sensorPopUp         = NSPopUpButton( frame: .zero, pullsDown: false )
        self.sensorPopUp.addItems( withTitles: FanSensorRole.allCases.map { $0.rawValue } )
        self.sensorPopUp.target  = self
        self.sensorPopUp.action  = #selector( self.sensorChanged( _: ) )

        sensorRow.addArrangedSubview( sensorLabel )
        sensorRow.addArrangedSubview( self.sensorPopUp )
        stack.addArrangedSubview( sensorRow )

        self.readingLabel        = self.makeLabel( "" )
        self.readingLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview( self.readingLabel )

        let header               = self.makeLabel( "Temperature  →  Fan speed" )
        header.font              = NSFont.boldSystemFont( ofSize: NSFont.smallSystemFontSize )
        stack.addArrangedSubview( header )

        for i in 0 ..< self.labels.count
        {
            stack.addArrangedSubview( self.makeThresholdRow( index: i ) )
        }

        let buttonRow            = NSStackView()
        buttonRow.orientation    = .horizontal
        buttonRow.spacing        = 8

        let reset                = NSButton( title: "Reset to Auto Boost Defaults", target: self, action: #selector( self.resetDefaults( _: ) ) )
        reset.bezelStyle         = .rounded
        let done                 = NSButton( title: "Done", target: self, action: #selector( self.closeWindow( _: ) ) )
        done.bezelStyle          = .rounded
        done.keyEquivalent       = "\r"

        buttonRow.addArrangedSubview( reset )
        buttonRow.addArrangedSubview( done )
        stack.addArrangedSubview( buttonRow )
    }

    private func makeThresholdRow( index: Int ) -> NSView
    {
        let row               = NSStackView()
        row.orientation        = .horizontal
        row.spacing            = 6

        let name               = self.makeLabel( self.labels[ index ] )
        name.widthAnchor.constraint( equalToConstant: 90 ).isActive = true

        let tempValue          = self.makeLabel( "--" )
        tempValue.widthAnchor.constraint( equalToConstant: 44 ).isActive = true
        tempValue.alignment    = .right

        let tempStepper        = NSStepper()
        tempStepper.minValue   = 30
        tempStepper.maxValue   = 105
        tempStepper.increment  = 1
        tempStepper.valueWraps = false
        tempStepper.target     = self
        tempStepper.action     = #selector( self.thresholdChanged( _: ) )
        tempStepper.tag        = index

        let arrow              = self.makeLabel( "→" )

        let pctValue           = self.makeLabel( "--" )
        pctValue.widthAnchor.constraint( equalToConstant: 44 ).isActive = true
        pctValue.alignment     = .right

        let pctStepper         = NSStepper()
        pctStepper.minValue    = 0
        pctStepper.maxValue    = 100
        pctStepper.increment   = 5
        pctStepper.valueWraps  = false
        pctStepper.target      = self
        pctStepper.action      = #selector( self.thresholdChanged( _: ) )
        pctStepper.tag         = 100 + index

        self.tempValues.append( tempValue )
        self.tempSteppers.append( tempStepper )
        self.pctValues.append( pctValue )
        self.pctSteppers.append( pctStepper )

        row.addArrangedSubview( name )
        row.addArrangedSubview( tempValue )
        row.addArrangedSubview( tempStepper )
        row.addArrangedSubview( arrow )
        row.addArrangedSubview( pctValue )
        row.addArrangedSubview( pctStepper )

        return row
    }

    private func makeLabel( _ text: String ) -> NSTextField
    {
        let field              = NSTextField( labelWithString: text )
        field.translatesAutoresizingMaskIntoConstraints = false

        return field
    }

    private func loadFromCurve()
    {
        let curve                = FanCurve.load()
        let points               = self.paddedPoints( curve.sortedPoints )

        self.enableButton.state  = curve.enabled ? .on : .off
        self.sensorPopUp.selectItem( withTitle: curve.role )

        for i in 0 ..< self.labels.count
        {
            self.tempSteppers[ i ].doubleValue = points[ i ].temperature
            self.pctSteppers[ i ].integerValue = points[ i ].percent
            self.tempValues[ i ].stringValue   = "\( Int( points[ i ].temperature ) )°C"
            self.pctValues[ i ].stringValue    = "\( points[ i ].percent )%"
        }

        self.updateReading()
    }

    /* Guarantees four points so every row has a value, even for older data. */
    private func paddedPoints( _ points: [ FanCurvePoint ] ) -> [ FanCurvePoint ]
    {
        var result   = points
        let defaults = FanCurve.autoBoostDefault.sortedPoints

        while result.count < defaults.count
        {
            result.append( defaults[ result.count ] )
        }

        return Array( result.prefix( defaults.count ) )
    }

    private func currentCurve() -> FanCurve
    {
        var points: [ FanCurvePoint ] = []

        for i in 0 ..< self.labels.count
        {
            points.append( FanCurvePoint( temperature: self.tempSteppers[ i ].doubleValue, percent: self.pctSteppers[ i ].integerValue ) )
        }

        return FanCurve( enabled: self.enableButton.state == .on, role: self.sensorPopUp.titleOfSelectedItem ?? FanSensorRole.performanceCores.rawValue, points: points )
    }

    private func persist()
    {
        var curve = self.currentCurve()

        /* Keep thresholds monotonically non-decreasing so the curve is sane. */
        var points = curve.points

        for i in 1 ..< points.count
        {
            if points[ i ].temperature < points[ i - 1 ].temperature
            {
                points[ i ].temperature = points[ i - 1 ].temperature
            }

            if points[ i ].percent < points[ i - 1 ].percent
            {
                points[ i ].percent = points[ i - 1 ].percent
            }
        }

        curve.points = points
        curve.save()

        if let provider = self.sensorProvider
        {
            let data = provider()

            FanCurveController.shared.evaluate( sensors: data.sensors, cpuTemperature: data.cpu )
        }
    }

    @objc private func enableChanged( _ sender: Any? )
    {
        if self.enableButton.state == .on
        {
            self.onEnableRequested?
            {
                [ weak self ] authorized in

                guard let self = self
                else
                {
                    return
                }

                if authorized == false
                {
                    self.enableButton.state = .off
                }

                self.persist()

                if authorized, let provider = self.sensorProvider
                {
                    let data = provider()

                    FanCurveController.shared.start( sensors: data.sensors, cpuTemperature: data.cpu )
                }
            }
        }
        else
        {
            self.persist()

            FanCurveController.shared.stop()
        }
    }

    @objc private func sensorChanged( _ sender: Any? )
    {
        self.persist()
        self.updateReading()
    }

    @objc private func thresholdChanged( _ sender: NSStepper )
    {
        for i in 0 ..< self.labels.count
        {
            self.tempValues[ i ].stringValue = "\( Int( self.tempSteppers[ i ].doubleValue ) )°C"
            self.pctValues[ i ].stringValue  = "\( self.pctSteppers[ i ].integerValue )%"
        }

        self.persist()
    }

    @objc private func resetDefaults( _ sender: Any? )
    {
        var defaults     = FanCurve.autoBoostDefault
        defaults.enabled = self.enableButton.state == .on
        defaults.save()

        self.loadFromCurve()
        self.persist()
    }

    @objc private func closeWindow( _ sender: Any? )
    {
        self.window?.close()
    }

    private func updateReading()
    {
        guard let provider = self.sensorProvider
        else
        {
            return
        }

        let data  = provider()
        let curve = self.currentCurve()
        let temp  = FanCurveController.shared.temperature( for: curve.sensorRole, sensors: data.sensors, fallback: data.cpu )

        if temp <= 0
        {
            self.readingLabel.stringValue = "Current: sensor unavailable"

            return
        }

        let target = curve.percent( for: temp )
        let start  = curve.sortedPoints.first?.temperature ?? 0
        let state  = temp < start ? "below start — fans on Automatic" : "target \( target )%"

        self.readingLabel.stringValue = "Current: \( Int( temp.rounded() ) )°C — \( state )"
    }

    public override func showWindow( _ sender: Any? )
    {
        super.showWindow( sender )

        self.loadFromCurve()

        self.timer?.invalidate()
        self.timer = Timer.scheduledTimer( withTimeInterval: 1, repeats: true )
        {
            [ weak self ] _ in self?.updateReading()
        }
    }

    public func stopUpdating()
    {
        self.timer?.invalidate()
        self.timer = nil
    }

    public func windowWillClose( _ notification: Notification )
    {
        self.stopUpdating()
    }
}
