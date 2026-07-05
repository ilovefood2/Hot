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
import SMCKit

public class FanControl
{
    public struct Fan
    {
        public let index:  Int
        public let rpm:    Double
        public let minRPM: Double
        public let maxRPM: Double
        public let target: Double
        public let manual: Bool
    }

    public enum FanControlError: LocalizedError
    {
        case cancelled
        case failed( String )

        public var errorDescription: String?
        {
            switch self
            {
                case .cancelled:           return "The operation was cancelled."
                case .failed( let text ):  return text
            }
        }
    }

    private init()
    {}

    public static var fanCount: Int
    {
        Int( self.uint8( "FNum" ) ?? 0 )
    }

    public static func fans() -> [ Fan ]
    {
        ( 0 ..< self.fanCount ).compactMap
        {
            index in

            guard let rpm = self.float( "F\( index )Ac" )
            else
            {
                return nil
            }

            return Fan(
                index:  index,
                rpm:    rpm,
                minRPM: self.float( "F\( index )Mn" )     ?? 0,
                maxRPM: self.float( "F\( index )Mx" )     ?? 0,
                target: self.float( "F\( index )Tg" )     ?? 0,
                manual: ( self.uint8( "F\( index )md" )   ?? 0 ) != 0
            )
        }
    }

    /*
     * Applies a fan setting by re-executing the app's own binary with the
     * `--fan-helper` flag through AppleScript's administrator authorization.
     * Pass nil to restore automatic fan management, or a percentage (0-100)
     * of the fan's RPM range to force a fixed speed.
     */
    public static func apply( percent: Int?, completion: @escaping ( Error? ) -> Void )
    {
        DispatchQueue.global( qos: .userInitiated ).async
        {
            let error = self.applySynchronously( percent: percent )

            DispatchQueue.main.async { completion( error ) }
        }
    }

    public static func applySynchronously( percent: Int? ) -> Error?
    {
        guard let executable = Bundle.main.executablePath
        else
        {
            return FanControlError.failed( "Cannot locate the application executable." )
        }

        let argument = percent.map { String( $0 ) } ?? "auto"
        let shell    = "\( self.shellQuoted( executable ) ) --fan-helper \( argument )"
        let script   = "do shell script \( self.appleScriptQuoted( shell ) ) with administrator privileges with prompt \( self.appleScriptQuoted( "Hot needs an administrator password to change fan settings." ) )"

        let process            = Process()
        let stderrPipe         = Pipe()
        process.launchPath     = "/usr/bin/osascript"
        process.arguments      = [ "-e", script ]
        process.standardError  = stderrPipe
        process.standardOutput = Pipe()

        do
        {
            try process.run()
        }
        catch
        {
            return error
        }

        process.waitUntilExit()

        if process.terminationStatus == 0
        {
            return nil
        }

        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String( data: data, encoding: .utf8 ) ?? ""

        if text.contains( "-128" )
        {
            return FanControlError.cancelled
        }

        return FanControlError.failed( text.trimmingCharacters( in: .whitespacesAndNewlines ) )
    }

    private static func float( _ key: String ) -> Double?
    {
        guard let value = SMC.shared.readKeyNamed( key )?.value as? Float
        else
        {
            return nil
        }

        return Double( value )
    }

    private static func uint8( _ key: String ) -> UInt8?
    {
        SMC.shared.readKeyNamed( key )?.value as? UInt8
    }

    private static func shellQuoted( _ string: String ) -> String
    {
        "'" + string.replacingOccurrences( of: "'", with: "'\\''" ) + "'"
    }

    private static func appleScriptQuoted( _ string: String ) -> String
    {
        "\"" + string.replacingOccurrences( of: "\\", with: "\\\\" ).replacingOccurrences( of: "\"", with: "\\\"" ) + "\""
    }
}
