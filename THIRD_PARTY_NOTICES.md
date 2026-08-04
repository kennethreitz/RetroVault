# Third-Party Notices

RetroVault is built with the projects listed below. This file is an overview,
not a replacement for their license texts. Each component remains governed by
its own license.

Release builds place this notice in the application bundle. Complete license
texts for bundled Libretro cores are stored under
`Contents/Resources/Libretro/Licenses`; the reviewed source revision and
build receipt are stored beside them. Hosted-emulator license texts are stored
with their respective bundled engines.

Some reviewed Libretro cores impose noncommercial-use conditions. Those
conditions continue to apply even though RetroVault itself is free software.
The RetroVault Core Linking Exception does not relax any third-party license.

## Swift packages

- [Nuke 13.0.6](https://github.com/kean/Nuke/tree/13.0.6) — MIT License
- [ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation/tree/0.9.20) — MIT License

### Nuke license

```text
The MIT License (MIT)

Copyright (c) 2015-2026 Alexander Grebenyuk

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### ZIPFoundation license

```text
MIT License

Copyright (c) 2017-2025 Thomas Zoechling (https://www.peakstep.com)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Hosted emulators

- [Cemu 2.6](https://github.com/cemu-project/Cemu/tree/v2.6) and the reviewed
  [native Metal revision](https://github.com/cemu-project/Cemu/tree/1706e5f37910fc6962ee54a41b219a53c1eed8b4)
  are distributed under the Mozilla Public License 2.0. Their complete
  `LICENSE.txt` ships with each companion.
- [Vita3K revision a10485eb](https://github.com/Vita3K/Vita3K/tree/a10485eb61b1ed4a291adab6017acd785659cccb)
  is distributed under the GNU General Public License version 2. Its complete
  `COPYING.txt` ships with the experimental engine.

## Bundled Libretro cores

The manifest is the source of truth for the exact core set embedded in a build.

| Core | Revision | License | License text |
| --- | --- | --- | --- |
| [2048 Pipeline Test](https://github.com/libretro/libretro-2048.git/tree/c90437d3c3913999624deca3fb55ecfa632b72c4) | `c90437d3` | Unlicense | [Notice](https://github.com/libretro/libretro-2048/blob/c90437d3c3913999624deca3fb55ecfa632b72c4/COPYING) |
| [A5200](https://github.com/libretro/a5200.git/tree/23c1ea482afb08656ec507e9ce98ed242a20bdfa) | `23c1ea48` | GPL-2.0-only | [Notice](https://github.com/libretro/a5200/blob/23c1ea482afb08656ec507e9ce98ed242a20bdfa/License.txt) |
| [Arduous](https://github.com/libretro/arduous.git/tree/798e3950f1de7c69455bc988d55eafeebac5a1eb) | `798e3950` | GPL-3.0-only | [Notice](https://github.com/libretro/arduous/blob/798e3950f1de7c69455bc988d55eafeebac5a1eb/COPYING) |
| [Beetle Cygne](https://github.com/libretro/beetle-wswan-libretro.git/tree/da6d0d9acb8d4e9bd6725ab44225a275325d8352) | `da6d0d9a` | GPL-2.0-only | [Notice](https://github.com/libretro/beetle-wswan-libretro/blob/da6d0d9acb8d4e9bd6725ab44225a275325d8352/COPYING) |
| [Beetle NeoPop](https://github.com/libretro/beetle-ngp-libretro.git/tree/a50d5ac288a81f2104ddf43195a4efdd15c72227) | `a50d5ac2` | GPL-2.0-only | [Notice](https://github.com/libretro/beetle-ngp-libretro/blob/a50d5ac288a81f2104ddf43195a4efdd15c72227/COPYING) |
| [Beetle PCE](https://github.com/libretro/beetle-pce-libretro.git/tree/ae99235c2139c176c1a8d0fde2957bf701d3cab0) | `ae99235c` | GPL-2.0-only | [Notice](https://github.com/libretro/beetle-pce-libretro/blob/ae99235c2139c176c1a8d0fde2957bf701d3cab0/COPYING) |
| [Beetle VB](https://github.com/libretro/beetle-vb-libretro.git/tree/7cc663e9044459b3dab1790bdce8f48dc7358ed6) | `7cc663e9` | GPL-2.0-only | [Notice](https://github.com/libretro/beetle-vb-libretro/blob/7cc663e9044459b3dab1790bdce8f48dc7358ed6/COPYING) |
| [bsnes-mercury Balanced](https://github.com/libretro/bsnes-mercury.git/tree/ac0b6b1fe5cb9448492f4c6b3d815205eefbd142) | `ac0b6b1f` | GPL-3.0-only | [Notice](https://github.com/libretro/bsnes-mercury/blob/ac0b6b1fe5cb9448492f4c6b3d815205eefbd142/LICENSE) |
| [Dolphin](https://github.com/libretro/dolphin.git/tree/d735584d1e1672a5a269508bbd84cf50e2e522a8) | `d735584d` | GPL-2.0-or-later | [Notice](https://github.com/libretro/dolphin/blob/d735584d1e1672a5a269508bbd84cf50e2e522a8/COPYING) |
| [DOSBox Pure](https://github.com/schellingb/dosbox-pure.git/tree/a4a0bab7f8931433588f2fcad9045c85b277373d) | `a4a0bab7` | GPL-2.0-or-later | [Notice](https://github.com/schellingb/dosbox-pure/blob/a4a0bab7f8931433588f2fcad9045c85b277373d/LICENSE) |
| [FAKE-08](https://github.com/jtothebell/fake-08.git/tree/814991a2571ad3970e386cef48f3b148aa1c27b9) | `814991a2` | MIT | [Notice](https://github.com/jtothebell/fake-08/blob/814991a2571ad3970e386cef48f3b148aa1c27b9/LICENSE.MD) |
| [FinalBurn Neo](https://github.com/libretro/FBNeo.git/tree/a2594cfa5e10341eb475647b77ebeb554779e740) | `a2594cfa` | LicenseRef-FinalBurn-Neo-NonCommercial | [Notice](https://github.com/libretro/FBNeo/blob/a2594cfa5e10341eb475647b77ebeb554779e740/src/license.txt) |
| [Flycast](https://github.com/flyinghead/flycast.git/tree/4126f1464fbc77c6bcec9cad00c32017ecabb799) | `4126f146` | GPL-2.0-or-later | [Notice](https://github.com/flyinghead/flycast/blob/4126f1464fbc77c6bcec9cad00c32017ecabb799/LICENSE) |
| [Gambatte](https://github.com/libretro/gambatte-libretro.git/tree/9b3b5e3cc18ec92f460d37dd551eaf90c55bfcea) | `9b3b5e3c` | GPL-2.0-only | [Notice](https://github.com/libretro/gambatte-libretro/blob/9b3b5e3cc18ec92f460d37dd551eaf90c55bfcea/COPYING) |
| [Gearcoleco](https://github.com/drhelius/Gearcoleco.git/tree/0803d3e28f11d5aece83eb822dadcefa9a06f0d0) | `0803d3e2` | GPL-3.0-only | [Notice](https://github.com/drhelius/Gearcoleco/blob/0803d3e28f11d5aece83eb822dadcefa9a06f0d0/LICENSE) |
| [Gearsystem](https://github.com/drhelius/Gearsystem.git/tree/c4f8dcd603a3037e2c05d9a63240455b505b002c) | `c4f8dcd6` | GPL-3.0-only | [Notice](https://github.com/drhelius/Gearsystem/blob/c4f8dcd603a3037e2c05d9a63240455b505b002c/LICENSE) |
| [Genesis Plus GX](https://github.com/libretro/Genesis-Plus-GX.git/tree/fa4dca561e08d5be9077419f7b255e1da213ed21) | `fa4dca56` | LicenseRef-Genesis-Plus-GX-NonCommercial | [Notice](https://github.com/libretro/Genesis-Plus-GX/blob/fa4dca561e08d5be9077419f7b255e1da213ed21/LICENSE.txt) |
| [melonDS](https://github.com/libretro/melonDS.git/tree/66b5d2634cd0a79030562811e6e05f5532f800ba) | `66b5d263` | GPL-3.0-only | [Notice](https://github.com/libretro/melonDS/blob/66b5d2634cd0a79030562811e6e05f5532f800ba/LICENSE) |
| [mGBA](https://github.com/libretro/mgba.git/tree/6dce57eef127dc4cc292644f38196e0e7c58590c) | `6dce57ee` | MPL-2.0 | [Notice](https://github.com/libretro/mgba/blob/6dce57eef127dc4cc292644f38196e0e7c58590c/LICENSE) |
| [Nestopia UE](https://github.com/libretro/nestopia.git/tree/b0fd87dd07e3c52903435d302b04e5e97796f127) | `b0fd87dd` | GPL-2.0-or-later | [Notice](https://github.com/libretro/nestopia/blob/b0fd87dd07e3c52903435d302b04e5e97796f127/COPYING) |
| [ParaLLEl-N64](https://github.com/libretro/parallel-n64.git/tree/39819865868231319f185b741466b9bb2203620d) | `39819865` | GPL-2.0-only | [Notice](https://github.com/libretro/parallel-n64/blob/39819865868231319f185b741466b9bb2203620d/mupen64plus-core/LICENSES) |
| [PCSX-ReARMed](https://github.com/libretro/pcsx_rearmed.git/tree/050981b6eeb715f142854f57c68086f62921f027) | `050981b6` | GPL-2.0-only | [Notice](https://github.com/libretro/pcsx_rearmed/blob/050981b6eeb715f142854f57c68086f62921f027/COPYING) |
| [PicoDrive](https://github.com/libretro/picodrive.git/tree/78a662e3135871a6c657d5e61900f6704152e594) | `78a662e3` | LicenseRef-PicoDrive-NonCommercial | [Notice](https://github.com/libretro/picodrive/blob/78a662e3135871a6c657d5e61900f6704152e594/COPYING) |
| [PokeMini](https://github.com/libretro/PokeMini.git/tree/bb009b1379ad15f1514f20ca7cbf710b4af42b3e) | `bb009b13` | GPL-3.0-or-later | [Notice](https://github.com/libretro/PokeMini/blob/bb009b1379ad15f1514f20ca7cbf710b4af42b3e/LICENSE) |
| [PPSSPP](https://github.com/hrydgard/ppsspp.git/tree/fa50bb1976065c4f8b1b47af227d367fe9771555) | `fa50bb19` | GPL-2.0-or-later | [Notice](https://github.com/hrydgard/ppsspp/blob/fa50bb1976065c4f8b1b47af227d367fe9771555/LICENSE.TXT) |
| [ProSystem](https://github.com/libretro/prosystem-libretro.git/tree/363b6dfbd3e240762e022c2b4897b4fe55722be3) | `363b6dfb` | GPL-2.0-only | [Notice](https://github.com/libretro/prosystem-libretro/blob/363b6dfbd3e240762e022c2b4897b4fe55722be3/License.txt) |
| [Stella 2014](https://github.com/libretro/stella2014-libretro.git/tree/4a7da82595d27b8df7af1ecb467a64b642a41bc9) | `4a7da825` | GPL-2.0-only | [Notice](https://github.com/libretro/stella2014-libretro/blob/4a7da82595d27b8df7af1ecb467a64b642a41bc9/stella/license.txt) |

## RetroVault

RetroVault original code is licensed under the GNU General Public License,
version 2 or later, with the RetroVault Core Linking Exception. See
[LICENSE](LICENSE) for the complete terms.
