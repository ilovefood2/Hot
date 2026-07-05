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

#import "CPUFrequency.h"

#import <dlfcn.h>

@import IOKit;

typedef struct IOReportSubscription * IOReportSubscriptionRef;

typedef CFMutableDictionaryRef  ( *IOReportCopyChannelsInGroup_f )( CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t );
typedef IOReportSubscriptionRef ( *IOReportCreateSubscription_f  )( void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef );
typedef CFDictionaryRef         ( *IOReportCreateSamples_f       )( IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef );
typedef CFDictionaryRef         ( *IOReportCreateSamplesDelta_f  )( CFDictionaryRef, CFDictionaryRef, CFTypeRef );
typedef CFStringRef             ( *IOReportChannelGetString_f    )( CFDictionaryRef );
typedef int                     ( *IOReportStateGetCount_f       )( CFDictionaryRef );
typedef uint64_t                ( *IOReportStateGetResidency_f   )( CFDictionaryRef, int );
typedef void                    ( *IOReportIterate_f             )( CFDictionaryRef, int ( ^ )( CFDictionaryRef ) );

@interface CPUFrequency()

@property( nonatomic, readwrite, assign ) BOOL                          available;
@property( nonatomic, readwrite, assign ) IOReportSubscriptionRef       subscription;
@property( nonatomic, readwrite, assign ) CFMutableDictionaryRef        subscribedChannels;
@property( nonatomic, readwrite, assign ) CFDictionaryRef               previousSample;

/* Per-cluster frequency tables (arrays of MHz), keyed by their active-state count. */
@property( nonatomic, readwrite, strong ) NSDictionary< NSNumber *, NSArray< NSNumber * > * > * frequencyTables;

@property( nonatomic, readwrite, assign ) IOReportCopyChannelsInGroup_f copyChannelsInGroup;
@property( nonatomic, readwrite, assign ) IOReportCreateSubscription_f  createSubscription;
@property( nonatomic, readwrite, assign ) IOReportCreateSamples_f       createSamples;
@property( nonatomic, readwrite, assign ) IOReportCreateSamplesDelta_f  createSamplesDelta;
@property( nonatomic, readwrite, assign ) IOReportChannelGetString_f    getSubGroup;
@property( nonatomic, readwrite, assign ) IOReportStateGetCount_f       stateGetCount;
@property( nonatomic, readwrite, assign ) IOReportStateGetResidency_f   stateGetResidency;
@property( nonatomic, readwrite, assign ) IOReportIterate_f             iterate;

@end

@implementation CPUFrequency

+ ( CPUFrequency * )shared
{
    static dispatch_once_t once;
    static CPUFrequency  * instance;

    dispatch_once( &once, ^( void ){ instance = [ CPUFrequency new ]; } );

    return instance;
}

- ( instancetype )init
{
    if( ( self = [ super init ] ) )
    {
        [ self setup ];
    }

    return self;
}

- ( void )setup
{
    self.frequencyTables = [ self readFrequencyTables ];

    if( self.frequencyTables.count == 0 )
    {
        return;
    }

    void * handle = dlopen( "/usr/lib/libIOReport.dylib", RTLD_NOW );

    if( handle == NULL )
    {
        return;
    }

    /* dlsym returns void *; converting it to a function pointer is well
     * defined on this platform but flagged by -Wpedantic, so silence it here. */
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wpedantic"
    self.copyChannelsInGroup = ( IOReportCopyChannelsInGroup_f )dlsym( handle, "IOReportCopyChannelsInGroup" );
    self.createSubscription  = ( IOReportCreateSubscription_f  )dlsym( handle, "IOReportCreateSubscription" );
    self.createSamples       = ( IOReportCreateSamples_f       )dlsym( handle, "IOReportCreateSamples" );
    self.createSamplesDelta  = ( IOReportCreateSamplesDelta_f  )dlsym( handle, "IOReportCreateSamplesDelta" );
    self.getSubGroup         = ( IOReportChannelGetString_f    )dlsym( handle, "IOReportChannelGetSubGroup" );
    self.stateGetCount       = ( IOReportStateGetCount_f       )dlsym( handle, "IOReportStateGetCount" );
    self.stateGetResidency   = ( IOReportStateGetResidency_f   )dlsym( handle, "IOReportStateGetResidency" );
    self.iterate             = ( IOReportIterate_f             )dlsym( handle, "IOReportIterate" );
    #pragma clang diagnostic pop

    if
    (
           self.copyChannelsInGroup == NULL || self.createSubscription == NULL
        || self.createSamples       == NULL || self.createSamplesDelta == NULL
        || self.getSubGroup         == NULL || self.stateGetCount      == NULL
        || self.stateGetResidency   == NULL || self.iterate            == NULL
    )
    {
        return;
    }

    CFMutableDictionaryRef  channels    = self.copyChannelsInGroup( CFSTR( "CPU Stats" ), NULL, 0, 0, 0 );

    if( channels == NULL )
    {
        return;
    }

    CFMutableDictionaryRef  subscribed  = NULL;
    IOReportSubscriptionRef subscription = self.createSubscription( NULL, channels, &subscribed, 0, NULL );

    CFRelease( channels );

    if( subscription == NULL || subscribed == NULL )
    {
        return;
    }

    self.subscription       = subscription;
    self.subscribedChannels = subscribed;
    self.available          = YES;
}

