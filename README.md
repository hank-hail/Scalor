# Scalor

`Scalor.luau` is a small Luau number type for very large or very small values.
Each value is stored as:

```text
mantissa * 10^exponent
```

The internal representation is normalized, so nonzero values stay in the form:

```text
1 <= abs(mantissa) < 10
```

That makes math, parsing, and formatting consistent.

## Files

- [Scalor.luau](./src/Scalor.luau): the number type
- [Config.luau](./src/Config.luau): suffixes and internal limits

## Setup

```luau
local Scalor = require(path.to.Scalor)
```

Adjust the require path to match your project layout.

## Quick Start

```luau
local Scalor = require(path.to.Scalor)

local a = Scalor.new(1.25, 6)   -- 1.25e6
local b = Scalor.new(5, 3)      -- 5e3

print(a:Scientific())           -- 1.25e6
print(a:Short())                -- 1.25M

print((a + b):Scientific())     -- new Scalor

a:add("250K")                   -- mutates a
print(a:Short())                -- 1.50M
```

## Accepted Inputs

Most math methods and operators accept `ScalorInput`, which can be:

- a `number`
- a `string`
- another `Scalor`

Supported string forms:

- plain numbers: `"125000"`
- scientific notation: `"9.9e12"`
- suffix notation from `Config.BASE_SUFFIXES`: `"1.25M"`

## Constructors

### `Scalor.new(mantissa, exponent?)`

Creates and normalizes a new value.

```luau
Scalor.new(10, 3)   -- becomes 1e4
Scalor.new(0.5, 3)  -- becomes 5e2
```

### `Scalor.zero()`

Returns `0e0`.

### `Scalor.one()`

Returns `1e0`.

## Mutating Methods

These change the current object and return `self`.

- `value:add(input)`
- `value:sub(input)`
- `value:mul(input)`
- `value:div(input)`
- `value:mod(input)`
- `value:pow(input)`
- `value:root(degree)`

Example:

```luau
local value = Scalor.new(1.5, 6)

value:add("250K")
value:mul(3)
value:div("2")
value:root(3)
```

## Comparison Helper

### `value:Compare(input)`

Compares a `Scalor` to another accepted input without relying on `==`.

Return values:

- `0` if both values are equal
- `< 0` if `value` is smaller
- `> 0` if `value` is larger

This is the reliable way to compare a `Scalor` against:

- another `Scalor`
- a `number`
- a plain number string like `"125000"`
- a scientific string like `"1e6"`
- a short string like `"1.25M"`

Example:

```luau
local value = Scalor.new(1, 3)

print(value:Compare(1000) == 0)
print(value:Compare("1e3") == 0)
print(value:Compare("1K") == 0)
print(value:Compare("2K") < 0)
```

## Operators

These operators are available on `Scalor`.

- `a + b`
- `a - b`
- `a * b`
- `a / b`
- `a % b`
- `a ^ b`
- `-a`
- `a .. b`
- `a == b`
- `a < b`
- `a <= b`
- `#a`

`tostring(a)` uses scientific formatting.

Comparison operators coerce inputs through the same parser used by the math methods, so they can compare against:

- another `Scalor`
- a plain number string like `"125000"`
- a scientific string like `"9.9e12"`
- a short string like `"1.25M"`

Concatenation renders any `Scalor` operand with `Scientific()` first.
`#a` returns the base-10 magnitude, which is the normalized exponent for nonzero values.

Examples:

```luau
print(Scalor.new(1.25, 6) .. " total") -- 1.25e6 total
print(Scalor.new(5, 3) < "1.25M")      -- true
print(Scalor.new(5, 3) <= 5000)        -- true
print(Scalor.new(9, 0) ^ 0.5)          -- 3.00e0
print(#Scalor.new(9.876, 9))           -- 9
```

`value:pow(input)` still requires an integer exponent.
Use operator `^` for fractional powers and `value:root(degree)` for explicit nth roots.

## Formatting

### `value:Scientific()`

Formats the value like `1.23e4`.

### `value:Short()`

Formats the value using suffixes from `Config.BASE_SUFFIXES`.

Examples:

- `1.25e6 -> "1.25M"`
- `5e3 -> "5.00K"`
- values outside the suffix range fall back to scientific notation

### `tostring(value)`

Uses `value:Scientific()`.

## Config

[Config.luau](./src/Config.luau) controls the suffix system and a few math limits.

### `Config.BASE_SUFFIXES`

Ordered suffix list for short formatting.

Examples:

- index `1` -> `""`
- index `2` -> `"K"`
- index `3` -> `"M"`

Each step is one group of `3` decimal exponents:

- `1` = `e0`
- `2` = `e3`
- `3` = `e6`

If you want different short-format labels, this is the main table to edit.

### `Config.SUFFIX_TO_POWER`

Reverse lookup table built from `BASE_SUFFIXES`.
`Scalor` uses this internally to parse strings like `"1.25M"`.

### `Config.MAX_ADD_DIFF`

Exponent-gap cutoff used by addition.
If one value is far smaller than the other, `Scalor` ignores the smaller term once it is beyond normal floating-point precision.

### `Config.MAX_SAFE_INTEGER`

Largest safe integer used when validating integer exponents and root degrees.

## Limits

- `:pow(...)` only supports integer exponents
- `^` supports fractional exponents for compatible real-valued inputs
- `%` and `:mod(...)` only work when both values fit in a regular Luau number
- Luau does not dispatch `==` against raw `number` or `string` operands, so mixed-type equality like `scalor == "1e3"` will not use `__eq`; use `value:Compare(input) == 0` instead
- `Scalor` still uses Luau `number` internally, so it is not arbitrary-precision math

## Notes

- Methods mutate; operators return a new value.
- Negative values are supported.
- Empty or invalid parse strings throw errors.
