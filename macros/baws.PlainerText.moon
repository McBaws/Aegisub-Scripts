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
export script_version = "1.0.0"
export script_namespace = "baws.PlainerText"

havedc, DependencyControl = pcall require, "l0.DependencyControl"
local dep, ConfigHandler, config
if havedc
    dep = DependencyControl{
        feed: "https://raw.githubusercontent.com/McBaws/Aegisub-Scripts/stable/DependencyControl.json",
        {
            {"a-mo.ConfigHandler", version: "1.1.4", url: "https://github.com/TypesettingTools/Aegisub-Motion",
             feed: "https://raw.githubusercontent.com/TypesettingTools/Aegisub-Motion/DepCtrl/DependencyControl.json"}
        }
    }
    ConfigHandler = dep\requireModules!

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

if havedc
    config = ConfigHandler config_diag, dep.configFile, false, script_version, dep.configDir

get_configuration = ->
    if havedc
        config\read!
        config\updateInterface "main"
    
    opts = {}
    for key, values in pairs config_diag.main
        if values.config
            opts[key] = values.value
    opts

show_config_dialog = ->
    if havedc
        config\read!
        config\updateInterface "main"
        button, result = aegisub.dialog.display config_diag.main
        if button
            config\updateConfiguration result, 'main'
            config\write!
            config\updateInterface 'main'
    else
        -- Fallback if no DependencyControl: show dialog and keep stored while program running
        button, result = aegisub.dialog.display config_diag.main
        if button
            for k, v in pairs result
                if config_diag.main[k]
                    config_diag.main[k].value = v

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