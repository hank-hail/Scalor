local Config = require('@self/Config')
local BASE_SUFFIXES = Config.BASE_SUFFIXES
local SUFFIX_TO_POWER = Config.SUFFIX_TO_POWER
local MAX_ADD_DIFF = Config.MAX_ADD_DIFF
local MAX_SAFE_INTEGER = Config.MAX_SAFE_INTEGER

export type ScalorInput = number | string | Scalor

export type Scalor = typeof(setmetatable({} :: {
    mantissa: number,
    exponent: number,

    add: (self: Scalor, value: ScalorInput) -> Scalor,
    sub: (self: Scalor, value: ScalorInput) -> Scalor,
    mul: (self: Scalor, value: ScalorInput) -> Scalor,
    div: (self: Scalor, value: ScalorInput) -> Scalor,
    mod: (self: Scalor, value: ScalorInput) -> Scalor,
    exp: (self: Scalor, value: ScalorInput) -> Scalor,
    Scientific: (self: Scalor) -> string,
    Short: (self: Scalor) -> string,

    __add: (left: ScalorInput, right: ScalorInput) -> Scalor,
    __sub: (left: ScalorInput, right: ScalorInput) -> Scalor,
    __mul: (left: ScalorInput, right: ScalorInput) -> Scalor,
    __div: (left: ScalorInput, right: ScalorInput) -> Scalor,
    __mod: (left: ScalorInput, right: ScalorInput) -> Scalor,
    __pow: (left: ScalorInput, right: ScalorInput) -> Scalor,
    __unm: (value: ScalorInput) -> Scalor,
    __tostring: (value: Scalor) -> string,
	__len: (value: Scalor) -> string
}, {}))

local Scalor = {}
Scalor.__index = Scalor

local function normalize(mantissa: number, exponent: number): (number, number)
	assert(mantissa == mantissa and not math.isinf(mantissa), "mantissa must be finite")
	assert(exponent == exponent and not math.isinf(exponent), "exponent must be finite")
	assert(exponent % 1 == 0, "exponent must be an integer")

	if mantissa == 0 then
		return 0, 0
	end

    local sign = mantissa < 0 and -1 or 1

    mantissa = math.abs(mantissa)
	local shift = math.floor(math.log10(mantissa))
	mantissa /= 10 ^ shift
	exponent += shift

	if mantissa >= 10 then
		mantissa *= 0.1
		exponent += 1
	elseif mantissa < 1 then
		mantissa *= 10
		exponent -= 1
	end

	return sign * mantissa, exponent
end

local function scientific(value: ScalorInput): (number, number)
	local kind = type(value)

	if kind == "number" then
		return normalize(
            value :: number, 
            0
        )
	elseif kind == "table" then
		local data = value :: Scalor
		return normalize(
            data.mantissa, 
            data.exponent
        )
	else
		local text = value :: string
		local start_pos = 1
		local end_pos = #text

		while start_pos <= end_pos do
			local code = text:byte(start_pos)
			if code ~= 9 and code ~= 10 and code ~= 11 and code ~= 12 and code ~= 13 and code ~= 32 then
				break
			end

			start_pos += 1
		end

		while end_pos >= start_pos do
			local code = text:byte(end_pos)
			if code ~= 9 and code ~= 10 and code ~= 11 and code ~= 12 and code ~= 13 and code ~= 32 then
				break
			end

			end_pos -= 1
		end

		if start_pos > end_pos then
			error(`invalid number string: {text}`)
		end

		local trimmed = text:sub(start_pos, end_pos)
		local scientific_pos = trimmed:find('e', 1, true) or trimmed:find('E', 1, true)
		if scientific_pos then
			local mantissa = tonumber(trimmed:sub(1, scientific_pos - 1))
			local exponent = tonumber(trimmed:sub(scientific_pos + 1))

			if mantissa and exponent and not math.isinf(mantissa) and not math.isnan(mantissa) and not math.isinf(exponent) and not math.isnan(exponent) then
				if exponent % 1 ~= 0 then
					error(`scientific exponent must be an integer: {text}`)
				end

				return normalize(mantissa, exponent)
			end
		end

		local direct = tonumber(trimmed)
		if direct then
			if math.isinf(direct) or math.isnan(direct) then
				error(`parsed value is not finite: {text}`)
			end

			return normalize(direct, 0)
		end

		local split = #trimmed
		while split > 0 do
			local code = trimmed:byte(split)
			if not code or ((code < 65 or code > 90) and (code < 97 or code > 122)) then
				break
			end

			split -= 1
		end

		if split == #trimmed then
			error(`invalid number string: {text}`)
		end

		local mantissa = tonumber(trimmed:sub(1, split))
		local power = SUFFIX_TO_POWER[trimmed:sub(split + 1)]

		if not mantissa or math.isinf(mantissa) or math.isnan(mantissa) then
			error(`invalid numeric portion in abbreviated number: {text}`)
		end

		if not power then
			error(`unknown suffix in abbreviated number: {text}`)
		end

		return normalize(mantissa, (power - 1) * 3)
	end
