--!optimize 2
--!native
--!strict

-- This module stores numeric values in scientific notation:
-- value = mantissa * 10^exponent
--
-- Roblox/Luau numbers are IEEE-754 doubles, so regular numbers
-- overflow around 1e308. This module keeps a normalized mantissa
-- and a separate exponent so you can represent much larger ranges.
--
-- The core invariant is:
-- mantissa == 0 OR 1 <= abs(mantissa) < 10
--
-- The implementation prioritizes arithmetic in raw mantissa/exponent form,
-- normalizes only when needed, and exposes allocation-free Into APIs for hot
-- loops. The same module also contains string parsing/formatting so the value
-- type can be used end to end without conversion helpers.
--
-- Example usage in a Script or ModuleScript:
-- local Scalor = require(path.To.Scalor)
--
-- local a = Scalor.fromString("9.99e400")
-- local b = Scalor.new(2.5, 120)
--
-- local sum = a:add(b)
-- local product = a:mul(b)
-- local power = a:powInt(3)
--
-- print("a:", a:toString(6)) -- a: 9.99e400
-- print("b:", b:toString(6)) -- b: 2.5e120
-- print("sum:", sum:toString(6)) -- sum: 9.99e400
-- print("product:", product:toString(6)) -- product: 2.4975e521
-- print("power:", power:toString(6)) -- power: 9.97003e1202
--
-- The sum is effectively equal to a here because b is many orders of magnitude
-- smaller, so it does not change the represented value at this precision.
--
-- If you are doing heavy repeated math in loops, prefer Acquire/AddInto/MulInto
-- style workflows to reuse objects and reduce allocations.

-- Hot local aliases
local abs = math.abs
local floor = math.floor
local huge = math.huge
local log10 = math.log10

local byte = string.byte
local sub = string.sub

local tonumber_ = tonumber
local type_ = type
local getmetatable_ = getmetatable
local setmetatable_ = setmetatable
local tostring_ = tostring

-- ASCII byte constants used by fast parsers
local ZERO = 48 -- '0'
local NINE = 57 -- '9'
local DOT = 46 -- '.'
local MINUS = 45 -- '-'
local PLUS = 43 -- '+'
local ELOW = 101 -- 'e'
local EUP = 69 -- 'E'
local SPACE = 32
local TAB = 9
local LF = 10
local CR = 13

-- Tuning constants
local MAX_ADD_DIFF = 16
local MAX_FMT_DIGITS = 15

-- Zero-padding strings for decimal formatting.
-- Index i stores a string with i-1 zeros.
local ZPAD: {string} = {
	"", "0", "00", "000", "0000", "00000", "000000", "0000000",
	"00000000", "000000000", "0000000000", "00000000000",
	"000000000000", "0000000000000", "00000000000000", "000000000000000",
}

-- This helper classifies ASCII whitespace for the manual parsers. Parsing in
-- this module is intentionally done byte-by-byte to avoid pattern overhead and
-- temporary allocations, so this tiny predicate is used repeatedly in hot scan
-- loops when skipping outer spaces around numeric text.
local function isSpaceByte(charByte: number): boolean
	return charByte == SPACE or charByte == TAB or charByte == LF or charByte == CR
end

-- Class definition and exported object type.
local Scalor = {}
Scalor.__index = Scalor

export type ScalorObject = {
	mantissa: number,
	exponent: number,

	-- pooled ops
	set: (self: ScalorObject, m: number, e: number) -> ScalorObject,
	Release: (self: ScalorObject) -> (),

	-- alloc ops (convenience)
	clone: (self: ScalorObject) -> ScalorObject,
	toString: (self: ScalorObject, sigFigs: number?) -> string,
	compare: (self: ScalorObject, other: ScalorObject) -> number,
	add: (self: ScalorObject, other: ScalorObject) -> ScalorObject,
	sub: (self: ScalorObject, other: ScalorObject) -> ScalorObject,
	mul: (self: ScalorObject, other: ScalorObject) -> ScalorObject,
	div: (self: ScalorObject, other: ScalorObject) -> ScalorObject,
	powInt: (self: ScalorObject, n: number) -> ScalorObject,

	-- internal pool link
	_next: any?,
}