/*
 * Reads all "voltage-states*-sram" frequency tables from the pmgr device-tree
 * node. Those blobs are arrays of (frequency-in-kHz, voltage) 32-bit pairs.
 * Tables are keyed by their entry count so they can later be matched to an
 * IOReport cluster channel by its number of active P-states.
 */
- ( NSDictionary< NSNumber *, NSArray< NSNumber * > * > * )readFrequencyTables
{
    NSMutableDictionary * tables = [ NSMutableDictionary new ];
    io_registry_entry_t   entry  = IOServiceGetMatchingService( kIOMasterPortDefault, IOServiceNameMatching( "pmgr" ) );

    if( entry == IO_OBJECT_NULL )
    {
        return tables;
    }

    CFMutableDictionaryRef properties = NULL;

    if( IORegistryEntryCreateCFProperties( entry, &properties, kCFAllocatorDefault, 0 ) == KERN_SUCCESS && properties != NULL )
    {
        NSDictionary * dict = ( __bridge NSDictionary * )properties;

        for( NSString * key in dict )
        {
            if( [ key isKindOfClass: NSString.class ] == NO )                        { continue; }
            if( [ key hasPrefix: @"voltage-states" ] == NO )                         { continue; }
            if( [ key hasSuffix: @"-sram" ]          == NO )                         { continue; }

            NSData * data = dict[ key ];

            if( [ data isKindOfClass: NSData.class ] == NO || data.length < 8 )      { continue; }

            NSUInteger        count    = data.length / 8;
            const uint32_t  * words     = data.bytes;
            NSMutableArray  * megahertz = [ NSMutableArray new ];
            BOOL              valid      = YES;

            for( NSUInteger i = 0; i < count; i++ )
            {
                uint32_t kHz = words[ i * 2 ];

                /* CPU frequency tables are in kHz (>= 1 GHz here); reject the
                 * encoded, non-kHz variants that share the voltage-states name. */
                if( kHz < 100000 )
                {
                    valid = NO;

                    break;
                }

                [ megahertz addObject: @( ( double )kHz / 1000.0 ) ];
            }

            if( valid && megahertz.count > 0 )
            {
                tables[ @( megahertz.count ) ] = megahertz;
            }
        }

        CFRelease( properties );
    }

    IOObjectRelease( entry );

    return tables;
}

- ( double )sampleMHz
{
    if( self.available == NO )
    {
        return 0;
    }

    CFDictionaryRef current = self.createSamples( self.subscription, self.subscribedChannels, NULL );

    if( current == NULL )
    {
        return 0;
    }

    if( self.previousSample == NULL )
    {
        self.previousSample = current;

        return 0;
    }

    CFDictionaryRef delta = self.createSamplesDelta( self.previousSample, current, NULL );

    CFRelease( self.previousSample );
    self.previousSample = current;

    if( delta == NULL )
    {
        return 0;
    }

    __block double weightedSum   = 0;
    __block double totalResidency = 0;

    IOReportStateGetCount_f     getCount     = self.stateGetCount;
    IOReportStateGetResidency_f getResidency = self.stateGetResidency;
    IOReportChannelGetString_f  getSubGroup  = self.getSubGroup;
    NSDictionary              * tables        = self.frequencyTables;

    self.iterate( delta, ^int ( CFDictionaryRef channel )
    {
        NSString * subGroup = ( __bridge NSString * )getSubGroup( channel );

        /* Per-core channels only, to avoid double-counting the complex aggregates. */
        if( [ subGroup isEqualToString: @"CPU Core Performance States" ] == NO )
        {
            return 0;
        }

        int                     count  = getCount( channel );
        int                     active = count - 2;                 /* minus DOWN and IDLE */
        NSArray< NSNumber * > * table   = tables[ @( active ) ];

        if( table == nil || table.count != ( NSUInteger )active )
        {
            return 0;
        }

        for( int i = 2; i < count; i++ )
        {
            uint64_t rawResidency = getResidency( channel, i );
            double   residency     = ( double )rawResidency;
            double   frequency      = table[ ( NSUInteger )( i - 2 ) ].doubleValue;

            weightedSum    += residency * frequency;
            totalResidency += residency;
        }

        return 0;
    } );

    CFRelease( delta );

    if( totalResidency <= 0 )
    {
        return 0;
    }

    return weightedSum / totalResidency;
}

@end
