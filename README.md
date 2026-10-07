# Aegisub-Scripts

### DependencyControl

My scripts will use [DependencyControl](https://github.com/TypesettingTools/DependencyControl) for versioning and dependency management. \
You should have this installed to receive automatic updates for my scripts.

## Scripts

### Encode

This script allows you to encode the files you have open in Aegisub. You can output any combination of video, audio, and subtitles (softsub or hardsub), and also output the video as an image sequence.

This script is very fast, with high quality processing and scaling. It can reuse any indexes created by the VapourSynth source in Aegisub, and any indexes it generates itself will be reused on subsequent runs.

You can set the desired output codecs, image size, bit depth, crf, target filesize, fps, audio bitrate of the output and more.

The main encoding logic uses VapourSynth, so this script requires Python to be installed, alongside these packages:
- vsjetpack >= 2.2.4
- muxtools >= 0.5.0
- vsmuxtools >= 0.4.4
- vapoursynth >= 80

You can install them with this command:

```bash
pip install "vsjetpack[full]" muxtools vsmuxtools --extra-index-url https://jaded-encoding-thaumaturgy.github.io/vs-wheels/simple
```

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
