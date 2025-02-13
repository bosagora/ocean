/*******************************************************************************

    Lightweight, memory friendly string formatting module

    This module provides 4 possible semantics:
    - For pedestrian usage which doesn't care about allocations, see `format`
    - For allocation-friendly semantic where the data is output either to
      a sink or to a `ref char[]`, see the `sformat` overloads
    - To ensure absolutely no allocation happens, see `snformat`

    Users of Phobos' `std.format` will find many similarities in the API:
    - `format` is equivalent to `std.format.format`
    - `snformat` is equivalent to `std.format.sformat`
    - `sformat` is roughly equivalent to `std.format.formattedWrite`

    Format_specifier:

    The Formatter uses a format specification similar to C#/.NET over
    the traditional `printf` style.
    As a result, the most simple usage is to call:
    ---
    format("This value will be default formatted: {}", value);
    ---

    More specific formatting options are however available.

    The format specifier is defined as follows:

    '{'[INDEX][WIDTH_CHAR[ALIGN_LEFT_CHAR][ALIGN_WIDTH][' '*]][':'][FORMAT_STRING]'}'

    In more details:
    - `INDEX` is the positive, decimal and 0 based index of the argument
      to format.
    - `WIDTH_CHAR` is either ',' (comma) if a minimum width is requested,
      in which case the output will be padded with spaces,
      or '.' if a maximum width is requested, in which case the output will be
      cropped and cropping will be noted by the presence of "..."
    - `ALIGN_LEFT_CHAR` is '-'. If present, padding / cropping will be done
      on the left side of the string, otherwise it will be the right side
      This can only be used after a `WIDTH_CHAR`.
    - `ALIGN_WIDTH` is the positive, decimal width the argument should have.
    - ':' can optionally be used to separate the index / width specification
      from the format string. So `{}`, `{:}` and `{0:X}` are all valid.
    - `FORMAT_STRING` is an argument-defined format string

    Format_string:

    The format string defines how the argument will be formatted, and thus
    is dependent on the argument type.

    Currently the following formatting strings are supported:
        - 'X' or 'x' are used for hexadecimal formatting of the output.
          'X' outputs uppercase, 'x' will output lowercase.
          Applies to integer types and pointers, and will also output
          the hexadecimal.
        - 'e' for floating point type will display exponential notation.
          Using a number will set the precision, so for example the string
          `"{:2}"` with argument `0.123456` will output `"0.12"`
          Finally, '.' will prevent padding.
    Unrecognized formatting strings should be ignored. For composed types,
    the formatting string is passed along, so using `X` on a `struct` or an
    array will display any integer / pointer members in uppercase hexadecimal.

    Copyright:
        Copyright (c) 2009-2016 dunnhumby Germany GmbH.
        Some parts (marked explicitly) copyright Kris and/or Larsivi.
        All rights reserved.

    License:
        Tango Dual License: 3-Clause BSD License / Academic Free License v3.0.
        See LICENSE_TANGO.txt for details.

*******************************************************************************/

module ocean.text.convert.Formatter;

import ocean.meta.types.Qualifiers;
import ocean.core.Buffer;
import Integer = ocean.text.convert.Integer_tango;
import Float = ocean.text.convert.Float;
import UTF = ocean.text.convert.Utf;
import ocean.core.Verify;

import ocean.meta.traits.Basic;
import ocean.meta.types.Typedef;
import ocean.meta.types.Arrays;
import ocean.meta.codegen.Identifier;

/*******************************************************************************

    Type of 'sink' that can be passed to `format`, that will just format a
    string into the provided sink.

*******************************************************************************/

public alias void delegate(in cstring) @safe FormatterSink;

/*******************************************************************************

    Internal sink type that wraps the user-provided one and takes care
    of cropping and width

    This sink expects to receive a full element as the first parameter,
    in other words, the full chunk of text that needs a fixed size.
    This is why one cannot format a whole aggregate (struct, arrays etc.), but
    only individual elements.

*******************************************************************************/

private alias void delegate(cstring, ref const(FormatInfo)) @safe ElemSink;


/*******************************************************************************

    Formats an input string into a newly-allocated string and returns it

    Params:
        fmt     = Format string to use
        args    = Variadic arguments to format according to `fmt`

    Returns:
        A newly allocated, immutable formatted string

*******************************************************************************/

