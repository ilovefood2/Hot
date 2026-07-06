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

import Foundation

/*
 * Drives the fans from a temperature curve (Auto Boost).
 *
 * On every refresh the controller is handed the current sensor readings. When
 * Auto Boost is enabled it resolves the profile's sensor, interpolates a target
 * fan percentage from the curve and applies it through the already-authorized
 * helper - so no password is ever requested while boosting. Hysteresis and a
 * minimum-change threshold keep it from writing to the SMC on every tick.
 */
public class FanCurveController
{
    public static let shared = FanCurveController()

    /* Once boosting, keep boosting until the temperature drops this far below
     * the curve's start point, to avoid flapping around the threshold. */
    private let hysteresis: Double = 5

    /* Only re-apply when the target moves at least this many points. */
    private let minChange: Int = 4

    private var boosting           = false
    private var lastAppliedPercent: Int?   // nil = fans handed back to the system
    private var hasApplied         = false

    public private( set ) var lastTemperature: Double = 0
    public private( set ) var lastTarget:      Int?

    private init()
    {}

    public var isEnabled: Bool
    {
        FanCurve.load().enabled
    }

    /*
     * Called once when the user turns Auto Boost on, after authorization has
     * been ensured, so the first adjustment happens immediately rather than at
     * the next refresh.
     */
    public func start( sensors: [ String: Double ], cpuTemperature: Double )
    {
        self.boosting           = false
        self.lastAppliedPercent = nil
        self.hasApplied         = false

        self.evaluate( sensors: sensors, cpuTemperature: cpuTemperature )
    }

    /* Turns Auto Boost off and hands the fans back to the system. */
    public func stop()
    {
        if self.hasApplied, self.lastAppliedPercent != nil
        {
            FanControl.applyAuthorizedOnly( percent: nil )
        }

        self.boosting           = false
        self.lastAppliedPercent = nil
        self.lastTarget         = nil
    }

    public func evaluate( sensors: [ String: Double ], cpuTemperature: Double )
    {
        let curve = FanCurve.load()

        guard curve.enabled, FanControl.isHelperInstalled
        else
        {
            return
        }

        let temperature      = self.temperature( for: curve.sensorRole, sensors: sensors, fallback: cpuTemperature )
        self.lastTemperature = temperature

        guard temperature > 0, let start = curve.sortedPoints.first?.temperature
        else
        {
            return
        }

        if self.boosting
        {
            if temperature < start - self.hysteresis
            {
                self.boosting = false

                self.apply( percent: nil )

                return
            }
        }
        else
        {
            if temperature >= start
            {
                self.boosting = true
            }
            else
            {
                self.apply( percent: nil )

                return
            }
        }

        self.apply( percent: curve.percent( for: temperature ) )
    }

    /* Resolves a role to the hottest matching sensor, else the CPU fallback. */
    public func temperature( for role: FanSensorRole, sensors: [ String: Double ], fallback: Double ) -> Double
    {
        let matched = sensors.filter
        {
            key, _ in

            role.matches.contains { key.hasPrefix( $0 ) || key.contains( $0 ) }
        }
        .values
        .filter { $0 > 0 && $0 < 120 }

        return matched.max() ?? fallback
    }

    private func apply( percent: Int? )
    {
        if let target = percent, let last = self.lastAppliedPercent, abs( last - target ) < self.minChange
        {
            return
        }

        if percent == nil, self.lastAppliedPercent == nil, self.hasApplied
        {
            return
        }

        self.lastAppliedPercent = percent
        self.lastTarget         = percent
        self.hasApplied         = true

        DispatchQueue.global( qos: .utility ).async
        {
            FanControl.applyAuthorizedOnly( percent: percent )
        }
    }
}
