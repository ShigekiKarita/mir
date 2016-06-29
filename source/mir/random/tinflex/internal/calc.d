module mir.random.tinflex.internal.calc;

import mir.random.tinflex.internal.types : GenerationInterval,  Interval;
import std.container.dlist : DList;

/**
Splits an interval into two points.

Params:
    l = Left starting point of the interval
    r = Right ending point of the interval
Returns:
    Splitting point within the interval
*/
auto arcmean(S, bool sorted = false)(const S x, const S y)
{
    import std.math: atan, tan;

    S l = x;
    S r = y;
    static if (!sorted)
    {
        if (r < l)
        {
            S t = r;
            r = l;
            l = t;
        }
    }

    if (r < -S(1e3) || l > S(1e3))
        return  2 / (1 / l + 1 / r);

    immutable d = atan(l);
    immutable b = atan(r);

    assert(d <= b);
    if (b - d < S(1e-6))
        return S(0.5) * l + S(0.5) * r;

    return tan(S(0.5) * (d + b));
}


/**
Calculate the parameters for an interval.
Given an interval, determine it's type and hat and squeeze function.
Given these functions, compute the area and overwrite the references data type

Params:
    iv = Interval
*/
void calcInterval(S)(ref Interval!S iv)
in
{
    assert(iv.lx < iv.rx, "invalid interval");
}
body
{
    import mir.random.tinflex.internal.types : determineType;
    import mir.random.tinflex.internal.area: determineSqueezeAndHat, hatArea, squeezeArea;
    import std.math: isFinite;

    // TODO: this is probably not needed anymore
    if (iv.lx == iv.rx)
    {
        iv.hatArea = 0;
        iv.squeezeArea = 0;
    }
    else
    {
        // calculate hat and squeeze functions
        determineSqueezeAndHat(iv);

        // update area
        hatArea!S(iv);
        squeezeArea!S(iv);

        assert(iv.hatArea.isFinite, "hat area should be lower than infinity");
        assert(iv.squeezeArea.isFinite, "squeezeArea area should be lower than infinity");
    }
}

/**
Calculate the intervals for the Tinflex algorithm for a T_c family given its
density function, the first two derivatives and a valid start partitioning.
The Tinflex algorithm will try to split the intervals until a chosen efficiency
rho is reached.

Params:
    f0 = probability density function of the distribution
    f1 = first derivative of f0
    f1 = second derivative of f0
    cs = T_c family (single value or array)
    points = non-overlapping partitioning with at most one inflection point per interval
    rho = efficiency of the Tinflex algorithm
    apprMaxPoints = maximal number of splitting points before Tinflex is aborted

Returns: Array of IntervalPoints
*/
GenerationInterval!S[] calcPoints(F0, F1, F2, S)
                            (in F0 f0, in F1 f1, in F2 f2,
                             in S[] cs, in S[] points, in S rho = 1.1,
                             in int apprMaxPoints = 1_000, in int maxIterations = 1_000)