public istring format (Args...) (cstring fmt, Args args)
{
    import ocean.core.TypeConvert : assumeUnique;

    mstring buffer;

    scope FormatterSink sink = (in cstring s)
    {
        buffer ~= s;
    };

    sformat(sink, fmt, args);
    return assumeUnique(buffer);
}


/*******************************************************************************

    Append the processed (formatted) input onto the end of the provided buffer

    Params:
        buffer  = The buffer to which to append the formatted string; its
                  capacity will be increased if necessary
        fmt     = Format string to use
        args    = Variadic arguments to format according to `fmt`

    Returns:
        A reference to `buffer`

*******************************************************************************/

public mstring sformat (Args...) (ref mstring buffer, cstring fmt, Args args)
{
    scope FormatterSink sink = (in cstring s)
    {
        buffer ~= s;
    };
    sformat(sink, fmt, args);
    return buffer;
}

/// ditto
public mstring sformat (Args...) (ref Buffer!(char) buffer, cstring fmt, Args args)
{
    scope FormatterSink sink = (in cstring s) @trusted
    {
        buffer ~= s;
    };
    sformat(sink, fmt, args);
    return buffer[];
}

/*******************************************************************************

    Write the processed (formatted) input into a fixed-length buffer

    This function will not perform any allocation.
    If the output does not fit in `buffer`, the extra output will simply
    be discarded.

    Params:
        buffer  = The buffer to write the formatted string into.
                  Unlike the sformat overloads, the buffer won't be extended.
                  This leads to a slightly different semantic for this
                  buffer (the others are only appended to, this one is
                  written to).
        fmt     = Format string to use
        args    = Variadic arguments to format according to `fmt`

    Returns:
        A reference to `buffer`

*******************************************************************************/

public mstring snformat (Args...) (mstring buffer, cstring fmt, Args args)
{
    size_t start;

    scope FormatterSink sink = (in cstring s)
    {
        size_t left = buffer.length - start;
        size_t wsize = left <= s.length ? left : s.length;
        if (wsize > 0)
            buffer[start .. start + wsize] = s[0 .. wsize];
        start += wsize;
    };

    sformat(sink, fmt, args);
    return buffer[0 .. start];
}

/*******************************************************************************

    Send the processed (formatted) input into a sink

    Params:
        sink    = A delegate that will be called, possibly multiple
                    times, with a portion of the result string
        fmt     = Format string to use
        args    = Variadic arguments to format according to fmt

    Returns:
        If formatting was successful, returns `true`, `false` otherwise.

*******************************************************************************/

public bool sformat (Args...) (scope FormatterSink sink, cstring fmt, Args args)
    @trusted
{
    FormatInfo info;
    size_t nextIndex;

    // A delegate to write elements according to the FormatInfo
    scope ElemSink elemSink = (cstring str, ref const(FormatInfo) f)
    {
        widthSink(sink, str, f);
    };

    // Main loop
    while (fmt.length)
    {
        info = consume(sink, fmt);

        if (info.flags & Flags.Error)
            return false;

        if (info.flags & Flags.Format)
        {
            // Handle index, the single source of pain
            if (info.flags & Flags.Index)
                nextIndex = info.index + 1;
            else
                info.index = nextIndex++;

            /*
             * The foreach within the switch is executed at compile time
             * It allows accessing a compile-time known parameter (and most
             * importantly, its type) using a runtime index.
             * It is basically generating a jump table, which is exactly
             * what the codegen will produce.
             * Note that we need to use the break to label feature as
             * `break` would otherwise break out of the static foreach
             * (even if that doesn't make sense), and thus, execute the
             * `default` statement in every case (!)
             */
        JT: switch (info.index)
            {
                // NOTE: We could static foreach over `args` (the values)
                // instead of `Args` (the type) but it currently triggers
                // a DMD bug, and as a result a deprecation message:
                // https://issues.dlang.org/show_bug.cgi?id=16521
                foreach (idx, Tunused; Args)
                {
                case idx:
                    handle(args[idx], info, sink, elemSink);
                    break JT;
                }

            default:
                sink("{invalid index}");
            }
        }
    }
    return true;
}

/*******************************************************************************

    A function that writes to a `Sink` according to the width limits

    Params:
        sink = Sink to write to
        str  = String to write to the sink
        f    = FormatInfo object from which to read the width and flags

*******************************************************************************/

