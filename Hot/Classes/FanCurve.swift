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
 * The temperature source an Auto Boost curve reacts to. Each role resolves to
 * the hottest matching sensor on the current machine, falling back to the
 * app's overall CPU temperature when no specific sensor is found.
 */
public enum FanSensorRole: String, CaseIterable
{
    case performanceCores = "CPU Performance Cores"
    case cpuProximity     = "CPU Proximity"
    case socDie           = "SoC Die"

    /* SMC key prefixes / IOHID name fragments matched for this role, in order. */
    public var matches: [ String ]
    {
        switch self
        {
            case .performanceCores: return [ "Tp", "pACC" ]
            case .cpuProximity:     return [ "TC0P", "TS0P", "Ts0P", "TW0P" ]
            case .socDie:           return [ "TCMb", "TVD", "TCM" ]
        }
    }
}

public struct FanCurvePoint: Codable, Equatable
{
    public var temperature: Double   // °C
    public var percent:     Int      // 0-100 of the fan's RPM range

    public init( temperature: Double, percent: Int )
    {
        self.temperature = temperature
        self.percent     = percent
    }
}

/*
 * An Auto Boost profile: a temperature -> fan-percentage curve applied to a
 * chosen sensor. Below the first point's temperature the fans are left under
 * automatic system control; between points the percentage is interpolated
 * linearly; above the last point the last percentage is held.
 */
public struct FanCurve: Codable, Equatable
{
    public var enabled: Bool
    public var role:    String
    public var points:  [ FanCurvePoint ]

    private static let defaultsKey = "fanCurve"

    public init( enabled: Bool, role: String, points: [ FanCurvePoint ] )
    {
        self.enabled = enabled
        self.role    = role
        self.points  = points
    }

    public var sensorRole: FanSensorRole
    {
        FanSensorRole( rawValue: self.role ) ?? .performanceCores
    }

    /* Matches the requested example: start ~58 C, then 70 / 80 / 90 C. */
    public static var autoBoostDefault: FanCurve
    {
        FanCurve(
            enabled: false,
            role:    FanSensorRole.performanceCores.rawValue,
            points:
            [
                FanCurvePoint( temperature: 58, percent: 20 ),   // start boost
                FanCurvePoint( temperature: 70, percent: 45 ),   // medium
                FanCurvePoint( temperature: 80, percent: 70 ),   // high
                FanCurvePoint( temperature: 90, percent: 100 ),  // max-ish
            ]
        )
    }

    public var sortedPoints: [ FanCurvePoint ]
    {
        self.points.sorted { $0.temperature < $1.temperature }
    }

    /* Fan percentage for a given temperature, per the interpolation rules above. */
    public func percent( for temperature: Double ) -> Int
    {
        let points = self.sortedPoints

        guard let first = points.first, let last = points.last
        else
        {
            return 0
        }

        if temperature <= first.temperature
        {
            return first.percent
        }

        if temperature >= last.temperature
        {
            return last.percent
        }

        for i in 1 ..< points.count
        {
            let a = points[ i - 1 ]
            let b = points[ i ]

            if temperature <= b.temperature
            {
                let span  = b.temperature - a.temperature
                let ratio = span > 0 ? ( temperature - a.temperature ) / span : 0
                let value = Double( a.percent ) + ratio * Double( b.percent - a.percent )

                return Int( value.rounded() )
            }
        }

        return last.percent
    }

    public static func load() -> FanCurve
    {
        guard let data = UserDefaults.standard.data( forKey: self.defaultsKey ),
              let curve = try? JSONDecoder().decode( FanCurve.self, from: data )
        else
        {
            return self.autoBoostDefault
        }

        return curve
    }

    public func save()
    {
        if let data = try? JSONEncoder().encode( self )
        {
            UserDefaults.standard.set( data, forKey: FanCurve.defaultsKey )
        }
    }
}
