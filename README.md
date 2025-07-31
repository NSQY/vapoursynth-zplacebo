# vapoursynth-zplacebo

A Zig VapourSynth plugin based on [Lypheo/vs-placebo](https://github.com/Lypheo/vs-placebo).

WIP!!\
Windows build (for test) in [actions](https://github.com/dnjulek/vapoursynth-zplacebo/actions).

## Changes from vs-placebo:

- planes arg: from `1 | 2 | 4` to `[0, 1, 2]` input.
- shared build: if we link `shaderc_combined.lib` Vulkan won't start, so I'm using `shaderc_shared.dll` (It's inside the same .zip file).
- threads arg: increase speed by using Vulkan in parallel, avoid split planes.

### Deband

```python
zplacebo.Deband(
    clip: vs.VideoNode,
    planes: int[] = None,
    iterations: int = 1,
    threshold: float = 4.0,
    radius: float = 16.0,
    grain: float = 6.0,
    dither: bool = True,
    dither_algo: int = 0,
    threads: int = 2,
    log_level: int = 2,
)
```

Input needs to be 8 or 16 bit Integer or 32 bit Float.

- `planes`: the planes to filter, ex: [0, 1, 2] (None = all planes).
- `iterations`: The number of debanding steps to perform per sample.
- `threshold`: The debanding filter's cut-off threshold. Higher numbers increase
  the debanding strength dramatically, but progressively diminish image details.
- `radius`: The debanding filter's initial radius. The radius increases linearly
  for each iteration. A higher radius will find more gradients, but a lower
  radius will smooth more aggressively.
- `grain`: Add some extra noise to the image. This significantly helps cover up
  remaining quantization artifacts. Higher numbers add more noise.
- `dither`: Whether the debanded frame should be dithered or rounded from float
  to the output bitdepth. Only works for 8 bit.
- `threads`: How many vulkan-init in parallel.
  Instead of split plans, you can `threads=3` 
  (Max: 8, but higher than 4 or 5 vulkan can have trouble starting).
- `dither_algo`: The dithering method to use. Defaults to `blue`.