-- Precomputed tables used by arithmetic and formatting.

-- POW10_NEG[k] = 10^(-(k-1)), k in [1..MAX_ADD_DIFF+1]
local POW10_NEG: { number } = table.create(MAX_ADD_DIFF + 1) :: { number }
do
	local scale = 1.0
	for i = 1, MAX_ADD_DIFF + 1 do
		POW10_NEG[i] = scale
		scale *= 0.1
	end
end

-- POW10_POS[k] = 10^(k-1), k in [1..MAX_FMT_DIGITS+1]
local POW10_POS: { number } = table.create(MAX_FMT_DIGITS + 1) :: { number }
do
	local scale = 1.0
	for i = 1, MAX_FMT_DIGITS + 1 do
		POW10_POS[i] = scale
		scale *= 10
	end
end

-- Object pool used to reduce temporary allocations.
local poolHead: any = false

-- Creates a fresh number object and attaches the class metatable. Keeping this
-- constructor tiny helps both readability and runtime behavior because most
-- allocating wrappers funnel through this exact code path.
local function rawNew(mantissa: number, exponent: number): ScalorObject
	return setmetatable_({ mantissa = mantissa, exponent = exponent }, Scalor) :: any
end

-- Retrieves a reusable object from the pool when possible, otherwise allocates
-- a new one. Arithmetic-heavy loops can create huge numbers of temporaries, so
-- this pool path can significantly reduce garbage collector work and improve
-- frame-time stability in scripts that chain many operations.
function Scalor.Acquire(): ScalorObject
	local node = poolHead
	if node ~= false then
		poolHead = node._next
		node._next = false
		return node :: any
	end
	return rawNew(0, 0)
end

-- Returns an object to the pool free list. After release, the object is no
-- longer exclusively owned by the caller, so it should be treated as invalid
-- for future reads or writes unless it is explicitly re-acquired again.
function Scalor.Release(self: ScalorObject): ()
	self._next = poolHead
	poolHead = self :: any
end

-- Rewrites mantissa and exponent in-place and returns the same object so calls
-- can be chained. This supports object-reuse workflows where you keep a small
-- fixed set of instances and overwrite values every update tick.
function Scalor.set(self: ScalorObject, mantissa: number, exponent: number): ScalorObject
	self.mantissa = mantissa
	self.exponent = exponent
	return self
end

-- Normalization helpers.

-- Canonicalizes any non-zero value into the invariant range using a logarithmic
-- exponent shift. It first moves the decimal point in one jump via log10, then
-- applies a small corrective step for edge cases caused by floating precision.
-- This is the robust path that handles very large or very tiny intermediates.
local function normalizeSlow(mantissa: number, exponent: number): (number, number)
	local sign = if mantissa < 0 then -1 else 1
	mantissa = abs(mantissa)

	local shift = floor(log10(mantissa))
	if shift >= 0 then
		if shift <= MAX_FMT_DIGITS then
			mantissa = mantissa / POW10_POS[shift + 1]
		else
			mantissa = mantissa / (10 ^ shift)
		end
	else
		local negativeShift = -shift
		if negativeShift <= MAX_FMT_DIGITS then
			mantissa = mantissa * POW10_POS[negativeShift + 1]
		else
			mantissa = mantissa / (10 ^ shift)
		end
	end
	exponent += shift

	if mantissa >= 10 then
		mantissa *= 0.1
		exponent += 1
	elseif mantissa < 1 then
		repeat
			mantissa *= 10
			exponent -= 1
		until mantissa >= 1
	end

	return mantissa * sign, exponent
end

-- Handles the common normalization cases with short threshold checks. Most math
-- results are already near normalized form, so one multiply or divide by ten is
-- often enough. Only rare extreme values fall through to normalizeSlow, which
-- keeps typical add/mul/div paths fast without losing correctness.
local function normalizeFast(mantissa: number, exponent: number): (number, number)
	if mantissa == 0 then
		return 0, 0
	end

	local absMantissa = abs(mantissa)
	if absMantissa >= 1 then
		if absMantissa < 10 then
			return mantissa, exponent
		elseif absMantissa < 100 then
			return mantissa * 0.1, exponent + 1
		end
	elseif absMantissa >= 0.1 then
		return mantissa * 10, exponent - 1
	end

	return normalizeSlow(mantissa, exponent)
