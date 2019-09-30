/*******************************************************************************

        Copyright:
            Copyright (c) 2004 Kris Bell.
            Some parts copyright (c) 2009-2016 dunnhumby Germany GmbH.
            All rights reserved.

        License:
            Tango Dual License: 3-Clause BSD License / Academic Free License v3.0.
            See LICENSE_TANGO.txt for details.

        Version: Initial release: May 2004

        Authors: Kris Bell

*******************************************************************************/

module ocean.util.log.AppendConsole;

import ocean.transition;
import ocean.util.log.Appender;
import ocean.util.log.Event;

/*******************************************************************************

        Appender for sending formatted output to the console

*******************************************************************************/

public class AppendConsole : Appender
{
    private Mask mask_;

    /***********************************************************************

      Create with the given layout

     ***********************************************************************/

    this ()
    {
        this.mask_ = register(name);
    }

    /***********************************************************************

      Return the name of this class

     ***********************************************************************/

    override istring name ()
    {
        return this.classinfo.name;
    }

    /// Return the fingerprint for this class
    final override Mask mask ()
    {
        return this.mask_;
    }

    /// Append an event to the output.
    final override void append (LogEvent event)
    {
        import std.stdio: write, writeln;
        this.layout.format(event, (in cstring content) { write(content); });
        writeln();
    }
}
