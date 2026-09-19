// kalman -- a constant-velocity Kalman filter on one scalar.
//
// State is position and velocity; the model is that the velocity holds and
// is nudged by noise of `q` per second (the process noise: how fast the thing
// may accelerate), and each measurement is off by `r` (its noise). Both are
// standard deviations, in the scalar's own units. Against an EMA this tracks
// motion without lagging behind it -- the velocity carries the prediction --
// while still averaging a still head's jitter away.
#pragma once

namespace mirror {

struct Kalman1D {
    float x = 0.f, v = 0.f;
    float P00 = 1.f, P01 = 0.f, P11 = 1.f;   // covariance, symmetric
    bool  init = false;

    void reset() { init = false; }

    // One step: `dt` seconds of motion, then the measurement `z`.
    void step(float z, float dt, float q, float r) {
        if (!init) {
            x = z; v = 0.f;
            P00 = r * r; P01 = 0.f; P11 = q * q;
            init = true;
            return;
        }
        // Predict. Process noise enters as an acceleration white over dt.
        x += v * dt;
        const float dt2 = dt * dt, dt3 = dt2 * dt, dt4 = dt3 * dt;
        const float qq = q * q;
        const float p00 = P00 + dt * (2.f * P01 + dt * P11) + 0.25f * dt4 * qq;
        const float p01 = P01 + dt * P11 + 0.5f * dt3 * qq;
        const float p11 = P11 + dt2 * qq;
        // Update.
        const float s = p00 + r * r;
        const float k0 = p00 / s, k1 = p01 / s;
        const float y = z - x;
        x += k0 * y;
        v += k1 * y;
        P00 = (1.f - k0) * p00;
        P01 = (1.f - k0) * p01;
        P11 = p11 - k1 * p01;
    }
};

}  // namespace mirror
