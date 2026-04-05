--!strict
--!native
local Config = require'@self/Config'
local Suffixes = require'@self/Suffixes'
local MAX_ADD_DIFF = Config.MAX_ADD_DIFF
local MAX_SAFE_INTEGER = Config.MAX_SAFE_INTEGER

local POWER_TO_SUFFIX = Suffixes.SUFFIXES
local SUFFIX_TO_POWER = Suffixes.SUFFIX_TO_POWER
local SMALL_POW10 = {[0] = 1, 10, 100}

export type ScalorInput = number | string | Scalor

export type Scalor = typeof(setmetatable({} :: {
	mantissa: number,
	exponent: number,

	add: (self: Scalor, value: ScalorInput) -> Scalor,
	sub: (self: Scalor, value: ScalorInput) -> Scalor,
	mul: (self: Scalor, value: ScalorInput) -> Scalor,
	div: (self: Scalor, value: ScalorInput) -> Scalor,
	mod: (self: Scalor, value: ScalorInput) -> Scalor,
	pow: (self: Scalor, value: ScalorInput) -> Scalor,
	root: (self: Scalor, degree: ScalorInput) -> Scalor,

	Equals: (self: Scalor, value: ScalorInput) -> boolean,
	Scientific: (self: Scalor) -> string,
	Short: (self: Scalor) -> string,

	__add: (left: ScalorInput, right: ScalorInput) -> Scalor,
	__sub: (left: ScalorInput, right: ScalorInput) -> Scalor,
	__mul: (left: ScalorInput, right: ScalorInput) -> Scalor,
	__div: (left: ScalorInput, right: ScalorInput) -> Scalor,
	__mod: (left: ScalorInput, right: ScalorInput) -> Scalor,
	__pow: (left: ScalorInput, right: ScalorInput) -> Scalor,
	__concat: (left: ScalorInput, right: ScalorInput) -> string,
	__eq: (left: ScalorInput, right: ScalorInput) -> boolean,
	__lt: (left: ScalorInput, right: ScalorInput) -> boolean,
	__le: (left: ScalorInput, right: ScalorInput) -> boolean,
	__unm: (value: ScalorInput) -> Scalor,
	__tostring: (value: Scalor) -> string,
	__len: (value: Scalor) -> number
}, {}))

local Scalor = {}
Scalor.__index = Scalor

local NEG_POW10 = {[0] = 1}
for exponent_difference = 1, MAX_ADD_DIFF do
	NEG_POW10[exponent_difference] = 10 ^ (-exponent_difference)
end

local function new_from_normalized(mantissa: number, exponent: number): Scalor
	return setmetatable({
		mantissa = mantissa,
		exponent = exponent,
	}, Scalor) :: any
end

