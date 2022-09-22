//! InfiniteAxisUtilitySystem

const std = @import("std");
const math = std.math;
const meta = std.meta;

pub const Response = struct {
    //! A `Response` curve maps a measurement of the environment
    //! to an estimated utility score used in deciding upon which
    //! action to take.
    //!
    //! Consider the decision of picking between aggressive actions
    //! and self preservation. For a simple character it may be
    //! enough to declare that as health declines the desire for
    //! aggressive actions follows:
    //!
    //! ```
    //! health / 100
    //! ```
    //!
    //! the opposite could also be defined where a character
    //! becomes increasingly aggressive as they take more damage:
    //!
    //! ```
    //! 1 - health / 100
    //! ```
    //!
    //! and that would be fine should your characters only have
    //! linear responses to stimulus. But what if you wanted to
    //! define a character which would become less aggessive as
    //! their health declines up to a limit where after they
    //! suddenly jump to full aggression as if they're making
    //! a final stand? enraged? berserk? You'll need something
    //! better:
    //!
    //! ```
    //! x = health / 100
    //! eu = 2.5(x-0.45)^2 + -2.3(x-0.45)^3 + 7.7(x-0.45)^4 + 0.3
    //! ```
    //!
    //! we gain the ability to modify how strong the response
    //! by fitting it to a curve which invokes a strong response
    //! at both extremes with a gradual decline from high health
    //! to medium while only a sharp rise near critical health.
    //! The curve is interpreted as follows:
    //!
    //! ```
    //!                         health is critical causing the
    //!                         character to lose hope in
    //!                         recovering and picking a more
    //!                         aggressive approach "if I'm
    //!                         going down then I'm taking you
    //!     ,------------------ with me"
    //!     |
    //!     v                   health is near full thus the
    //!   y                     desire to perform aggressive
    //! 1 | ;          ,'  <--- actions is higher due to lower
    //!   | ;         ,         risk in getting hurt while a
    //!   | ;        ,          higher reward for inflicting
    //!   |  ,      ,           damage
    //!   |    , , '
    //!  0|          <--------- health is low so the desire to
    //!   |________________ x   attack is low as the risk from
    //!    0              1     taking more damage is higher
    //!                         than the utility gained from
    //!                         attacking.
    //! ```
    //!
    //! Here we've mapped health to match the desired behaviour
    //! by applying our very own response curve which maps an
    //! otherwise linear value to that we wish for it to be.
    //! Health isn't the only consideration that can be mapped
    //! like this and usually the choice of performing an
    //! aggressive action involves multiple considerations in
    //! addition to health declared above such as:
    //!
    //! - distance to the target
    //! - current weapon if any
    //! - their weapon if any
    //! - perceived level of threat
    //! - perceived level of allied support
    //! - status (stamina, mana, broken/fractured bones)
    //! - purpose (self defence, enemy, bounty)
    //!
    //! and likely many more that need to be considered before
    //! deciding which behaviour is the most suitable for the
    //! current situation.

    /// Function
    type: Type,
    /// Slope
    m: f32,
    /// X-shift
    c: f32,
    /// Y-shift
    b: f32,
    /// Exponent
    k: f32,

    pub const Type = enum {
        linear,
        logistic,
        logit,
        normal,
        polynomial,
        sine,
    };

    /// Compute the response given a stimulus.
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
