-- Copyright (c) 2026, McBaws
-- Based on Honorary by Petzku
--
-- Permission to use, copy, modify, and distribute this software for any
-- purpose with or without fee is hereby granted, provided that the above
-- copyright notice and this permission notice appear in all copies.
--
-- THE SOFTWARE IS PROVIDED 'AS IS' AND THE AUTHOR DISCLAIMS ALL WARRANTIES
-- WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
-- MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
-- ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
-- WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
-- ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
-- OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

script_name = 'AutoSwapper'
script_description = 'Insert muxtools autoswapper markers and run the swap'
script_author = 'McBaws'
script_namespace = "baws.AutoSwapper"
script_version = '1.0.0'

local haveDepCtrl, DependencyControl, depctrl = pcall(require, "l0.DependencyControl")
if haveDepCtrl then
    depctrl = DependencyControl {
        feed="https://raw.githubusercontent.com/McBaws/Aegisub-Scripts/stable/DependencyControl.json",
    }
end

-- keep this the same as what the mux script passes to autoswapper()
-- nil = muxtools default, braces just get stripped from hidden text
local TAG_MARKERS = "[]"

local DEFAULTS = {
    -- same list as muxtools' DEFAULT_DIALOGUE_STYLES
    styles = "default, main, alt, overlap, flashback, top, italics",
    exact_names = true,
    inline_marker = "*",
    line_marker = "***",
}

-- settings only keep what differs from the defaults, so changing a default later still reaches people
-- without depctrl they just live in here until aegisub closes
local config, session = nil, {}

local function store_settings(store)
    if not config then
        session = store
        return true
    end
    -- depctrl 0.6 only ever adds keys when it writes, so clear the section first or old values stick around
    local ok, err = config:delete()
    if not ok then return ok, err end
    if next(store) == nil then return true end
    for k, v in pairs(store) do config.c[k] = v end
    return config:write()
end

if haveDepCtrl then
    config = depctrl:getConfigHandler(DEFAULTS, "settings")

    -- a-mo saved to <depctrl configDir>/<configFile>. newer depctrl doesn't expose configDir on the
    -- script's record, so there a-mo fell back to ?user, older depctrl gives ?user/config. check them all
    local function find_old_config()
        local okjson, json = pcall(require, "json")
        if not okjson then json = require("l0.dkjson") end
        local name = depctrl.configFile or (script_namespace .. ".json")
        local seen = {}
        for _, dir in ipairs({depctrl.configDir or "?user", "?user", "?user/config"}) do
            local path = aegisub.decode_path(dir .. "/" .. name)
            local f = not seen[path] and io.open(path, "r")
            seen[path] = true
            if f then
                local text = f:read("*a")
                f:close()
                local ok, old = pcall(json.decode, text)
                if ok and type(old) == "table" and old.__version ~= nil then return path, old end
            end
        end
    end

    -- one time move from the old a-mo file, which looks like {"main": {...}, "__version": ...}
    -- anything already saved with the new handler wins, the old values only fill in the rest
    local path, old = find_old_config()
    if path then
        local main = type(old.main) == "table" and old.main or {}
        local store = {}
        for k, v in pairs(DEFAULTS) do
            local now = config.userConfig and config.userConfig[k]
            if now ~= nil then
                store[k] = now
            elseif main[k] ~= nil and main[k] ~= v then
                store[k] = main[k]
            end
        end
        os.remove(path)
        store_settings(store)
    end
end

local function get_config()
    local c = {}
    for k, v in pairs(DEFAULTS) do
        if config then
            c[k] = config.c[k]
        elseif session[k] ~= nil then
            c[k] = session[k]
        else
            c[k] = v
        end
    end
    return c
end

-- new values go over the current ones, anything the script doesn't know about is ignored
local function save_config(new)
    local store = {}
    for k, v in pairs(get_config()) do
        if new[k] ~= nil then v = new[k] end
        if v ~= DEFAULTS[k] then store[k] = v end
    end
    return store_settings(store)
end