private void widthSink (scope FormatterSink sink, cstring str, ref const(FormatInfo) f)
    @trusted
{
    if (f.flags & Flags.Width)
    {
        // "{.4}",  "Hello" gives "Hell..."
        // "{.-4}", "Hello" gives "...ello"
        if (f.flags & Flags.Crop)
        {
            if (f.flags & Flags.AlignLeft)
            {
                if (str.length > f.width)
                {
                    sink("...");
                    sink(str[$ - f.width .. $]);
                }
                else
                    sink(str);
            }
            else
            {
                verify((f.flags & Flags.AlignRight) != 0);
                if (str.length > f.width)
                {
                    sink(str[0 .. f.width]);
                    sink("...");
                }
                else
                    sink(str);
            }
        }
        else if (f.width > str.length)
        {
            if (f.flags & Flags.AlignLeft)
            {
                sink(str);
                writeSpace(sink, f.width - str.length);
            }
            else
            {
                verify((f.flags & Flags.AlignRight) != 0);
                writeSpace(sink, f.width - str.length);
                sink(str);
            }
        }
        // Else fall back to just writing the string
        else
        {
            sink(str);
        }
    }
    else
        sink(str);
}


/*******************************************************************************

    Converts a value of a given type to its string representation

    Params:
        T   = Type of the argument to convert
        v   = Value of the argument to convert
        f   = Format information gathered from parsing
        sf  = Fragment sink, to emit a part of the text without alignment
        se  = Element sink, to emit a single element with alignment

*******************************************************************************/

