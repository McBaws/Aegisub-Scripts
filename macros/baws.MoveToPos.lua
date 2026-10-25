-- Copyright (c) 2026, McBaws
--
-- Permission to use, copy, modify, and distribute this software for any
-- purpose with or without fee is hereby granted, provided that the above
-- copyright notice and this permission notice appear in all copies.
--
-- THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
-- WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
-- MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
-- ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
-- WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
-- ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
-- OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

script_name = "MoveToPos"
script_description = "Converts move to pos on selected lines"
script_author = "McBaws"
script_namespace = "baws.MoveToPos"
script_version = "1.0.0"

local havedc, DependencyControl = pcall(require, "l0.DependencyControl")
local dep
if havedc then
    dep = DependencyControl{
        feed = "https://raw.githubusercontent.com/McBaws/Aegisub-Scripts/stable/DependencyControl.json",
    }
end

-- everything between the brackets of \move(x1,y1,x2,y2) or \move(x1,y1,x2,y2,t1,t2)
local MOVE = "\\move%(([^%)]*)%)"

local function convert(text, use_end)
    -- only touch tags inside {}, a \move outside of them is just text
    return (text:gsub("{[^}]*}", function(block)
        return (block:gsub(MOVE, function(args)
            local n = {}
            for v in args:gmatch("[^,]+") do n[#n + 1] = v:match("^%s*(.-)%s*$") end
            -- not a proper \move, leave it alone
            if #n ~= 4 and #n ~= 6 then return nil end
            if use_end then return "\\pos(" .. n[3] .. "," .. n[4] .. ")" end
            return "\\pos(" .. n[1] .. "," .. n[2] .. ")"
        end))
    end))
end

local function run(subs, sel, use_end)
    for _, i in ipairs(sel) do
        local line = subs[i]
        if line.class == "dialogue" then
            local text = convert(line.text, use_end)
            if text ~= line.text then
                line.text = text
                subs[i] = line
            end
        end
    end
    aegisub.set_undo_point(script_name)
    return sel
end

local macros = {
    {"Beginning", "Converts \\move to \\pos using where the move starts", function(subs, sel) return run(subs, sel, false) end},
    {"End", "Converts \\move to \\pos using where the move ends", function(subs, sel) return run(subs, sel, true) end},
}

if havedc then
    dep:registerMacros(macros)
else
    for _, m in ipairs(macros) do
        aegisub.register_macro(script_name .. "/" .. m[1], m[2], m[3])
    end
end