local function normalize(mantissa: number, exponent: number): (number, number)
	if mantissa ~= mantissa or math.isinf(mantissa) then
		error('mantissa must be finite')
	elseif exponent ~= exponent or math.isinf(exponent) then
		error('exponent must be finite')
	elseif exponent % 1 ~= 0 then 
		error('exponent must be an integer')
	elseif mantissa == 0 then
		return 0, 0
	end

	local sign = mantissa < 0 and -1 or 1
	mantissa = math.abs(mantissa)

	if mantissa >= 1 then
		if mantissa < 10 then
			return sign * mantissa, exponent
		end

		if mantissa < 100 then
			return sign * mantissa * 0.1, exponent + 1
		end
	elseif mantissa >= 0.1 then
		return sign * mantissa * 10, exponent - 1
	end

	local shift = math.log10(mantissa) // 1
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
		return normalize(value :: number, 0)
	elseif kind == "table" then
		local data = value :: any

		if getmetatable(data) == Scalor then
			return data.mantissa, data.exponent
		end

		return normalize(data.mantissa, data.exponent)
	else
		local text = value :: string
		local start_pos = 1
		local end_pos = #text

		while start_pos <= end_pos do
			local code = string.byte(text, start_pos)
			if code ~= 9 and code ~= 10 and code ~= 11 and code ~= 12 and code ~= 13 and code ~= 32 then
				break
			end

			start_pos += 1
		end

		while end_pos >= start_pos do
			local code = string.byte(text, end_pos)
			if code ~= 9 and code ~= 10 and code ~= 11 and code ~= 12 and code ~= 13 and code ~= 32 then
				break
			end

			end_pos -= 1
		end

		if start_pos > end_pos then
			error(`invalid number string: {text}`)
		end

		local trimmed = string.sub(text, start_pos, end_pos)
		local scientific_pos = string.find(trimmed, 'e', 1, true) or string.find(trimmed, 'E', 1, true)
		if scientific_pos then
			local parsed_mantissa = tonumber(string.sub(trimmed, 1, scientific_pos - 1))
			local parsed_exponent = tonumber(string.sub(trimmed, scientific_pos + 1))

			if parsed_mantissa and parsed_exponent and not math.isinf(parsed_mantissa) and not math.isnan(parsed_mantissa) and not math.isinf(parsed_exponent) and not math.isnan(parsed_exponent) then
				if parsed_exponent % 1 ~= 0 then
					error(`scientific exponent must be an integer: {text}`)
				end

				return normalize(parsed_mantissa, parsed_exponent)
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
			local code = string.byte(trimmed, split)
			if not code or ((code < 65 or code > 90) and (code < 97 or code > 122)) then
				break
			end

			split -= 1
		end

		if split == #trimmed then
			error(`invalid number string: {text}`)
		end

		local parsed_mantissa = tonumber(string.sub(trimmed, 1, split))
		local power = SUFFIX_TO_POWER[string.sub(trimmed, split + 1)]

		if not parsed_mantissa or math.isinf(parsed_mantissa) or math.isnan(parsed_mantissa) then
			error(`invalid numeric portion in abbreviated number: {text}`)
		end

		if not power then
			error(`unknown suffix in abbreviated number: {text}`)
		end

		return normalize(parsed_mantissa, (power - 1) * 3)
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

local function scientific_string(mantissa: number, exponent: number): string
	if mantissa == 0 then
		return '0e0'
	end

	local sign = ''
	if mantissa < 0 then
		sign = '-'
		mantissa = -mantissa
	end

	local scaled = math.round(mantissa * SMALL_POW10[2])
	if scaled >= 1000 then
		scaled = 100
		exponent += 1
	end

	return sign .. shift(scaled, 2) .. 'e' .. exponent
end

local function compare_parts(left_mantissa: number, left_exponent: number, right_mantissa: number, right_exponent: number): number
	if left_mantissa == right_mantissa and left_exponent == right_exponent then
		return 0
	end

	if left_mantissa == 0 then
		return right_mantissa > 0 and -1 or 1
	end

	if right_mantissa == 0 then
		return left_mantissa < 0 and -1 or 1
	end

	local left_negative = left_mantissa < 0
	if left_negative ~= (right_mantissa < 0) then
		return left_negative and -1 or 1
	end

	if left_exponent ~= right_exponent then
		if left_negative then
			return left_exponent > right_exponent and -1 or 1
		end

		return left_exponent < right_exponent and -1 or 1
	end

	return left_mantissa < right_mantissa and -1 or 1
end

local function compare(left: ScalorInput, right: ScalorInput): number
	local left_mantissa, left_exponent = scientific(left)
	local right_mantissa, right_exponent = scientific(right)

	return compare_parts(
		left_mantissa,
		left_exponent,
		right_mantissa,
		right_exponent
	)
end