end

-- Comparison helpers.

-- Compares two values directly in mantissa/exponent form and returns -1, 0, or
-- The comparison order is designed for speed: exact equality first, then
-- zero/sign checks, then exponent checks, then mantissa checks only when needed.
-- This avoids expensive reconstruction into plain Lua numbers.
local function compareRaw(aMantissa: number, aExponent: number, bMantissa: number, bExponent: number): number
	if aMantissa == bMantissa and aExponent == bExponent then
		return 0
	end
	if aMantissa == 0 then
		return if bMantissa > 0 then -1 else 1
	end
	if bMantissa == 0 then
		return if aMantissa > 0 then 1 else -1
	end

	local aIsNegative = aMantissa < 0
	if aIsNegative ~= (bMantissa < 0) then
		return if aIsNegative then -1 else 1
	end

	if aExponent ~= bExponent then
		if aIsNegative then
			return if aExponent > bExponent then -1 else 1
		else
			return if aExponent > bExponent then 1 else -1
		end
	end

	if aMantissa < bMantissa then
		return -1
	else
		return 1
	end
end

-- Static compare entry point for callers that prefer `Scalor.Compare(a,b)`
-- style usage. It delegates to the same raw comparator used by the instance
-- method, so both APIs always produce identical ordering.
function Scalor.Compare(a: ScalorObject, b: ScalorObject): number
	return compareRaw(a.mantissa, a.exponent, b.mantissa, b.exponent)
end

-- Instance compare entry point for `a:compare(b)` style usage. This is a thin
-- wrapper around the shared raw comparator so behavior stays perfectly aligned
-- with the static compare function.
function Scalor.compare(self: ScalorObject, other: ScalorObject): number
	return compareRaw(self.mantissa, self.exponent, other.mantissa, other.exponent)
end

-- Raw arithmetic core.

-- Adds two values in component form by aligning exponents before combining the
-- mantissas. If exponents differ too much, the smaller term is ignored because
-- it cannot affect the target precision. The result is then cheaply normalized
-- with fast thresholds and only falls back to full normalization when required.
local function addRaw(aMantissa: number, aExponent: number, bMantissa: number, bExponent: number): (number, number)
	if aMantissa == 0 then
		return bMantissa, bExponent
	elseif bMantissa == 0 then
		return aMantissa, aExponent
	end

	if bExponent > aExponent then
		aMantissa, bMantissa = bMantissa, aMantissa
		aExponent, bExponent = bExponent, aExponent
	end

	local exponentDiff = aExponent - bExponent
	if exponentDiff > MAX_ADD_DIFF then
		return aMantissa, aExponent
	end

	local scale = POW10_NEG[exponentDiff + 1]
	local sumMantissa = aMantissa + bMantissa * scale
	if sumMantissa == 0 then
		return 0, 0
	end

	local absSum = abs(sumMantissa)
	if absSum >= 1 then
		if absSum < 10 then
			return sumMantissa, aExponent
		elseif absSum < 100 then
			return sumMantissa * 0.1, aExponent + 1
		end
	elseif absSum >= 0.1 then
		return sumMantissa * 10, aExponent - 1
	end

	return normalizeSlow(sumMantissa, aExponent)
end

-- Into APIs that avoid result allocation.

-- Writes `a + b` into `out` without allocating a new table. This is ideal for
-- tight loops where allocation cost matters more than API convenience.
function Scalor.AddInto(out: ScalorObject, a: ScalorObject, b: ScalorObject): ScalorObject
	local mantissa, exponent = addRaw(a.mantissa, a.exponent, b.mantissa, b.exponent)
	out.mantissa = mantissa
	out.exponent = exponent
	return out
end

