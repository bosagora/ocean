/*******************************************************************************

        Copyright:
            Copyright (c) 2007 Kris Bell.
            Some parts copyright (c) 2009-2016 dunnhumby Germany GmbH.
            All rights reserved.

        License:
            Tango Dual License: 3-Clause BSD License / Academic Free License v3.0.
            See LICENSE_TANGO.txt for details.

        Version: Feb 2007: Initial release

        Authors: Kris

*******************************************************************************/

module ocean.time.Clock;

import Phobos = std.datetime;
import ocean.core.ExceptionDefinitions;
public import ocean.time.Time;

version (unittest) import ocean.core.Test;

/******************************************************************************

        Exposes UTC time relative to Jan 1st, 1 AD. These values are
        based upon a clock-tick of 100ns, giving them a span of greater
        than 10,000 years. These units of time are the foundation of most
        time and date functionality in Tango contributors.

        Interval is another type of time period, used for measuring a
        much shorter duration; typically used for timeout periods and
        for high-resolution timers. These intervals are measured in
        units of 1 second, and support fractional units (0.001 = 1ms).

*******************************************************************************/

struct Clock
{
        /// Time at which the program started
        private static Time start_time_;

        /// Returns: Time at which the application started
        public static Time startTime ()
        {
            return start_time_;
        }

        static this ()
        {
            start_time_ = Clock.now;
        }

        // copied from Gregorian.  Used while we rely on OS for toDate.
        package static uint[] DaysToMonthCommon = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365];
        package static void setDoy(ref DateTime dt)
        {
            uint doy = dt.date.day + DaysToMonthCommon[dt.date.month - 1];
            uint year = dt.date.year;

            if(dt.date.month > 2 && (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)))
                doy++;

            dt.date.doy = doy;
        }


    /***************************************************************************

        Returns:
            the current time as UTC since the epoch

    ***************************************************************************/

    static Time now ()
    {
        return Time(Phobos.Clock.currTime().stdTime);
    }

    /***************************************************************************

        Set Date fields to represent the current time.

    ***************************************************************************/

    static DateTime toDate ()
    {
        return toDate(now);
    }

    /***************************************************************************

        Set fields to represent the provided time.

        Note that the conversion is limited by the underlying OS, and will fail
        to operate correctly with Time values beyond the domain, which is
        01-01-1970 on Linux.
        Date is limited to millisecond accuracy at best.

    ***************************************************************************/

    static DateTime toDate (Time time, immutable Phobos.TimeZone tz = Phobos.UTC())
    {
        DateTime dt = void;
        Phobos.SysTime st = Phobos.SysTime(time.ticks(), tz);

        dt.date.year    = st.year;
        dt.date.month   = st.month; // +1 ?
        dt.date.day     = st.day;
        dt.date.dow     = st.dayOfWeek;
        dt.date.doy     = st.dayOfYear;
        dt.date.era     = 0;
        dt.time.hours   = st.hour;
        dt.time.minutes = st.minute;
        dt.time.seconds = st.second;
        dt.time.millis  = cast(uint) st.fracSecs.total!"msecs";

        return dt;
    }
}
