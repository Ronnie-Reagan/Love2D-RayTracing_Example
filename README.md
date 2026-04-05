<div align="center">
  <img src="Love2D-SDF-RayTracer-LOGO.png" alt="Love2D SDF RayTracer logo" width="220" />

# LÖVE2D SDF RayTracer

A compact interactive **SDF ray tracer / path tracer demo** built with **LÖVE 11.5/12.0**, Lua, and GLSL.

It focuses on realtime experimentation: scene switching, progressive accumulation, adjustable quality, path tracing controls, and runtime OBJ previewing from the `objects/` folder.
</div>

---

## Preview

<table>
  <tr>
    <td align="center">
      <img src="Fancy.png" alt="Fancy preset screenshot" width="100%" />
      <br />
      <sub>Fancy / Showcase</sub>
    </td>
    <td align="center">
      <img src="Potato.png" alt="Potato preset screenshot" width="100%" />
      <br />
      <sub>Potato / Showcase</sub>
    </td>
  </tr>
</table>

## What this is

This project is a shader-driven rendering demo that combines:

- signed distance field rendering
- progressive frame accumulation
- adjustable bounce and march-step limits
- optional shadows and reflections
- multiple built-in scenes
- runtime OBJ loading for quick imported-scene testing

It is built to be easy to run, easy to tweak, and easy to abuse.

## Current features

- **Five quality presets**: Potato, Low, Medium, High, Ultra
- **Four tracer modes**: Ultra-Fast, Fast, Balanced, Fancy
- **Four scene variants**:
  - Studio
  - Showcase
  - House of Mirrors
  - Imported Objects
- **Progressive accumulation** with manual reset
- **Adjustable render scale** and FPS target
- **Free-fly camera** with mouse look
- **Runtime OBJ browser** from `objects/`
- **Pause menu** for changing render settings live

## Quick start

### Run from source

1. Install **LÖVE 11.5**.
2. Clone or download this repository.
3. Run the project with:

```bash
love .
```

You can also drag the project folder onto the LÖVE executable on Windows.

## Controls

### In scene

- `W A S D` — move
- `Mouse` — look around
- `Space` — move up
- `Left Ctrl` — move down
- `Left Shift` — move faster
- `R` — reset accumulation
- `Tab` — toggle HUD
- `F1` — compact HUD
- `Caps Lock` — toggle input capture
- `Q / E` — cycle runtime OBJ models
- `F5` — refresh the `objects/` folder
- `Esc` — open pause menu

### In pause menu

- `W / S` or `Up / Down` — move selection
- `A / D` or `Left / Right` — adjust setting
- `Page Up / Page Down` — large step adjustments
- `Enter` / `Space` — activate item
- `R` — reset accumulation
- `Esc` — close pause menu

## Imported objects

The **Imported Objects** scene loads OBJ files from the `objects/` folder.

The default testing objects have been omittd due to license restrictions/conflicts

Notes:

- the runtime import path is intended for quick previewing rather than full asset fidelity
- imported geometry is sampled down for rendering, so extremely dense meshes are not the target
- `Q` / `E` cycles available models, and `F5` rescans the folder

## Project structure

```text
.
├── .gitignore
├── Fancy.png
├── Love2D-SDF-RayTracer-LOGO.png
├── main.lua
├── objloader.lua
├── Potato.png
├── shader.glsl
└── objects/
```

### Important files

- `main.lua` — app logic, controls, UI, camera, scene switching, accumulation management
- `shader.glsl` — core ray tracing / path tracing shader
- `objloader.lua` — simple & lightweight OBJ loader used by the imported-object scene
- `objects/` — runtime OBJ models

## Possible next steps

- better material variety for imported meshes
- denser or more specialized showcase scenes
- denoising or temporal filtering experiments
- more procedural primitives and lighting setups
- better low-end adaptive scaling
- richer object import support

## License