-- Writes `a - b` into `out` without allocating. Subtraction is implemented by
-- negating the right mantissa and reusing the same exponent-alignment logic as
-- addition so both operations share identical precision rules.
function Scalor.SubInto(out: ScalorObject, a: ScalorObject, b: ScalorObject): ScalorObject
	local mantissa, exponent = addRaw(a.mantissa, a.exponent, -b.mantissa, b.exponent)
	out.mantissa = mantissa
	out.exponent = exponent
	return out
end

-- Writes `a * b` into `out` without allocating. The operation multiplies the
-- mantissas, adds exponents, then re-normalizes. Fast one-step normalization is
-- attempted first, while very extreme results use the robust slow path.
function Scalor.MulInto(out: ScalorObject, a: ScalorObject, b: ScalorObject): ScalorObject
	local aMantissa = a.mantissa
	local bMantissa = b.mantissa
	if aMantissa == 0 or bMantissa == 0 then
		out.mantissa = 0
		out.exponent = 0
		return out
	end

	local mantissa = aMantissa * bMantissa
	local exponent = a.exponent + b.exponent

	local absMantissa = abs(mantissa)
	if absMantissa >= 1 then
		if absMantissa < 10 then
			out.mantissa = mantissa
			out.exponent = exponent
			return out
		elseif absMantissa < 100 then
			out.mantissa = mantissa * 0.1
			out.exponent = exponent + 1
			return out
		end
	elseif absMantissa >= 0.1 then
		out.mantissa = mantissa * 10
		out.exponent = exponent - 1
		return out
	end

	local normalizedMantissa, normalizedExponent = normalizeSlow(mantissa, exponent)
	out.mantissa = normalizedMantissa
	out.exponent = normalizedExponent
	return out
end

-- Writes `a / b` into `out` without allocating. The function asserts on division
-- by zero, divides mantissas, subtracts exponents, and normalizes the result.
-- It mirrors multiply behavior so both operations share consistent invariants.
function Scalor.DivInto(out: ScalorObject, a: ScalorObject, b: ScalorObject): ScalorObject
	local bMantissa = b.mantissa
	assert(bMantissa ~= 0, "division by zero")

	local aMantissa = a.mantissa
	if aMantissa == 0 then
		out.mantissa = 0
		out.exponent = 0
		return out
	end

	local mantissa = aMantissa / bMantissa
	local exponent = a.exponent - b.exponent

	local absMantissa = abs(mantissa)
	if absMantissa >= 1 then
		if absMantissa < 10 then
			out.mantissa = mantissa
			out.exponent = exponent
			return out
		elseif absMantissa < 100 then
			out.mantissa = mantissa * 0.1
			out.exponent = exponent + 1
			return out
		end
	elseif absMantissa >= 0.1 then
		out.mantissa = mantissa * 10
		out.exponent = exponent - 1
		return out
	end

	local normalizedMantissa, normalizedExponent = normalizeSlow(mantissa, exponent)
	out.mantissa = normalizedMantissa
	out.exponent = normalizedExponent
	return out
end

-- Integer power helpers.

-- Computes a square directly in component form. This helper exists so the power
-- routine can skip general logarithmic math for one of the most common exponents
-- while still preserving normalization guarantees.
local function pow2(mantissa: number, exponent: number): (number, number)
	local resultMantissa = mantissa * mantissa
	local resultExponent = exponent + exponent
	local absMantissa = abs(resultMantissa)
	if absMantissa >= 1 then
		if absMantissa < 10 then
			return resultMantissa, resultExponent
		elseif absMantissa < 100 then
			return resultMantissa * 0.1, resultExponent + 1
		end
	elseif absMantissa >= 0.1 then
		return resultMantissa * 10, resultExponent - 1
	end
	return normalizeSlow(resultMantissa, resultExponent)
end

-- Computes a cube directly in component form for the same reason as the square
-- helper: small integer powers are common and can be evaluated faster with pure
-- multiply/add logic than with logarithmic decomposition.
local function pow3(mantissa: number, exponent: number): (number, number)
	local resultMantissa = mantissa * mantissa * mantissa
	local resultExponent = exponent * 3
	local absMantissa = abs(resultMantissa)
	if absMantissa >= 1 then
		if absMantissa < 10 then
			return resultMantissa, resultExponent
		elseif absMantissa < 100 then
			return resultMantissa * 0.1, resultExponent + 1
		end
	elseif absMantissa >= 0.1 then
		return resultMantissa * 10, resultExponent - 1
	end
	return normalizeSlow(resultMantissa, resultExponent)
