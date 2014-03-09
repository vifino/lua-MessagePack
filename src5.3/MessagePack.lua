--
-- lua-MessagePack : <http://fperrad.github.com/lua-MessagePack/>
--

local SIZEOF_NUMBER = debug.numbits'f' / 8
local luac = string.dump(load "a = 1")
local header = { luac:sub(1, 12):byte(1, 12) }
local NUMBER_INTEGRAL = 1 == header[12]

local assert = assert
local error = error
local pairs = pairs
local pcall = pcall
local setmetatable = setmetatable
local tostring = tostring
local type = type
local char = require'string'.char
local isfloat = require'math'.isfloat
local frexp = require'math'.frexp
local ldexp = require'math'.ldexp
local huge = require'math'.huge
local tconcat = require'table'.concat

--[[ debug only
local format = require'string'.format
local function hexadump (s)
    return (s:gsub('.', function (c) return format('%02X ', c:byte()) end))
end
--]]

_ENV = nil
local m = {}

--[[ debug only
m.hexadump = hexadump
--]]

local function argerror (caller, narg, extramsg)
    error("bad argument #" .. tostring(narg) .. " to "
          .. caller .. " (" .. extramsg .. ")")
end

local function typeerror (caller, narg, arg, tname)
    argerror(caller, narg, tname .. " expected, got " .. type(arg))
end

local function checktype (caller, narg, arg, tname)
    if type(arg) ~= tname then
        typeerror(caller, narg, arg, tname)
    end
end

local packers = setmetatable({}, {
    __index = function (t, k) error("pack '" .. k .. "' is unimplemented") end
})
m.packers = packers

