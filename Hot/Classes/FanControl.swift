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

    /* Root-owned helper and the passwordless sudoers rule that authorizes it. */
    private static let helperPath  = "/Library/PrivilegedHelperTools/hot-fan-helper"
    private static let sudoersPath = "/etc/sudoers.d/hot-fan-control"

    private static var bundledHelperPath: String
    {
        Bundle.main.bundleURL.appendingPathComponent( "Contents/Helpers/hot-fan-helper" ).path
    }

    /* True once the privileged helper has been installed on this machine. */
    public static var isHelperInstalled: Bool
    {
        FileManager.default.fileExists( atPath: self.helperPath )
    }

    /*
     * Applies a fan setting only if the helper is already authorized, without
     * ever prompting or installing. Used by the Auto Boost engine so its
     * automatic, periodic adjustments never trigger a password dialog.
     * Returns true if the setting was applied as root.
     */
    @discardableResult
    public static func applyAuthorizedOnly( percent: Int? ) -> Bool
    {
        let argument = percent.map { String( $0 ) } ?? "auto"

        return self.runHelperPasswordless( argument: argument ).ranAsRoot
    }

    /*
     * Applies a fan setting through the privileged helper.
     *
     * The helper runs as root via a passwordless sudoers rule, so once it has
     * been installed no password is required. The first call (or any call after
     * the rule was removed) performs a one-time install that prompts for an
     * administrator password. Pass nil to restore automatic fan management, or
     * a percentage (0-100) of the fan's RPM range to force a fixed speed.
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
        let argument = percent.map { String( $0 ) } ?? "auto"

        /* Fast path: the helper is already authorized, so no prompt appears. */
        let first = self.runHelperPasswordless( argument: argument )

        if first.ranAsRoot
        {
            return first.error
        }

        /* Not authorized yet - install the helper and sudoers rule (one prompt). */
        if let installError = self.installHelper()
        {
            return installError
        }

        let second = self.runHelperPasswordless( argument: argument )

        if second.ranAsRoot
        {
            return second.error
        }

        return FanControlError.failed( second.error?.localizedDescription ?? "The fan helper could not be authorized." )
    }

    /*
     * Runs the installed helper through `sudo -n` (never prompts). Returns
     * whether sudo actually executed the helper as root, plus any error the
     * helper itself reported. If sudo would need a password, ranAsRoot is false.
     */
    private static func runHelperPasswordless( argument: String ) -> ( ranAsRoot: Bool, error: Error? )
    {
        if FileManager.default.fileExists( atPath: self.helperPath ) == false
        {
            return ( false, nil )
        }

        let process            = Process()
        let stderrPipe         = Pipe()
        process.launchPath     = "/usr/bin/sudo"
        process.arguments      = [ "-n", self.helperPath, argument ]
        process.standardError  = stderrPipe
        process.standardOutput = Pipe()

        do
        {
            try process.run()
        }
        catch
        {
            return ( false, error )
        }

        process.waitUntilExit()

        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String( data: data, encoding: .utf8 ) ?? ""

        /* sudo prints its own diagnostics ("sudo: a password is required",
         * "sudo: a terminal is required", "not allowed") when it declines to
         * run - meaning the rule is missing and we must (re)install. */
        if process.terminationStatus != 0, text.contains( "sudo:" )
        {
            return ( false, nil )
        }

        if process.terminationStatus == 0
        {
            return ( true, nil )
        }

        return ( true, FanControlError.failed( text.trimmingCharacters( in: .whitespacesAndNewlines ) ) )
    }

    /*
     * One-time privileged install: copies the bundled helper to a root-owned
     * location and adds a sudoers rule allowing the current user to run only
     * that helper without a password. Prompts once for an administrator
     * password via AppleScript.
     */
    private static func installHelper() -> Error?
    {
        let source = self.bundledHelperPath

        guard FileManager.default.fileExists( atPath: source )
        else
        {
            return FanControlError.failed( "The bundled fan helper is missing from the application." )
        }

        let user    = NSUserName()
        let rule     = "\( user ) ALL=(root) NOPASSWD: \( self.helperPath )"
        let tmpRule  = "\( self.sudoersPath ).new"

        let commands =
        [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/cp \( self.shellQuoted( source ) ) \( self.shellQuoted( self.helperPath ) )",
            "/usr/sbin/chown root:wheel \( self.shellQuoted( self.helperPath ) )",
            "/bin/chmod 755 \( self.shellQuoted( self.helperPath ) )",
            "/usr/bin/xattr -c \( self.shellQuoted( self.helperPath ) ) || true",
            "/usr/bin/printf '%s\\n' \( self.shellQuoted( rule ) ) > \( self.shellQuoted( tmpRule ) )",
            "/usr/sbin/chown root:wheel \( self.shellQuoted( tmpRule ) )",
            "/bin/chmod 440 \( self.shellQuoted( tmpRule ) )",
            "/usr/sbin/visudo -cf \( self.shellQuoted( tmpRule ) )",
            "/bin/mv \( self.shellQuoted( tmpRule ) ) \( self.shellQuoted( self.sudoersPath ) )",
        ]

        let shell  = "set -e; " + commands.joined( separator: "; " )
        let script = "do shell script \( self.appleScriptQuoted( shell ) ) with administrator privileges with prompt \( self.appleScriptQuoted( "Hot needs an administrator password once to set up fan control." ) )"

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