end

-- Raises `a` to an integer power and writes the result into `out` without extra
-- allocation. The function handles many special cases explicitly, including zero
-- powers, reciprocal power, and tiny integer powers, before using a general
-- logarithmic approach for large exponents. Negative powers invert at the end,
-- and sign handling for negative bases depends on odd/even parity.
function Scalor.PowIntInto(out: ScalorObject, a: ScalorObject, n: number): ScalorObject
	assert(n == n and n ~= huge and n ~= -huge and floor(n) == n, "PowIntInto expects a finite integer")

	local mantissa = a.mantissa
	local exponent = a.exponent

	if n == 0 then
		out.mantissa = 1
		out.exponent = 0
		return out
	elseif n == 1 then
		out.mantissa = mantissa
		out.exponent = exponent
		return out
	elseif n == -1 then
		assert(mantissa ~= 0, "0 cannot be raised to a negative power")
		local reciprocalMantissa = 1 / mantissa
		local reciprocalExponent = -exponent
		local absReciprocal = abs(reciprocalMantissa)
		if absReciprocal >= 1 then
			if absReciprocal < 10 then
				out.mantissa = reciprocalMantissa
				out.exponent = reciprocalExponent
				return out
			elseif absReciprocal < 100 then
				out.mantissa = reciprocalMantissa * 0.1
				out.exponent = reciprocalExponent + 1
				return out
			end
		elseif absReciprocal >= 0.1 then
			out.mantissa = reciprocalMantissa * 10
			out.exponent = reciprocalExponent - 1
			return out
		end
		local normalizedMantissa, normalizedExponent = normalizeSlow(reciprocalMantissa, reciprocalExponent)
		out.mantissa = normalizedMantissa
		out.exponent = normalizedExponent
		return out
	elseif n == 2 then
		if mantissa == 0 then
			out.mantissa = 0
			out.exponent = 0
			return out
		end
		local normalizedMantissa, normalizedExponent = pow2(mantissa, exponent)
		out.mantissa = normalizedMantissa
		out.exponent = normalizedExponent
		return out
	elseif n == 3 then
		if mantissa == 0 then
			out.mantissa = 0
			out.exponent = 0
			return out
		end
		local normalizedMantissa, normalizedExponent = pow3(mantissa, exponent)
		out.mantissa = normalizedMantissa
		out.exponent = normalizedExponent
		return out
	end

	if mantissa == 0 then
		assert(n > 0, "0 cannot be raised to a negative power")
		out.mantissa = 0
		out.exponent = 0
		return out
	end

	local invert = false
	if n < 0 then
		invert = true
		n = -n
	end
	local isOdd = (n % 2 == 1)

	local absMantissa = abs(mantissa)
	if absMantissa == 1 then
		local resultMantissa = if mantissa < 0 and isOdd then -1 else 1
		local resultExponent = exponent * n
		if invert then resultExponent = -resultExponent end
		out.mantissa = resultMantissa
		out.exponent = resultExponent
		return out
	end

	local logValue = log10(absMantissa) * n
	local integerPart = floor(logValue)
	local fractionalPart = logValue - integerPart

	local resultMantissa = 10 ^ fractionalPart
	if mantissa < 0 and isOdd then
		resultMantissa = -resultMantissa
	end

	local resultExponent = exponent * n + integerPart

	if invert then
		resultMantissa = 1 / resultMantissa
		resultExponent = -resultExponent

		local absResultMantissa = abs(resultMantissa)
		if absResultMantissa >= 1 then
			if absResultMantissa < 10 then
				out.mantissa = resultMantissa
				out.exponent = resultExponent
				return out
			elseif absResultMantissa < 100 then
				out.mantissa = resultMantissa * 0.1
				out.exponent = resultExponent + 1
				return out
			end
		elseif absResultMantissa >= 0.1 then
			out.mantissa = resultMantissa * 10
			out.exponent = resultExponent - 1
			return out
		end

		local normalizedMantissa, normalizedExponent = normalizeSlow(resultMantissa, resultExponent)
		out.mantissa = normalizedMantissa
		out.exponent = normalizedExponent
		return out
	end

	out.mantissa = resultMantissa
	out.exponent = resultExponent
	return out
