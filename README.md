# Aegisub-Scripts

## Required modules

### DependencyControl

Scripts I make will use [DependencyControl](https://github.com/TypesettingTools/DependencyControl) for versioning and dependency management.

## Scripts

### Encode

Based on [EncodeClip](https://github.com/petzku/Aegisub-Scripts/blob/master/macros/petzku.EncodeClip.lua).

My main motivation was having a script that quickly encoded a bunch of lines for use with aegisub motion. a-mo was too slow and petzku's version doesn't encode with a constant frame rate. This turned out to be because mpv is incapable of encoding in CFR for some ungodly reason. So we just remux with mkvmerge.

Anyway, this script lets you set the desired bit depth, crf, fps, and encode with avc, avc-nvenc, hevc, and av1.

### PlainerText

Based on [PlainText](https://github.com/petzku/Aegisub-Scripts/blob/master/macros/petzku.PlainText.moon) and [evadiff](https://github.com/Irrational-Sneed-Wizardry/evadiff).

Basically does a bunch of stuff to clean up the script and convert it to plaintext, then copies it to your clipboard. Yay!

### SceneBleed

Based on [Scenebleed Detector](https://github.com/garret1317/aegisub-scripts/blob/master/scenebleed.lua).

Detects lines with scenebleeds and marks them with an effect. \
I recommend you [generate keyframes](https://tilde.club/~garret/fansub.html#generating-keyframes) before using this script.

### Smartify

Based on [SmartQuotify](https://github.com/petzku/Aegisub-Scripts/blob/master/macros/petzku.SmartQuotify.moon).

It replaces all the "normal" quotes, ellipses, and dashes in your script into “smart” ones. \
You can specify which ones you want to convert when you run the script, and your choice is saved between runs. \
It has an interactive pop-up window to help you quickly turn ambiguous single quotes into apostrophes or starting quotes.

The script accounts for newlines and hard spaces as well.

Original:
```
Here is a normal line with "double quotes" and 'single quotes'.
He shouted,\N"This is a test of the newline patch!"
Wait...\N'Twas the night before Christmas.
I asked her,\h"What about hard spaces?"
"'Nested quotes' are always--always--a pain..."
"This is a quote extending across 'multiple lines',
and here is the end of it."
It don't matter if we have contractions like we're or they've.
```
Smartified:
```
Here is a normal line with “double quotes” and ‘single quotes’.
He shouted,\N“This is a test of the newline patch!”
Wait…\N’Twas the night before Christmas.
I asked her,\h“What about hard spaces?”
“‘Nested quotes’ are always—always—a pain…”
“This is a quote extending across ‘multiple lines’,
and here is the end of it.”
It don’t matter if we have contractions like we’re or they’ve.
```
