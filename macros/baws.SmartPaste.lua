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

script_name = "SmartPaste"
script_description = "Paste plain text over lines without losing their tags"
script_author = "McBaws"
script_namespace = "baws.SmartPaste"
script_version = "1.1.0"

local clipboard = require("aegisub.clipboard")

local havedc, DependencyControl = pcall(require, "l0.DependencyControl")
local dep
if havedc then
    dep = DependencyControl{
        feed = "https://raw.githubusercontent.com/McBaws/Aegisub-Scripts/stable/DependencyControl.json",
    }
end

-- text gets handled as a list of "chars": one utf-8 char each, except \N \n \h which count as one

local BREAKS = {["\\N"] = true, ["\\n"] = true}
-- anything that separates words
local SPACES = {[" "] = true, ["\t"] = true, ["\\N"] = true, ["\\n"] = true, ["\\h"] = true,
    ["\194\160"] = true, ["\227\128\128"] = true}
-- spaces that get eaten around a line break that's put back in
local PLAIN_SPACES = {[" "] = true, ["\t"] = true}

local PUNCT = {}
for c in ("“ ” ‘ ’ … — – 「 」 『 』 、 。 ！ ？ ， ： ； （ ） « » ・ ～ ♪"):gmatch("%S+") do PUNCT[c] = true end