end

-- Formatting helpers.

-- Converts pre-rounded mantissa pieces into text. The integer part is emitted
-- first, fractional digits are left-padded when needed, and trailing fractional
-- zeros are trimmed to keep output compact. The function is string-focused so
-- `toString` can stay focused on numeric rounding behavior.
local function formatMantissaFromScaled(isNegative: boolean, intPart: number, fracPart: number, decimals: number): string
	local intString = tostring_(intPart)
	if fracPart == 0 then
		return isNegative and ("-" .. intString) or intString
	end

	local fracString = tostring_(fracPart)
	local requiredZeros = decimals - #fracString
	if requiredZeros > 0 then
		fracString = ZPAD[requiredZeros + 1] .. fracString
	end

	local originalLength = #fracString
	local trimIndex = originalLength
	while trimIndex > 0 and byte(fracString, trimIndex) == ZERO do
		trimIndex -= 1
	end
	if trimIndex ~= originalLength then
		fracString = sub(fracString, 1, trimIndex)
	end

	local result = intString .. "." .. fracString
	return isNegative and ("-" .. result) or result
end

-- Converts the stored value to scientific-notation text with configurable
-- significant figures. Digits are clamped to a safe precision range for double
-- arithmetic, and rounding overflow is corrected so values like 9.999... become
-- `1e(nextExponent)` instead of producing an invalid `10.xeN` mantissa.
function Scalor.toString(self: ScalorObject, sigFigs: number?): string
	local mantissa = self.mantissa
	if mantissa == 0 then
		return "0"
	end

	local digits = if sigFigs == nil then 6 else floor(sigFigs)
	if digits < 1 then
		digits = 1
	elseif digits > MAX_FMT_DIGITS then
		digits = MAX_FMT_DIGITS
	end

	local isNegative = mantissa < 0
	local absMantissa = if isNegative then -mantissa else mantissa

	if digits == 1 then
		local rounded = floor(absMantissa + 0.5)
		if rounded >= 10 then
			return (isNegative and "-1" or "1") .. "e" .. tostring_(self.exponent + 1)
		end
		return (isNegative and ("-" .. tostring_(rounded)) or tostring_(rounded)) .. "e" .. tostring_(self.exponent)
	end

	local decimals = digits - 1
	local powerScale = POW10_POS[decimals + 1]
	local scaled = floor(absMantissa * powerScale + 0.5)
	local intPart = floor(scaled / powerScale)
	if intPart >= 10 then
		return (isNegative and "-1" or "1") .. "e" .. tostring_(self.exponent + 1)
	end

	local fracPart = scaled - intPart * powerScale
	return formatMantissaFromScaled(isNegative, intPart, fracPart, decimals) .. "e" .. tostring_(self.exponent)
end

-- Parsing helpers.

-- Parses the exponent portion after `e` or `E`. It accepts optional sign,
-- requires at least one digit, tolerates trailing whitespace, and rejects any
-- non-whitespace trailing characters so invalid mixed strings fail cleanly.
local function parseExponentInt(text: string, startPos: number): number?
	local textLength = #text
	if startPos > textLength then
		return nil
	end

	local i = startPos
	local sign = 1
	local charByte = byte(text, i)
	if charByte == MINUS then
		sign = -1
		i += 1
	elseif charByte == PLUS then
		i += 1
	end

	if i > textLength then
		return nil
	end

	charByte = byte(text, i)
	if charByte < ZERO or charByte > NINE then
		return nil
	end

	local value = 0
	repeat
		value = value * 10 + (charByte - ZERO)
		i += 1
		if i > textLength then
			return value * sign
		end
		charByte = byte(text, i)
	until charByte < ZERO or charByte > NINE

	if not isSpaceByte(charByte) then
		return nil
	end

	repeat
		i += 1
		if i > textLength then
			return value * sign
		end
		charByte = byte(text, i)
	until not isSpaceByte(charByte)

	return nil
