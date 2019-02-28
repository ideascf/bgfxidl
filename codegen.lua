-- Copyright 2019 云风 https://github.com/cloudwu . All rights reserved.
-- License (the same with bgfx) : https://github.com/bkaradzic/bgfx/blob/master/LICENSE

local codegen = {}

local NAMEALIGN = 20

local function namealign(name)
	return string.rep(" ", NAMEALIGN - #name)
end

local function camelcase_to_underscorecase(name)
	local tmp = {}
	for v in name:gmatch "[%u%d]+%l*" do
		tmp[#tmp+1] = v:lower()
	end
	return table.concat(tmp, "_")
end

local function convert_typename(name)
	if name:match "^%u" then
		return "bgfx_" .. camelcase_to_underscorecase(name) .. "_t"
	else
		return name
	end
end

local function convert_funcname(name)
	name = name:gsub("^%l", string.upper)	-- Change to upper CamlCase
	return camelcase_to_underscorecase(name)
end

local function convert_arg(all_types, arg, what)
	local fulltype, array = arg.fulltype:match "(.-)%s*(%[%s*[%d%a_]*%s*%])"
	if array then
		arg.fulltype = fulltype
		arg.array = array
	end
	local t, postfix = arg.fulltype:match "(%a[%a%d_:]*)%s*([*&]+)%s*$"
	if t then
		arg.type = t
		if postfix == "&" then
			arg.ref = true
		end
	else
		local prefix, t = arg.fulltype:match "^%s*(%a+)%s+(%S+)"
		if prefix then
			arg.type = t
		else
			arg.type = arg.fulltype
		end
	end
	local ctype = all_types[arg.type]
	if not ctype then
		error ("Undefined type " .. arg.fulltype .. " for " .. what)
	end
	arg.ctype = arg.fulltype:gsub(arg.type, ctype.cname):gsub("&", "*")
	if ctype.cname ~= arg.type then
		arg.cpptype = arg.fulltype:gsub(arg.type, "bgfx::"..arg.type)
	else
		arg.cpptype = arg.fulltype
	end
	if arg.ref then
		arg.ptype = arg.cpptype:gsub("&", "*")
	end
end

local function alternative_name(name)
	if name:sub(1,1) == "_" then
		return name:sub(2)
	else
		return name .. "_"
	end
end

local function gen_arg_conversion(all_types, arg)
	if arg.ctype == arg.fulltype then
		-- do not need conversion
		arg.aname = arg.name
		return
	end
	local ctype = all_types[arg.type]
	if ctype.handle and arg.type == arg.fulltype then
		local aname = alternative_name(arg.name)
		arg.aname = aname .. ".cpp"
		arg.conversion = string.format(
			"union { %s c; bgfx::%s cpp; } %s = { %s };" ,
			ctype.cname, arg.type, aname, arg.name)
	elseif arg.ref then
		if ctype.cname == arg.type then
			arg.aname = "*" .. arg.name
		elseif arg.out and ctype.enum then
			local aname = alternative_name(arg.name)
			local cpptype = arg.cpptype:match "(.-)%s*&"	-- remove &
			arg.aname = aname
			arg.conversion = string.format("%s %s;", cpptype, aname)
			arg.out_conversion = string.format("*%s = (%s)%s;", arg.name, ctype.cname, aname)
		else
			arg.aname = alternative_name(arg.name)
			arg.conversion = string.format(
				"%s %s = *(%s)%s;",
				arg.cpptype, arg.aname, arg.ptype, arg.name)
		end
	else
		local cpptype = arg.cpptype
		if arg.array then
			cpptype = cpptype .. "*"
		end
		arg.aname = string.format(
			"(%s)%s",
			cpptype, arg.name)
	end
end

local function gen_ret_conversion(all_types, func)
	local postfix = { func.vararg and "va_end(argList);" }
	func.ret_postfix = postfix

	for _, arg in ipairs(func.args) do
		if arg.out_conversion then
			postfix[#postfix+1] = arg.out_conversion
		end
	end

	local ctype = all_types[func.ret.type]
	if ctype.handle then
		func.ret_conversion = string.format(
			"union { %s c; bgfx::%s cpp; } handle_ret;" ,
			ctype.cname, func.ret.type)
		func.ret_prefix = "handle_ret.cpp = "
		postfix[#postfix+1] = "return handle_ret.c;"
	elseif func.ret.fulltype ~= "void" then
		local ctype_conversion = func.ret.type == func.ret.ctype and "" or ("(" ..  func.ret.ctype .. ")")
		if #postfix > 0 then
			func.ret_prefix = string.format("%s retValue = %s", func.ret.ctype , ctype_conversion)
			postfix[#postfix+1] = "return retValue;"
		else
			func.ret_prefix = string.format("return %s", ctype_conversion)
		end
	end
end

function codegen.nameconversion(all_types, all_funcs)
	local enums = {}
	for k,v in pairs(all_types) do
		if not v.cname then
			v.cname = convert_typename(k)
		end
		v.name = k
		if v.enum then
			enums[#enums+1] = k
		end
	end

	for _, e in ipairs(enums) do
		local t = all_types[e]
		all_types[e] = nil
		all_types[e .. "::Enum"] = t
	end

	for k,v in pairs(all_types) do
		if v.struct then
			for _, item in ipairs(v.struct) do
				convert_arg(all_types, item, v.name)
			end
		end
	end

	for _,v in ipairs(all_funcs) do
		if v.cname == nil then
			v.cname = convert_funcname(v.name)
		end
		if v.class then
			v.cname = convert_funcname(v.class) .. "_" .. v.cname
		end
		for _, arg in ipairs(v.args) do
			convert_arg(all_types, arg, v.name)
			gen_arg_conversion(all_types, arg)
		end
		if v.vararg then
			local args = v.args
			local vararg = {
				name = "",
				ctype = "...",
				aname = "argList",
				conversion = string.format(
					"va_list argList;\n\tva_start(argList, %s);",
					args[#args].name),
			}
			args[#args + 1] = vararg
			v.implname = v.vararg
		else
			v.implname = v.name
		end
		convert_arg(all_types, v.ret, v.name .. "@rettype")
		gen_ret_conversion(all_types, v)
		if v.class then
			local classname = v.class
			if v.const then
				classname = "const " .. classname
			end
			local classtype = { fulltype = classname .. "*" }
			convert_arg(all_types, classtype, "class member " .. v.name)
			v.this = classtype.ctype .. " _this"
			v.this_conversion = string.format( "%s This = (%s)_this;", classtype.cpptype, classtype.cpptype)
		end
	end
end

local function lines(tbl)
	if #tbl == 0 then
		return "//EMPTYLINE"
	else
		return table.concat(tbl, "\n\t")
	end
end

local function remove_emptylines(txt)
	return (txt:gsub("\t//EMPTYLINE\n", ""))
end

local function codetemp(func)
	local conversion = {}
	local args = {}
	local callargs = {}
	local cppfunc
	if func.class then
		-- It's a member function
		args[1] = func.this
		conversion[1] = func.this_conversion
		cppfunc = "This->" .. func.name
	else
		cppfunc = "bgfx::" .. func.implname
	end
	for _, arg in ipairs(func.args) do
		conversion[#conversion+1] = arg.conversion
		local name = arg.ctype .. " " .. arg.name
		if arg.array then
			name = name .. arg.array
		end
		args[#args+1] = name
		callargs[#callargs+1] = arg.aname
	end
	conversion[#conversion+1] = func.ret_conversion

	return {
		RET = func.ret.ctype,
		FUNCNAME = func.cname,
		ARGS = table.concat(args, ", "),
		CONVERSION = lines(conversion),
		PRERET = func.ret_prefix or "",
		CPPFUNC = cppfunc,
		CALLARGS = table.concat(callargs, ", "),
		POSTRET = lines(func.ret_postfix),
		CODE = func.cfunc,
	}
end

local function apply_template(func, temp)
	func.codetemp = func.codetemp or codetemp(func)
	return (temp:gsub("$(%u+)", func.codetemp))
end

local c99temp = [[
BGFX_C_API $RET bgfx_$FUNCNAME($ARGS)
{
	$CONVERSION
	$PRERET$CPPFUNC($CALLARGS);
	$POSTRET
}
]]

local c99usertemp = [[
BGFX_C_API $RET bgfx_$FUNCNAME($ARGS)
{
$CODE
}
]]

function codegen.gen_c99(func)
	if func.cfunc then
		return apply_template(func, c99usertemp)
	else
		return remove_emptylines(apply_template(func, c99temp))
	end
end

local template_function_declaration = [[
/**/
BGFX_C_API $RET bgfx_$FUNCNAME($ARGS);
]]

function codegen.gen_c99decl(func)
	return apply_template(func, template_function_declaration)
end

function codegen.gen_interface_struct(func)
	return apply_template(func, "$RET (*$FUNCNAME)($ARGS);")
end

function codegen.gen_interface_import(func)
	return "bgfx_" .. func.cname
end

function codegen.doxygen_type(typedef, doxygen)
	if doxygen == nil then
		return
	end
	local result = {}
	for _, line in ipairs(doxygen) do
		result[#result+1] = "/// " .. line
	end
	result[#result+1] = "///"
	result[#result+1] = string.format("/// @attention C99 equivalent is `%s`.", typedef.cname)
	result[#result+1] = "///"
	return table.concat(result, "\n")
end

local enum_temp = [[
struct $NAME
{
	$COMMENT
	enum Enum
	{
		$ITEMS

		Count
	};
};
]]

function codegen.gen_enum_define(enum)
	assert(type(enum.enum) == "table", "Not an enum")
	local items = {}
	for _, item in ipairs(enum.enum) do
		local text
		if not item.comment then
			text = item.name .. ","
		else
			text = string.format("%s,%s //!< %s",
				item.name, namealign(item.name), item.comment)
		end
		items[#items+1] = text
	end
	local comment = ""
	if enum.comment then
		comment = "/// " .. enum.comment
	end
	local temp = {
		NAME = enum.name,
		COMMENT = comment,
		ITEMS = table.concat(items, "\n\t\t"),
	}
	return (enum_temp:gsub("$(%u+)", temp))
end

local cenum_temp = [[
typedef enum $NAME
{
	$ITEMS

	$COUNT

} $NAME_t;
]]
function codegen.gen_enum_cdefine(enum)
	assert(type(enum.enum) == "table", "Not an enum")
	local cname = enum.cname:match "(.-)_t$"
	local uname = cname:upper()
	local items = {}
	for _, item in ipairs(enum.enum) do
		items[#items+1] = uname .. "_" .. item.name:upper()
	end

	local temp = {
		NAME = cname,
		COUNT = uname .. "_COUNT",
		ITEMS = table.concat(items, ",\n\t"),
	}

	return (cenum_temp:gsub("$(%u+)", temp))
end

local struct_temp = [[
struct $NAME
{
	$CTOR
	$ITEMS
};
]]
function codegen.gen_struct_define(struct)
	assert(type(struct.struct) == "table", "Not a struct")
	local items = {}
	for _, item in ipairs(struct.struct) do
		local name = item.name
		if item.array then
			name = name .. item.array
		end
		local text = string.format("%s%s %s;", item.fulltype, namealign(item.fulltype), name)
		if item.comment then
			text = string.format("%s %s//!< %s", text,  namealign(name),  item.comment)
		end
		items[#items+1] = text
	end
	local ctor = {}
	if struct.ctor then
		ctor[1] = struct.name .. "();"
		ctor[2] = ""
	end
	local temp = {
		NAME = struct.name,
		ITEMS = table.concat(items, "\n\t"),
		CTOR = lines(ctor),
	}
	return remove_emptylines(struct_temp:gsub("$(%u+)", temp))
end

local cstruct_temp = [[
typedef struct $NAME_s
{
	$ITEMS

} $NAME_t;
]]
function codegen.gen_cstruct_define(struct)
	assert(type(struct.struct) == "table", "Not a struct")
	local cname = struct.cname:match "(.-)_t$"
	local items = {}
	for _, item in ipairs(struct.struct) do
		local text = string.format("%s%s %s%s;", item.ctype, namealign(item.ctype), item.name, item.array or "")
		items[#items+1] = text
	end
	local temp = {
		NAME = cname,
		ITEMS = table.concat(items, "\n\t"),
	}
	return cstruct_temp:gsub("$(%u+)", temp)
end

return codegen
