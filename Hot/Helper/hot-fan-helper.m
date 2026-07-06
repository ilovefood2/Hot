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
 * Standalone privileged fan-control helper for Hot.
 *
 * This is a self-contained command-line tool (no framework dependencies) so it
 * can be installed to a root-owned location and run through a passwordless
 * sudoers rule. It writes the SMC fan keys directly:
 *
 *   hot-fan-helper auto    Restore automatic (SMC-controlled) fan management
 *   hot-fan-helper <pct>   Force all fans to <pct>% of their RPM range
 *
 * It must run as root; the SMC rejects key writes from unprivileged processes.
 */

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

#pragma clang diagnostic ignored "-Wfour-char-constants"

/* Layout defined by AppleSMC.kext - do not modify. */
enum { kSMCUserClientOpen = 0, kSMCUserClientClose = 1, kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCWriteKey = 6, kSMCGetKeyInfo = 9 };
enum { kSMCSuccess = 0 };

typedef struct { unsigned char major; unsigned char minor; unsigned char build; unsigned char reserved; unsigned short release; } SMCVersion;
typedef struct { uint16_t version; uint16_t length; uint32_t cpuPLimit; uint32_t gpuPLimit; uint32_t memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfoData;
typedef struct
{
    uint32_t       key;
    SMCVersion     vers;
    SMCPLimitData  pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t        result;
    uint8_t        status;
    uint8_t        data8;
    uint32_t       data32;
    uint8_t        bytes[ 32 ];
}
SMCParamStruct;

static io_connect_t gConnection = IO_OBJECT_NULL;

static BOOL SMCOpen( void )
{
    io_service_t service = IOServiceGetMatchingService( kIOMasterPortDefault, IOServiceMatching( "AppleSMC" ) );

    if( service == IO_OBJECT_NULL )
    {
        return NO;
    }

    kern_return_t result = IOServiceOpen( service, mach_task_self(), 0, &gConnection );

    IOObjectRelease( service );

    return result == kIOReturnSuccess && gConnection != IO_OBJECT_NULL;
}

static BOOL SMCCall( uint32_t function, const SMCParamStruct * input, SMCParamStruct * output )
{
    size_t size = sizeof( SMCParamStruct );

    if( IOConnectCallMethod( gConnection, kSMCUserClientOpen, NULL, 0, NULL, 0, NULL, NULL, NULL, NULL ) != kIOReturnSuccess )
    {
        return NO;
    }

    kern_return_t result = IOConnectCallStructMethod( gConnection, function, input, size, output, &size );

    IOConnectCallMethod( gConnection, kSMCUserClientClose, NULL, 0, NULL, 0, NULL, NULL, NULL, NULL );

    return result == kIOReturnSuccess;
}

static BOOL SMCKeyInfo( uint32_t key, SMCKeyInfoData * info )
{
    SMCParamStruct input;
    SMCParamStruct output;

    bzero( &input, sizeof( input ) );
    bzero( &output, sizeof( output ) );

    input.key   = key;
    input.data8 = kSMCGetKeyInfo;

    if( SMCCall( kSMCHandleYPCEvent, &input, &output ) == NO || output.result != kSMCSuccess )
    {
        return NO;
    }

    *( info ) = output.keyInfo;

    return YES;
}

static BOOL SMCReadKey( uint32_t key, uint8_t * buffer, uint32_t * size )
{
    SMCKeyInfoData info;

    if( SMCKeyInfo( key, &info ) == NO || info.dataSize > *( size ) )
    {
        return NO;
    }

    SMCParamStruct input;
    SMCParamStruct output;

    bzero( &input, sizeof( input ) );
    bzero( &output, sizeof( output ) );

    input.key              = key;
    input.data8            = kSMCReadKey;
    input.keyInfo.dataSize = info.dataSize;

    if( SMCCall( kSMCHandleYPCEvent, &input, &output ) == NO || output.result != kSMCSuccess )
    {
        return NO;
    }

    for( uint32_t i = 0; i < info.dataSize; i++ )
    {
        buffer[ i ] = output.bytes[ info.dataSize - ( i + 1 ) ];
    }

    *( size ) = info.dataSize;

    return YES;
}

static BOOL SMCWriteKey( uint32_t key, const uint8_t * buffer, uint32_t size )
{
    SMCKeyInfoData info;

    if( SMCKeyInfo( key, &info ) == NO || info.dataSize != size )
    {
        return NO;
    }

    SMCParamStruct input;
    SMCParamStruct output;

    bzero( &input, sizeof( input ) );
    bzero( &output, sizeof( output ) );

    input.key              = key;
    input.data8            = kSMCWriteKey;
    input.keyInfo.dataSize = info.dataSize;

    for( uint32_t i = 0; i < info.dataSize; i++ )
    {
        input.bytes[ i ] = buffer[ info.dataSize - ( i + 1 ) ];
    }

    return SMCCall( kSMCHandleYPCEvent, &input, &output ) && output.result == kSMCSuccess;
}

static uint32_t SMCKeyCode( const char * name )
{
    return ( uint32_t )( ( ( uint8_t )name[ 0 ] << 24 ) | ( ( uint8_t )name[ 1 ] << 16 ) | ( ( uint8_t )name[ 2 ] << 8 ) | ( uint8_t )name[ 3 ] );
}

static BOOL SMCReadFloat( const char * name, float * value )
{
    uint8_t  buffer[ 32 ];
    uint32_t size = sizeof( buffer );

    if( SMCReadKey( SMCKeyCode( name ), buffer, &size ) == NO || size != 4 )
    {
        return NO;
    }

    uint32_t u = ( ( uint32_t )buffer[ 0 ] << 24 ) | ( ( uint32_t )buffer[ 1 ] << 16 ) | ( ( uint32_t )buffer[ 2 ] << 8 ) | ( uint32_t )buffer[ 3 ];

    memcpy( value, &u, sizeof( u ) );

    return YES;
}

static BOOL SMCWriteFloat( const char * name, float value )
{
    uint32_t u;

    memcpy( &u, &value, sizeof( u ) );

    uint8_t bytes[ 4 ] = { ( uint8_t )( u >> 24 ), ( uint8_t )( u >> 16 ), ( uint8_t )( u >> 8 ), ( uint8_t )u };

    return SMCWriteKey( SMCKeyCode( name ), bytes, 4 );
}

static BOOL SMCWriteUInt8( const char * name, uint8_t value )
{
    return SMCWriteKey( SMCKeyCode( name ), &value, 1 );
}

int main( int argc, const char * argv[] )
{
    @autoreleasepool
    {
        if( argc != 2 )
        {
            fprintf( stderr, "Usage: hot-fan-helper <auto|0-100>\n" );

            return 2;
        }

        BOOL isAuto  = strcmp( argv[ 1 ], "auto" ) == 0;
        int  percent = atoi( argv[ 1 ] );

        if( isAuto == NO && ( percent < 0 || percent > 100 || ( percent == 0 && strcmp( argv[ 1 ], "0" ) != 0 ) ) )
        {
            fprintf( stderr, "Usage: hot-fan-helper <auto|0-100>\n" );

            return 2;
        }

        if( SMCOpen() == NO )
        {
            fprintf( stderr, "Cannot open the SMC.\n" );

            return 1;
        }

        uint8_t  fanCount = 0;
        uint32_t size     = sizeof( fanCount );

        if( SMCReadKey( SMCKeyCode( "FNum" ), &fanCount, &size ) == NO || fanCount == 0 )
        {
            fprintf( stderr, "No fans found (FNum unavailable).\n" );

            return 1;
        }

        for( uint8_t i = 0; i < fanCount; i++ )
        {
            char modeKey[ 5 ];
            char targetKey[ 5 ];

            snprintf( modeKey,   sizeof( modeKey ),   "F%umd", ( unsigned )i );
            snprintf( targetKey, sizeof( targetKey ), "F%uTg", ( unsigned )i );

            if( isAuto )
            {
                if( SMCWriteUInt8( modeKey, 0 ) == NO )
                {
                    fprintf( stderr, "Fan %u: failed to restore automatic control (need root).\n", ( unsigned )i );

                    return 1;
                }
            }
            else
            {
                char minKey[ 5 ];
                char maxKey[ 5 ];

                snprintf( minKey, sizeof( minKey ), "F%uMn", ( unsigned )i );
                snprintf( maxKey, sizeof( maxKey ), "F%uMx", ( unsigned )i );

                float min = 0;
                float max = 0;

                if( SMCReadFloat( minKey, &min ) == NO || SMCReadFloat( maxKey, &max ) == NO || max <= min )
                {
                    fprintf( stderr, "Fan %u: cannot read RPM range.\n", ( unsigned )i );

                    return 1;
                }

                float target = min + ( ( max - min ) * ( float )percent ) / 100.0f;

                if( SMCWriteFloat( targetKey, target ) == NO || SMCWriteUInt8( modeKey, 1 ) == NO )
                {
                    fprintf( stderr, "Fan %u: failed to set target (need root).\n", ( unsigned )i );

                    return 1;
                }
            }
        }

        return 0;
    }
}