end

local function shift(value: number, decimals: number): string
	if decimals == 0 then
		return tostring(value)
	end

	if decimals == 1 then
		local whole = value // 10
		return whole .. '.' .. (value - whole * 10)
	end

	local whole = value // 100
	local fraction = value - whole * 100
	return whole .. '.' .. (fraction // 10) .. (fraction % 10)
end

local function add(left_mantissa: number, left_exponent: number, right_mantissa: number, right_exponent: number): (number, number)
	if left_mantissa == 0 then
		return right_mantissa, right_exponent
	end

	if right_mantissa == 0 then
		return left_mantissa, left_exponent
	end

	local larger_mantissa = left_mantissa
	local larger_exponent = left_exponent
	local smaller_mantissa = right_mantissa
	local smaller_exponent = right_exponent

	if smaller_exponent > larger_exponent then
		larger_mantissa, smaller_mantissa = smaller_mantissa, larger_mantissa
		larger_exponent, smaller_exponent = smaller_exponent, larger_exponent
	end

	local exponent_difference = larger_exponent - smaller_exponent
	if exponent_difference > MAX_ADD_DIFF then
		return larger_mantissa, larger_exponent
	end

	return normalize(
        larger_mantissa + smaller_mantissa * 10 ^ (-exponent_difference), 
        larger_exponent
    )
end

local function sub(left_mantissa: number, left_exponent: number, right_mantissa: number, right_exponent: number): (number, number)
	return add(
		left_mantissa,
		left_exponent,
		-right_mantissa,
		right_exponent
	)
end

local function mul(left_mantissa: number, left_exponent: number, right_mantissa: number, right_exponent: number): (number, number)
	if left_mantissa == 0 or right_mantissa == 0 then
		return 0, 0
	end

	return normalize(
		left_mantissa * right_mantissa,
		left_exponent + right_exponent
	)
end

local function div(left_mantissa: number, left_exponent: number, right_mantissa: number, right_exponent: number): (number, number)
	assert(right_mantissa ~= 0, "division by zero")

	if left_mantissa == 0 then
		return 0, 0
	end

	return normalize(
		left_mantissa / right_mantissa,
		left_exponent - right_exponent
	)
end

local function regular_value(mantissa: number, exponent: number, operation: string): number
	local value = mantissa * 10 ^ exponent
	assert(value == value and not math.isinf(value), `{operation} only supports values that fit in a regular number`)
	return value
end

local function integer_value(mantissa: number, exponent: number, operation: string): number
	local value = regular_value(mantissa, exponent, operation)
	assert(value % 1 == 0, `${operation} requires an integer exponent`)
	assert(math.abs(value) <= MAX_SAFE_INTEGER, `${operation} exponent is too large`)
	return value
end

local function mod(left_mantissa: number, left_exponent: number, right_mantissa: number, right_exponent: number): (number, number)
	assert(right_mantissa ~= 0, "modulo by zero")

	if left_mantissa == 0 then
		return 0, 0
	end

	return normalize(
		regular_value(left_mantissa, left_exponent, "modulo") % regular_value(right_mantissa, right_exponent, "modulo"),
		0
	)
end

local function exp(left_mantissa: number, left_exponent: number, right_mantissa: number, right_exponent: number): (number, number)
	local power = integer_value(right_mantissa, right_exponent, "power")

	if left_mantissa == 0 then
		assert(power > 0, "0 cannot be raised to a non-positive power")
		return 0, 0
	end

	if power == 0 then
		return 1, 0
	end

	if power == 1 then
		return left_mantissa, left_exponent
	end

	local invert = power < 0
	if invert then
		power = -power
	end

	local result_mantissa = 1
	local result_exponent = 0
	local base_mantissa = left_mantissa
	local base_exponent = left_exponent

	while power > 0 do
		if power % 2 == 1 then
			result_mantissa, result_exponent = mul(result_mantissa, result_exponent, base_mantissa, base_exponent)
		end

		power = math.floor(power / 2)
		if power > 0 then
			base_mantissa, base_exponent = mul(base_mantissa, base_exponent, base_mantissa, base_exponent)
		end
	end

	if invert then
		return div(1, 0, result_mantissa, result_exponent)
	end

	return result_mantissa, result_exponent
end

function Scalor.new(mantissa: number, exponent: number?): Scalor
    local self = {}
    self.mantissa, self.exponent = normalize(mantissa, exponent or 0)

    return setmetatable(self, Scalor) :: any
end

function Scalor.zero(): Scalor
    local self = {}
    self.mantissa = 0
    self.exponent = 0

    return setmetatable(self, Scalor) :: any
end

function Scalor.one(): Scalor
    local self = {}
    self.mantissa = 1
    self.exponent = 0

    return setmetatable(self, Scalor) :: any
end

function Scalor.add(self: Scalor, value: ScalorInput): Scalor
	self.mantissa, self.exponent = add(
        self.mantissa, 
        self.exponent, 
        scientific(value)
    )

	return self
end

function Scalor.sub(self: Scalor, value: ScalorInput): Scalor
	self.mantissa, self.exponent = sub(
        self.mantissa, 
        self.exponent, 
        scientific(value)
    )

	return self
end

function Scalor.mul(self: Scalor, value: ScalorInput): Scalor
	self.mantissa, self.exponent = mul(
        self.mantissa,
        self.exponent,
        scientific(value)
    )

	return self
end

function Scalor.div(self: Scalor, value: ScalorInput): Scalor
	self.mantissa, self.exponent = div(
        self.mantissa,
        self.exponent,
        scientific(value)
    )

	return self
end

function Scalor.mod(self: Scalor, value: ScalorInput): Scalor
	self.mantissa, self.exponent = mod(
        self.mantissa,
        self.exponent,
        scientific(value)
    )

	return self
end

function Scalor.exp(self: Scalor, value: ScalorInput): Scalor
	self.mantissa, self.exponent = exp(
        self.mantissa,
        self.exponent,
        scientific(value)
    )

	return self
end

function Scalor.Scientific(self: Scalor): string
	local mantissa, exponent = self.mantissa, self.exponent
	if mantissa == 0 then
		return '0e0'
	end

	local sign = ''
	if mantissa < 0 then
		sign = '-'
		mantissa = -mantissa
	end

	local scaled = math.round(mantissa * 100)
	if scaled >= 1000 then
		scaled = 100
		exponent += 1
	end

	return sign .. shift(scaled, 2) .. 'e' .. exponent
end

function Scalor.Short(self: Scalor): string
	local mantissa, exponent = self.mantissa, self.exponent
	if mantissa == 0 then
		return '0'
	end

	local sign = ''
	if mantissa < 0 then
		sign = '-'
		mantissa = -mantissa
	end

	if exponent >= -6 and exponent < 3 then
		return sign .. tostring(mantissa * 10 ^ exponent)
	end

	if self.exponent < 0 then
		return self:Scientific()
	end

	local power = self.exponent // 3 + 1
	if power > #BASE_SUFFIXES then
		return self:Scientific()
	end

	local scaled = self.mantissa * 10 ^ (self.exponent - (power - 1) * 3)
	local decimals = scaled < 10 and 2 or scaled < 100 and 1 or 0
	local display = math.round(scaled * (decimals == 0 and 1 or decimals == 1 and 10 or 100))

	if display >= 1000 then
		if decimals == 2 then
			decimals = 1
			display = 100
		elseif decimals == 1 then
			decimals = 0
			display = 100
		else
			power += 1
			decimals = 2
			display = 100
		end
	end

	if power > #BASE_SUFFIXES then
		return self:Scientific()
	end

	return sign .. shift(display, decimals) .. BASE_SUFFIXES[power]
end

function Scalor.__add(left: ScalorInput, right: ScalorInput): Scalor
	local left_mantissa, left_exponent = scientific(left)

	return Scalor.new(
        add(
            left_mantissa, 
            left_exponent,
			scientific(right)
        )
    )
end

function Scalor.__sub(left: ScalorInput, right: ScalorInput): Scalor
	local left_mantissa, left_exponent = scientific(left)

	return Scalor.new(
        sub(
            left_mantissa, 
            left_exponent, 
			scientific(right)
        )
    )
end

function Scalor.__mul(left: ScalorInput, right: ScalorInput): Scalor
	local left_mantissa, left_exponent = scientific(left)

	return Scalor.new(
        mul(
            left_mantissa,
            left_exponent,
			scientific(right)
        )
    )
end

function Scalor.__div(left: ScalorInput, right: ScalorInput): Scalor
	local left_mantissa, left_exponent = scientific(left)

	return Scalor.new(
        div(
            left_mantissa,
            left_exponent,
			scientific(right)
        )
    )
end

function Scalor.__mod(left: ScalorInput, right: ScalorInput): Scalor
	local left_mantissa, left_exponent = scientific(left)

	return Scalor.new(
        mod(
            left_mantissa,
            left_exponent,
			scientific(right)
        )
    )
end

function Scalor.__pow(left: ScalorInput, right: ScalorInput): Scalor
	local left_mantissa, left_exponent = scientific(left)

	return Scalor.new(
        exp(
            left_mantissa,
            left_exponent,
			scientific(right)
        )
    )
end

function Scalor.__unm(value: ScalorInput): Scalor
	local mantissa, exponent = scientific(value)
	
	return Scalor.new(
		-mantissa, 
		exponent
	)
end

function Scalor.__tostring(value: Scalor): string
	return value:Scientific()
end

function Scalor.__len(value: Scalor): string
	return value:Scientific()
end

return Scalor
