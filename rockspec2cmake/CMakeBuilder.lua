local Template = require 'pl.text'.Template

module("rockspec2cmake", package.seeall)

-- All valid supported_platforms from rockspec file and their cmake counterparts
local rock2cmake_platform =
{
    ["unix"] = "UNIX",
    ["linux"] = "UNIX",
    ["freebsd"] = "UNIX",
    ["macosx"] = "APPLE",
    ["windows"] = "WIN32",
    ["win32"] = "WIN32",
    ["mingw32"] = "WIN32",
    ["msys"] = "WIN32",
    ["cygwin"] = "CYGWIN",
}

local intro = Template[[
# Generated Cmake file begin
cmake_minimum_required(VERSION 3.1)

project(${package_name} C CXX)

find_package(Lua REQUIRED)

## INSTALL DEFAULTS (Relative to CMAKE_INSTALL_PREFIX)
# Primary paths
set(INSTALL_BIN bin CACHE PATH "Where to install binaries to.")
set(INSTALL_LIB lib CACHE PATH "Where to install libraries to.")
set(INSTALL_ETC etc CACHE PATH "Where to store configuration files")
set(INSTALL_SHARE share CACHE PATH "Directory for shared data.")

set(INSTALL_LMOD ${dollar}{INSTALL_LIB}/lua/${dollar}{LUA_VERSION_MAJOR}.${dollar}{LUA_VERSION_MINOR} CACHE PATH "Directory to install Lua modules.")
set(INSTALL_CMOD ${dollar}{INSTALL_LIB}/lua/${dollar}{LUA_VERSION_MAJOR}.${dollar}{LUA_VERSION_MINOR} CACHE PATH "Directory to install Lua binary modules.")

]]

local fatal_error_msg = Template[[
message(FATAL_ERROR "${message}")

]]

local unsupported_platform_check = Template [[
if (${platform})
    message(FATAL_ERROR "Unsupported platform (your platform was explicitly marked as not supported)")
endif()

]]

local supported_platform_check = Template [[
if (${expr})
    message(FATAL_ERROR "Unsupported platform (your platform is not in list of supported platforms)")
endif()

]]

local find_ext_dep = Template [[
find_package(${name})
set(${name}_LIBDIR ${dollar}{${name}_LIBRARIES})
set(${name}_INCDIR ${dollar}{${name}_INCLUDE_DIRS})

]]

local set_variable = Template [[
set(${name} ${value})
]]

local platform_specific_block = Template[[
if (${platform})
${definitions}endif()

]]

local build_install_copy = Template[[
install(DIRECTORY ${dollar}{BUILD_COPY_DIRECTORIES} DESTINATION ${dollar}{INSTALL_SHARE}/${package_name})

function(build_install KEYS DIR)
    list(REMOVE_DUPLICATES KEYS)

    foreach(KEY ${dollar}{${dollar}{KEYS}})
        set(BASE_NAME ${dollar}{KEYS}_${dollar}{KEY})
        install(FILES ${dollar}{${dollar}{BASE_NAME}_SRC} DESTINATION ${dollar}{DIR}/${dollar}{${dollar}{BASE_NAME}_DST} RENAME ${dollar}{${dollar}{BASE_NAME}_RENAME})
    endforeach(KEY)
endfunction(build_install)

build_install(BUILD_INSTALL_lua ${dollar}{INSTALL_LMOD})
build_install(BUILD_INSTALL_lib ${dollar}{INSTALL_LIB})
build_install(BUILD_INSTALL_conf ${dollar}{INSTALL_ETC})
build_install(BUILD_INSTALL_bin ${dollar}{INSTALL_BIN})

]]

local install_lua_module = Template[[
install(FILES ${dollar}{${name}_SOURCES} DESTINATION ${dollar}{INSTALL_LMOD}/${dest} RENAME ${new_name})
]]