-- plain find and replace, no patterns
local function replace(s, a, b)
    if a == "" then return s end
    local out, i = {}, 1
    while true do
        local j, k = s:find(a, i, true)
        if not j then break end
        out[#out + 1] = s:sub(i, j - 1) .. b
        i = k + 1
    end
    out[#out + 1] = s:sub(i)
    return table.concat(out)
end

local function trim(s) return (s:match("^%s*(.-)%s*$")) end
local function esc(s) return (s:gsub("%p", "%%%0")) end
-- wx eats single & in labels
local function amp(s) return (s:gsub("&", "&&")) end

-- keeps long labels from making the dialog huge, without cutting a utf-8 char in half
local function clip(s, n)
    n = n or 80
    if #s <= n then return s end
    return (s:sub(1, n):gsub("[\192-\255][\128-\191]*$", "")) .. "…"
end

local function message(text)
    aegisub.dialog.display({{class="label", label=amp(text), x=0, y=0}}, {"OK"})
end

local MARKER, LINE_MARKER, STYLES, EXACT_NAMES
local SHOW_PAT, EN_SEL, DIS_SEL, AB_SEL, CONV_SEL

-- reads the config and rebuilds the patterns, every action calls this first
local function load_settings()
    local c = get_config()
    MARKER = trim(c.inline_marker) ~= "" and trim(c.inline_marker) or "*"
    LINE_MARKER = trim(c.line_marker) ~= "" and trim(c.line_marker) or "***"
    EXACT_NAMES = c.exact_names
    STYLES = {}
    for n in c.styles:gmatch("[^,]+") do
        n = trim(n):lower()
        if n ~= "" then STYLES[#STYLES + 1] = n end
    end

    local m = esc(MARKER)
    -- the ab and enabled ones can't be lua patterns (they need lookaheads), see ab_at / hide_at
    SHOW_PAT = "{" .. m .. m .. "([^}]+)}"

    -- what a selection can already look like
    EN_SEL = "^{" .. m .. "}(.*){" .. m .. "}$"
    DIS_SEL = "^{" .. m .. m .. "([^}]*)}$"
    AB_SEL = "^{" .. m .. "}(.-){" .. m .. "([^}]+)}$"
    CONV_SEL = "^(.+){" .. m .. m .. "([^}]+)}$"
end

local function check_config(c)
    if c.inline_marker == "" then return "The inline marker can't be empty." end
    if c.inline_marker:find("[{}]") then return "The inline marker can't have { or } in it." end
    if c.line_marker == "" then return "The line marker can't be empty." end
end

local function show_config(vals)
    vals = vals or get_config()
    while true do
        local btn, res = aegisub.dialog.display({
            {class="label", label="Styles to swap:", x=0, y=0},
            {class="edit", name="styles", value=vals.styles, x=1, y=0, width=3,
             hint="Comma separated, case insensitive. Leave empty to swap every style.\nOnly used by Swap > Entire Script."},
            {class="checkbox", name="exact_names", label="Match style names exactly", value=vals.exact_names, x=1, y=1, width=3,
             hint='Off: a style matches if its name contains one of the names, so "main" also hits "Main Top"'},
            {class="label", label="Inline marker:", x=0, y=2},
            {class="edit", name="inline_marker", value=vals.inline_marker, x=1, y=2, hint="Should be one character, like the * in {*}...{*}"},
            {class="label", label="Line marker:", x=0, y=3},
            {class="edit", name="line_marker", value=vals.line_marker, x=1, y=3, hint="Put in the effect or actor field to comment/uncomment the whole line"},
        }, {"Save", "Reset Defaults", "Cancel"}, {ok="Save", cancel="Cancel"})
        if not btn then return end
        if btn == "Reset Defaults" then
            -- only fills the dialog in, nothing's saved until Save
            vals = {}
            for k, v in pairs(DEFAULTS) do vals[k] = v end
        else
            res.inline_marker = trim(res.inline_marker)
            res.line_marker = trim(res.line_marker)
            local err = check_config(res)
            if err then
                message(err)
                vals = res
            else
                local ok, werr = save_config(res)
                if not ok then message("Couldn't save the settings: " .. tostring(werr)) end
                return
            end
        end
    end
end

-- hidden text lives inside a comment so it can't have braces, tags become [/i1] and back
local function hide(s)
    if TAG_MARKERS then
        local o, c = TAG_MARKERS:sub(1, 1), TAG_MARKERS:sub(2, 2)
        return replace(replace(replace(s, "{", o), "}", c), "\\", "/")
    end
    return replace(replace(s, "{", ""), "}", "")
end

local function reveal(s)
    if TAG_MARKERS then
        local o, c = TAG_MARKERS:sub(1, 1), TAG_MARKERS:sub(2, 2)
        return replace(replace(replace(s, o, "{"), c, "}"), "/", "\\")
    end
    return s
end

-- stuff like "and/or" or [brackets] doesn't survive hide -> reveal, so ask first
local function roundtrip_ok(strs)
    local msg = {"This won't come back exactly after swapping twice:"}
    for _, s in ipairs(strs) do
        local back = reveal(hide(s))
        if s ~= "" and back ~= s then
            msg[#msg + 1] = clip(s) .. "  →  " .. clip(back)
        end
    end
    if #msg == 1 then return true end
    local btn = aegisub.dialog.display({{class="label", label=amp(table.concat(msg, "\n")), x=0, y=0}},
        {"Continue", "Cancel"}, {ok="Continue", cancel="Cancel"})
    return btn == "Continue"
end

-- what each construct turns into when swapped
local function swap_ab(a, b)
    return "{" .. MARKER .. "}" .. reveal(b) .. "{" .. MARKER .. hide(a) .. "}"
end

local function swap_show(h)
    return "{" .. MARKER .. "}" .. reveal(h) .. "{" .. MARKER .. "}"
end

local function swap_hide(s)
    return "{" .. MARKER .. MARKER .. hide(s) .. "}"
end

-- after a {*} opener the text runs up to the very next {* and can't go past it,
-- that next {* decides what it is. same as the fixed muxtools regexes:
--   ab:   {*}((?:(?!{*).)*?){*(?!*)([^}]+)}
--   hide: {*}((?:(?!{*).)*?){* *}
local function next_closer(text, s)
    local c = s + #MARKER + 2
    local p = text:find("{" .. MARKER, c, true)
    if p then return text:sub(c, p - 1), p + #MARKER + 1 end
end

-- {*}A{*B}, returns end, A, B
local function ab_at(text, s)
    local a, q = next_closer(text, s)
    if not a or text:sub(q, q + #MARKER - 1) == MARKER then return end
    local _, e, b = text:find("^([^}]+)}", q)
    if e then return e, a, b end
end

-- {*}X{*}, returns end, X
local function hide_at(text, s)
    local x, q = next_closer(text, s)
    if not x then return end
    local _, e = text:find("^ *}", q)
    if e then return e, x end
end

-- finds every swap construct in the line with its position. scans left to right and at each {* tries
-- enabled, then ab, then hidden, same as one combined regex would
local function find_constructs(text)
    local found, i = {}, 1
    local open = "{" .. MARKER
    while true do
        local s = text:find(open, i, true)
        if not s then break end
        local e
        if text:sub(s + #open, s + #open) == "}" then
            -- {* } closers count as both in muxtools, the enabled one wins there too
            local x
            e, x = hide_at(text, s)
            if e then
                found[#found + 1] = {s=s, e=e, new=swap_hide(x)}
            else
                local a, b
                e, a, b = ab_at(text, s)
                if e then found[#found + 1] = {s=s, e=e, new=swap_ab(a, b)} end
            end
        else
            local _, he, h = text:find("^" .. SHOW_PAT, s)
            if he then
                e = he
                found[#found + 1] = {s=s, e=e, new=swap_show(h)}
            end
        end
        i = e and e + 1 or s + 1
    end
    return found
end

-- the swap itself. every construct is swapped in place in one pass, so one swap's result can't
-- get swapped again by another (muxtools' replace-by-string does that, see the PR)
local function swap_text(text)
    local out, i = {}, 1
    for _, c in ipairs(find_constructs(text)) do
        out[#out + 1] = text:sub(i, c.s - 1)
        out[#out + 1] = c.new
        i = c.e + 1
    end
    out[#out + 1] = text:sub(i)
    return table.concat(out)
end

local function has_line_marker(line)
    return trim(line.effect) == LINE_MARKER or trim(line.actor) == LINE_MARKER
end

local function swap_line(line)
    local text = swap_text(line.text)
    local flip = has_line_marker(line)
    if text == line.text and not flip then return line, false end
    line.text = text
    if flip then line.comment = not line.comment end
    return line, true
end

local function style_ok(style)
    if #STYLES == 0 then return true end
    local st = style:lower()
    for _, n in ipairs(STYLES) do
        if EXACT_NAMES then
            if st == n then return true end
        elseif st:find(n, 1, true) then
            return true
        end
    end
    return false
end

local function swap_script(subs)
    load_settings()
    for i = 1, #subs do
        local line = subs[i]
        if line.class == "dialogue" and style_ok(line.style) then
            local new, changed = swap_line(line)
            if changed then subs[i] = new end
        end
    end
end

-- grows the selection so it never cuts a {} block in half
local function snap(text, ss, se)
    local i = 1
    while true do
        local bs, be = text:find("{[^}]*}", i)
        if not bs then break end
        if ss == se then
            -- just a cursor inside a block, move it out the back
            if ss > bs and ss <= be then ss = be + 1 end
            se = ss
        else
            if ss > bs and ss <= be then ss = bs end
            if se > bs and se <= be then se = be + 1 end
        end
        i = be + 1
    end
    return ss, se
end

local function need_gui()
    if aegisub.gui and aegisub.gui.get_selection then return true end
    message("Inserting markers needs arch1t3cht's Aegisub (aegisub.gui is missing).")
    return false
end

-- before / selected / after, from the edit box selection (byte positions)
local function parts(text)
    local ss, se = aegisub.gui.get_selection()
    ss, se = math.min(ss, #text + 1), math.min(se, #text + 1)
    ss, se = snap(text, ss, se)
    return text:sub(1, ss - 1), text:sub(ss, se - 1), text:sub(se)
end

-- the ops below get the selected text and return (replacement, cursor offset inside it), or nil to bail

local function enable(s)
    local h = s:match(DIS_SEL)
    if h then
        s = reveal(h)
    elseif s:match(EN_SEL) then
        return s, #s
    end
    if s == "" then
        -- cursor between the markers so you can type
        return "{" .. MARKER .. "}{" .. MARKER .. "}", #MARKER + 2
    end
    if not roundtrip_ok({s}) then return nil end
    local mid = "{" .. MARKER .. "}" .. s .. "{" .. MARKER .. "}"
    return mid, #mid
end

local function disable(s)
    local e = s:match(EN_SEL)
    if e then
        s = e
    elseif s:match(DIS_SEL) then
        return s, #s
    end
    if s == "" then
        -- cursor right before the } so you can type the hidden bit
        local mid = "{" .. MARKER .. MARKER .. "}"
        return mid, #mid - 1
    end
    local hidden = hide(s)
    if hidden == "" then
        message("There's nothing left to hide once the braces are stripped.")
        return nil
    end
    if not roundtrip_ok({s}) then return nil end
    local mid = "{" .. MARKER .. MARKER .. hidden .. "}"
    return mid, #mid
end

local B_HINT = TAG_MARKERS and "Type it like normal line text, tags and all, e.g. {\\b1}Mary-tan{\\b0}"
    or "TAG_MARKERS is off, so any {} in here gets stripped"

local function ask_b(a, prefill)
    local shown = a == "" and "(nothing, the text just gets inserted)" or a
    local btn, res = aegisub.dialog.display({
        {class="label", label="What should show here instead after swapping?", x=0, y=0, width=2},
        {class="label", label="Now:", x=0, y=1},
        {class="label", label=amp(clip(shown)), x=1, y=1},
        {class="label", label="After swap:", x=0, y=2},
        {class="edit", name="b", value=prefill, x=1, y=2, hint=B_HINT},
    }, {"OK", "Cancel"}, {ok="OK", cancel="Cancel"})
    return btn and res.b
end

local function ab(s)
    local a, b = s:match(AB_SEL)
    if a then
        -- already an AB, just edit the B side
        b = ask_b(a, reveal(b))
    else
        -- normal text right before a {**hidden} bit, just move the marker to the front
        local n, h = s:match(CONV_SEL)
        if n then
            local mid = "{" .. MARKER .. "}" .. n .. "{" .. MARKER .. h .. "}"
            return mid, #mid
        end
        a = s:match(EN_SEL) or s
        b = ask_b(a, a)
    end
    if not b then return nil end
    local hidden = hide(b)
    if hidden == "" then
        message("The swapped in text can't be empty. Use Disable if you just want to hide it.")
        return nil
    end
    if not roundtrip_ok({a, b}) then return nil end
    local mid = "{" .. MARKER .. "}" .. a .. "{" .. MARKER .. hidden .. "}"
    return mid, #mid
end

local function on_active(op)
    return function(subs, sel, act)
        if not need_gui() then return end
        load_settings()
        local line = subs[act]
        local beg, s, den = parts(line.text)
        local mid, cur = op(s)
        if not mid then return end
        line.text = beg .. mid .. den
        subs[act] = line
        aegisub.gui.set_cursor(#beg + cur + 1)
    end
end

-- only swaps the constructs the edit box selection touches
local function swap_selected_text(subs, act, ss, se)
    local line = subs[act]
    local text = line.text
    local hits = {}
    for _, c in ipairs(find_constructs(text)) do
        if c.s < se and c.e >= ss then hits[#hits + 1] = c end
    end
    if #hits == 0 then
        message("The selected text isn't part of any swap markers.")
        return
    end
    -- right to left so the earlier positions stay valid
    local first, last = hits[1].s, hits[#hits].e
    for k = #hits, 1, -1 do
        local c = hits[k]
        text = text:sub(1, c.s - 1) .. c.new .. text:sub(c.e + 1)
        last = last + #c.new - (c.e - c.s + 1)
    end
    line.text = text
    subs[act] = line
    -- keep the swapped bit selected so running it again swaps it back
    if aegisub.gui.set_selection then
        aegisub.gui.set_selection(first, last + 1)
    else
        aegisub.gui.set_cursor(last + 1)
    end
end

-- you picked the lines yourself, so no style filter here
local function swap_selected(subs, sel)
    load_settings()
    for _, i in ipairs(sel) do
        local new, changed = swap_line(subs[i])
        if changed then subs[i] = new end
    end
end

-- only the selected text, falls back to the selected lines if nothing's selected
local function swap_text_or_lines(subs, sel, act)
    if aegisub.gui and aegisub.gui.get_selection then
        local ss, se = aegisub.gui.get_selection()
        if se > ss then
            load_settings()
            return swap_selected_text(subs, act, ss, se)
        end
    end
    swap_selected(subs, sel)
end

local do_enable = on_active(enable)
local do_disable = on_active(disable)
local do_ab = on_active(ab)

-- adds the line marker to all selected lines, or takes it off if they all have it already
local function toggle_lines(subs, sel)
    load_settings()
    local all_have = true
    for _, i in ipairs(sel) do
        if not has_line_marker(subs[i]) then all_have = false end
    end
    local skipped = 0
    for _, i in ipairs(sel) do
        local line = subs[i]
        if all_have then
            if trim(line.effect) == LINE_MARKER then line.effect = "" end
            if trim(line.actor) == LINE_MARKER then line.actor = "" end
        elseif not has_line_marker(line) then
            -- effect first, actor if effect is taken, never overwrite anything
            if trim(line.effect) == "" then
                line.effect = LINE_MARKER
            elseif trim(line.actor) == "" then
                line.actor = LINE_MARKER
            else
                skipped = skipped + 1
            end
        end
        subs[i] = line
    end
    if skipped > 0 then
        message(skipped .. " line(s) skipped, both effect and actor were already filled in.")
    end
end

local function menu_info(subs, sel, act)
    local info = #sel .. " line(s) selected"
    if aegisub.gui and aegisub.gui.get_selection then
        local ss, se = aegisub.gui.get_selection()
        local s = subs[act].text:sub(ss, se - 1)
        info = info .. "\nText: " .. (s == "" and "(none)" or clip(s))
    end
    return {{class="label", label=amp(info), x=0, y=0}}
end

local function quick_swap(subs, sel, act)
    local btn = aegisub.dialog.display(menu_info(subs, sel, act),
        {"Entire Scrip&t", "Selected &Lines", "Selected Te&xt", "Cancel"}, {cancel="Cancel"})
    if btn == "Entire Scrip&t" then swap_script(subs)
    elseif btn == "Selected &Lines" then swap_selected(subs, sel)
    elseif btn == "Selected Te&xt" then swap_text_or_lines(subs, sel, act)
    end
end

local function quick_insert(subs, sel, act)
    local btn = aegisub.dialog.display(menu_info(subs, sel, act),
        {"&Enable", "&Disable", "&AB Swap", "Entire &Line", "Cancel"}, {cancel="Cancel"})
    if btn == "&Enable" then do_enable(subs, sel, act)
    elseif btn == "&Disable" then do_disable(subs, sel, act)
    elseif btn == "&AB Swap" then do_ab(subs, sel, act)
    elseif btn == "Entire &Line" then toggle_lines(subs, sel)
    end
end

local macros = {
    {"Apply Swap/Entire Script", "Run the autoswapper on the whole script (style filter applies)", swap_script},
    {"Apply Swap/Selected Lines", "Run the autoswapper on the selected lines", swap_selected},
    {"Apply Swap/Selected Text", "Swap only the selected text, or the selected lines if no text is selected", swap_text_or_lines},
    {"Insert Markers/Enable", "Shown now, hidden after swapping", do_enable},
    {"Insert Markers/Disable", "Hidden now, shown after swapping", do_disable},
    {"Insert Markers/AB Swap", "Swap the selection for different text", do_ab},
    {"Insert Markers/Entire Line", "Toggle the line marker on the selected lines", toggle_lines},
    {"Quick Menu/Apply Swap", "Pick a swap action from a dialog", quick_swap},
    {"Quick Menu/Insert Markers", "Pick a marker to insert from a dialog", quick_insert},
    {"Setup Config", "Styles and markers to use", function() show_config() end},
}

if haveDepCtrl then
    depctrl:registerMacros(macros)
else
    for _, m in ipairs(macros) do
        aegisub.register_macro(script_name .. "/" .. m[1], m[2], m[3])
    end
end
