--!strict
const Config = require("./Config")

const table_create = table.create
const table_concat = table.concat

const Suffixes = {}

local MAX_CONFIGURED_SUFFIX_POWER = Config.MAX_SUFFIX_POWER
const MAX_CACHED_GROUP = 1000

const SUFFIXES = table_create(MAX_CONFIGURED_SUFFIX_POWER)
const SUFFIX_TO_POWER = {[""] = 1}

SUFFIXES[1] = ""

const MAX_DEFINED_SUFFIX_POWER = 1

const STANDALONE_GROUP_SUFFIXES = {
	"K",
	"M",
	"B",
	"T",
	"Qd",
	"Qn",
	"Sx",
	"Sp",
	"Oc",
	"No",
}

const GROUP_PREFIXES = {
	"",
	"U",
	"D",
	"T",
	"Qd",
	"Qn",
	"Sx",
	"Sp",
	"Oc",
	"No",
}

const TEN_GROUP_ROOTS = {
	"De",
	"Vt",
	"Tg",
	"qg",
	"Qg",
	"sg",
	"Sg",
	"Og",
	"Ng",
}

const HUNDRED_GROUP_ROOTS = {
	"Ce",
	"Du",
	"Tr",
	"Qa",
	"Qi",
	"Se",
	"Si",
	"Ot",
	"Ni",
}

const HIGHER_TIER_ROOTS = {
	"Mi",
	"Mc",
	"Na",
	"Pi",
	"Fm",
	"At",
	"Zp",
	"Yc",
	"Xo",
	"Ve",
	"Me",
	"Due",
	"Tre",
	"Te",
	"Pt",
	"He",
	"Hp",
	"Oct",
	"Ex",
	"Ic",
	"Mei",
	"Dui",
	"Tri",
	"Teti",
	"Pti",
	"Hei",
	"Hp",
	"Oci",
	"Eni",
	"Tra",
	"TeC",
	"MTc",
	"DTc",
	"TrTc",
	"TeTc",
	"PeTc",
	"HTc",
	"HpT",
	"OcT",
	"EnT",
	"TetC",
	"MTetc",
	"DTetc",
	"TrTetc",
	"TeTetc",
	"PeTetc",
	"HTetc",
	"HpTetc",
	"OcTetc",
	"EnTetc",
	"PcT",
	"MPcT",
	"DPcT",
	"TPCt",
	"TePCt",
	"PePCt",
	"HePCt",
	"HpPct",
	"OcPct",
	"EnPct",
	"HCt",
	"MHcT",
	"DHcT",
	"THCt",
	"TeHCt",
	"PeHCt",
	"HeHCt",
	"HpHct",
	"OcHct",
	"EnHct",
	"HpCt",
	"MHpcT",
	"DHpcT",
	"THpCt",
	"TeHpCt",
	"PeHpCt",
	"HeHpCt",
	"HpHpct",
	"OcHpct",
	"EnHpct",
	"OCt",
	"MOcT",
	"DOcT",
	"TOCt",
	"TeOCt",
	"PeOCt",
	"HeOCt",
	"HpOct",
	"OcOct",
	"EnOct",
	"Ent",
	"MEnT",
	"DEnT",
	"TEnt",
	"TeEnt",
	"PeEnt",
	"HeEnt",
	"HpEnt",
	"OcEnt",
	"EnEnt",
	"Hect",
	"MeHect",
}

const PREFIX_CHUNKS = table_create(MAX_CACHED_GROUP) :: {string}
const STANDALONE_CHUNKS = table_create(MAX_CACHED_GROUP) :: {string}

PREFIX_CHUNKS[1] = ""
STANDALONE_CHUNKS[1] = STANDALONE_GROUP_SUFFIXES[1]

for group = 2, 10 do
	PREFIX_CHUNKS[group] = GROUP_PREFIXES[group]
	STANDALONE_CHUNKS[group] = STANDALONE_GROUP_SUFFIXES[group]
end

for group = 11, 100 do
	const offset = group - 11
	const suffix = GROUP_PREFIXES[(offset % 10) + 1] .. TEN_GROUP_ROOTS[offset // 10 + 1]

	PREFIX_CHUNKS[group] = suffix
	STANDALONE_CHUNKS[group] = suffix
end

for group = 101, MAX_CACHED_GROUP do
	const offset = group - 101
	const suffix = PREFIX_CHUNKS[(offset % 100) + 1] .. HUNDRED_GROUP_ROOTS[offset // 100 + 1]

	PREFIX_CHUNKS[group] = suffix
	STANDALONE_CHUNKS[group] = suffix
end

const function build(group: number): string?
	if group <= 0 then
		return ""
	end

	if group <= 1000 then
		return STANDALONE_CHUNKS[group]
	end

	const chunks = table_create(4) :: {number?}
	local chunk_count = 0
	local remaining = group

	while remaining > 0 do
		chunk_count += 1
		chunks[chunk_count] = remaining % 1000
		remaining = remaining // 1000
	end

	const parts = table_create(chunk_count)
	local part_count = 0

	for position = chunk_count, 2, -1 do
		const chunk = chunks[position]
		if chunk and chunk > 0 then
			const tier_root = HIGHER_TIER_ROOTS[position - 1]
			if tier_root == nil then
				return nil
			end

			part_count += 1
			parts[part_count] = PREFIX_CHUNKS[chunk] .. tier_root
		end
	end

	const low_chunk = chunks[1] or 0
	if low_chunk > 0 then
		if part_count == 0 then
			part_count += 1
			parts[part_count] = STANDALONE_CHUNKS[low_chunk]
		elseif low_chunk ~= 1 then
			part_count += 1
			parts[part_count] = PREFIX_CHUNKS[low_chunk]
		end
	end

	return table_concat(parts, "", 1, part_count)
end

if MAX_CONFIGURED_SUFFIX_POWER <= MAX_CACHED_GROUP + 1 then
	for power = 2, MAX_CONFIGURED_SUFFIX_POWER do
		const suffix = STANDALONE_CHUNKS[power - 1]
		SUFFIXES[power] = suffix
		SUFFIX_TO_POWER[suffix] = power
	end

	MAX_DEFINED_SUFFIX_POWER = MAX_CONFIGURED_SUFFIX_POWER
else
	for power = 2, MAX_CONFIGURED_SUFFIX_POWER do
		const suffix = build(power - 1)
		if suffix == nil then
			break
		end

		SUFFIXES[power] = suffix
		SUFFIX_TO_POWER[suffix] = power
		MAX_DEFINED_SUFFIX_POWER = power
	end
end

Suffixes.MAX_SUFFIX_POWER = MAX_DEFINED_SUFFIX_POWER
Suffixes.SUFFIXES = SUFFIXES :: {[number]: string}
Suffixes.SUFFIX_TO_POWER = SUFFIX_TO_POWER :: {[string]: number}

function Suffixes.BUILD_SUFFIX(power: number): string?
	if power <= 1 then
		return ""
	end

	return SUFFIXES[power] :: string?
end

function Suffixes.PARSE_SUFFIX(text: string): number?
	return SUFFIX_TO_POWER[text]
end

return Suffixes
