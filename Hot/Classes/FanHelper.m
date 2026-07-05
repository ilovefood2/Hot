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

/*
 * Privileged fan-control helper.
 *
 * When the Hot executable is invoked with `--fan-helper <auto|0-100>`, this
 * constructor runs before NSApplicationMain, performs the requested SMC fan
 * writes, and exits - so the app can re-exec itself with administrator
 * privileges (via AppleScript) to control the fans without needing a
 * separate helper tool.
 *
 *   --fan-helper auto   Restore automatic (SMC-controlled) fan management
 *   --fan-helper <pct>  Force all fans to <pct>% of their RPM range
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

@import SMCKit;

/*
 * Captures one of the app's own windows (e.g. an open menu) to a PNG file.
 * Capturing windows belonging to the current process does not require the
 * screen-recording permission. Used by the hidden `--demo-menu` flag to
 * produce the README screenshots.
 */
BOOL HotDemoCaptureWindow( uint32_t windowID, NSString * path );

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
BOOL HotDemoCaptureWindow( uint32_t windowID, NSString * path )
{
    CGImageRef image = CGWindowListCreateImage( CGRectNull, kCGWindowListOptionIncludingWindow, windowID, kCGWindowImageBoundsIgnoreFraming );

    if( image == NULL )
    {
        return NO;
    }

    NSURL                * url         = [ NSURL fileURLWithPath: path ];
    CGImageDestinationRef destination  = CGImageDestinationCreateWithURL( ( __bridge CFURLRef )url, ( __bridge CFStringRef )@"public.png", 1, NULL );

    if( destination == NULL )
    {
        CGImageRelease( image );

        return NO;
    }

    CGImageDestinationAddImage( destination, image, NULL );

    BOOL success = CGImageDestinationFinalize( destination ) ? YES : NO;

    CFRelease( destination );
    CGImageRelease( image );

    return success;
}
#pragma clang diagnostic pop

#pragma clang diagnostic ignored "-Wglobal-constructors"

static NSString * HotFanHelperErrorText( NSError * error )
{
    if( error.localizedRecoverySuggestion != nil )
    {
        return error.localizedRecoverySuggestion;
    }

    return error.localizedDescription;
}

static BOOL HotFanHelperReadFloat( NSString * key, float * value )
{
    uint8_t  buffer[ 32 ];
    uint32_t size = sizeof( buffer );

    if( [ SMC.shared readKeyNamed: key buffer: buffer maxSize: &size ] == NO || size != 4 )
    {
        return NO;
    }

    uint32_t u = ( ( uint32_t )buffer[ 0 ] << 24 )
               | ( ( uint32_t )buffer[ 1 ] << 16 )
               | ( ( uint32_t )buffer[ 2 ] <<  8 )
               | ( ( uint32_t )buffer[ 3 ] <<  0 );

    memcpy( value, &u, sizeof( u ) );

    return YES;
}

static BOOL HotFanHelperWriteFloat( NSString * key, float value, NSError * __autoreleasing * error )
{
    uint32_t u;

    memcpy( &u, &value, sizeof( u ) );

    uint8_t bytes[ 4 ] =
    {
        ( uint8_t )( ( u >> 24 ) & 0xFF ),
        ( uint8_t )( ( u >> 16 ) & 0xFF ),
        ( uint8_t )( ( u >>  8 ) & 0xFF ),
        ( uint8_t )( ( u >>  0 ) & 0xFF ),
    };

    return [ SMC.shared writeKeyNamed: key data: [ NSData dataWithBytes: bytes length: 4 ] error: error ];
}

static BOOL HotFanHelperWriteUInt8( NSString * key, uint8_t value, NSError * __autoreleasing * error )
{
    return [ SMC.shared writeKeyNamed: key data: [ NSData dataWithBytes: &value length: 1 ] error: error ];
}

__attribute__( ( noreturn ) )
static void HotFanHelperExit( int status, NSString * message )
{
    fprintf( status == 0 ? stdout : stderr, "%s\n", message.UTF8String );
    exit( status );
}

__attribute__( ( constructor ) )
static void HotFanHelperMain( void )
{
    @autoreleasepool
    {
        NSArray< NSString * > * args  = NSProcessInfo.processInfo.arguments;
        NSUInteger              index = [ args indexOfObject: @"--fan-helper" ];

        if( index == NSNotFound )
        {
            return;
        }

        if( index + 1 >= args.count )
        {
            HotFanHelperExit( 2, @"Usage: Hot --fan-helper <auto|0-100>" );
        }

        NSString * mode    = args[ index + 1 ];
        BOOL       isAuto  = [ mode isEqualToString: @"auto" ];
        int        percent = mode.intValue;

        if( isAuto == NO && ( percent < 0 || percent > 100 || ( percent == 0 && [ mode isEqualToString: @"0" ] == NO ) ) )
        {
            HotFanHelperExit( 2, @"Usage: Hot --fan-helper <auto|0-100>" );
        }

        uint8_t  fanCount = 0;
        uint32_t size     = sizeof( fanCount );

        if( [ SMC.shared readKeyNamed: @"FNum" buffer: &fanCount maxSize: &size ] == NO || fanCount == 0 )
        {
            HotFanHelperExit( 1, @"No fans found (FNum unavailable). This machine may be fanless." );
        }

        for( uint8_t i = 0; i < fanCount; i++ )
        {
            NSString * modeKey   = [ NSString stringWithFormat: @"F%umd", ( unsigned )i ];
            NSString * targetKey = [ NSString stringWithFormat: @"F%uTg", ( unsigned )i ];
            NSError  * error     = nil;

            if( isAuto )
            {
                if( HotFanHelperWriteUInt8( modeKey, 0, &error ) == NO )
                {
                    HotFanHelperExit( 1, [ NSString stringWithFormat: @"Fan %u: %@", ( unsigned )i, HotFanHelperErrorText( error ) ] );
                }
            }
            else
            {
                float min = 0;
                float max = 0;

                if( HotFanHelperReadFloat( [ NSString stringWithFormat: @"F%uMn", ( unsigned )i ], &min ) == NO
                 || HotFanHelperReadFloat( [ NSString stringWithFormat: @"F%uMx", ( unsigned )i ], &max ) == NO
                 || max <= min )
                {
                    HotFanHelperExit( 1, [ NSString stringWithFormat: @"Fan %u: cannot read RPM range.", ( unsigned )i ] );
                }

                float target = min + ( ( max - min ) * ( float )percent ) / 100.0f;

                if( HotFanHelperWriteFloat( targetKey, target, &error ) == NO
                 || HotFanHelperWriteUInt8( modeKey, 1, &error ) == NO )
                {
                    HotFanHelperExit( 1, [ NSString stringWithFormat: @"Fan %u: %@", ( unsigned )i, HotFanHelperErrorText( error ) ] );
                }

                fprintf( stdout, "Fan %u: target %.0f RPM\n", ( unsigned )i, ( double )target );
            }
        }

        HotFanHelperExit( 0, isAuto ? @"Fans restored to automatic control." : @"Fan targets applied." );
    }
}