local cxx_module = Template [[
add_library(${name} SHARED ${dollar}{${name}_SOURCES})

foreach(LIBRARY ${dollar}{${name}_LIB_NAMES})
    find_library(${name}_${dollar}{LIBRARY} ${dollar}{LIBRARY} ${dollar}{${name}_LIBDIRS})
    list(APPEND ${name}_LIBRARIES ${dollar}{LIBRARY})
endforeach(LIBRARY)

target_include_directories(${name} PRIVATE ${dollar}{${name}_INCDIRS} ${dollar}{LUA_INCLUDE_DIRS} ${dollar}{LUA_INCLUDE_DIR})
target_compile_definitions(${name} PRIVATE ${dollar}{${name}_DEFINES})
target_link_libraries(${name} PRIVATE ${dollar}{${name}_LIBRARIES} ${dollar}{LUA_LIBRARIES})
# Do not prefix "lib" before target name
set_target_properties(${name} PROPERTIES PREFIX "")
set_target_properties(${name} PROPERTIES OUTPUT_NAME ${output_name})
install(TARGETS ${name} DESTINATION ${dollar}{INSTALL_CMOD}/${dest})
]]

local function indent(str)
    local _indent = "    "
    return _indent .. str:gsub("\n", "\n" .. _indent):gsub(_indent .. "$", "")
end

-- Converts string in lua package notation into search path for such package
-- Examples:
-- a.b.c -> a.b
-- a -> <empty string>
local function path_from_lua_notation(str)
    return (str:match("^(.*)%.") or ""):gsub("%.", "/")
end

-- Converts string in lua package notation into name of such package
-- Examples:
-- a.b.c -> c
-- a -> a
local function name_from_lua_notation(str)
    return str:match("([^.]+)$")
end

-- CMakeBuilder
CMakeBuilder = {}

function CMakeBuilder:new(o, package_name)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    -- Tables with string values, for *_platforms tables, only values in
    -- rock2cmake_platform are inserted
    self.errors = {}
    self.supported_platforms = {}
    self.unsupported_platforms = {}

    -- Required external dependencies, each of them creates
    -- name_LIBDIR and name_INCDIR cmake variables
    --
    -- These variables need to be generated before other cmake variables
    -- because they can use them in their definitions
    self.ext_deps = {}
    self.override_ext_deps = {}

    -- Variables generated from build rules (builtin only)
    -- ["variable_name"] = "value"
    --
    -- Variables not depending on module name have their names formed from rockspec
    -- table hierarchy with dots replaced by underscores, for example BUILD_INSTALL_lua
    --
    -- Variables depending on module name have form of
    -- MODULENAME_{SOURCES|LIB_NAMES|DEFINES|INCDIRS|LIBDIRS}
    self.cmake_variables = {}
    self.override_cmake_variables = {}

    -- Tables containing only names of targets, override_*_targets can contain default
    -- targets, target is platform specific only if it is contained in override_*_targets and not in
    -- corresponding targets table
    self.lua_targets = {}
    self.override_lua_targets = {}
    self.cxx_targets = {}
    self.override_cxx_targets = {}

    self.package_name = package_name
    return o
end

function CMakeBuilder:platform_valid(platform)
    if rock2cmake_platform[platform] == nil then
        self:fatal_error("CMake alternative to platform '" .. platform .. "' was not defined," ..
            "cmake actions for this platform were not generated")
        return nil
    end

    return true
end

function CMakeBuilder:fatal_error(message)
    self.errors[message] = true
end

function CMakeBuilder:add_unsupported_platform(platform)
    if self:platform_valid(platform) then
        table.insert(self.unsupported_platforms, platform)
    end
end

function CMakeBuilder:add_supported_platform(platform)
    if self:platform_valid(platform) then
        table.insert(self.supported_platforms, platform)
    end
end

function CMakeBuilder:_internal_set_value(tbl, tbl_override, name, value, platform, append)
    if platform ~= nil then
        if self:platform_valid(platform) then
            if tbl_override[platform] == nil then
                tbl_override[platform] = {}
            end

            if append ~= nil then
                local old_value = (tbl_override[platform][name] and tbl_override[platform][name] .. ";") or ("${" .. name .. "};")
                tbl_override[platform][name] = old_value .. value
            else
                tbl_override[platform][name] = value
            end
        end
    else
        if append ~= nil then
            local old_value = (tbl[name] and tbl[name] .. ";") or ("${" .. name .. "};")
            tbl[name] = old_value .. value
        else
            tbl[name] = value
        end
    end
end

function CMakeBuilder:set_cmake_variable(name, value, platform, append)
    if value == "" then
        return
    end

    self:_internal_set_value(self.cmake_variables, self.override_cmake_variables,
        name, value, platform, append)
end

function CMakeBuilder:add_lua_module(name, platform)
    self:_internal_set_value(self.lua_targets, self.override_lua_targets,
        name, name, platform)