local function concat_value(value: ScalorInput): string
	if type(value) == "table" then
		local data = value :: any

		if getmetatable(data) == Scalor then
			return scientific_string(data.mantissa, data.exponent)
		end

		return data:Scientific()
	end

	return tostring(value)
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

	local scaled_smaller_mantissa = exponent_difference == 0
		and smaller_mantissa
		or smaller_mantissa * NEG_POW10[exponent_difference]

	return normalize(
		larger_mantissa + scaled_smaller_mantissa,
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
	if right_mantissa == 0 then
		error('divistion by zero')
	elseif left_mantissa == 0 then
		return 0, 0
	end

	return normalize(
		left_mantissa / right_mantissa,
		left_exponent - right_exponent
	)
end

local function regular_value(mantissa: number, exponent: number, operation: string): number
	local value = mantissa * 10 ^ exponent
	if value ~= value or math.isinf(value) then
		error(`{operation} only supports values that fit in a regular number`)
	end

	return value
end

local function integer_value(mantissa: number, exponent: number, operation: string): number
	local value = regular_value(
		mantissa,
		exponent,
		operation
	)

	if value % 1 ~= 0 then
		error(`{operation} requires an integer exponent`)
	elseif math.abs(value) >= MAX_SAFE_INTEGER then
		error(`{operation} exponent is too large`)
	end

	return value
end

local function mod(left_mantissa: number, left_exponent: number, right_mantissa: number, right_exponent: number): (number, number)
	if right_mantissa == 0 then
		error('modulo by zero')
	elseif left_mantissa == 0 then
		return 0, 0
	end

	return normalize(
		regular_value(
			left_mantissa,
			left_exponent,
			"modulo"
		) % regular_value(
			right_mantissa,
			right_exponent,
			"modulo"
		),
		0
	)
end

local function exp(left_mantissa: number, left_exponent: number, right_mantissa: number, right_exponent: number): (number, number)
	local power = integer_value(
		right_mantissa,
		right_exponent,
		"power"
	)

	if left_mantissa == 0 then
		if power < 0 then
			error('0 cannot be raised to a non-positive power')
		end

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

	while power > 0 do
		if power % 2 == 1 then
			result_mantissa, result_exponent = mul(
				result_mantissa,
				result_exponent,
				left_mantissa,
				left_exponent
			)
		end

		power = power // 2
		if power > 0 then
			left_mantissa, left_exponent = mul(
				left_mantissa,
				left_exponent,
				left_mantissa,
				left_exponent
			)
		end
	end

	if invert then
		return div(
			1,
			0,
			result_mantissa,
			result_exponent
		)
	end

	return result_mantissa, result_exponent
end

local function pow(left_mantissa: number, left_exponent: number, right_mantissa: number, right_exponent: number): (number, number)
	local power = regular_value(
		right_mantissa,
		right_exponent,
		"power"
	)
	if power % 1 == 0 then
		return exp(
			left_mantissa,
			left_exponent,
			right_mantissa,
			right_exponent
		)
	end

	if left_mantissa == 0 then
		if power < 0 then
			error('0 cannot be raised to a non-positive power')
		end

		return 0, 0
	end

	if left_mantissa < 0 then
		error('fractional powers of negative values are not supported')
	end

	local total_exponent = (math.log10(left_mantissa) + left_exponent) * power

	if total_exponent ~= total_exponent or math.isinf(total_exponent) then
		error('power result is too large')
	end

	return normalize(
		10 ^ (total_exponent - total_exponent//1),
		total_exponent//1
	)
end

local function root(value_mantissa: number, value_exponent: number, degree_mantissa: number, degree_exponent: number): (number, number)
	local degree = integer_value(
		degree_mantissa,
		degree_exponent,
		"root"
	)

	if degree < 0 then
		error('root degree must be positive')
	elseif value_mantissa == 0 then
		return 0, 0
	end

	local sign = 1
	local mantissa = value_mantissa
	if mantissa < 0 then
		if degree % 2 == 0 then
			error('even root of a negative value is not real')
		end

		sign = -1
		mantissa = -mantissa
	end

	local total_exponent = (math.log10(mantissa) + value_exponent) / degree
	if total_exponent ~= total_exponent or math.isinf(total_exponent) then
		error('root result must be finite')
	end

	local rooted_exponent = total_exponent // 1

	return normalize(
		sign * 10 ^ (total_exponent - rooted_exponent),
		rooted_exponent
	)
end

function Scalor.new(mantissa: number, exponent: number?): Scalor
	return new_from_normalized(normalize(
		mantissa, 
		exponent or 0
		))
end

function Scalor.zero(): Scalor
	return new_from_normalized(
		0,
		0
	)
end

function Scalor.one(): Scalor
	return new_from_normalized(
		1, 
		0
	)
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

function Scalor.pow(self: Scalor, value: ScalorInput): Scalor
	self.mantissa, self.exponent = exp(
		self.mantissa,
		self.exponent,
		scientific(value)
	)

	return self
end

function Scalor.root(self: Scalor, degree: ScalorInput): Scalor
	self.mantissa, self.exponent = root(
		self.mantissa,
		self.exponent,
		scientific(degree)
	)

	return self
end

function Scalor.Equals(self: Scalor, value: ScalorInput): boolean
	return compare_parts(
		self.mantissa,
		self.exponent,
		scientific(value)
	) == 0
end

function Scalor.Scientific(self: Scalor): string
	return scientific_string(
		self.mantissa, 
		self.exponent
	)
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

	if exponent < 0 then
		return scientific_string(
			self.mantissa, 
			self.exponent
		)
	end

	local power = exponent // 3 + 1
	local suffix = POWER_TO_SUFFIX[power]
	if not suffix then
		return scientific_string(
			self.mantissa, 
			self.exponent
		)
	end

	local scaled = mantissa * SMALL_POW10[exponent % 3]
	local decimals = scaled < 10 and 2 or scaled < 100 and 1 or 0
	local display = math.round(scaled * SMALL_POW10[decimals])

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

	suffix = POWER_TO_SUFFIX[power]

	return suffix and sign .. shift(display, 
		decimals
	) .. suffix or scientific_string(
		self.mantissa, 
		self.exponent
	)
end

function Scalor.__add(left: ScalorInput, right: ScalorInput): Scalor
	local left_mantissa, left_exponent = scientific(left)

	return new_from_normalized(
		add(
			left_mantissa,
			left_exponent,
			scientific(right)
		)
	)
end

function Scalor.__sub(left: ScalorInput, right: ScalorInput): Scalor
	local left_mantissa, left_exponent = scientific(left)

	return new_from_normalized(
		sub(
			left_mantissa,
			left_exponent,
			scientific(right)
		)
	)
end

function Scalor.__mul(left: ScalorInput, right: ScalorInput): Scalor
	local left_mantissa, left_exponent = scientific(left)

	return new_from_normalized(
		mul(
			left_mantissa,
			left_exponent,
			scientific(right)
		)
	)
end

function Scalor.__div(left: ScalorInput, right: ScalorInput): Scalor
	local left_mantissa, left_exponent = scientific(left)

	return new_from_normalized(
		div(
			left_mantissa,
			left_exponent,
			scientific(right)
		)
	)
end

function Scalor.__mod(left: ScalorInput, right: ScalorInput): Scalor
	local left_mantissa, left_exponent = scientific(left)

	return new_from_normalized(
		mod(
			left_mantissa,
			left_exponent,
			scientific(right)
		)
	)
end

function Scalor.__pow(left: ScalorInput, right: ScalorInput): Scalor
	local left_mantissa, left_exponent = scientific(left)

	return new_from_normalized(
		pow(
			left_mantissa,
			left_exponent,
			scientific(right)
		)
	)
end

function Scalor.__concat(left: ScalorInput, right: ScalorInput): string
	return concat_value(left) .. concat_value(right)
end

function Scalor.__eq(left: ScalorInput, right: ScalorInput): boolean
	return compare(
		left, 
		right
	) == 0
end

function Scalor.__lt(left: ScalorInput, right: ScalorInput): boolean
	return compare(
		left, 
		right
	) < 0
end

function Scalor.__le(left: ScalorInput, right: ScalorInput): boolean
	return compare(
		left, 
		right
	) <= 0
end

function Scalor.__unm(value: ScalorInput): Scalor
	local mantissa, exponent = scientific(value)

	return new_from_normalized(
		-mantissa, 
		exponent
	)
end

function Scalor.__tostring(value: Scalor): string
	return scientific_string(
		value.mantissa, 
		value.exponent
	)
end

function Scalor.__len(value: Scalor): number
	if value.mantissa == 0 then
		return 0
	end

	return value.exponent
end

return Scalor