in
{
    import std.algorithm.searching : all;
    import std.math : isFinite, isInfinity;
    import std.range: drop, empty, front, save;

    // check points
    assert(points.length >= 2, "two or more splitting points are required");
    assert(points[1..$-1].all!isFinite, "intermediate interval can't be indefinite");

    // check cs
    assert(cs.length == points.length - 1, "cs must have length equal to |points| - 1");

    // check first c
    if (points[0].isInfinity)
        assert(cs.front > - 1,"c must be > -1 for unbounded domains");

    // check last c
    if (points[$ - 1].isInfinity)
        assert(cs[$ - 1] > - 1,"cs must be > -1 for unbounded domains");
}
body
{
    import mir.random.tinflex.internal.transformations : transform,  transformToInterval;
    import mir.sum: Summator, Summation;
    import std.range.primitives : front, empty, popFront;

    alias Sum = Summator!(S, Summation.precise);

    Sum totalHatAreaSummator = 0;
    Sum totalSqueezeAreaSummator = 0;

    auto nrIntervals = cs.length;

    auto ips = DList!(Interval!S)();
    S l = points[0];
    S l0 = f0(points[0]);
    S l1 = f1(points[0]);
    S l2 = f2(points[0]);

    version(Tinflex_logging)
    {
        import std.experimental.logger;
        log("starting tinflex with p=", points, ", cs=", cs);
    }

    // initialize with user given splitting points
    foreach (i, r; points[1..$])
    {
        // reuse computations
        S r0 = f0(r);
        S r1 = f1(r);
        S r2 = f2(r);
        auto iv = transformToInterval(l, r, cs[i], l0, l1, l2,
                                                   r0, r1, r2);
        l = r;
        l0 = r0;
        l1 = r1;
        l2 = r2;

        calcInterval(iv);
        totalHatAreaSummator += iv.hatArea;
        totalSqueezeAreaSummator += iv.squeezeArea;

        ips.insertBack(iv);
    }

    version(Tinflex_logging)
    {
        import std.algorithm;
        import std.array;
        log("----");
        log("Interval: ", ips.array.map!`a.lx`);
        log("hatArea", ips.array.map!`a.hatArea`);
        log("squeezeArea", ips.array.map!`a.squeezeArea`);
        log("----");
    }

    // Tinflex is not guaranteed to converge
    for (auto i = 0; i < maxIterations && nrIntervals < apprMaxPoints; i++)
    {
        immutable totalHatArea = totalHatAreaSummator.sum;
        immutable totalSqueezeArea = totalSqueezeAreaSummator.sum;

        // Tinflex aims for a user defined efficiency
        if (totalHatArea / totalSqueezeArea <= rho)
            break;

        version(Tinflex_logging)
        {
            tracef("iteration %d: totalHat: %.3f, totalSqueeze: %.3f, rho: %.3f",
                    i, totalHatArea, totalSqueezeArea, totalHatArea / totalSqueezeArea);
        }

        import std.math: nextDown;
        immutable avgArea = nextDown(totalHatArea - totalSqueezeArea) / nrIntervals;
        for (auto it = ips[]; !it.empty;)
        {
            immutable curArea = it.front.hatArea - it.front.squeezeArea;
            if (curArea > avgArea)
            {
                // prepare total areas for update
                totalHatAreaSummator -= it.front.hatArea;
                totalSqueezeAreaSummator -= it.front.squeezeArea;

                // split the interval at the arcmean into two parts
                auto mid = arcmean!(S, true)(it.front.lx, it.front.rx);

                // create new interval (right side)
                S m0 = void, m1 = void, m2 = void;

                // apply transformation to new values
                transform(it.front.c, f0(mid), f1(mid), f2(mid), m0, m1, m2);

                Interval!S midIP = Interval!S(mid, it.front.rx, it.front.c,
                                              m0, m1, m2,
                                              it.front.rtx, it.front.rt1x, it.front.rt2x);

                version(Tinflex_logging)
                {
                    log("--split ", nrIntervals, " between ", it.front.lx, " - ", it.front.rx);
                    log("interval to be splitted: ", it.front);
                    log("new middle interval created: ", midIP);
                }

                // left interval: update right values
                it.front.rx = mid;
                it.front.rtx = m0;
                it.front.rt1x = m1;
                it.front.rt2x = m2;

                // recalculate intervals
                calcInterval(it.front);
                calcInterval(midIP);

                version(Tinflex_logging)
                {
                    log("update left: ", it.front);
                    log("update mid: ", midIP);
                }

                // update total areas
                totalHatAreaSummator += it.front.hatArea;
                totalHatAreaSummator += midIP.hatArea;
                totalSqueezeAreaSummator += it.front.squeezeArea;
                totalSqueezeAreaSummator += midIP.squeezeArea;

                // insert new middle part into linked list
                it.popFront;
                // @@@bug@@@ in DList, insertBefore with an empty list inserts
                // at the front
                if (it.empty)
                    ips.insertBack(midIP);
                else
                    ips.insertBefore(it, midIP);
                nrIntervals++;
            }
            else
            {
                it.popFront;
            }
        }
    }

    // for sampling only a subset of the attributes is needed
    auto gvs = new GenerationInterval!S[nrIntervals];
    size_t i = 0;
    foreach (ref ip; ips)
        gvs[i++] = GenerationInterval!S(ip.lx, ip.rx, ip.c, ip.hat,
                                     ip.squeeze, ip.hatArea, ip.squeezeArea);

    version(Tinflex_logging)
    {
        log("----");
        log("Intervals generated: ", gvs.length);
        import std.algorithm;
        import std.array;
        log("Interval: ", ips.array.map!`a.lx`);
        log("hatArea", ips.array.map!`a.hatArea`);
        log("squeezeArea", ips.array.map!`a.squeezeArea`);
        log("----");
    }

    return gvs;
}