end

-- Parses the mantissa portion before the exponent marker. It supports optional
-- leading sign, integer and decimal forms, and surrounding whitespace. Parsing
-- is strict enough to reject leftover invalid characters in the provided range.
local function parseMantissaRange(text: string, endPos: number): number?
	if endPos < 1 then
		return nil
	end

	local i = 1
	local charByte = byte(text, i)
	while i <= endPos and charByte ~= nil and isSpaceByte(charByte) do
		i += 1
		charByte = byte(text, i)
	end

	if i > endPos or charByte == nil then
		return nil
	end

	local sign = 1
	if charByte == MINUS then
		sign = -1
		i += 1
	elseif charByte == PLUS then
		i += 1
	end

	if i > endPos then
		return nil
	end

	local value = 0.0
	local sawDigit = false

	charByte = byte(text, i)
	while charByte ~= nil and i <= endPos and charByte >= ZERO and charByte <= NINE do
		sawDigit = true
		value = value * 10 + (charByte - ZERO)
		i += 1
		charByte = byte(text, i)
	end

	if charByte == DOT and i <= endPos then
		i += 1
		charByte = byte(text, i)
		local place = 0.1
		while charByte ~= nil and i <= endPos and charByte >= ZERO and charByte <= NINE do
			sawDigit = true
			value += (charByte - ZERO) * place
			place *= 0.1
			i += 1
			charByte = byte(text, i)
		end
	end

	if not sawDigit then
		return nil
	end

	while i <= endPos and charByte ~= nil and isSpaceByte(charByte) do
		i += 1
		charByte = byte(text, i)
	end

	if i <= endPos then
		return nil
	end

	return value * sign
end

-- Parses user text into a normalized object. The fast path uses `tonumber` for
-- common finite inputs, while the fallback manually parses scientific notation
-- so values beyond regular double range can still be represented correctly.
function Scalor.fromString(text: string): ScalorObject
	local numeric = tonumber_(text)
	if numeric ~= nil and numeric == numeric and numeric ~= huge and numeric ~= -huge then
		local mantissa, exponent = normalizeFast(numeric, 0)
		return rawNew(mantissa, exponent)
	end

	local exponentMarkerPos = nil
	local textLength = #text
	for i = 1, textLength do
		local charByte = byte(text, i)
		if charByte == ELOW or charByte == EUP then
			exponentMarkerPos = i
			break
		end
	end
	assert(exponentMarkerPos ~= nil, "invalid number string")
	local markerPos = exponentMarkerPos :: number

	local mantissa = parseMantissaRange(text, markerPos - 1)
	assert(mantissa ~= nil and mantissa == mantissa and mantissa ~= huge and mantissa ~= -huge, "invalid scientific notation")

	local exponentValue = parseExponentInt(text, markerPos + 1)
	assert(exponentValue ~= nil, "invalid scientific notation")

	local normalizedMantissa, normalizedExponent = normalizeFast(mantissa, exponentValue :: number)
	return rawNew(normalizedMantissa, normalizedExponent)
end

-- Converts a finite Lua number into normalized component form. This constructor
-- validates NaN/infinity first so invalid states never enter the module.
function Scalor.fromNumber(value: number): ScalorObject
	assert(value == value, "value cannot be NaN")
	assert(value ~= huge and value ~= -huge, "value cannot be infinite")
	local mantissa, exponent = normalizeFast(value, 0)
	return rawNew(mantissa, exponent)
end

-- Constructors and runtime checks.

-- Builds a value from raw mantissa/exponent inputs and normalizes immediately.
-- Validating finiteness here ensures every instance produced by the public API
-- always satisfies the same numeric invariants.
function Scalor.new(mantissa: number, exponent: number): ScalorObject
	assert(mantissa == mantissa, "mantissa cannot be NaN")
	assert(exponent == exponent, "exponent cannot be NaN")
	assert(mantissa ~= huge and mantissa ~= -huge, "mantissa cannot be infinite")
	assert(exponent ~= huge and exponent ~= -huge, "exponent cannot be infinite")

	local normalizedMantissa, normalizedExponent = normalizeFast(mantissa, exponent)
	return rawNew(normalizedMantissa, normalizedExponent)