private void handle (T) (T v, FormatInfo f, scope FormatterSink sf, scope ElemSink se)
{
    /** The order in which the following conditions are applied matters.
     * Explicit type checks (e.g. associative array, or `is(T == V)`)
     * should go first as they are unambiguous.
     * Multiple conditions could be matched by the same type.
     */

    // `typeof(null)` matches way too many things
    static if (is(T == typeof(null)))
        se("null", f);


    // Pretty print enum
    // Note that switch is only available for string and integer based enums.
    // However, since it expands to a jump table for integers and a binary
    // search for strings, we still want to special case it.
    else static if (is(T V == enum) && canSwitchOn!T)
    {
        sw: switch (v)
        {
            foreach (member; __traits(allMembers, T))
            {
            case mixin("T." ~ member):
                sf(T.stringof);
                sf(".");
                sf(member);
                break sw;
            }
            default :
                sf("cast(");
                sf(T.stringof);
                sf(") ");
                handle!(V)(v, f, sf, se);
        }
    }

    // Pretty print enum for non-integer, non-string base types
    // This branch should be rarely, if ever, used.
    else static if (is(T E == enum))
    {
        foreach (member; __traits(allMembers, T))
        {
            if (v == mixin("T." ~ member))
            {
                sf(T.stringof);
                sf(".");
                sf(member);
                return;
            }
        }

        sf("cast(");
        sf(T.stringof);
        sf(") ");
        handle!(E)(v, f, sf, se);
    }

    // Delegate / Function pointers
    else static if (is(T == delegate))
    {
        sf(T.stringof ~ ": { funcptr: ");
        writePointer(v.funcptr, f, se);
        sf(", ptr: ");
        writePointer(v.ptr, f, se);
        sf(" }");
    }
    else static if (is(T U == return))
    {
        sf(T.stringof ~ ": ");
        writePointer(v, f, se);
    }

    // Pointers need to be at the top because `(int*).min` compiles
    // and hence would match the integer rules
    // In addition, thanks to automatic dereferencing, checks such as
    // `v.toString()` and `T.IsTypedef` pass when `typeof(v)` is an `Object*`,
    // and when `T` is a pointer to a typedef.
    else static if (is (T P == P*))
        writePointer(v, f, se);

    /** D1 + D2 support of typedef
     * Note that another approach would be to handle `struct` at the very
     * last stage and relying on `alias this` for implicit conversions.
     * However this is not a reliable approach, as having an `alias this`
     * doesn't mean that it will be a typedef, and a user might want the struct
     * to be printed instead of the first matching `alias this`.
     * In fact, there is no way to semantically express subtyping,
     * but only the means to perform it.
     * This could be solved later with a UDA, but it's at best a workaround.
     */
    else static if (isTypedef!(T))
        handle!(TypedefBaseType!(T))(v, f, sf, se);

    // toString hook: Give priority to the non-allocating one
    // Note: sink `toString` overload should take a `scope` delegate
    else static if (is(typeof(v.toString(sf))))
        nullWrapper(&v,
                    v.toString((in cstring e) { se(e, f); }),
                    se("null", f));
    else static if (is(typeof(v.toString()) : cstring))
        nullWrapper(&v, se(v.toString(), f), se("null", f));
    else static if (is(T == interface))
        handle!(Object)(cast(Object) v, f, sf, se);
    else static if (isForwardRange!T && !isInfinite!T)
    {
        Flags old_flag = f.flags;
        f.flags |= Flags.Nested;
        sf("[");
        auto range = v.save;
        while (!range.empty)
        {
            handle(range.front, f, sf, se);
            range.popFront();
            if (!range.empty)
                sf(", ");
        }
        sf("]");
        f.flags = old_flag;
    }
    // Aggregate should be matched before basic type to avoid
    // `alias this` kicking in. See typedef support for more info.
    else static if (is (T == struct))
    {
        Flags old = f.flags;
        f.flags |= Flags.Nested;
        foreach (idx, ref m; v.tupleof)
        {
            static if (idx == 0)
                sf("{ " ~ identifier!(T.tupleof[idx]) ~ ": ");
            else
                sf(", " ~ identifier!(T.tupleof[idx]) ~ ": ");

            // A bit ugly but it makes string much more readable
            handle(m, f, sf, se);
        }
        sf(v.tupleof.length ? " }" : "{ empty struct }");
        f.flags = old;
    }

    // Bool
    else static if (is (Unqual!(T) == bool))
        se(v ? "true" : "false", f);

    // Floating point values - Explicitly typed because we don't want
    // to support imaginary and complex FP types
    else static if (is(Unqual!(T) == float) || is(Unqual!(T) == double)
                    || is(Unqual!(T) == real))
    {
        char[T.sizeof * 8] buff = void;
        se(Float.format(buff, v, f.format), f);
    }

    // Associative array cannot be matched by IsExp in D1
    else static if (isArrayType!(T) == ArrayKind.Associative)
    {
        bool started;
        Flags old = f.flags;
        f.flags |= Flags.Nested;
        foreach (key, ref val; v)
        {
            if (!started)
            {
                started = true;
                sf("[ ");
            }
            else
                sf(", ");

            handle(key, f, sf, se);
            sf(": ");
            handle(val, f, sf, se);
        }
        if (started)
            sf(" ]");
        else // Empty or null
            sf("[:]");
        f.flags = old;
    }

    // UTF-8 strings and chars (UTF-16 and UTF-32 unsupported)
    else static if (is(T : cstring)
                    || is(T : const(wchar)[])
                    || is(T : const(dchar)[]))
    {
        if (f.flags & Flags.Nested) sf(`"`);
        UTF.toString(v, (cstring val) { se(val, f); return val.length; });
        if (f.flags & Flags.Nested) sf(`"`);
    }
    else static if (is(typeof((&v)[0 .. 1]) : cstring)
                    || is(typeof((&v)[0 .. 1]) : const(wchar)[])
                    || is(typeof((&v)[0 .. 1]) : const(dchar)[]))
    {
        T[3] b = [ '\'', v, '\'' ];
        if (f.flags & Flags.Nested)
            UTF.toString(b, (cstring val) { se(val, f); return val.length; });
        else
            UTF.toString(b[1 .. 2], (cstring val) { se(val, f); return val.length; });
    }

    // Signed integer
    else static if (is(typeof(T.min)) && T.min < 0)
    {
        // Needs to support base 2 at most, plus an optional prefix
        // of 2 chars max
        char[T.sizeof * 8 + 2] buff = void;
        se(Integer.format(buff, v, f.format), f);
    }
    // Unsigned integer
    else static if (is(typeof(T.min)) && T.min == 0)
    {
        // Needs to support base 2 at most, plus an optional prefix of 2 chars
        // max
        char[T.sizeof * 8 + 2] buff = void;
        se(Integer.format(buff, v, (f.format.length ? f.format : "u")), f);
    }

    // Arrays (dynamic and static)
    else static if (isBasicArrayType!(T))
    {
        alias ElementTypeOf!(T) A;

        static if (is(Unqual!(A) == void))
            handle!(const(ubyte)[])(cast(const(ubyte)[]) v, f, sf, se);
        else
        {
            sf("[");
            if (v.length)
            {
                Flags old = f.flags;
                f.flags |= Flags.Nested;

                handle!(A)(v[0], f, sf, se);
                foreach (idx, ref e; v[1 .. $])
                {
                    sf(", ");
                    handle!(A)(e, f, sf, se);
                }

                f.flags = old;
            }
            sf("]");
        }
    }

    else
        static assert (0, "Type unsupported by ocean.text.convert.Formatter: "
                       ~ T.stringof);
}


