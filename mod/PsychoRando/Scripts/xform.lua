-- Minimal transform math (Unreal conventions: rotator in degrees, quaternions X,Y,Z,W)
local X = {}

function X.quatFromRotator(pitch, yaw, roll)
    local d = math.pi / 360
    local SP, CP = math.sin(pitch * d), math.cos(pitch * d)
    local SY, CY = math.sin(yaw * d), math.cos(yaw * d)
    local SR, CR = math.sin(roll * d), math.cos(roll * d)
    return {
        CR * SP * SY - SR * CP * CY,
        -CR * SP * CY - SR * CP * SY,
        CR * CP * SY - SR * SP * CY,
        CR * CP * CY + SR * SP * SY,
    }
end

function X.quatMul(a, b) -- a * b
    return {
        a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2],
        a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
        a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4],
        a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
    }
end

function X.rotate(q, v)
    local qv = { v[1], v[2], v[3], 0 }
    local qc = { -q[1], -q[2], -q[3], q[4] }
    local r = X.quatMul(X.quatMul(q, qv), qc)
    return { r[1], r[2], r[3] }
end

-- t = { loc = {x,y,z}, rot = {x,y,z,w}, scale = {x,y,z} }; returns parent * child
function X.compose(parent, child)
    local s = { child.loc[1] * parent.scale[1], child.loc[2] * parent.scale[2], child.loc[3] * parent.scale[3] }
    local r = X.rotate(parent.rot, s)
    return {
        loc = { parent.loc[1] + r[1], parent.loc[2] + r[2], parent.loc[3] + r[3] },
        rot = X.quatMul(parent.rot, child.rot),
        scale = { parent.scale[1] * child.scale[1], parent.scale[2] * child.scale[2], parent.scale[3] * child.scale[3] },
    }
end

-- quaternion -> {pitch, yaw, roll} in degrees (Unreal's FQuat::Rotator)
function X.quatToRotator(q)
    local x, y, z, w = q[1], q[2], q[3], q[4]
    local singTest = z * x - w * y
    local yawY = 2 * (w * z + x * y)
    local yawX = 1 - 2 * (y * y + z * z)
    local r2d = 180 / math.pi
    local yaw = math.atan(yawY, yawX) * r2d
    local pitch, roll
    if singTest < -0.4999995 then
        pitch = -90; roll = -yaw - 2 * math.atan(x, w) * r2d
    elseif singTest > 0.4999995 then
        pitch = 90; roll = yaw - 2 * math.atan(x, w) * r2d
    else
        pitch = math.asin(2 * singTest) * r2d
        roll = math.atan(-2 * (w * x + y * z), 1 - 2 * (x * x + y * y)) * r2d
    end
    return { pitch, yaw, roll }
end

X.IDENTITY = { loc = { 0, 0, 0 }, rot = { 0, 0, 0, 1 }, scale = { 1, 1, 1 } }

return X
