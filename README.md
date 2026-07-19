# Aegisub-Scripts

## Required modules

### DependencyControl

Scripts I make will use [DependencyControl](https://github.com/TypesettingTools/DependencyControl) for versioning and dependency management.

## Scripts

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