end

-- Returns an object representing exact zero. Keeping this as a constructor
-- avoids repeating literal component pairs at call sites.
function Scalor.zero(): ScalorObject
	return rawNew(0, 0)
end

-- Returns an object representing exact one in normalized form.
function Scalor.one(): ScalorObject
	return rawNew(1, 0)
end

-- Runtime type guard for external code paths. Checking the metatable identity
-- is more robust than checking fields because user tables may mimic structure.
function Scalor.is(value: any): boolean
	return type_(value) == "table" and getmetatable_(value) == Scalor
end

-- Allocating convenience APIs.

-- Allocates and returns an exact copy, which is useful when callers need value
-- semantics and cannot safely mutate or release the original object.
function Scalor.clone(self: ScalorObject): ScalorObject
	return rawNew(self.mantissa, self.exponent)
end

-- Convenience wrapper for addition that allocates a fresh result object. This
-- is easier to use than `AddInto` when allocation cost is not a bottleneck.
function Scalor.add(self: ScalorObject, other: ScalorObject): ScalorObject
	local mantissa, exponent = addRaw(self.mantissa, self.exponent, other.mantissa, other.exponent)
	return rawNew(mantissa, exponent)
end

-- Convenience wrapper for subtraction that returns a new object while preserving
-- the same alignment and normalization behavior used by allocation-free paths.
function Scalor.sub(self: ScalorObject, other: ScalorObject): ScalorObject
	local mantissa, exponent = addRaw(self.mantissa, self.exponent, -other.mantissa, other.exponent)
	return rawNew(mantissa, exponent)
end

-- Convenience wrapper for multiplication that allocates a new object. The math
-- and normalization behavior intentionally mirrors `MulInto` so results stay
-- identical regardless of allocation strategy.
function Scalor.mul(self: ScalorObject, other: ScalorObject): ScalorObject
	local aMantissa = self.mantissa
	local bMantissa = other.mantissa
	if aMantissa == 0 or bMantissa == 0 then
		return rawNew(0, 0)
	end

	local mantissa = aMantissa * bMantissa
	local exponent = self.exponent + other.exponent

	local absMantissa = abs(mantissa)
	if absMantissa >= 1 then
		if absMantissa < 10 then
			return rawNew(mantissa, exponent)
		elseif absMantissa < 100 then
			return rawNew(mantissa * 0.1, exponent + 1)
		end
	elseif absMantissa >= 0.1 then
		return rawNew(mantissa * 10, exponent - 1)
	end

	local normalizedMantissa, normalizedExponent = normalizeSlow(mantissa, exponent)
	return rawNew(normalizedMantissa, normalizedExponent)
end

-- Convenience wrapper for division that allocates a new object. It shares the
-- same zero checks and normalization flow as `DivInto` for consistent behavior.
function Scalor.div(self: ScalorObject, other: ScalorObject): ScalorObject
	local bMantissa = other.mantissa
	assert(bMantissa ~= 0, "division by zero")

	local aMantissa = self.mantissa
	if aMantissa == 0 then
		return rawNew(0, 0)
	end

	local mantissa = aMantissa / bMantissa
	local exponent = self.exponent - other.exponent

	local absMantissa = abs(mantissa)
	if absMantissa >= 1 then
		if absMantissa < 10 then
			return rawNew(mantissa, exponent)
		elseif absMantissa < 100 then
			return rawNew(mantissa * 0.1, exponent + 1)
		end
	elseif absMantissa >= 0.1 then
		return rawNew(mantissa * 10, exponent - 1)
	end

	local normalizedMantissa, normalizedExponent = normalizeSlow(mantissa, exponent)
	return rawNew(normalizedMantissa, normalizedExponent)
end

-- Convenience wrapper for integer exponentiation. It allocates a destination
-- object and then reuses the full `PowIntInto` implementation.
function Scalor.powInt(self: ScalorObject, n: number): ScalorObject
	return Scalor.PowIntInto(rawNew(0, 0), self, n)
end

return Scalor
