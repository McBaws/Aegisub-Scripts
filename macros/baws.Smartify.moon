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
export script_namespace = "baws.Smartify"
export script_version = "1.1.0"

havedc, DependencyControl = pcall require, "l0.DependencyControl"
local dep
if havedc
    dep = DependencyControl{
        feed: "https://raw.githubusercontent.com/McBaws/Aegisub-Scripts/stable/DependencyControl.json",
    }

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
    fill_dialog!

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
    save_configuration res

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