```text
Don Source-Available Non-Derivative License (DSANDL) v1.2

Copyright (c) 2025 Don Reagan
All rights reserved.

1. Definitions
   “Software” means the source code, scripts, binaries, and related files
   distributed by the Author.
   “Author” and/or "author" means the original copyright holder.
   “You” and/or "you" means any individual or entity using the Software.
   “Derivative Work” means any modification, adaptation, refactor, extension,
   partial reuse, or translation of the Software.
   “Combined Work” means embedding, linking, bundling, or integrating the
   Software into another system, application, library, mod, plugin, framework,
   or service.

2. Grant of Rights (Limited)
   The Author grants You a non-exclusive, non-transferable, revocable license to:
   - View and study the Software
   - Use the Software only in its original, unmodified form
   - Modify the Software privately for personal use only
   - Submit 'Pull Requests' to the original Github Repo

   No other rights are granted, whether implied or explicit.

3. Redistribution
   You may redistribute the Software only if ALL of the following are met:
   - The Software is completely unmodified
   - All original copyright notices are preserved
   - Clear attribution to the Author is included
   - This license text is included in full

   Redistribution of modified versions is strictly prohibited.

4. No Derivatives
   You may NOT:
   - Share modified versions
   - Publish forks
   - Distribute patches
   - Recompile or redistribute altered binaries
   - Share partial, extracted, or adapted logic

   Any modified version must remain private and undistributed.

5. No Combination or Embedding
   Without explicit written permission from the Author, You may NOT:
   - Embed the Software into another project
   - Combine it with other software
   - Link it as a dependency
   - Include it in a larger system or service
   - Use it in a plugin, mod, SDK, or framework
   - Deploy it in a manner that obscures attribution or authorship

   These restrictions apply to commercial and non-commercial use alike.

6. Contributions and Bug Fixes
   Bug fixes or improvements may be submitted privately to the Author.
   By submitting any contribution, You agree that:
   - The contribution is voluntary
   - The Author receives a perpetual, irrevocable, exclusive license
   - The Author may modify, relicense, commercialize, or discard it
   - You retain no rights to the contribution unless explicitly agreed in writing

7. Patent Rights
   The Author retains all patent rights related to the Software.

   The Author grants You a limited, non-exclusive, non-transferable patent
   license solely to use the Software in its original, unmodified form as
   permitted under this license.

   This patent license does NOT extend to:
   - Derivative Works
   - Combined Works
   - Modified versions
   - Commercial exploitation
   - Any use not explicitly permitted herein

   No patent exhaustion or implied patent license is granted.

8. Trademark Rights
   All trademarks, service marks, logos, and names associated with the Software
   are the exclusive property of the Author.

   This license grants no right to use the Author’s trademarks, except for
   factual attribution of authorship as required under Section 3 and Section 12.

   Any branding, promotional use, or representation implying endorsement is
   strictly prohibited without written permission.

9. Commercial Use and Paid Licensing
   The following require explicit written permission or a separate paid license:
   - Commercial use
   - Redistribution for profit
   - Embedding or combination into other software
   - Distribution as part of a product or service
   - Any use beyond the limited rights granted herein

10. Termination
    This license terminates automatically upon any violation.
    Upon termination, You must immediately cease all use and destroy all copies
    of the Software.

11. Disclaimer
    The Software is provided “AS IS”, without warranty of any kind.
    The Author is not liable for any damages arising from use of the Software.

12. Governing Law
    This license is governed by the laws of the Author’s jurisdiction.

13. Attribution
    Any permitted redistribution must include clear and visible attribution to
    the Author and include this license text in full.

14. Third-Party Software, Licenses, and Attributions

    This Software may include or depend on third-party libraries, assets, or
    components that are licensed under their own terms.

    Notwithstanding Section 5 (“No Combination or Embedding”), the Author grants
    permission to combine, link, and distribute the Software with such third-party
    components solely as required to build, run, and use the Software as distributed.

    Where required by applicable third-party licenses, attribution
    must be preserved and displayed in a reasonable and visible manner.

    This exception does NOT grant permission to combine this Software with other
    software beyond what is necessary to use the Software as distributed.

    Failure to comply with third-party license terms may result in loss of rights
    granted under those respective licenses.
```
---