packers['nil'] = function (buffer)
    buffer[#buffer+1] = char(0xC0)              -- nil
end

packers['boolean'] = function (buffer, bool)
    if bool then
        buffer[#buffer+1] = char(0xC3)          -- true
    else
        buffer[#buffer+1] = char(0xC2)          -- false
    end
end

packers['string_compat'] = function (buffer, str)
    local n = #str
    if n <= 0x1F then
        buffer[#buffer+1] = char(0xA0 + n)      -- fixstr
    elseif n <= 0xFFFF then
        buffer[#buffer+1] = char(0xDA,          -- str16
                                 n // 0x100,
                                 n % 0x100)
    elseif n <= 0xFFFFFFFF then
        buffer[#buffer+1] = char(0xDB,          -- str32
                                 n // 0x1000000,
                                 (n // 0x10000) % 0x100,
                                 (n // 0x100) % 0x100,
                                 n % 0x100)
    else
        error"overflow in pack 'string_compat'"
    end
    buffer[#buffer+1] = str
end

packers['_string'] = function (buffer, str)
    local n = #str
    if n <= 0x1F then
        buffer[#buffer+1] = char(0xA0 + n)      -- fixstr
    elseif n <= 0xFF then
        buffer[#buffer+1] = char(0xD9,          -- str8
                                 n)
    elseif n <= 0xFFFF then
        buffer[#buffer+1] = char(0xDA,          -- str16
                                 n // 0x100,
                                 n % 0x100)
    elseif n <= 0xFFFFFFFF then
        buffer[#buffer+1] = char(0xDB,          -- str32
                                 n // 0x1000000,
                                 (n // 0x10000) % 0x100,
                                 (n // 0x100) % 0x100,
                                 n % 0x100)
    else
        error"overflow in pack 'string'"
    end
    buffer[#buffer+1] = str
end

packers['binary'] = function (buffer, str)
    local n = #str
    if n <= 0xFF then
        buffer[#buffer+1] = char(0xC4,          -- bin8
                                 n)
    elseif n <= 0xFFFF then
        buffer[#buffer+1] = char(0xC5,          -- bin16
                                 n // 0x100,
                                 n % 0x100)
    elseif n <= 0xFFFFFFFF then
        buffer[#buffer+1] = char(0xC6,          -- bin32
                                 n // 0x1000000,
                                 (n // 0x10000) % 0x100,
                                 (n // 0x100) % 0x100,
                                 n % 0x100)
    else
        error"overflow in pack 'binary'"
    end
    buffer[#buffer+1] = str
end

local set_string = function (str)
    if str == 'string_compat' then
        packers['string'] = packers['string_compat']
    elseif str == 'string' then
        packers['string'] = packers['_string']
    elseif str == 'binary' then
        packers['string'] = packers['binary']
    else
        argerror('set_string', 1, "invalid option '" .. str .."'")
    end
end
m.set_string = set_string

packers['map'] = function (buffer, tbl, n)
    if n <= 0x0F then
        buffer[#buffer+1] = char(0x80 + n)      -- fixmap
    elseif n <= 0xFFFF then
        buffer[#buffer+1] = char(0xDE,          -- map16
                                 n // 0x100,
                                 n % 0x100)
    elseif n <= 0xFFFFFFFF then
        buffer[#buffer+1] = char(0xDF,          -- map32
                                 n // 0x1000000,
                                 (n // 0x10000) % 0x100,
                                 (n // 0x100) % 0x100,
                                 n % 0x100)
    else
        error"overflow in pack 'map'"
    end
    for k, v in pairs(tbl) do
        packers[type(k)](buffer, k)
        packers[type(v)](buffer, v)
    end
end

packers['array'] = function (buffer, tbl, n)
    if n <= 0x0F then
        buffer[#buffer+1] = char(0x90 + n)      -- fixarray
    elseif n <= 0xFFFF then
        buffer[#buffer+1] = char(0xDC,          -- array16
                                 n // 0x100,
                                 n % 0x100)
    elseif n <= 0xFFFFFFFF then
        buffer[#buffer+1] = char(0xDD,          -- array32
                                 n // 0x1000000,
                                 (n // 0x10000) % 0x100,
                                 (n // 0x100) % 0x100,
                                 n % 0x100)
    else
        error"overflow in pack 'array'"
    end
    for i = 1, n do
        local v = tbl[i]
        packers[type(v)](buffer, v)
    end
end

local set_array = function (array)
    if array == 'without_hole' then
        packers['_table'] = function (buffer, tbl)
            local is_map, n, max = false, 0, 0
            for k in pairs(tbl) do
                if type(k) == 'number' and k > 0 then
                    if k > max then
                        max = k
                    end
                else
                    is_map = true
                end
                n = n + 1
            end
            if max ~= n then    -- there are holes
                is_map = true
            end
            if is_map then
                return packers['map'](buffer, tbl, n)
            else
                return packers['array'](buffer, tbl, n)
            end
        end
    elseif array == 'with_hole' then
        packers['_table'] = function (buffer, tbl)
            local is_map, n, max = false, 0, 0
            for k in pairs(tbl) do
                if type(k) == 'number' and k > 0 then
                    if k > max then
                        max = k
                    end
                else
                    is_map = true
                end
                n = n + 1
            end
            if is_map then
                return packers['map'](buffer, tbl, n)
            else
                return packers['array'](buffer, tbl, max)
            end
        end
    elseif array == 'always_as_map' then
        packers['_table'] = function(buffer, tbl)
            local n = 0
            for k in pairs(tbl) do
                n = n + 1
            end
            return packers['map'](buffer, tbl, n)
        end
    else
        argerror('set_array', 1, "invalid option '" .. array .."'")
    end
end
m.set_array = set_array

packers['table'] = function (buffer, tbl)
    return packers['_table'](buffer, tbl)
end

packers['unsigned'] = function (buffer, n)
    if n >= 0 then
        if n <= 0x7F then
            buffer[#buffer+1] = char(n)         -- fixnum_pos
        elseif n <= 0xFF then
            buffer[#buffer+1] = char(0xCC,      -- uint8
                                     n)
        elseif n <= 0xFFFF then
            buffer[#buffer+1] = char(0xCD,      -- uint16
                                     n // 0x100,
                                     n % 0x100)
        elseif n <= 0xFFFFFFFF then
            buffer[#buffer+1] = char(0xCE,      -- uint32
                                     n // 0x1000000,
                                     (n // 0x10000) % 0x100,
                                     (n // 0x100) % 0x100,
                                     n % 0x100)
        else
            buffer[#buffer+1] = char(0xCF,      -- uint64
                                     n // 0x100000000000000,
                                     (n // 0x1000000000000) % 0x100,
                                     (n // 0x10000000000) % 0x100,
                                     (n // 0x100000000) % 0x100,
                                     (n // 0x1000000) % 0x100,
                                     (n // 0x10000) % 0x100,
                                     (n // 0x100) % 0x100,
                                     n % 0x100)
        end
    else
        if n >= -0x20 then
            buffer[#buffer+1] = char(0x100 + n) -- fixnum_neg
        elseif n >= -0x80 then
            buffer[#buffer+1] = char(0xD0,      -- int8
                                     0x100 + n)
        elseif n >= -0x8000 then
            n = 0x10000 + n
            buffer[#buffer+1] = char(0xD1,      -- int16
                                     n // 0x100,
                                     n % 0x100)
        elseif n >= -0x80000000 then
            n = 0x100000000 + n
            buffer[#buffer+1] = char(0xD2,      -- int32
                                     n // 0x1000000,
                                     (n // 0x10000) % 0x100,
                                     (n // 0x100) % 0x100,
                                     n % 0x100)
        else
            buffer[#buffer+1] = char(0xD3,      -- int64
                                     (n // 0x100000000000000) % 0x100,
                                     (n // 0x1000000000000) % 0x100,
                                     (n // 0x10000000000) % 0x100,
                                     (n // 0x100000000) % 0x100,
                                     (n // 0x1000000) % 0x100,
                                     (n // 0x10000) % 0x100,
                                     (n // 0x100) % 0x100,
                                     n % 0x100)
        end
    end
end

packers['signed'] = function (buffer, n)
    if n >= 0 then
        if n <= 0x7F then
            buffer[#buffer+1] = char(n)         -- fixnum_pos
        elseif n <= 0x7FFF then
            buffer[#buffer+1] = char(0xD1,      -- int16
                                     n // 0x100,
                                     n % 0x100)
        elseif n <= 0x7FFFFFFF then
            buffer[#buffer+1] = char(0xD2,      -- int32
                                     n // 0x1000000,
                                     (n // 0x10000) % 0x100,
                                     (n // 0x100) % 0x100,
                                     n % 0x100)
        else
            buffer[#buffer+1] = char(0xD3,      -- int64
                                     n // 0x100000000000000,
                                     (n // 0x1000000000000) % 0x100,
                                     (n // 0x10000000000) % 0x100,
                                     (n // 0x100000000) % 0x100,
                                     (n // 0x1000000) % 0x100,
                                     (n // 0x10000) % 0x100,
                                     (n // 0x100) % 0x100,
                                     n % 0x100)
        end
    else
        if n >= -0x20 then
            buffer[#buffer+1] = char(0xE0 + 0x20 + n)   -- fixnum_neg
        elseif n >= -0x80 then
            buffer[#buffer+1] = char(0xD0,      -- int8
                                     0x100 + n)
        elseif n >= -0x8000 then
            n = 0x10000 + n
            buffer[#buffer+1] = char(0xD1,      -- int16
                                     n // 0x100,
                                     n % 0x100)
        elseif n >= -0x80000000 then
            n = 0x100000000 + n
            buffer[#buffer+1] = char(0xD2,      -- int32
                                     n // 0x1000000,
                                     (n // 0x10000) % 0x100,
                                     (n // 0x100) % 0x100,
                                     n % 0x100)
        else
            buffer[#buffer+1] = char(0xD3,      -- int64
                                     (n // 0x100000000000000) % 0x100,
                                     (n // 0x1000000000000) % 0x100,
                                     (n // 0x10000000000) % 0x100,
                                     (n // 0x100000000) % 0x100,
                                     (n // 0x1000000) % 0x100,
                                     (n // 0x10000) % 0x100,
                                     (n // 0x100) % 0x100,
                                     n % 0x100)
        end
    end
end

local set_integer = function (integer)
    if integer == 'unsigned' then
        packers['integer'] = packers['unsigned']
    elseif integer == 'signed' then
        packers['integer'] = packers['signed']
    else
        argerror('set_integer', 1, "invalid option '" .. integer .."'")
    end
end
m.set_integer = set_integer

packers['float'] = function (buffer, n)
    local sign = 0
    if n < 0.0 then
        sign = 0x80
        n = -n
    end
    local mant, expo = frexp(n)
    if mant ~= mant then
        buffer[#buffer+1] = char(0xCA,  -- nan
                                 0xFF, 0x88, 0x00, 0x00)
    elseif mant == huge or expo > 0x80 then
        if sign == 0 then
            buffer[#buffer+1] = char(0xCA,      -- inf
                                     0x7F, 0x80, 0x00, 0x00)
        else
            buffer[#buffer+1] = char(0xCA,      -- -inf
                                     0xFF, 0x80, 0x00, 0x00)
        end
    elseif (mant == 0.0 and expo == 0) or expo < -0x7E then
        buffer[#buffer+1] = char(0xCA,  -- zero
                                 sign, 0x00, 0x00, 0x00)
    else
        expo = expo + 0x7E
        mant = (mant * 2.0 - 1.0) * ldexp(0.5, 24)
        buffer[#buffer+1] = char(0xCA,
                                 sign + (expo // 0x2),
                                 (expo % 0x2) * 0x80 + (mant // 0x10000),
                                 (mant // 0x100) % 0x100,
                                 mant % 0x100)
    end
end

packers['double'] = function (buffer, n)
    local sign = 0
    if n < 0.0 then
        sign = 0x80
        n = -n
    end
    local mant, expo = frexp(n)
    if mant ~= mant then
        buffer[#buffer+1] = char(0xCB,  -- nan
                                 0xFF, 0xF8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
    elseif mant == huge then
        if sign == 0 then
            buffer[#buffer+1] = char(0xCB,      -- inf
                                     0x7F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
        else
            buffer[#buffer+1] = char(0xCB,      -- -inf
                                     0xFF, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
        end
    elseif mant == 0.0 and expo == 0 then
        buffer[#buffer+1] = char(0xCB,  -- zero
                                 sign, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
    else
        expo = expo + 0x3FE
        mant = (mant * 2.0 - 1.0) * ldexp(0.5, 53)
        buffer[#buffer+1] = char(0xCB,
                                 sign + (expo // 0x10),
                                 (expo % 0x10) * 0x10 + (mant // 0x1000000000000),
                                 (mant // 0x10000000000) % 0x100,
                                 (mant // 0x100000000) % 0x100,
                                 (mant // 0x1000000) % 0x100,
                                 (mant // 0x10000) % 0x100,
                                 (mant // 0x100) % 0x100,
                                 mant % 0x100)
    end
end

local set_number = function (number)
    if number == 'integer' then
        packers['number'] = packers['signed']
    elseif number == 'float' then
        packers['number'] = function (buffer, n)
            if isfloat(n) then
                return packers['float'](buffer, n)
            else
                return packers['integer'](buffer, n)
            end
        end
    elseif number == 'double' then
        packers['number'] = function (buffer, n)
            if isfloat(n) then
                return packers['double'](buffer, n)
            else
                return packers['integer'](buffer, n)
            end
        end
    else
        argerror('set_number', 1, "invalid option '" .. number .."'")
    end
end
m.set_number = set_number

for k = 0, 4 do
    local n = 2^k
    local fixext = 0xD4 + k
    packers['fixext' .. n] = function (buffer, tag, data)
        assert(#data == n, "bad length for fixext" .. n)
        buffer[#buffer+1] = char(fixext,
                                 tag < 0 and tag + 0x100 or tag)
        buffer[#buffer+1] = data
    end
end

packers['ext'] = function (buffer, tag, data)
    local n = #data
    if n <= 0xFF then
        buffer[#buffer+1] = char(0xC7,          -- ext8
                                 n,
                                 tag < 0 and tag + 0x100 or tag)
    elseif n <= 0xFFFF then
        buffer[#buffer+1] = char(0xC8,          -- ext16
                                 n // 0x100,
                                 n % 0x100,
                                 tag < 0 and tag + 0x100 or tag)
    elseif n <= 0xFFFFFFFF then
        buffer[#buffer+1] = char(0xC9,          -- ext&32
                                 n // 0x1000000,
                                 (n // 0x10000) % 0x100,
                                 (n // 0x100) % 0x100,
                                 n % 0x100,
                                 tag < 0 and tag + 0x100 or tag)
    else
        error"overflow in pack 'ext'"
    end
    buffer[#buffer+1] = data
end

function m.pack (data)
    local buffer = {}
    packers[type(data)](buffer, data)
    return tconcat(buffer)
end


local types_map = setmetatable({
    [0xC0] = 'nil',
    [0xC2] = 'false',
    [0xC3] = 'true',
    [0xC4] = 'bin8',
    [0xC5] = 'bin16',
    [0xC6] = 'bin32',
    [0xC7] = 'ext8',
    [0xC8] = 'ext16',
    [0xC9] = 'ext32',
    [0xCA] = 'float',
    [0xCB] = 'double',
    [0xCC] = 'uint8',
    [0xCD] = 'uint16',
    [0xCE] = 'uint32',
    [0xCF] = 'uint64',
    [0xD0] = 'int8',
    [0xD1] = 'int16',
    [0xD2] = 'int32',
    [0xD3] = 'int64',
    [0xD4] = 'fixext1',
    [0xD5] = 'fixext2',
    [0xD6] = 'fixext4',
    [0xD7] = 'fixext8',
    [0xD8] = 'fixext16',
    [0xD9] = 'str8',
    [0xDA] = 'str16',
    [0xDB] = 'str32',
    [0xDC] = 'array16',
    [0xDD] = 'array32',
    [0xDE] = 'map16',
    [0xDF] = 'map32',
}, { __index = function (t, k)
        if k < 0xC0 then
            if k < 0x80 then
                return 'fixnum_pos'
            elseif k < 0x90 then
                return 'fixmap'
            elseif k < 0xA0 then
                return 'fixarray'
            else
                return 'fixstr'
            end
        elseif k > 0xDF then
            return 'fixnum_neg'
        else
            return 'reserved' .. k
        end
end })
m.types_map = types_map

local unpackers = setmetatable({}, {
    __index = function (t, k) error("unpack '" .. k .. "' is unimplemented") end
})
m.unpackers = unpackers

local function unpack_array (c, n)
    local t = {}
    local decode = unpackers['any']
    for i = 1, n do
        t[i] = decode(c)
    end
    return t
end

local function unpack_map (c, n)
    local t = {}
    local decode = unpackers['any']
    for i = 1, n do
        local k = decode(c)
        t[k] = decode(c)
    end
    return t
end

unpackers['any'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i > j then
        c:underflow(i)
        s, i, j = c.s, c.i, c.j
    end
    local val = s:sub(i, i):byte()
    c.i = i+1
    return unpackers[types_map[val]](c, val)
end

unpackers['nil'] = function ()
    return nil
end

unpackers['false'] = function ()
    return false
end

unpackers['true'] = function ()
    return true
end

unpackers['float'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+3 > j then
        c:underflow(i+3)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2, b3, b4 = s:sub(i, i+3):byte(1, 4)
    local sign = b1 > 0x7F
    local expo = (b1 % 0x80) * 0x2 + (b2 // 0x80)
    local mant = ((b2 % 0x80) * 0x100 + b3) * 0x100 + b4
    if sign then
        sign = -1
    else
        sign = 1
    end
    local n
    if mant == 0 and expo == 0 then
        n = sign * 0.0
    elseif expo == 0xFF then
        if mant == 0 then
            n = sign * huge
        else
            n = 0.0/0.0
        end
    else
        n = sign * ldexp(1.0 + mant / 0x800000, expo - 0x7F)
    end
    c.i = i+4
    return n
end

unpackers['double'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+7 > j then
        c:underflow(i+7)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2, b3, b4, b5, b6, b7, b8 = s:sub(i, i+7):byte(1, 8)
    local sign = b1 > 0x7F
    local expo = (b1 % 0x80) * 0x10 + (b2 // 0x10)
    local mant = ((((((b2 % 0x10) * 0x100 + b3) * 0x100 + b4) * 0x100 + b5) * 0x100 + b6) * 0x100 + b7) * 0x100 + b8
    if sign then
        sign = -1
    else
        sign = 1
    end
    local n
    if mant == 0 and expo == 0 then
        n = sign * 0.0
    elseif expo == 0x7FF then
        if mant == 0 then
            n = sign * huge
        else
            n = 0.0/0.0
        end
    else
        n = sign * ldexp(1.0 + mant / 0x10000000000000, expo - 0x3FF)
    end
    c.i = i+8
    return n
end

unpackers['fixnum_pos'] = function (c, val)
    return val
end

unpackers['uint8'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i > j then
        c:underflow(i)
        s, i, j = c.s, c.i, c.j
    end
    local b1 = s:sub(i, i):byte()
    c.i = i+1
    return b1
end

unpackers['uint16'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+1 > j then
        c:underflow(i+1)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2 = s:sub(i, i+1):byte(1, 2)
    c.i = i+2
    return b1 * 0x100 + b2
end

unpackers['uint32'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+3 > j then
        c:underflow(i+3)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2, b3, b4 = s:sub(i, i+3):byte(1, 4)
    c.i = i+4
    return ((b1 * 0x100 + b2) * 0x100 + b3) * 0x100 + b4
end

unpackers['uint64'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+7 > j then
        c:underflow(i+7)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2, b3, b4, b5, b6, b7, b8 = s:sub(i, i+7):byte(1, 8)
    c.i = i+8
    return ((((((b1 * 0x100 + b2) * 0x100 + b3) * 0x100 + b4) * 0x100 + b5) * 0x100 + b6) * 0x100 + b7) * 0x100 + b8
end

unpackers['fixnum_neg'] = function (c, val)
    return val - 0x100
end

unpackers['int8'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i > j then
        c:underflow(i)
        s, i, j = c.s, c.i, c.j
    end
    local b1 = s:sub(i, i):byte()
    c.i = i+1
    if b1 < 0x80 then
        return b1
    else
        return b1 - 0x100
    end
end

unpackers['int16'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+1 > j then
        c:underflow(i+1)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2 = s:sub(i, i+1):byte(1, 2)
    c.i = i+2
    if b1 < 0x80 then
        return b1 * 0x100 + b2
    else
        return ((b1 - 0xFF) * 0x100 + (b2 - 0xFF)) - 1
    end
end

unpackers['int32'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+3 > j then
        c:underflow(i+3)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2, b3, b4 = s:sub(i, i+3):byte(1, 4)
    c.i = i+4
    if b1 < 0x80 then
        return ((b1 * 0x100 + b2) * 0x100 + b3) * 0x100 + b4
    else
        return ((((b1 - 0xFF) * 0x100 + (b2 - 0xFF)) * 0x100 + (b3 - 0xFF)) * 0x100 + (b4 - 0xFF)) - 1
    end
end

unpackers['int64'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+7 > j then
        c:underflow(i+7)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2, b3, b4, b5, b6, b7, b8 = s:sub(i, i+7):byte(1, 8)
    c.i = i+8
    if b1 < 0x80 then
        return ((((((b1 * 0x100 + b2) * 0x100 + b3) * 0x100 + b4) * 0x100 + b5) * 0x100 + b6) * 0x100 + b7) * 0x100 + b8
    else
        return ((((((((b1 - 0xFF) * 0x100 + (b2 - 0xFF)) * 0x100 + (b3 - 0xFF)) * 0x100 + (b4 - 0xFF)) * 0x100 + (b5 - 0xFF)) * 0x100 + (b6 - 0xFF)) * 0x100 + (b7 - 0xFF)) * 0x100 + (b8 - 0xFF)) - 1
    end
end

unpackers['fixstr'] = function (c, val)
    local s, i, j = c.s, c.i, c.j
    local n = val % 0x20
    local e = i+n-1
    if e > j then
        c:underflow(e)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+n
    return s:sub(i, e)
end

unpackers['str8'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i > j then
        c:underflow(i)
        s, i, j = c.s, c.i, c.j
    end
    local n = s:sub(i, i):byte()
    i = i+1
    c.i = i
    local e = i+n-1
    if e > j then
        c:underflow(e)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+n
    return s:sub(i, e)
end

unpackers['str16'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+1 > j then
        c:underflow(i+1)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2 = s:sub(i, i+1):byte(1, 2)
    i = i+2
    c.i = i
    local n = b1 * 0x100 + b2
    local e = i+n-1
    if e > j then
        c:underflow(e)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+n
    return s:sub(i, e)
end

unpackers['str32'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+3 > j then
        c:underflow(i+3)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2, b3, b4 = s:sub(i, i+3):byte(1, 4)
    i = i+4
    c.i = i
    local n = ((b1 * 0x100 + b2) * 0x100 + b3) * 0x100 + b4
    local e = i+n-1
    if e > j then
        c:underflow(e)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+n
    return s:sub(i, e)
end

unpackers['bin8'] = unpackers['str8']
unpackers['bin16'] = unpackers['str16']
unpackers['bin32'] = unpackers['str32']

unpackers['fixarray'] = function (c, val)
    return unpack_array(c, val % 0x10)
end

unpackers['array16'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+1 > j then
        c:underflow(i+1)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2 = s:sub(i, i+1):byte(1, 2)
    c.i = i+2
    return unpack_array(c, b1 * 0x100 + b2)
end

unpackers['array32'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+3 > j then
        c:underflow(i+3)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2, b3, b4 = s:sub(i, i+3):byte(1, 4)
    c.i = i+4
    return unpack_array(c, ((b1 * 0x100 + b2) * 0x100 + b3) * 0x100 + b4)
end

unpackers['fixmap'] = function (c, val)
    return unpack_map(c, val % 0x10)
end

unpackers['map16'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+1 > j then
        c:underflow(i+1)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2 = s:sub(i, i+1):byte(1, 2)
    c.i = i+2
    return unpack_map(c, b1 * 0x100 + b2)
end

unpackers['map32'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+3 > j then
        c:underflow(i+3)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2, b3, b4 = s:sub(i, i+3):byte(1, 4)
    c.i = i+4
    return unpack_map(c, ((b1 * 0x100 + b2) * 0x100 + b3) * 0x100 + b4)
end

function m.build_ext (tag, data)
    return nil
end

for k = 0, 4 do
    local n = 2^k
    unpackers['fixext' .. n] = function (c)
        local s, i, j = c.s, c.i, c.j
        if i > j then
            c:underflow(i)
            s, i, j = c.s, c.i, c.j
        end
        local tag = s:sub(i, i):byte()
        i = i+1
        c.i = i
        local e = i+n-1
        if e > j then
            c:underflow(e)
            s, i, j = c.s, c.i, c.j
        end
        c.i = i+n
        return m.build_ext(tag < 0x80 and tag or tag - 0x100, s:sub(i, e))
    end
end

unpackers['ext8'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i > j then
        c:underflow(i)
        s, i, j = c.s, c.i, c.j
    end
    local n = s:sub(i, i):byte()
    i = i+1
    c.i = i
    if i > j then
        c:underflow(i)
        s, i, j = c.s, c.i, c.j
    end
    local tag = s:sub(i, i):byte()
    i = i+1
    c.i = i
    local e = i+n-1
    if e > j then
        c:underflow(e)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+n
    return m.build_ext(tag < 0x80 and tag or tag - 0x100, s:sub(i, e))
end

unpackers['ext16'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+1 > j then
        c:underflow(i+1)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2 = s:sub(i, i+1):byte(1, 2)
    i = i+2
    c.i = i
    local n = b1 * 0x100 + b2
    if i > j then
        c:underflow(i)
        s, i, j = c.s, c.i, c.j
    end
    local tag = s:sub(i, i):byte()
    i = i+1
    c.i = i
    local e = i+n-1
    if e > j then
        c:underflow(e)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+n
    return m.build_ext(tag < 0x80 and tag or tag - 0x100, s:sub(i, e))
end

unpackers['ext32'] = function (c)
    local s, i, j = c.s, c.i, c.j
    if i+3 > j then
        c:underflow(i+3)
        s, i, j = c.s, c.i, c.j
    end
    local b1, b2, b3, b4 = s:sub(i, i+3):byte(1, 4)
    i = i+4
    c.i = i
    local n = ((b1 * 0x100 + b2) * 0x100 + b3) * 0x100 + b4
    if i > j then
        c:underflow(i)
        s, i, j = c.s, c.i, c.j
    end
    local tag = s:sub(i, i):byte()
    i = i+1
    c.i = i
    local e = i+n-1
    if e > j then
        c:underflow(e)
        s, i, j = c.s, c.i, c.j
    end
    c.i = i+n
    return m.build_ext(tag < 0x80 and tag or tag - 0x100, s:sub(i, e))
end


local function cursor_string (str)
    return {
        s = str,
        i = 1,
        j = #str,
        underflow = function (self)
                        error "missing bytes"
                    end,
    }
end

local function cursor_loader (ld)
    return {
        s = '',
        i = 1,
        j = 0,
        underflow = function (self, e)
                        self.s = self.s:sub(self.i)
                        e = e - self.i + 1
                        self.i = 1
                        self.j = 0
                        while e > self.j do
                            local chunk = ld()
                            if not chunk then
                                error "missing bytes"
                            end
                            self.s = self.s .. chunk
                            self.j = #self.s
                        end
                    end,
    }
end

function m.unpack (s)
    checktype('unpack', 1, s, 'string')
    local cursor = cursor_string(s)
    local data = unpackers['any'](cursor)
    if cursor.i < cursor.j then
        error "extra bytes"
    end
    return data
end

function m.unpacker (src)
    if type(src) == 'string' then
        local cursor = cursor_string(src)
        return function ()
            if cursor.i <= cursor.j then
                return cursor.i, unpackers['any'](cursor)
            end
        end
    elseif type(src) == 'function' then
        local cursor = cursor_loader(src)
        return function ()
            if cursor.i > cursor.j then
                pcall(cursor.underflow, cursor, cursor.i)
            end
            if cursor.i <= cursor.j then
                return true, unpackers['any'](cursor)
            end
        end
    else
        argerror('unpacker', 1, "string or function expected, got " .. type(src))
    end
end

set_string'string_compat'
set_integer'signed'
if NUMBER_INTEGRAL then
    set_number'integer'
elseif SIZEOF_NUMBER == 4 then
    set_number'float'
else
    set_number'double'
end
set_array'without_hole'

m.full64bits = true
m._VERSION = "0.3.0"
m._DESCRIPTION = "lua-MessagePack : a pure Lua implementation"
m._COPYRIGHT = "Copyright (c) 2012-2013 Francois Perrad"
return m
--
-- This library is licensed under the terms of the MIT/X11 license,
-- like Lua itself.
--