/*******************************************************************************

    Wrapper to call `toString` methods after checking for `null`

    Before calling `toString`, a `null` check should be performed.
    However, it shouldn't always be performed, as `T` might not be a ref type.

    Params:
        v = Object to check, might be a reference type
        expr = Expression to call if `v` is not null or not a ref type
        onNull = Expression to call if `v` is null

    Returns:
        Value returned by either `expr` or `onNull`, if any.

*******************************************************************************/

private RetType nullWrapper (T, RetType) (T* v, lazy RetType expr,
                                          lazy RetType onNull)
{
    static if (is(typeof(*v is null)))
        if (*v is null)
            return onNull;
    return expr;
}


/*******************************************************************************

        Consumes the format string until a format specifier is found,
        then returns information about that format specifier

        Note:
          This function iterates over 'char', and is *NOT* Unicode-correct.
          However, neither is the original Tango one.

        Params:
            sink    = An output delegate to write to
            fmt     = The format string to consume

        Copyright:
            This function was adapted from
            `tango.text.convert.Layout.Layout.consume`.
            The original was (c) Kris

        Returns:
            A description of the format specification, see `FormatInfo`'s
            definition for more details

*******************************************************************************/

private FormatInfo consume (scope FormatterSink sink, ref cstring fmt)
{
    FormatInfo ret;
    auto s = fmt.ptr;
    auto end = s + fmt.length;

    while (s < end && *s != '{')
        ++s;

    // Write all non-formatted content
    sink(forwardSlice(fmt, s));

    if (s == end)
        return ret;

    // Tango format allowed escaping braces: "{{0}" would be turned
    // into "{0}"
    if (*++s == '{')
    {
        // Will always return "{{", but we only need the first char
        sink(forwardSlice(fmt, s + 1)[0 .. 1]);
        return ret;
    }

    ret.flags |= Flags.Format;

    // extract index
    if (readNumber(ret.index, s))
        ret.flags |= Flags.Index;

    s = skipSpace(s, end);

    // has minimum or maximum width?
    if (*s == ',' || *s == '.')
    {
        if (*s == '.')
            ret.flags |= Flags.Crop;

        s = skipSpace(++s, end);
        if (*s == '-')
        {
            ret.flags |= Flags.AlignLeft;
            ++s;
        }
        else
            ret.flags |= Flags.AlignRight;

        // Extract expected width
        if (readNumber(ret.width, s))
            ret.flags |= Flags.Width;

        // skip spaces
        s = skipSpace(s, end);
    }

    // Finally get the format string, if any
    // e.g. for `{5:X} that would be 'X'
    if (*s == ':')
        ++s;
    if (s < end)
    {
        auto fs = s;
        // eat everything up to closing brace
        while (s < end && *s != '}')
            ++s;
        ret.format = fs[0 .. cast(size_t) (s - fs)];
    }

    forwardSlice(fmt, s);

    // When the user-provided string is e.g. "Foobar {0:X"
    if (*s != '}')
    {
        sink("{missing closing '}'}");
        ret.flags |= Flags.Error;
        return ret;
    }

    // Eat the closing bracket ('}')
    fmt = fmt[1 .. $];

    return ret;
}


/*******************************************************************************

        Helper function to advance a slice to a pointer

        Params:
            s   = Slice to advance
            p   = Internal pointer to 's'

        Returns:
            A slice to the data that was consumed (e.g. s[0 .. s.ptr - p])

*******************************************************************************/

private cstring forwardSlice (ref cstring s, const(char)* p)
out (ret)
{
    assert(s.ptr == p);
    assert(ret.ptr + ret.length == p);
}
do
{
    verify(s.ptr <= p);
    verify(s.ptr + s.length >= p);

    cstring old = s.ptr[0 .. cast(size_t) (p - s.ptr)];
    s = s[old.length .. $];
    return old;
}

/*******************************************************************************

        Helper function to advance a pointer to the next non-space character

        Params:
            s   = Pointer to iterate
            end = Pointer to the end of 's'

        Returns:
            's' pointing to a non-space character or 'end'

*******************************************************************************/

