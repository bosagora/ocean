/*******************************************************************************

        Copyright:
            Copyright (c) 2007 Kris Bell.
            Some parts copyright (c) 2009-2016 dunnhumby Germany GmbH.
            All rights reserved.

        License:
            Tango Dual License: 3-Clause BSD License / Academic Free License v3.0.
            See LICENSE_TANGO.txt for details.

        Version: Apr 2007: split away from utc

        Authors: Kris

*******************************************************************************/

module ocean.time.WallClock;

import ocean.time.Clock;
public import ocean.time.Time;


/******************************************************************************

        Exposes wall-time relative to Jan 1st, 1 AD. These values are
        based upon a clock-tick of 100ns, giving them a span of greater
        than 10,000 years. These Units of time are the foundation of most
        time and date functionality in Tango contributors.

        Please note that conversion between UTC and Wall time is performed
        in accordance with the OS facilities.
        Posix system calculates based on a provided point in time).
        They should typically have the TZ environment variable set to
        a valid descriptor.

*******************************************************************************/

struct WallClock
{
    /***************************************************************************

        Returns
            the current local time

    ***************************************************************************/

    static Time now ()
    {
        tm t = void;
        timeval tv = void;
        gettimeofday (&tv, null);
        localtime_r (&tv.tv_sec, &t);
        tv.tv_sec = timegm (&t);
        return Clock.convert (tv);
    }

    /***************************************************************************

        Returns
            the timezone relative to GMT. The value is negative when west of GMT

    ***************************************************************************/

    static TimeSpan zone ()
    {
        return TimeSpan.fromSeconds(-timezone);
    }

    /***************************************************************************

        Set fields to represent a local version of the current UTC time

        All values must fall within the domain supported by the OS

    ***************************************************************************/

    static DateTime toDate ()
    {
        return toDate (Clock.now);
    }

    /***************************************************************************

        Set fields to represent a local version of the provided UTC time

        All values must fall within the domain supported by the OS

    ***************************************************************************/

    static DateTime toDate (Time utc)
    {
        return Clock.toDate(utc, null);
    }
}
