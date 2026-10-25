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

export script_name = "PlainerText"
export script_author = "McBaws"
export script_description = "Clean up and export script as plaintext"
export script_version = "1.1.0"
export script_namespace = "baws.PlainerText"

havedc, DependencyControl = pcall require, "l0.DependencyControl"
local dep
if havedc
    dep = DependencyControl{
        feed: "https://raw.githubusercontent.com/McBaws/Aegisub-Scripts/stable/DependencyControl.json",
    }

clipboard = require 'aegisub.clipboard'
re = require 'aegisub.re'

-- Define the configuration dialog layout and defaults
config_diag = {
    main: {
        stripTags:               {class: 'checkbox', label: 'Strip tags', name: 'stripTags', value: true, config: true, x: 0, y: 0}
        removeEmptyLines:        {class: 'checkbox', label: 'Remove empty lines', name: 'removeEmptyLines', value: true, config: true, x: 0, y: 1}
        removeComments:          {class: 'checkbox', label: 'Remove comments', name: 'removeComments', value: true, config: true, x: 0, y: 2}
        removeNewlines:          {class: 'checkbox', label: 'Remove newlines', name: 'removeNewlines', value: true, config: true, x: 0, y: 3}
        normalizeWhitespace:     {class: 'checkbox', label: 'Normalize whitespace', name: 'normalizeWhitespace', value: true, config: true, x: 1, y: 0}
        normalizeCharacters:     {class: 'checkbox', label: 'Normalize characters', name: 'normalizeCharacters', value: true, config: true, x: 1, y: 1}
        removePosLines:          {class: 'checkbox', label: 'Remove \\pos lines', name: 'removePosLines', value: true, config: true, x: 1, y: 2}
        removeDrawLines:         {class: 'checkbox', label: 'Remove drawing lines', name: 'removeDrawLines', value: true, config: true, x: 1, y: 3}
        mergeDuplicateLines:     {class: 'checkbox', label: 'Merge duplicate lines', name: 'mergeDuplicateLines', value: true, config: true, x: 2, y: 0}
        mergeAlphaTiming:        {class: 'checkbox', label: 'Merge alpha timing', name: 'mergeAlphaTiming', value: true, config: true, x: 2, y: 1}
        removePunctSymbols:      {class: 'checkbox', label: 'Remove punctuation and symbols', name: 'removePunctSymbols', value: false, config: true, x: 2, y: 2}
        removeHonorifics:        {class: 'checkbox', label: 'Remove honorifics', name: 'removeHonorifics', value: false, config: true, x: 2, y: 3}
        clipboardConfirm:        {class: 'checkbox', label: "Display confirmation window when copying to clipboard", name: 'clipboardConfirm', value: true, config: true, x: 0, y: 5, width: 3}
		showOutputWindow:        {class: 'checkbox', label: "Always show output window and don't copy to clipboard", name: 'showOutputWindow', value: false, config: true, x: 0, y: 6, width: 3}
    }
}

-- defaults come straight from the dialog, grabbed before anything changes its values
DEFAULTS = {k, v.value for k, v in pairs config_diag.main when v.config}

-- settings only keep what differs from the defaults, so changing a default later still reaches people
-- without depctrl they just live in here until aegisub closes
local config
session = {}

store_settings = (store) ->
    unless config
        session = store
        return true
    -- depctrl 0.6 only ever adds keys when it writes, so clear the section first or old values stick around
    ok, err = config\delete!
    return ok, err unless ok
    return true if next(store) == nil
    config.c[k] = v for k, v in pairs store
    config\write!

if havedc
    config = dep\getConfigHandler DEFAULTS, "settings"

    -- a-mo saved to <depctrl configDir>/<configFile>. newer depctrl doesn't expose configDir on the
    -- script's record, so there a-mo fell back to ?user, older depctrl gives ?user/config. check them all
    find_old_config = ->
        okjson, json = pcall require, "json"
        json = require "l0.dkjson" unless okjson
        name = dep.configFile or "#{script_namespace}.json"
        seen = {}
        for dir in *{dep.configDir or "?user", "?user", "?user/config"}
            path = aegisub.decode_path "#{dir}/#{name}"
            f = not seen[path] and io.open path, "r"
            seen[path] = true
            if f
                text = f\read "*a"
                f\close!
                ok, old = pcall json.decode, text
                return path, old if ok and type(old) == "table" and old.__version != nil
        return

    -- one time move from the old a-mo file, which looks like {"main": {...}, "__version": ...}
    -- anything already saved with the new handler wins, the old values only fill in the rest
    path, old = find_old_config!
    if path
        main = type(old.main) == "table" and old.main or {}
        saved = config.userConfig or {}
        store = {}
        for k, v in pairs DEFAULTS
            if saved[k] != nil
                store[k] = saved[k]
            elseif main[k] != nil and main[k] != v
                store[k] = main[k]
        os.remove path
        store_settings store