private const(char)* skipSpace (const(char)* s, const(char)* end)
{
    while (s < end && *s == ' ')
        ++s;
    return s;
}

/*******************************************************************************

        Helper function to write a space to a sink

        Allows one to pad a string. Writes in chunk of 32 chars at most.

        Params:
            s   = Sink to write to
            n   = Amount of spaces to write

*******************************************************************************/

private void writeSpace (scope FormatterSink s, size_t n)
{
    static immutable istring Spaces32 = "                                ";

    // Make 'n' a multiple of Spaces32.length (32)
    s(Spaces32[0 .. n % Spaces32.length]);
    n -= n % Spaces32.length;

    verify((n % Spaces32.length) == 0);

    while (n != 0)
    {
        s(Spaces32);
        n -= Spaces32.length;
    }
}

/*******************************************************************************

        Helper function to read a number while consuming the input

        Params:
            f = Value in which to store the number
            s = Pointer to consume / read from

        Copyright:
            Originally from `tango.text.convert.Layout`.
            Copyright Kris

        Returns:
            `true` if a number was read, `false` otherwise

*******************************************************************************/

private bool readNumber (out size_t f, ref const(char)* s)
{
    if (*s >= '0' && *s <= '9')
    {
        do
            f = f * 10 + *s++ -'0';
        while (*s >= '0' && *s <= '9');
        return true;
    }
    return false;
}


/*******************************************************************************

        Write a pointer to the sink

        Params:
            v   = Pointer to write
            f   = Format information gathered from parsing
            se  = Element sink, to emit a single element with alignment

*******************************************************************************/

private void writePointer (in void* v, ref FormatInfo f, scope ElemSink se)
{
    alias void* T;

    enum l = (T.sizeof * 2);
    enum defaultFormat = "X" ~ l.stringof ~ "#";

    if (v is null)
        se("null", f);
    else
    {
        // Needs to support base 2 at most, plus an optional prefix
        // of 2 chars max
        char[T.sizeof * 8 + 2] buff = void;
        se(Integer.format(buff, cast(ptrdiff_t) v,
                          (f.format.length ? f.format : defaultFormat)), f);
    }
}


/*******************************************************************************

    Represent all possible boolean values that can be set in FormatInfo.flags

*******************************************************************************/

private enum Flags : ubyte
{
    None        = 0x00,     /// Default
    Format      = 0x01,     /// There was a formatting string (even if empty)
    Error       = 0x02,     /// An error happened during formatting, bail out
    AlignLeft   = 0x04,     /// Left alignment requested (via ',-' or '.-')
    AlignRight  = 0x08,     /// Right alignment requested (via ',' or '.')
    Crop        = 0x10,     /// Crop to width (via '.')
    Index       = 0x20,     /// An index was explicitly provided
    Width       = 0x40,     /// A width was explicitly provided
    Nested      = 0x80,     /// We are formatting something nested
                            ///   (i.e. in an aggregate type or an array)
}

/*******************************************************************************

    Internal struct to hold information about the format specification

*******************************************************************************/

private struct FormatInfo
{
    /***************************************************************************

        Format string, might be empty

        E.g. "{}" gives an empty `format`, and so does "{0}"
        The string "{d}" and "{0,10:f}" give 'd' and 'f', respectively.

    ***************************************************************************/

    public cstring format;

    /***************************************************************************

        Explicitly requested index to use, only meaningful if flags.Index is set

    ***************************************************************************/

    public size_t index;

    /***************************************************************************

        Output width explicitly requested, only meaningful if flags.Width is set

    ***************************************************************************/

    public size_t width;

    /***************************************************************************

        Grab bag of boolean values, check `Flags` enum for complete doc

    ***************************************************************************/

    public Flags flags;
}

/// Returns: Whether or not `T` can be `switch`ed on
private template canSwitchOn (T)
{
    enum canSwitchOn = is(typeof(() { switch (T.init) { default: break; }}));
}

unittest
{
    static assert(canSwitchOn!string);
    static assert(canSwitchOn!(immutable int));
    static assert(!canSwitchOn!(real));
}

/*******************************************************************************

    Returns `true` if `R` is an input range

    See_Also:
        https://github.com/dlang/phobos/blob/
        418106123d6106efb03b2753bf191215b411ad96/std/range/primitives.d#L124

    Params:
        R = type to be tested
    Returns:
        `true` if R is an input range, `false` if not

*******************************************************************************/

