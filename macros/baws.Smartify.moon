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

-- Based on petzku's SmartQuotify

export script_name = "Smartify"
export script_description = [[Change all your "normal" quotes, ellipses, and dashes into “smart” ones]]
export script_author = "McBaws"
export script_namespace = "McBaws.Smartify"
export script_version = "1.0.0"

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

re = require 'aegisub.re'

-- Define the configuration dialog layout and defaults
config_diag = {
    main: {
        doubleQuotes:     {class: 'checkbox', label: 'Convert double quotes (" -> “ ”)', name: 'doubleQuotes', value: true, config: true, x: 0, y: 0}
        singleQuotes:     {class: 'checkbox', label: 'Convert single quotes (\' -> ‘ ’)', name: 'singleQuotes', value: true, config: true, x: 0, y: 1}
        ellipses:         {class: 'checkbox', label: 'Convert ellipses (... -> …)', name: 'ellipses', value: true, config: true, x: 0, y: 2}
        emDashes:         {class: 'checkbox', label: 'Convert double dashes (-- -> —)', name: 'emDashes', value: true, config: true, x: 0, y: 3}
        interactiveQuote: {class: 'checkbox', label: 'Enable interactive mode for ambiguous quotes', name: 'interactiveQuote', value: true, config: true, x: 0, y: 5}
        markActor:        {class: 'checkbox', label: 'Mark changed lines', name: 'markActor', value: true, config: true, x: 0, y: 6}
    }
}

if havedc
    config = ConfigHandler config_diag, dep.configFile, false, script_version, dep.configDir

trim = (s) ->
    return "" unless s
    s = s\gsub "^%s+", ""
    s = s\gsub "%s+$", ""
    s

cleanup_text = (text) ->
    new = text
    -- stripTags
    new, _ = re.sub new, "\\{[^\\}]*\\\\p(?:0+[1-9]|[1-9]{1}\\d{0,3})[^\\}]*\\}.*?\\{[^\\}]*\\\\p0.*?(?<!\\\\p1)\\}|\\{[^\\}]*\\\\p(?:0+[1-9]|[1-9]{1}\\d{0,3}).*$", ""
    new, _ = re.sub new, "\\{[^\\}]*\\}", ""
    -- removeNewlines
    new, _ = re.sub new, "\\\\h", " "
    new, _ = re.sub new, "\\s?\\\\n\\s?", " "
    new, _ = re.sub new, "\\s?\\\\N\\s?", "\r\n"
    -- normalizeWhitespace
    new, _ = re.sub new, "\u{00A0}", " "
    new, _ = re.sub new, "\\s+", " "
    trim new

process_line = (line, opts, state) ->
    return line unless line.class == "dialogue" and not line.comment
    -- Quick check if there is anything to replace at all
    return line unless line.text\find("['\"%.%-]")

    text = line.text
    apos_found_count = 0
    changes_made = {}

    if opts.singleQuotes
        orig_text = text
        -- Find ambiguous single quotes at the start of a word
        matches = re.find text, [[(?:(?<!\w)|(?<=\\[Nnh]))'(?=\w)]]
        if matches
            -- Iterate backwards so index shifting from string manipulation doesn't offset earlier matches
            for i = #matches, 1, -1
                m = matches[i]
                if opts.interactiveQuote and not state.interactive_cancelled
                    -- Insert the Japanese brackets into a raw copy before passing it to cleanup_text
                    preview_raw = text\sub(1, m.first - 1) .. "「" .. m.str .. "」" .. text\sub(m.last + 1)
                    cleaned = cleanup_text preview_raw
                    
                    prompt_diag = {
                        {class: "label", label: "Is the quote marked by 「」 an apostrophe or an opening quotation mark?", x: 0, y: 0, width: 40}
                        {class: "textbox", text: cleaned, x: 0, y: 2, width: 40, height: 4}
                    }
                    buttons = {"Apostrophe", "Quotation", "Cancel Interactive Mode"}
                    btn = aegisub.dialog.display prompt_diag, buttons
                    
                    if btn == "Apostrophe"
                        text = text\sub(1, m.first - 1) .. "’" .. text\sub(m.last + 1)
                    elseif btn == "Quotation"
                        text = text\sub(1, m.first - 1) .. "‘" .. text\sub(m.last + 1)
                    else
                        state.interactive_cancelled = true
                        text = text\sub(1, m.first - 1) .. "’" .. text\sub(m.last + 1)
                        apos_found_count += 1
                else
                    text = text\sub(1, m.first - 1) .. "’" .. text\sub(m.last + 1)
                    apos_found_count += 1
                    
        -- Cases where another quotation mark appears between the quote and the word
        text = re.sub text, [[(?:(?<!\w)|(?<=\\[Nnh]))'(?=['"]+\w)]], "‘"
        text = re.sub text, "'", "’"
        if orig_text != text
            table.insert changes_made, "'"

    if opts.doubleQuotes
        orig_text = text
        -- Replace any pairs of double quotes.
        text = re.sub text, [["(.+?)"]], [[“\1”]]
        -- Handle any remaining, unpaired double-quotes heuristically.
        text = re.sub text, [[(?:(?<!\w)|(?<=\\[Nnh]))"(?=[‘’"]*\w)]], "“"
        text = re.sub text, '"', "”"
        if orig_text != text
            table.insert changes_made, '"'

    if opts.ellipses
        orig_text = text
        -- Replace exactly three sequential periods with a smart ellipsis.
        text = re.sub text, [[(?<!\.)\.\.\.(?!\.)]], "…"
        if orig_text != text
            table.insert changes_made, "..."
            
    if opts.emDashes
        orig_text = text
        -- Replace exactly two dashes with an em-dash.
        text = re.sub text, [[(?<!-)--(?!-)]], "—"
        if orig_text != text
            table.insert changes_made, "--"

    -- Mark actor field based on the recorded changes
    if opts.markActor and #changes_made > 0
        line.actor ..= "[Smartified: " .. table.concat(changes_made, ", ") .. "]"

    line.text = text

    if apos_found_count > 0
        line.effect ..= "[Smartify: Ambiguous single quote#{apos_found_count > 1 and 's' or ''} at start of word -- assumed apostrophe]"

    return line

main = (subs, sel) ->
    -- Load previous settings
    if havedc
        config\read!
        config\updateInterface "main"
        
    -- Prepare the table sequence for Aegisub's dialog
    dialog_elements = {}
    for key, values in pairs config_diag.main
        dialog_elements[#dialog_elements + 1] = values

    buttons = {"Entire Script", "Selected Lines", "Cancel"}
    
    -- Show dialog with custom buttons
    btn, res = aegisub.dialog.display dialog_elements, buttons, {cancel: "Cancel"}
    
    -- Abort if user cancelled or closed the window
    if not btn or btn == "Cancel"
        aegisub.cancel!

    -- Save new settings state
    if havedc
        config\updateConfiguration res, 'main'
        config\write!
        config\updateInterface 'main'
    else
        for k, v in pairs res
            if config_diag.main[k]
                config_diag.main[k].value = v

    -- Shared state to track user cancelations in interactive mode
    state = { interactive_cancelled: false }

    -- Process lines based on the button clicked
    if btn == "Entire Script"
        for i = 1, #subs
            subs[i] = process_line(subs[i], res, state)
    elseif btn == "Selected Lines"
        for i in *sel
            subs[i] = process_line(subs[i], res, state)
            
    aegisub.set_undo_point script_name

if havedc
    dep\registerMacro main
else
    aegisub.register_macro script_name, script_description, main