-- what a word can end on, closing quotes and brackets are skipped first
local CLOSERS = {}
for c in ([[" ' ) ] ” ’ 」 』 ） »]]):gmatch("%S+") do CLOSERS[c] = true end
local SENTENCE = {}
for c in (". ! ? … 。 ！ ？"):gmatch("%S+") do SENTENCE[c] = true end
local CLAUSE = {}
for c in (", ; : — – - 、 ， ： ；"):gmatch("%S+") do CLAUSE[c] = true end
local ANY_BREAK = {}
for c in pairs(SENTENCE) do ANY_BREAK[c] = true end
for c in pairs(CLAUSE) do ANY_BREAK[c] = true end

local function trim(s) return (s:match("^%s*(.-)%s*$")) end

local function message(text)
    aegisub.dialog.display({{class="label", label=(text:gsub("&", "&&")), x=0, y=0}}, {"OK"})
end

local function chars(s)
    local out, i = {}, 1
    while i <= #s do
        local c = s:match("^\\[Nnh]", i) or s:match("^[%z\1-\127\192-\255][\128-\191]*", i) or s:sub(i, i)
        out[#out + 1] = c
        i = i + #c
    end
    return out
end

local function is_punct(c)
    if #c == 1 then return c:match("%p") ~= nil end
    return PUNCT[c] or false
end

-- cjk text has no spaces, so each char there is a word of its own
local function is_cjk(c)
    local b = c:byte(1)
    return #c == 3 and b >= 227 and b <= 237 and not SPACES[c]
end

-- splits the original line into its plain text and the tags sitting in it
-- tags with no text between them become one group, at = how many chars of text come before it
-- if keep_breaks is off, \N is pulled out like a tag and leaves a space in the text so the words
-- around it stay apart
local function parse(text, keep_breaks)
    local plain, groups, open = {}, {}, nil
    local function add(s)
        if not open then
            open = {s = "", at = #plain}
            groups[#groups + 1] = open
        end
        open.s = open.s .. s
    end
    local i = 1
    while i <= #text do
        local e = text:sub(i, i) == "{" and text:find("}", i, true)
        if e then
            add(text:sub(i, e))
            i = e + 1
        else
            local c = chars(text:sub(i, i + 3))[1]
            if BREAKS[c] and not keep_breaks then
                if not (open and open.brk) then plain[#plain + 1] = " " end
                add(c)
                open.brk = true
            else
                plain[#plain + 1] = c
                open = nil
            end
            i = i + #c
        end
    end
    return plain, groups
end

-- words with their position in the text, s = chars before it, e = chars up to its end
local function tokenize(text)
    local toks, start = {}, nil
    local function push(s, e)
        local ch, key, lead, trail = {}, {}, 0, 0
        for k = s + 1, e do ch[#ch + 1] = text[k] end
        while lead < #ch and is_punct(ch[lead + 1]) do lead = lead + 1 end
        while trail < #ch - lead and is_punct(ch[#ch - trail]) do trail = trail + 1 end
        for _, c in ipairs(ch) do
            if not is_punct(c) then key[#key + 1] = c:lower() end
        end
        local raw = table.concat(ch)
        key = table.concat(key)
        toks[#toks + 1] = {s = s, e = e, ch = ch, raw = raw, key = key ~= "" and key or raw, lead = lead, trail = trail}
    end
    for k, c in ipairs(text) do
        if SPACES[c] or is_cjk(c) then
            if start then push(start, k - 1) end
            start = nil
            if not SPACES[c] then push(k - 1, k) end
        elseif not start then
            start = k - 1
        end
    end
    if start then push(start, #text) end
    return toks
end

local function score(a, b)
    if a.raw == b.raw then return 3 end
    if a.key == b.key then return 2 end
    return 0
end

-- lines up the words of both texts. seg[i] says which stretch between tags word i is in
-- goes for, in order: the most matched words, the most stretches that keep at least one word (so a
-- tagged word doesn't lose its tags to a copy of itself elsewhere), then the most exact matches
-- returns the matched pairs, with a pair before the start and one after the end
local function align(A, B, seg)
    local n, m = #A, #B
    local EXACT, COVER = 1, n + 1
    local MATCH = COVER * (n + 1)

    -- c = whether word i's stretch already has a match from an earlier word, this gives it for word i + 1
    local function nextc(i, c)
        if i < n and seg[i + 1] ~= seg[i] then return 0 end
        return c
    end
    local function gain(i, j, c)
        local w = score(A[i], B[j])
        if w == 0 then return nil end
        return MATCH + (w == 3 and EXACT or 0) + (c == 0 and COVER or 0)
    end

    local D = {[0] = {}, [1] = {}}
    for c = 0, 1 do
        for i = 1, n + 1 do
            D[c][i] = {}
            for j = 1, m + 1 do D[c][i][j] = 0 end
        end
    end
    for i = n, 1, -1 do
        for j = m, 1, -1 do
            for c = 0, 1 do
                local best = math.max(D[nextc(i, c)][i + 1][j], D[c][i][j + 1])
                local g = gain(i, j, c)
                if g then best = math.max(best, D[nextc(i, 1)][i + 1][j + 1] + g) end
                D[c][i][j] = best
            end
        end
    end

    local pairs_, match = {{0, 0}}, {}
    local i, j, c = 1, 1, 0
    while i <= n and j <= m do
        local g = gain(i, j, c)
        if g and D[c][i][j] == D[nextc(i, 1)][i + 1][j + 1] + g then
            pairs_[#pairs_ + 1] = {i, j}
            match[i] = j
            c = nextc(i, 1)
            i, j = i + 1, j + 1
        elseif D[c][i][j] == D[nextc(i, c)][i + 1][j] then
            c = nextc(i, c)
            i = i + 1
        else
            j = j + 1
        end
    end
    pairs_[#pairs_ + 1] = {n + 1, m + 1}
    return pairs_, match
end

local function ends_with(tok, set)
    local k = #tok.ch
    while k > 1 and CLOSERS[tok.ch[k]] do k = k - 1 end
    return set[tok.ch[k]] or false
end

-- the unmatched stretch around a boundary (b = words before it). oa..ob are the boundaries of the
-- original's stretch, pa..pb the pasted one's
local function gap(pairs_, b)
    local l, r
    for _, p in ipairs(pairs_) do
        if p[1] <= b then l = p end
        if not r and p[1] >= b + 1 then r = p end
    end
    return l[1], r[1] - 1, l[2], r[2] - 1
end

-- where a boundary between words of the original lands in the pasted text, as words before it
local function map_boundary(b, attach, OT, PT, pairs_)
    local oa, ob, pa, pb = gap(pairs_, b)
    local no, np = ob - oa, pb - pa
    -- nothing removed here: stick to whichever word the tag was touching
    if no == 0 then return attach == "back" and pa or pb end
    if b == oa then return pa end
    if b == ob then return pb end
    -- same number of words swapped out, go word for word
    if no == np then return pa + (b - oa) end
    if np == 0 then return pa end
    -- after a sentence or clause end, go to the matching one in the new text if they line up
    for _, set in ipairs({SENTENCE, CLAUSE, ANY_BREAK}) do
        if ends_with(OT[b], set) then
            local ox, py = {}, {}
            for x = oa + 1, ob - 1 do
                if ends_with(OT[x], set) then ox[#ox + 1] = x end
            end
            for y = pa + 1, pb - 1 do
                if ends_with(PT[y], set) then py[#py + 1] = y end
            end
            if #ox == #py then
                for r, x in ipairs(ox) do
                    if x == b then return py[r] end
                end
            end
        end
    end
    local j = pa + math.floor((b - oa) * np / no + 0.5)
    return math.max(pa, math.min(pb, j))
end

-- a tag inside a word, rel = chars into the word. keeps it next to leading/trailing punctuation
local function within(ot, rel, pt)
    local on, pn = #ot.ch, #pt.ch
    if ot.raw == pt.raw then return rel end
    if ot.lead + ot.trail >= on or pt.lead + pt.trail >= pn then
        return math.floor(rel * pn / on + 0.5)
    end
    if rel <= ot.lead then return math.min(rel, pt.lead) end
    if rel >= on - ot.trail then return pn - math.min(on - rel, pt.trail) end
    local oc, pc = on - ot.lead - ot.trail, pn - pt.lead - pt.trail
    local x = pt.lead + math.floor((rel - ot.lead) * pc / oc + 0.5)
    return math.max(pt.lead, math.min(pn - pt.trail, x))
end

local function boundary_offset(j, attach, PT, plen)
    if attach == "back" then return j > 0 and PT[j].e or 0 end
    return j < #PT and PT[j + 1].s or plen
end

-- where in the pasted text (chars before it) a tag group goes
local function place(g, plain, OT, PT, pairs_, match, plen)
    local k = g.at
    if k == 0 then return 0 end
    if k >= #plain then return plen end

    for t, tok in ipairs(OT) do
        if tok.s < k and k < tok.e then
            local rel = k - tok.s
            local v = match[t]
            if not v then
                local oa, ob, pa, pb = gap(pairs_, t - 1)
                if ob - oa == pb - pa then v = pa + (t - oa) end
            end
            if v then return PT[v].s + within(tok, rel, PT[v]) end
            -- word got replaced by a different number of words, go to whichever end is closer
            if rel * 2 <= #tok.ch then
                return boundary_offset(map_boundary(t - 1, "fwd", OT, PT, pairs_), "fwd", PT, plen)
            end
            return boundary_offset(map_boundary(t, "back", OT, PT, pairs_), "back", PT, plen)
        end
    end

    local b = 0
    for t, tok in ipairs(OT) do
        if tok.e <= k then b = t end
    end
    -- a tag right before a word belongs to it, same for one right after a word
    local attach = "fwd"
    if g.brk then
        attach = "back"
    elseif SPACES[plain[k + 1]] and not SPACES[plain[k]] then
        attach = "back"
    end
    return boundary_offset(map_boundary(b, attach, OT, PT, pairs_), attach, PT, plen)
end

local function assemble(text, groups, offsets)
    local out, gi, skip = {}, 1, false
    for k = 0, #text do
        while gi <= #groups and offsets[gi] == k do
            local g = groups[gi]
            if g.brk then
                -- the break replaces the space it's sitting on
                while #out > 0 and out[#out].space do table.remove(out) end
                skip = true
            end
            out[#out + 1] = {s = g.s}
            gi = gi + 1
        end
        local c = text[k + 1]
        if c and not (skip and PLAIN_SPACES[c]) then
            skip = false
            out[#out + 1] = {s = c, space = PLAIN_SPACES[c]}
        end
    end
    local s = {}
    for i, o in ipairs(out) do s[i] = o.s end
    return table.concat(s)
end

-- tag names, longest first so \fscx isn't read as \fs. some are the same thing under another name
local TAG_NAMES = {}
for n in ([[xbord ybord xshad yshad iclip alpha blur bord clip fade fscx fscy move shad fad fax fay fsp
    frx fry frz pbo pos 1c 2c 3c 4c 1a 2a 3a 4a an be fn fs fe fr a b c i u s q p]]):gmatch("%S+") do
    TAG_NAMES[#TAG_NAMES + 1] = n
end
table.sort(TAG_NAMES, function(x, y) return #x > #y end)
local TAG_ALIAS = {c = "1c", fr = "frz", a = "an", fade = "fad", move = "pos", iclip = "clip"}

-- nil for tags that can show up more than once (\t, karaoke, \r) or that aren't known
local function tag_name(tag)
    local body = tag:sub(2)
    for _, n in ipairs(TAG_NAMES) do
        if body:sub(1, #n) == n then return TAG_ALIAS[n] or n end
    end
end

-- {\fad(0,200)\i1} -> {"\fad(0,200)", "\i1"}, and whatever's before the first \
local function split_tags(inner)
    local first = inner:find("\\", 1, true)
    if not first then return {}, inner end
    local tags, depth, start = {}, 0, first
    for k = first + 1, #inner do
        local c = inner:sub(k, k)
        if c == "(" then
            depth = depth + 1
        elseif c == ")" then
            depth = math.max(0, depth - 1)
        elseif c == "\\" and depth == 0 then
            tags[#tags + 1] = inner:sub(start, k - 1)
            start = k
        end
    end
    tags[#tags + 1] = inner:sub(start)
    return tags, inner:sub(1, first - 1)
end

-- anything in {} that doesn't start with \ is a comment
local function is_tag_block(b) return b:match("^{%s*\\") ~= nil end

-- splits the {} blocks off the front of a line
local function leading_blocks(s)
    local blocks = {}
    while true do
        local b, rest = s:match("^({[^}]*})(.*)$")
        if not b then return blocks, s end
        blocks[#blocks + 1] = b
        s = rest
    end
end

-- puts tags pasted at the start of a line into the line's own first tag block. the pasted ones win
-- over the same tag already there, comments stay in their own blocks after the line's own
local function merge_leading(line, ptags, pcomments)
    local blocks, rest = leading_blocks(line)
    local names = {}
    for _, t in ipairs(ptags) do
        local n = tag_name(t)
        if n then names[n] = true end
    end
    local out, merged = {}, #ptags == 0
    for _, b in ipairs(blocks) do
        if is_tag_block(b) then
            local tags, pre = split_tags(b:sub(2, -2))
            local keep = {}
            for _, t in ipairs(tags) do
                local n = tag_name(t)
                if not (n and names[n]) then keep[#keep + 1] = t end
            end
            if not merged then
                for _, t in ipairs(ptags) do keep[#keep + 1] = t end
                merged = true
            end
            if #keep > 0 or trim(pre) ~= "" then out[#out + 1] = "{" .. pre .. table.concat(keep) .. "}" end
        else
            out[#out + 1] = b
        end
    end
    if not merged then table.insert(out, 1, "{" .. table.concat(ptags) .. "}") end
    for _, c in ipairs(pcomments) do out[#out + 1] = c end
    return table.concat(out) .. rest
end

local function paste_plain(orig, new, by_char)
    local text = chars(new)
    local has_breaks = false
    for _, c in ipairs(text) do
        if BREAKS[c] then has_breaks = true end
    end
    local plain, groups = parse(orig, has_breaks)
    if #groups == 0 then return new end

    local offsets = {}
    if by_char then
        for i, g in ipairs(groups) do
            offsets[i] = g.at >= #plain and #text or math.min(g.at, #text)
        end
    else
        local OT, PT = tokenize(plain), tokenize(text)
        -- which stretch between tags each word starts in, line breaks don't count
        local seg = {}
        for t, tok in ipairs(OT) do
            seg[t] = 0
            for _, g in ipairs(groups) do
                if g.at <= tok.s and g.s:find("{", 1, true) then seg[t] = seg[t] + 1 end
            end
        end
        local pairs_, match = align(OT, PT, seg)
        for i, g in ipairs(groups) do
            offsets[i] = place(g, plain, OT, PT, pairs_, match, #text)
        end
    end
    -- tags never swap order
    for i = 1, #offsets do
        offsets[i] = math.max(0, math.min(#text, offsets[i]))
        if i > 1 and offsets[i] < offsets[i - 1] then offsets[i] = offsets[i - 1] end
    end
    return assemble(text, groups, offsets)
end

-- Dialogue: 0,0:12:11.00,0:12:14.21,Default,,0,0,0,,text
-- layer, start, end, style, name, margin l/r/v, effect, then the text. none of the fields before the
-- text can have commas in them, so the text is everything after the 9th one (commas and all)
local TIME = "%s*%d+:%d+:%d+[%.:]%d+%s*"
local MARGIN = "%s*%-?%d+%s*"
local EVENT = "^%s*(%a+):%s*[^,]*," .. TIME .. "," .. TIME .. ",[^,]*,[^,]*,"
    .. MARGIN .. "," .. MARGIN .. "," .. MARGIN .. ",[^,]*,(.*)$"

-- if a whole event line got copied (like copying rows in aegisub), just take its text
local function event_text(s)
    local kind, text = s:match(EVENT)
    if kind == "Dialogue" or kind == "Comment" then return text end
    return s
end

local function paste(orig, new, by_char)
    new = trim(event_text(new))
    local blocks, rest = leading_blocks(new)
    -- tags past the start mean it's already been typeset, so whatever's pasted is what you want
    if rest:find("{[^}]*}") then return new end
    local result = paste_plain(orig, trim(rest), by_char)
    if #blocks == 0 then return result end

    local ptags, pcomments = {}, {}
    for _, b in ipairs(blocks) do
        if is_tag_block(b) then
            for _, t in ipairs((split_tags(b:sub(2, -2)))) do ptags[#ptags + 1] = t end
        else
            pcomments[#pcomments + 1] = b
        end
    end
    return merge_leading(result, ptags, pcomments)
end

local function clipboard_lines()
    local s = clipboard.get()
    if not s then return {} end
    s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
    local out = {}
    for l in (s .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = l end
    while #out > 0 and trim(out[#out]) == "" do table.remove(out) end
    while #out > 0 and trim(out[1]) == "" do table.remove(out, 1) end
    return out
end

local function confirm(text)
    local btn = aegisub.dialog.display({{class="label", label=text, x=0, y=0}},
        {"Paste", "Cancel"}, {ok="Paste", cancel="Cancel"})
    return btn == "Paste"
end

local function run(subs, sel, by_char)
    local texts = clipboard_lines()
    if #texts == 0 then
        message("The clipboard is empty.")
        return
    end

    -- one line goes on every selected line, several go one per line
    local targets = {}
    if #texts == 1 then
        targets = sel
    elseif #sel == 1 then
        -- just one line selected: fill it and the lines after it
        local i = sel[1]
        while #targets < #texts and i <= #subs do
            if subs[i].class == "dialogue" then targets[#targets + 1] = i end
            i = i + 1
        end
        if #targets < #texts and not confirm(("The clipboard has %d lines, but there are only %d lines left."
            .. "\nPaste the first %d?"):format(#texts, #targets, #targets)) then return end
    else
        for k = 1, math.min(#sel, #texts) do targets[k] = sel[k] end
        if #sel ~= #texts and not confirm(("The clipboard has %d lines, but %d lines are selected."
            .. "\nPaste the first %d?"):format(#texts, #sel, #targets)) then return end
    end

    for k, i in ipairs(targets) do
        local line = subs[i]
        if line.class == "dialogue" then
            line.text = paste(line.text, texts[#texts == 1 and 1 or k], by_char)
            subs[i] = line
        end
    end
    aegisub.set_undo_point(script_name)
    if #texts > 1 and #targets > 0 then return targets, targets[1] end
end

local macros = {
    {"Paste", "Paste the clipboard over the selected lines, keeping their tags where they fit",
        function(subs, sel) return run(subs, sel, false) end},
    {"Paste by Character", "Paste the clipboard over the selected lines, keeping tags at the same character position",
        function(subs, sel) return run(subs, sel, true) end},
}

if havedc then
    dep:registerMacros(macros)
else
    for _, m in ipairs(macros) do
        aegisub.register_macro(script_name .. "/" .. m[1], m[2], m[3])
    end
end
