# Amogus

VapourSynth filter for (shitty) bitdepth reduction.

It is based on ordered dithering but instead of a bayer matrix a (very bad) amogus pattern is used.
Please don't use it, it's as shitty as the meme. I just needed an excuse to write something in Zig.

## Usage

Don't.

```
amogus.Amogus(clip, depth[, range])
```
To make the pattern obvious you can set `depth` to something lower than 8. This plugin will then scale the lower bitdepth back to 8, since VapourSynth only supports clips with a bitdepth of 8 or more.
`range` can be used to force the output range. Input range is always derived from the frame properties.

## Compilation

You may need to add `-I/usr/include` to the commands below to find the VapourSynth headers.
I think, by default, Zig only looks for C headers in its own directories.

### Native

```
$ zig build-lib amogus.zig -dynamic -O ReleaseFast --strip
```

### Cross-compilation

```
$ zig build-lib amogus.zig -dynamic -O ReleaseFast --strip -target x86_64-windows
```
