//! InfiniteAxisUtilitySystem

const std = @import("std");
const math = std.math;
const meta = std.meta;

pub const Response = struct {
    type: Type,
    m: f32, // slope
    c: f32, // x-shift
    b: f32, // y-shift
    k: f32, // exponent

    pub const Type = enum {
        linear,
        logistic,
        logit,
        normal,
        polynomial,
        sine,
    };

    pub fn y(self: Response, x: f32) f32 {
        return switch (self.type) {
            .linear => self.linear(x),
            .logistic => self.logistic(x),
            .logit => self.logit(x),
            .normal => self.normal(x),
            .polynomial => self.polynomial(x),
            .sine => self.sine(x),
        };
    }

    /// ```
    ///   y
    /// 1 |                , '
    ///   |            , '
    ///   |        , '
    ///   |    , '
    /// 0 |, '
    ///   |___________________ x
    ///    0                 1
    /// ```
    /// https://en.wikipedia.org/wiki/Linear_function
    pub fn linear(self: Response, x: f32) f32 {
        const m = self.m;
        const c = self.c;
        const b = self.b;
        return math.clamp(m * (x - c) + b, 0, 1);
    }

    /// ```
    ///   y
    /// 1 |           ,-'''
    ///   |         ,'
    ///   |        ,
    ///   |       ,
    ///   |     ,'
    ///  0|,,,-'
    ///   |________________ x
    ///    0              1
    /// ```
    /// https://en.wikipedia.org/wiki/Logistic_function
    pub fn logistic(self: Response, x: f32) f32 {
        const m = self.m;
        const k = self.k;
        const c = self.c;
        const b = self.b;
        return math.clamp(m / (1 + @exp(k * (x - c))) + b, 0, 1);
    }

    /// ```
    ///   y
    /// 1 |
    ///   |
    ///   |
    ///   |
    ///   |
    ///   |
    /// 0 |__________________ x
    ///    0
    /// ```
    /// https://en.wikipedia.org/wiki/Logit
    pub fn logit(self: Response, x: f32) f32 {
        const m = self.m;
        const c = self.c;
        const b = self.b;
        return math.clamp(
            m * math.log((x - c) / (1.0 - (x - c))) / 5.0 + 0.5 + b,
            0,
            1,
        );
    }

    /// ```
    ///   y
    /// 1 |
    ///   |
    ///   |
    ///   |
    ///   |
    ///   |
    /// 0 |__________________ x
    ///    0
    /// ```
    /// https://en.wikipedia.org/wiki/Polynomial
    pub fn polynomial(self: Response, x: f32) f32 {
        const m = self.m;
        const k = self.k;
        const c = self.c;
        const b = self.b;
        return math.clamp(m * math.pow(x - c, k) + b, 0, 1);
    }

    /// ```
    ///   y
    /// 1 |
    ///   |
    ///   |
    ///   |
    ///   |
    ///   |
    /// 0 |__________________ x
    ///    0
    /// ```
    /// https://en.wikipedia.org/wiki/Normal_distribution
    pub fn normal(self: Response, x: f32) f32 {
        const m = self.m;
        const k = self.k;
        const c = self.c;
        const b = self.b;
        return math.clamp(
            m * @exp(-30.0 * k * math.pow(x - c - 0.5, 2)) + b,
            0,
            1,
        );
    }

    /// ```
    ///   y
    /// 1 |                             , '  ' ,
    ///   |,                          ,
    ///   | '                        '
    ///   |   '                    '
    ///   |    '                  '
    ///   |     '                '
    ///   |       ',          ,'
    /// 0 |          ' ,  , '
    ///   |______________________________________ x
    ///    0                                    1
    /// ```
    /// https://en.wikipedia.org/wiki/Sine_and_cosine
    pub fn sine(self: Response, x: f32) f32 {
        const m = self.m;
        const k = self.k;
        const c = self.c;
        const b = self.b;
        return math.clamp(
            0.5 * k * @sin(math.tau * m * (x - c)) + 0.5 + b,
            0,
            1,
        );
    }
};