end

function CMakeBuilder:add_cxx_target(name, platform)
    self:_internal_set_value(self.cxx_targets, self.override_cxx_targets,
        name, name, platform)
end

function CMakeBuilder:add_ext_dep(name, platform)
    self:_internal_set_value(self.ext_deps, self.override_ext_deps,
        name, name, platform)
end

function CMakeBuilder:generate()
    local res = ""

    res = res .. intro:substitute({package_name = self.package_name, dollar = "$"})

    -- Print all fatal errors at the beginning
    for error_msg, _  in pairs(self.errors) do
        res = res .. fatal_error_msg:substitute({message = error_msg})
    end

    -- Unsupported platforms
    for _, plat in pairs(self.unsupported_platforms) do
        res = res .. unsupported_platform_check:substitute({platform = rock2cmake_platform[plat]})
    end

    -- Supported platforms
    if #self.supported_platforms ~= 0 then
        local supported_platforms_check_str = ""
        for _, plat in pairs(self.supported_platforms) do
            if supported_platforms_check_str == "" then
                supported_platforms_check_str = "NOT " .. rock2cmake_platform[plat]
            else
                supported_platforms_check_str = supported_platforms_check_str .. " AND NOT " .. rock2cmake_platform[plat]
            end
        end

        res = res .. supported_platform_check:substitute({expr = supported_platforms_check_str})
    end

    -- External dependencies
    for name, _ in pairs(self.ext_deps) do
        res = res .. find_ext_dep:substitute({name = name, dollar = "$"})
    end

    for platform, ext_deps in pairs(self.override_ext_deps) do
        local definitions = ""
        for name, _ in pairs(ext_deps) do
            definitions = definitions .. indent(find_ext_dep:substitute({name = name, dollar = "$"}))
        end

        res = res .. platform_specific_block:substitute({platform = rock2cmake_platform[platform], definitions = definitions})
    end

    -- Default (not overriden) variables
    for name, value in pairs(self.cmake_variables) do
        res = res .. set_variable:substitute({name = name, value = value})
    end
    res = res .. "\n"

    -- Platform overriden variables
    for platform, variables in pairs(self.override_cmake_variables) do
        local definitions = ""
        for name, value in pairs(variables) do
            definitions = definitions .. indent(set_variable:substitute({name = name, value = value}))
        end

        res = res .. platform_specific_block:substitute({platform = rock2cmake_platform[platform], definitions = definitions})
    end

    -- install.{lua|conf|bin|lib} and copy_directories
    res = res .. build_install_copy:substitute({package_name = self.package_name, dollar = "$"})

    -- Lua targets, install only
    for _, name in pairs(self.lua_targets) do
        -- Force install file as name.lua, rename if needed
        res = res .. install_lua_module:substitute({name = name, dest = path_from_lua_notation(name),
        new_name = name_from_lua_notation(name) .. ".lua", dollar = "$"})
    end
    res = res .. "\n"

    -- Platform specific Lua targets
    for platform, targets in pairs(self.override_lua_targets) do
        local definitions = ""
        for _, name in pairs(targets) do
            if self.lua_targets[name] == nil then
                -- Force install file as name.lua, rename if needed
                definitions = definitions .. indent(install_lua_module:substitute({name = name, dest = path_from_lua_notation(name),
                new_name = name_from_lua_notation(name) .. ".lua", dollar = "$"}))
            end
        end

        if definitions ~= "" then
            res = res .. platform_specific_block:substitute({platform = rock2cmake_platform[platform], definitions = definitions})
        end
    end

    -- Cxx targets
    for _, name in pairs(self.cxx_targets) do
        res = res .. cxx_module:substitute({name = name, dest = path_from_lua_notation(name),
            output_name = name_from_lua_notation(name), dollar = "$"})
    end

    -- Platform specific cxx targets
    for platform, targets in pairs(self.override_cxx_targets) do
        local definitions = ""
        for _, name in pairs(targets) do
            if self.cxx_targets[name] == nil then
                definitions = definitions .. indent(cxx_module:substitute({name = name, dest = path_from_lua_notation(name),
                    output_name = name_from_lua_notation(name), dollar = "$"}))
            end
        end

        if definitions ~= "" then
            res = res .. platform_specific_block:substitute({platform = rock2cmake_platform[platform], definitions = definitions})
        end
    end

    return res
end

return CMakeBuilder
