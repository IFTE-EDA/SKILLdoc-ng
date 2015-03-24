#!/usr/bin/env lua

--[[
Dependencies
------------
- Lua   - http://www.lua.org
- lpeg  - http://www.inf.puc-rio.br/~roberto/lpeg/lpeg.html
- cosmo - http://cosmo.luaforge.net
--]]

-- usage:  lua skilldoc-ng.lua skillppfile.ils
-- output: skillppfile.html

-- Work arround for a bug in the Lua package of Scientific Linux
package.path = package.path .. ";/usr/share/lua/5.1/?.lua"

--local pretty = require "pl.pretty"

-- template engine
local cosmo  = require "cosmo"

local format = string.format
local match  = string.match
local gmatch = string.gmatch
local concat = table.concat

local filename = ...
local fh = assert(io.open(filename))
-- get the basename of the file
local module_name = match(filename, "([^%.]+)")

-------------------------------------------------
-- First part: Collect all block comments
-- starting with ;;; and the line that comes
-- after these blocks. This line is used to
-- determine the type of source code that is
-- documented by the block comment.
-------------------------------------------------

-- Table containing all comments as distinct tables.
local comments = {}
-- Table storing the current comment.
local comment = {}
-- Table storing the position of the constructors of all classes. Later on,
-- we can find the the class to which a method definition belongs.
local constructors = {}
-- Are we currently in a block comment?
local block_comment = false
for l in fh:lines() do
    -- Look for constructors and save their position.
    -- Format: defmethod( initializeInstance ((obj class_name ...
    local class = match(l,
      "%s*%(?%s*defmethod%(?%s*initializeInstance%s*%(%([%w_]+%s*([%w_]+)")
    if class then
        constructors[class] = fh:seek("cur")
    end

    -- Split the current line in semicolons and rest.
    local cstart, cline = match(l, "%s*(;*)%s*([^\n]*)")
    -- Does the line start with at least 3 semicolons?
    if cstart:len() >= 3 then
        block_comment = true
    end
    -- Does it start with semicolons at all?
    if cstart ~= "" and block_comment then
        -- Store line in current comment table.
        comment[#comment+1] = cline
    elseif block_comment then
        -- Line does not start with semicolons -> is no comment.
        -- Store the next line.
        comment.next_line = cline
        -- Store the position of the next line.
        -- This is used later on to parse the package export list.
        comment.pos = fh:seek("cur") - cline:len() - 1
        -- Store comment.
        comments[#comments+1] = comment
        comment = {}
        block_comment = false
    end
end

-------------------------------------------------
-- Second part: Process all block comments and
-- construct a structure of the file.
-------------------------------------------------

--- Takes a block comment and extracts summary, description and tags.
-- @param comment List of all lines of all block comment.
local function parse_comment(comment)
    local t = {}
    local tags = {params = {}}
    comment = concat(comment, " ")
    t.summary, t.description = match(comment, "([^%.@]+%.)%s*([^@]*)")
    -- Iterate over all tag definitions.
    for tag, param, sep, description in gmatch(comment, "@([%w_]+)%s*([%S]*)(%s*)([^@]*)") do
        description = match(description, "^%s*(.-)%s*$")
        if tag == "param" then
            tags.params[#tags.params+1] = {param = param, description = description}
        else
            tags[tag] = tags[tag] or {}
            tags[tag][#tags[tag]+1] = param .. sep .. description
        end
    end
    t.tags = tags
    return t
end

-- This table stores the whole file structure.
local content = {classes = {}, functions = {}, packages = {}, module_name = module_name}
-- Are we parsing a class defintion?
local in_class = nil
-- Are we parsing a package definition?
local in_package = nil

-- Process all block comments that were found in the previous step.
for _,comment in ipairs(comments) do
    -- Parse the block comment.
    local doc = parse_comment(comment)
    local next_line = comment.next_line

    -- Check the line after block comment for all possible patterns.

    -- match "defun"
    local func         = match(next_line, "%(?%s*defun%(?%s*([%w_]+)") or
                         match(next_line, "%(?%s*procedure%(?%s*([%w_]+)")
    -- match class name in "defclass" or "defmethod"
    local class        = match(next_line, "%(?%s*defclass%(?%s*([%w_]+)") or
                         match(next_line, "%(?%s*defmethod%(?%s*[%w_]+%s*%(%(%s*[%w_]+%s*([%w_]+)")
    -- match "(member)"
    local member       = match(next_line, "^%(%s*([%w_]+)")
    -- match method name "defmethod" or "*->method = lambda ..."
    local method       = match(next_line, "%(?%s*defmethod%(?%s*([%w_]+)") or
                         match(next_line, "[%w_]+%->([%w_]+)%s*=%s*%(?%s*lambda%W")
    -- match package name in "package_name = let(..."
    local package      = match(next_line, "([%w_]+)%s*=%s*let%(")
    -- match package export list (disembodied property list) in "list(nil ..."
    local package_list = match(next_line, "%(?%s*list%(?%s*nil")

    if next_line == "" then
        -- global comment (usually at the beginning of the file)
        content.doc = doc
    -- Check for method before we check for class, because the variable
    -- "class" possibly contains the class name (see class matching above)
    elseif method then
        -- If "class" containts the class name, "defmethod" was found.
        if class then
            -- found defmethod
            local methods = content.classes[class].methods
            methods[#methods+1] = {name = method, doc = doc}
        else
            -- found obj->method = lambda ...
            -- Now, we need the name of the class to which this method
            -- belongs...
            local current_pos = 0
            local current_class
            -- Search for the last constructor before the line containing
            -- the method definition (= the constructor we're currently in).
            for class, pos in pairs(constructors) do
                if pos < comment.pos and pos > current_pos then
                    current_class = class
                end
            end
            assert(current_class)
            local methods = content.classes[current_class].methods
            methods[#methods+1] = {name = method, doc = doc}
        end
        in_class = false
    elseif class then
        content.classes[#content.classes+1] =
          {class_name = class, members = {}, methods = {}, doc = doc}
        -- Create a link, so that we can access this class by index and by
        -- name.
        content.classes[class] = content.classes[#content.classes]
        in_class = true
    elseif package then
        content.packages[#content.packages+1] =
          {package_name = package, functions = {}, mappings = {}, doc = doc}
        -- Create a link.
        content.packages[package] = content.packages[#content.packages]
        in_class = false
        in_package = true
    elseif package_list then
        -- A package export list is only allowed inside of a package
        -- definition.
        assert(in_package)
        -- Now, we examine all lines following this block comment and
        -- extract all pairs export_name->function_name.
        fh:seek("set", comment.pos)
        local line = ""
        -- Get all lines until we find a closing parantheses.
        repeat
            line = line .. fh:read("*line")
        until match(line, "%)")
        -- Get the last package that was added to the list (the current one).
        local package = content.packages[#content.packages]
        local mappings = package.mappings
        -- Store all mappings export_name->function_name in the mappings
        -- table.
        for export, func in gmatch(line, "'([%w_]+)%s+([%w_]+)") do
            if not package.functions[func] then
              error(format("Exported function '%s' was not defined", func))
            end
            mappings[#mappings+1] = {export = export, func = package.functions[func]}
            -- Create a link.
            mappings[export] = mappings[#mappings]
            content.has_functions = true
        end
        in_class = false
        in_package = false
    elseif func then
        if in_package then
            -- Found a function definition inside a package definition.
            local package = content.packages[#content.packages]
            package.functions[#package.functions+1] = {name = func, doc = doc}
            -- Create a link.
            package.functions[func] = package.functions[#package.functions]
        else
            -- Found a global function definition.
            content.functions[#content.functions+1] = {name = func, doc = doc}
            -- Create a link.
            content.functions[func] = content.functions[#content.functions]
            content.has_functions = true
        end
        in_class = false
    elseif member then
        -- Found class member.
        assert(in_class)
        local members = content.classes[#content.classes].members
        members[#members+1] = {name = member, doc = doc}
    end
end

--pretty.dump(content)

-- Cosmo template (contains special markup).
local template = [=[
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
   "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8"/>
    <title>$module_name</title>
    <style type="text/css">
    <!--
/* BEGIN RESET

Copyright (c) 2010, Yahoo! Inc. All rights reserved.
Code licensed under the BSD License:
http://developer.yahoo.com/yui/license.html
version: 2.8.2r1
*/
html {
    color: #000;
    background: #FFF;
}
body,div,dl,dt,dd,ul,ol,li,h1,h2,h3,h4,h5,h6,pre,code,form,fieldset,legend,input,button,textarea,p,blockquote,th,td {
    margin: 0;
    padding: 0;
}
table {
    border-collapse: collapse;
    border-spacing: 0;
}
fieldset,img {
    border: 0;
}
address,caption,cite,code,dfn,em,strong,th,var,optgroup {
    font-style: inherit;
    font-weight: inherit;
}
del,ins {
    text-decoration: none;
}
li {
    list-style: bullet;
    margin-left: 20px;
}
caption,th {
    text-align: left;
}
h1,h2,h3,h4,h5,h6 {
    font-size: 100%;
    font-weight: bold;
}
q:before,q:after {
    content: '';
}
abbr,acronym {
    border: 0;
    font-variant: normal;
}
sup {
    vertical-align: baseline;
}
sub {
    vertical-align: baseline;
}
legend {
    color: #000;
}
input,button,textarea,select,optgroup,option {
    font-family: inherit;
    font-size: inherit;
    font-style: inherit;
    font-weight: inherit;
}
input,button,textarea,select {
  font-size:100%;
}
/* END RESET */

body {
    margin-left: 1em;
    margin-right: 1em;
    font-family: arial, helvetica, geneva, sans-serif;
    background-color: #ffffff; margin: 0px;
}

code, tt { font-family: monospace; }

body, p, td, th { font-size: .95em; line-height: 1.2em;}

p, ul { margin: 10px 0 0 10px;}

strong { font-weight: bold;}

em { font-style: italic;}

h1 {
    font-size: 1.5em;
    margin: 0 0 20px 0;
}
h2, h3, h4 { margin: 15px 0 10px 0; }
h2 { font-size: 1.25em; }
h3 { font-size: 1.15em; }
h4 { font-size: 1.06em; }

a:link { font-weight: bold; color: #004080; text-decoration: none; }
a:visited { font-weight: bold; color: #006699; text-decoration: none; }
a:link:hover { text-decoration: underline; }

hr {
    color:#cccccc;
    background: #00007f;
    height: 1px;
}

blockquote { margin-left: 3em; }

ul { list-style-type: disc; }

p.name {
    font-family: "Andale Mono", monospace;
    padding-top: 1em;
}

pre.example {
    background-color: rgb(245, 245, 245);
    border: 1px solid silver;
    padding: 10px;
    margin: 10px 0 10px 0;
    font-family: "Andale Mono", monospace;
    font-size: .85em;
}

pre {
    background-color: rgb(245, 245, 245);
    border: 1px solid silver;
    padding: 10px;
    margin: 10px 0 10px 0;
    overflow: auto;
    font-family: "Andale Mono", monospace;
}


table.index { border: 1px #00007f; }
table.index td { text-align: left; vertical-align: top; }

#container {
    margin-left: 1em;
    margin-right: 1em;
    background-color: #f0f0f0;
}

#product {
    text-align: center;
    border-bottom: 1px solid #cccccc;
    background-color: #ffffff;
}

#product big {
    font-size: 2em;
}

#main {
    background-color: #f0f0f0;
    border-left: 2px solid #cccccc;
}

#content {
    /*margin-left: 18em;*/
    padding: 1em;
    border-left: 2px solid #cccccc;
    border-right: 2px solid #cccccc;
    background-color: #ffffff;
}

#about {
    clear: both;
    padding: 5px;
    border-top: 2px solid #cccccc;
    background-color: #ffffff;
}

@media print {
    body {
        font: 12pt "Times New Roman", "TimeNR", Times, serif;
    }
    a { font-weight: bold; color: #004080; text-decoration: underline; }

    #main {
        background-color: #ffffff;
        border-left: 0px;
    }

    #container {
        margin-left: 2%;
        margin-right: 2%;
        background-color: #ffffff;
    }

    #content {
        padding: 1em;
        background-color: #ffffff;
    }

    #navigation {
        display: none;
    }
    pre.example {
        font-family: "Andale Mono", monospace;
        font-size: 10pt;
        page-break-inside: avoid;
    }
}

table.module_list {
    border-width: 1px;
    border-style: solid;
    border-color: #cccccc;
    border-collapse: collapse;
}
table.module_list td {
    border-width: 1px;
    padding: 3px;
    border-style: solid;
    border-color: #cccccc;
}
table.module_list td.name { background-color: #f0f0f0; ; min-width: 200px; }
table.module_list td.summary { width: 100%; }


table.function_list {
    border-width: 1px;
    border-style: solid;
    border-color: #cccccc;
    border-collapse: collapse;
}
table.function_list td {
    border-width: 1px;
    padding: 3px;
    border-style: solid;
    border-color: #cccccc;
}
table.function_list td.name { background-color: #f0f0f0; ; min-width: 200px; }
table.function_list td.indented_name { min-width: 200px; padding-left: 20px; }
table.function_list td.summary { width: 100%; }

dl.table dt, dl.function dt {border-top: 1px solid #ccc; padding-top: 1em;}
dl.table dd, dl.function dd {padding-bottom: 1em; margin: 10px 0 0 20px;}
dl.table h3, dl.function h3 {font-size: .95em;}
dl.methods {margin: 0 0 0 20px;}

/* stop sublists from having initial vertical space */
ul ul { margin-top: 0px; }
ol ul { margin-top: 0px; }
ol ol { margin-top: 0px; }
ul ol { margin-top: 0px; }

/* styles for prettification of source */
.keyword {font-weight: bold; color: #6666AA; }
.number  { color: #AA6666; }
.string  { color: #8888AA; }
.comment { color: #666600; }
.prepro { color: #006666; }
.global { color: #800080; }
-->
</style>
</head>
<body>

<div id="container">

<div id="product">
  <div id="product_logo"></div>
  <div id="product_name"><big><b></b></big></div>
  <div id="product_description"></div>
</div> <!-- id="product" -->

<div id="main">

<div id="content">

<h1>Module <code>$module_name</code></h1>

$if{$doc}[[
  $if{$doc|summary}[[
<p>$doc|summary</p>
  ]]
  $if{$doc|description}[[
<p>$doc|description</p>
  ]]
  $if{$doc|tags|copyright}[[
    $doc|tags|copyright[[
<p>Copyright &copy; $get_list{$doc|tags|copyright}[[$list]]</p>
    ]]
  ]]
  $if{$doc|tags|author}[[
<p>
    $if{#doc.tags.author == 1}[[Author: ]],[[Authors: ]]
    $get_list{$doc|tags|author}[[$list]]
</p>
  ]]
]]

$if{#classes > 0}[[
<h2><a href="#Classes">Classes</a></h2>
<table class="function_list">
    $classes[[
    <tr>
      <td class="name" nowrap="nowrap"><a href="#class-$class_name">$class_name</a></td>
      <td class="summary">$doc|summary</td>
    </tr>
    $methods[[
    <tr>
      <td class="indented_name" nowrap="nowrap"><a href="#method-$class_name-$name">obj-&gt;$name</a></td>
      <td class="summary">$doc|summary</td>
    </tr>
    ]]
    ]]
</table>
]]

$if{has_functions}[[
<h2><a href="#Functions">Functions</a></h2>
<table class="function_list">
    $packages[[
    $mappings[[
    <tr>
      <td class="name" nowrap="nowrap"><a href="#$package_name-$export">$package_name->$export($get_params{$func|doc}[[$result]])</a></td>
      <td class="summary">$func|doc|summary</td>
    </tr>
    ]]
    ]]
    $functions[[
    <tr>
    <td class="name" nowrap="nowrap"><a href="#$name">$name($get_params{$doc}[[$result]])</a></td>
      <td class="summary">$doc|summary</td>
    </tr>
    ]]
</table>
]]

<br/>
<br/>

$if{#classes > 0}[[
    <h2><a name="Classes"></a>Classes</h2>
    $classes[[
    <dl class="function">
      <dt>
        <a name="class-$class_name"></a>
        <strong>$class_name</strong>
      </dt>
      <dd>
      $doc|summary $doc|description

      $if{#members > 0}[[
      <h3>Slots:</h3>
      <ul>
        $members[[
        <li><code><em>$name</em></code>: $doc|summary $doc|description</li>
        ]]
      </ul>
      ]]

      $if{#methods > 0}[[
      <h3>Methods:</h3>
      <dl class="methods">
        $methods[[
        <dt>
          <a name="method-$class_name-$name"></a>
          <strong>obj-&gt;$name($get_params{$doc}[[$result]])</strong>
        </dt>
        <dd>
          $doc|summary $doc|description

          $if{#doc.tags.params > 0}[[
          <h4>Parameters:</h4>
          $doc|tags|params[[
          <ul>
            <li><code><em>$param</em></code>$if{$description ~= ""}[[: $description]]</li>
          </ul>
          ]]
          ]]
        </dd>
        ]]
      </dl>
      ]]
      </dd>
    </dl>
    ]]
]]

$if{has_functions}[[
    <h2><a name="Functions"></a>Functions</h2>
    $packages[[
    $mappings[[
    <dl class="function">
    <dt>
    <a name="$package_name-$export"></a>
    <strong>$package_name->$export($get_params{$func|doc}[[$result]])</strong>
    </dt>
    <dd>
    $func|doc|summary $func|doc|description

    $if{#func.doc.tags.params > 0}[[
    <h3>Parameters:</h3>
    $func|doc|tags|params[[
    <ul>
       <li><code><em>$param</em></code>$if{$description ~= ""}[[: $description]]</li>
    </ul>
    ]]
    ]]
    </dd>
    </dl>
    ]]
    ]]
    $functions[[
    <dl class="function">
    <dt>
    <a name="$name"></a>
    <strong>$name($get_params{$doc}[[$result]])</strong>
    </dt>
    <dd>
    $doc|summary $doc|description

    $if{#doc.tags.params > 0}[[
    <h3>Parameters:</h3>
    $doc|tags|params[[
    <ul>
       <li><code><em>$param</em></code>$if{$description ~= ""}[[: $description]]</li>
    </ul>
    ]]
    ]]
    </dd>
    </dl>
    ]]
]]

</div> <!-- id="content" -->
</div> <!-- id="main" -->
</div> <!-- id="container" -->
</body>
</html>
]=]

-- Open output file.
local html = assert(io.open(module_name .. ".html", "w"))

-- Prepare the content table for cosmo.
-- If function (in template: $if)
content["if"] = cosmo.cif
-- Function to generate a string representation for a list.
-- (in template: $get_list{$list}[[$list]]
content.get_list = function(arg)
    cosmo.yield{list = concat(arg[1], ", ")}
end
-- Function to generate a parameter list for methods and functions.
-- (in template: $get_params{$doc}[[$result]])
content.get_params = function(arg)
    local params = {}
    -- Iterate over all "param" tags in the given doc structure.
    for _,param in ipairs(arg[1].tags.params) do
        params[#params+1] = param.param
    end
    local result = concat(params, " ")
    if result:len() > 20 then
      result = "<br/>&nbsp;&nbsp;&nbsp;" .. concat(params, "<br/>&nbsp;&nbsp;&nbsp;") .. "<br/>"
    end
    cosmo.yield{result = result}
end
html:write(cosmo.fill(template, content))
html:close()