private enum bool isInputRange(R) =
    is(typeof(R.init) == R)
    && is(typeof((R r) { return r.empty; }(R.init)) == bool)
    && is(typeof((return ref R r) => r.front))
    && !is(typeof((R r) { return r.front; }(R.init)) == void)
    && is(typeof((R r) => r.popFront));


//  Test for isInputRange
//
//  See_Also:
//      https://github.com/dlang/phobos/blob/
//      418106123d6106efb03b2753bf191215b411ad96/std/range/primitives.d#L180
@safe unittest
{
    struct A {}
    struct B
    {
        void popFront();
        @property bool empty();
        @property int front();
    }

    static assert(!isInputRange!A);
    static assert( isInputRange!B);

    static struct NotDefaultConstructible
    {
        @disable this();
        void popFront();
        @property bool empty();
        @property int front();
    }
    static assert( isInputRange!NotDefaultConstructible);

    static struct NotDefaultConstructibleOrCopyable
    {
        @disable this();
        @disable this(this);
        void popFront();
        @property bool empty();
        @property int front();
    }
    static assert(isInputRange!NotDefaultConstructibleOrCopyable);

    static struct Frontless
    {
        void popFront();
        @property bool empty();
    }
    static assert(!isInputRange!Frontless);

    static struct VoidFront
    {
        void popFront();
        @property bool empty();
        void front();
    }
    static assert(!isInputRange!VoidFront);
}

//  Test for isInputRange
//
//  See_Also:
//      https://github.com/dlang/phobos/blob/
//      418106123d6106efb03b2753bf191215b411ad96/std/range/primitives.d#L231
@safe unittest
{
    import std.algorithm.comparison : equal;

    static struct R
    {
        static struct Front
        {
            R* impl;
            @property int value() { return impl._front; }
            alias value this;
        }

        int _front;

        @property bool empty() { return _front >= 3; }
        @property auto front() { return Front(&this); }
        void popFront() { _front++; }
    }
    R r;

    static assert(isInputRange!R);
    assert(r.equal([ 0, 1, 2 ]));
}

//  Test for isInputRange
@safe unittest
{
    bool[string] foo;
    foo["A"] = true;
    foo["B"] = true;
    static assert (isInputRange!(typeof(foo.byKey())));
    static assert (isInputRange!(typeof(foo.byValue())));
}

/*******************************************************************************

    Returns `true` if `R` is a forward range

    See_Also:
        https://github.com/dlang/phobos/blob/
        418106123d6106efb03b2753bf191215b411ad96/std/range/primitives.d#L949

    Params:
        R = type to be tested
    Returns:
        `true` if R is an forward range, `false` if not

*******************************************************************************/

private enum bool isForwardRange(R) = isInputRange!R
    && is(typeof((R r) { return r.save; }(R.init)) == R);


//  Test for isForwardRange
//
//  See_Also:
//      https://github.com/dlang/phobos/blob/
//      418106123d6106efb03b2753bf191215b411ad96/std/range/primitives.d#L990
@safe unittest
{
    struct R14544
    {
        int front() { return 0;}
        void popFront() {}
        bool empty() { return false; }
        R14544 save() {return this;}
    }
    static assert (isForwardRange!R14544);
}

//  Test for isForwardRange
@safe unittest
{
    bool[string] foo;
    foo["A"] = true;
    foo["B"] = true;
    static assert (isForwardRange!(typeof(foo.byKey())));
    static assert (isForwardRange!(typeof(foo.byValue())));
}

/*******************************************************************************

    Returns `true` if `R` is an infinite input range. An
    infinite input range is an input range that has a statically-defined
    enumerated member called `empty` that is always `false`,

    See_Also:
        https://github.com/dlang/phobos/blob/
        418106123d6106efb03b2753bf191215b411ad96/std/range/primitives.d#L1608

    Params:
        R = type to be tested
    Returns:
        `true` if R is an infinite input range, `false` if not

*******************************************************************************/

private template isInfinite (R)
{
    static if (isInputRange!R && __traits(compiles, { enum e = R.empty; }))
        enum bool isInfinite = !R.empty;
    else
        enum bool isInfinite = false;
}

//  Test for isInfinite
@safe unittest
{
    struct Sample
    {
        int front() { return 0;}
        void popFront() {}
        enum bool empty = false;
    }

    static assert (isInfinite!(Sample));
}