get_configuration = ->
    opts = {}
    for k, v in pairs DEFAULTS
        opts[k] = if config
            config.c[k]
        elseif session[k] != nil
            session[k]
        else
            v
    opts

-- new values go over the current ones, anything the script doesn't know about is ignored
save_configuration = (new) ->
    store = {}
    for k, v in pairs get_configuration!
        v = new[k] if new[k] != nil
        store[k] = v if v != DEFAULTS[k]
    ok, err = store_settings store
    aegisub.log 2, "Couldn't save the settings: #{err}\n" unless ok
    ok

-- puts the current settings into the dialog before it's shown
fill_dialog = ->
    config_diag.main[k].value = v for k, v in pairs get_configuration!
    return

show_config_dialog = ->
    fill_dialog!
    button, result = aegisub.dialog.display config_diag.main
    save_configuration result if button

trim = (s) ->
    return "" unless s
    s = s\gsub("^%s+", "")
    s = s\gsub("%s+$", "")
    s

get_text = (line, out, opts) ->
    return unless line.class == 'dialogue'
    return if opts.removeComments and line.comment

    if opts.removePosLines and re.match(line.text, "\\{[^\\}]*\\\\pos")
        return

    if opts.removeDrawLines and re.match(line.text, "\\{[^\\}]*\\\\p[0-9 .-\\\\}]")
        return

    new = line.text

    if opts.stripTags
        new, _ = re.sub new, "\\{[^\\}]*\\\\p(?:0+[1-9]|[1-9]{1}\\d{0,3})[^\\}]*\\}.*?\\{[^\\}]*\\\\p0.*?(?<!\\\\p1)\\}|\\{[^\\}]*\\\\p(?:0+[1-9]|[1-9]{1}\\d{0,3}).*$", "" -- drawings
        new, _ = re.sub new, "\\{[^\\}]*\\}", "" ------ override tags
        
    if opts.removeNewlines
        new, _ = re.sub new, "\\\\h", " " ------------- \h -> space
        new, _ = re.sub new, "\\s?\\\\n\\s?", " " ----- inline \n
        new, _ = re.sub new, "\\s?\\\\N\\s?", "\r\n" -- block \N

    if opts.normalizeCharacters
        new, _ = re.sub new, "[‘’]", "'"
        new, _ = re.sub new, "[“”]", "\""
        new, _ = re.sub new, "…", "..."

    if opts.removeHonorifics
        honorifics = "\\b-(?:san|sama|kun|chan|tan|senpai|sensei|kohai|hakase|neechan|oneesan|oneesama|oneechan|oniichan|oniisan|obasan|oobasan|neesan|aneki|aniki|zeki|han|niichan|dono|ojosama|niisan|oniisama|ojisan|nee|nii)\\b"
        new, _ = re.sub new, honorifics, "", re.ICASE

    if opts.removePunctSymbols
        new, _ = re.sub new, "[.,/#!$%\\^&\\*;:{}=_`~()…–—?-]", ""

    if opts.normalizeWhitespace
        new, _ = re.sub new, "\u{00A0}", " "
        new, _ = re.sub new, "\\s+", " "
        new = trim new

    if opts.removeEmptyLines
        tmp, _ = re.sub new, "\u{00A0}", " "
        if trim(tmp) == "" then return

    -- merging duplicates and alpha timing
    prev = out[#out]
    if prev == new
        return if opts.mergeDuplicateLines
    else if opts.mergeAlphaTiming and prev and new\sub(1, #prev) == prev
        out[#out] = new
        return

    table.insert(out, new)

main = (subs, sel) ->
    text = {}
    opts = get_configuration!
    
    if sel
        for z, i in ipairs(sel) do
            line = subs[i]
            get_text(line, text, opts)
    else
        for line in *subs
            get_text(line, text, opts)
    
    plain = table.concat(text, "\n")
    
    aegisub.log(5, plain)
    
	if opts.showOutputWindow
		aegisub.dialog.display({{class:'textbox', x:0, y:0, width:50, height:40, text: plain}},{close:'Close'})
    else
		copied = clipboard.set(plain)
		if copied
        	aegisub.dialog.display({{class:'label', label: "Script was converted to plaintext and copied to clipboard."}},{"OK"}) if opts.clipboardConfirm
    	else
        	aegisub.dialog.display({{class:'label', x:0, y:0, label: "Failed to copy to clipboard, manual copy required."},{class:'textbox', x:0, y:2, width:50, height:40, text: plain}},{close:'Close'})

all_lines = (subs) ->
    main(subs, nil)
    
sel_lines = (subs, sel) ->
    main(subs, sel)

macros = {
    {"Entire Script", "Export entire script as plaintext", all_lines},
    {"Selected Lines", "Export selected lines as plaintext", sel_lines},
    {"Setup Config", "Open configuration menu", show_config_dialog}
}

if havedc
    dep\registerMacros macros
else
    for macro in *macros
        name, desc, fun, cond = unpack macro
        aegisub.register_macro script_name..'/'..name, desc, fun, cond