// default tinflex with c=1.5
unittest
{
    import std.meta : AliasSeq;
    foreach (S; AliasSeq!(float, double, real))
    {
        auto f0 = (S x) => -x^^4 + 5 * x^^2 - 4;
        auto f1 = (S x) => 10 * x - 4 * x ^^ 3;
        auto f2 = (S x) => 10 - 12 * x ^^ 2;
        S[] cs = [1.5, 1.5, 1.5, 1.5];
        S[] points = [-3, -1.5, 0, 1.5, 3];
        auto ips = calcPoints(f0, f1, f2, cs, points, S(1.1));

        import std.stdio;
        writeln("IP points generated", ips.length);
        //assert(ips.length == 45);
    }
}

// default tinflex with c=1
unittest
{
    import std.meta : AliasSeq;
    foreach (S; AliasSeq!(float, double, real))
    {
        auto f0 = (S x) => -x^^4 + 5 * x^^2 - 4;
        auto f1 = (S x) => 10 * x - 4 * x ^^ 3;
        auto f2 = (S x) => 10 - 12 * x ^^ 2;
        S[] points = [-3, -1.5, 0, 1.5, 3];
        S[] cs = [1.0, 1.0, 1.0, 1.0];
        auto ips = calcPoints(f0, f1, f2, cs, points, S(1.1));

        import std.stdio;
        writeln("IP points generated", ips.length);
        //assert(ips.length == 45);
    }
}

// default tinflex with custom c's
unittest
{
    import std.meta : AliasSeq;
    foreach (S; AliasSeq!(float, double, real))
    {
        auto f0 = (S x) => -x^^4 + 5 * x^^2 - 4;
        auto f1 = (S x) => 10 * x - 4 * x ^^ 3;
        auto f2 = (S x) => 10 - 12 * x ^^ 2;
        S[] cs = [1.3, 1.4, 1.5, 1.6];
        S[] points = [-3, -1.5, 0, 1.5, 3];
        auto ips = calcPoints(f0, f1, f2, cs, points, S(1.1));

        //assert(ips.length == 45);
    }
}

// test standard normal distribution
unittest
{
    import mir.internal.math : exp, sqrt;
    import std.meta : AliasSeq;
    import std.math : PI;
    foreach (S; AliasSeq!(float, double, real))
    {
        S sqrt2PI = sqrt(2 * PI);
        auto f0 = (S x) => 1 / (exp(x * x / 2) * sqrt2PI);
        auto f1 = (S x) => -(x/(exp(x * x/2) * sqrt2PI));
        auto f2 = (S x) => (-1 + x * x) / (exp(x * x/2) * sqrt2PI);
        S[] cs = [1.5, 1.5, 1.5, 1.5];
        S[] points = [-3, -1.5, 0, 1.5, 3];
        auto ips = calcPoints(f0, f1, f2, cs, points, S(1.1));

        import std.stdio;
        writeln("IP points generated", ips.length);
    }
}

unittest
{
    import std.array : array;
    import std.meta : AliasSeq;
    import std.range : repeat;
    enum xs =    [-1, -0.9, -0.681543496892237, -0.5, -0.236067977499790,
                  0, 0.236067977499790, 0.5, 0.681543496892237, 0.9];
    enum hats = [0.0229266666666667,  0.136019342722764, 0.161670170668440,
                 0.2612709044556, 0.236795080652736, 0.236795080652736,
                 0.2612709044556, 0.161670170668440, 0.136019342722764,
                 0.0229266666666667];
    enum sqs = [0, 0.124439727192501, 0.156697988044425, 0.255354531224623,
                0.235701598814137, 0.235701598814137, 0.255354531224623,
                0.156697988044425, 0.124439727192501, 0];

    //foreach (S; AliasSeq!(float, double, real))
    foreach (S; AliasSeq!(real))
    {
        import std.math : log;
        auto f0 = (S x) => log(1 - x^^4);
        auto f1 = (S x) => -4 * x^^3 / (1 - x^^4);
        auto f2 = (S x) => -(4 * x^^6 + 12 * x^^2) / (x^^8 - 2 * x^^4 + 1);
        S[] points = [S(-1), -0.9, -0.5, 0.5, 0.9, 1];
        S[] cs = S(2).repeat(points.length - 1).array;

        auto ips = calcPoints(f0, f1, f2, cs, points, S(1.1));

        import std.stdio;
        writeln(points);
    }
}
