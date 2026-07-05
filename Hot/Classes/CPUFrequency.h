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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * Reports the current active-core CPU frequency on Apple Silicon.
 *
 * There is no public API and no sysctl for the live CPU clock on Apple
 * Silicon, so this samples per-core P-state residencies through the private
 * IOReport framework (resolved at runtime via dlopen, so nothing private is
 * linked) and weights them against the per-cluster frequency tables read from
 * the "pmgr" device-tree node. The result is the average frequency of the
 * cores that were active between two successive samples.
 */
@interface CPUFrequency: NSObject

@property( class, nonatomic, readonly ) CPUFrequency * shared;

/*
 * Average frequency (in MHz) of the active cores over the interval since the
 * previous call. Returns 0 if unavailable (e.g. non-Apple-Silicon, or all
 * cores idle for the whole interval, or on the very first call).
 */
- ( double )sampleMHz;

@end

NS_ASSUME_NONNULL_END
