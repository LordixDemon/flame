## Unreleased

> Note: This release has breaking changes.

 - **FEAT**(flame_3d): Add the modules documented in `doc/bridge_packages/flame_3d`: post-processing, image-based lighting and probes, the shadow atlas, order-independent transparency, particles and ribbons, model loading and animation, collisions and physics, navigation, spatial audio, large-world helpers, scenes and assets, cinematics, 3D UI and debugging tools. ([11c8ff56](https://github.com/LordixDemon/flame/commit/11c8ff56afef16b3b4170b09d20a270bdbe927c0))
 - **DOCS**(flame_3d): Document the whole package against the code in 21 pages, each with costs, platform support and limitations, and correct them with the fixes below. ([4a757e88](https://github.com/LordixDemon/flame/commit/4a757e884a2cbf5b26751dd4c0e7a524db627953), [42252919](https://github.com/LordixDemon/flame/commit/42252919c04f4d9d550d34ad2a554cd6fdb2bc7c), [ac51592d](https://github.com/LordixDemon/flame/commit/ac51592d94611d51fadae91c2515d3dcf0ed151d))

### Scenes, embedding and cameras

 - **FIX**(flame_3d): `World3D.raycast` and `raycastAll` skip hidden components and components whose `cameraMask` shares no bit with the new `cameraMask` argument; `includeHidden: true` tests everything. Layer picking, `CameraStack3D.raycastAt` and `PointerRouter3D` pass the mask of their view. ([2b74a52a](https://github.com/LordixDemon/flame/commit/2b74a52a6306a99ca369e9fde9fe4ca4664a5171), [3c849b6a](https://github.com/LordixDemon/flame/commit/3c849b6a1310ca69bc921de2636bef27744b20b4), [d791ecad](https://github.com/LordixDemon/flame/commit/d791ecad269e1b68128cb17d905cb74cd72fbbe0))
 - **FIX**(flame_3d): Public setters report their changes to the scene versions: `color`, `instanceData` (now a `NotifyingVector4`) and `jointTransforms` of meshes, models and LOD meshes, `castsShadows`, `cameraMask`, the fields of light sources, `Material.castsShadows`, `depthPrepassEnabled`, `prioritizeNearestLights` and camera moves; writing an unchanged value notifies nothing. New `Component3D.markDrawDirty` and `LightSource.markChanged` report changes made in place. ([e4433826](https://github.com/LordixDemon/flame/commit/e44338260d547be856b000743788c9d98db31983), [3645f053](https://github.com/LordixDemon/flame/commit/3645f0533a0c93247c8f958bdf8918094c8536f7))
 - **FIX**(flame_3d): Only the moves that can move a shadow raise `castersVersion`, so moving lights without shadows, colliders and sounds keep a cached shadow map. ([cdf19d95](https://github.com/LordixDemon/flame/commit/cdf19d950f130778ccad7ae5966f280216fd2318), [bc9eeba1](https://github.com/LordixDemon/flame/commit/bc9eeba16696aa3a5393c1af25481ba064a4f944))
 - **FIX**(flame_3d): The `cameraMask` of a `Group3D` hides its subtree in every pass. ([55c4d4fe](https://github.com/LordixDemon/flame/commit/55c4d4fee90c8b8bca101615753cea831beb485e))
 - **FIX**(flame_3d): Retained `Scene3DComponent`s keep one target per path, re-present the kept image to its target, and compare an exact key that includes the layer's mask and the SSAO and depth-of-field fields. ([471307df](https://github.com/LordixDemon/flame/commit/471307df98ffac41005b7a6ee2fa5a58d6ac5c78))
 - **FEAT**(flame_3d): `Scene3DComponent.visibleRect` and `visibleSceneBounds` bound a layer's render pass. ([3b35ffe8](https://github.com/LordixDemon/flame/commit/3b35ffe8d46e3dc750bfb1d7dee56ca584beaae6))
 - **FEAT**(flame_3d): `Component3D.includeInSceneBounds` keeps a component out of `World3D.sceneBounds` and the sun's shadow fit (`World3D.hasUnboundedComponents`); adding a `DebugRenderer3D` no longer removes the shadows of the scene. ([7699199a](https://github.com/LordixDemon/flame/commit/7699199a0d8a32eac8f82d5555fccaa27de9b530), [265ed7c0](https://github.com/LordixDemon/flame/commit/265ed7c035e2ea053a78bfd9e9e0070fe4d26b33))
 - **FIX**(flame_3d): `RenderTexture3D.texture` is one texture for the render texture's life; `renderWorld` renders through a temporary host and, like `renderToImage`, works for an unmounted world, whose lights are gathered from its tree. ([decab6f2](https://github.com/LordixDemon/flame/commit/decab6f22fa5eb93ff92b08c81f5bcf79f16c153), [6c70140d](https://github.com/LordixDemon/flame/commit/6c70140d4ee6f573cf725cd885cd5f5bad2968e5))
 - **PERF**(flame_3d): `CameraStack3D` keeps a render target per slot instead of creating one per slot and frame. ([4025969a](https://github.com/LordixDemon/flame/commit/4025969ab055d3f5a201f5be744918dfae879129))
 - **FIX**(flame_3d): `Canvas3DFallbackComponent` draws what a camera pass would (visibility, masks, custom matrices, 0 to 1 depth), without per-frame allocations. ([051c9d44](https://github.com/LordixDemon/flame/commit/051c9d445d8e44c054d9f63bc2ede7b77320f8e4))
 - **FIX**(flame_3d): `ThirdPersonCamera` damping snaps instead of diverging on long frames; the camera rigs stop allocating per update. ([2c33903d](https://github.com/LordixDemon/flame/commit/2c33903d499a56978094e6d037bc596886668680))
 - **FEAT**(flame_3d): `World3D.lightsFrom` lets the layers of a `ShadowGroup` borrow the lights of one world instead of each holding a copy (`lightsVersion`, `lights`). ([2ba33c56](https://github.com/LordixDemon/flame/commit/2ba33c56))
 - **FEAT**(flame, flame_3d): `RasterScale` marks canvases that already contain a raster scale (`PostProcess.rasterizeSubtree`, a camera's scaled offscreen world); `Scene3DComponent` detects it and picks its resolution and pass bounds itself, and offscreen raster canvases are clipped to their image. ([65141704](https://github.com/LordixDemon/flame/commit/65141704), [ad20e9b9](https://github.com/LordixDemon/flame/commit/ad20e9b9), [9d321310](https://github.com/LordixDemon/flame/commit/9d321310))
 - **FEAT**(flame_3d): `RayHit3D.instanceIndex` for hits on instanced groups and crowd agents. ([1dc1feb8](https://github.com/LordixDemon/flame/commit/1dc1feb8))


### Rendering and post-processing

 - **BREAKING** **FIX**(flame_3d): With `World3D.hdrEnabled` the scene target holds extended-range sRGB for every material, so the other materials are no longer tone-mapped and encoded twice; only the native `SpatialMaterial` keeps light above white (custom shaders that compute linear light read `PassOptions.flags.x` as it does). `ToneMapMode.agx` uses the full fit, and color grading leaves the transparent pixels of a layer transparent. ([fb359cbe](https://github.com/LordixDemon/flame/commit/fb359cbe1ae529fdb32a79d2302674cf62fa0f55), [eb85ada0](https://github.com/LordixDemon/flame/commit/eb85ada053330bf7cdf973667cc304871051163e))
 - **FIX**(flame_3d): `OitMode3D.weightedBlended` draws every alpha-blended draw with its own material (lighting, fog, skinning), draws additive draws sorted after the composite, and falls back to sorting without float targets. `GraphicsDevice.textureTarget` takes a `role`, so the targets of one frame never alias. ([330f547d](https://github.com/LordixDemon/flame/commit/330f547dbc52b807dc4ca6f454c753ce8195bef8), [2c369442](https://github.com/LordixDemon/flame/commit/2c369442231f6ce0c5f660254ddf56d0342b3ad2))
 - **FIX**(flame_3d): MSAA applies when the scene renders through a texture target (post-processing, HDR, order-independent transparency, `afterScene` passes). ([d003a1f9](https://github.com/LordixDemon/flame/commit/d003a1f9446e30e5eab51b549180dd5af35680fc))
 - **FIX**(flame_3d): The depth-normal prepass stores each pixel's own depth and leaves out draws whose instances do not hold model matrices (`Material.instancesHoldModelMatrices`); `Material.depthNormalMaterial` draws opaque billboards and font text into it. ([c00bb74d](https://github.com/LordixDemon/flame/commit/c00bb74de79921adfabda6a0a22e48e3afc1c0e9), [e5255228](https://github.com/LordixDemon/flame/commit/e52552284e728f0ce513391cf3c2904ffcab0996))
 - **FEAT**(flame_3d): `beginTexturePass(keepContents: true)` lets `afterScene` custom passes draw over the scene. ([422d949c](https://github.com/LordixDemon/flame/commit/422d949c48166e4b3f7b871a981bba560dfec872))
 - **FIX**(flame_3d): Opaque draws after a depth-only draw write their color. ([f558635c](https://github.com/LordixDemon/flame/commit/f558635c07c7a35a4c5ecbc0a09525dc8b598c54))
 - **FIX**(flame_3d): Mirrored `InstancedGroup3D` instances keep their front faces; `drawInstances` takes `mirrored`. ([643e4402](https://github.com/LordixDemon/flame/commit/643e440235d2da4efec295754a77efb00b208f70))
 - **FIX**(flame_3d): `RenderGraph3D` releases pooled targets unused for 30 executions. ([9a82cc7e](https://github.com/LordixDemon/flame/commit/9a82cc7e1417f7e669ce295fbc8db8adf394c0bd))
 - **FIX**(flame_3d): WebGPU strip index format; package shaders without a web build throw an `UnsupportedError` naming the shader. ([34a08e09](https://github.com/LordixDemon/flame/commit/34a08e097042310f35c5c05b99ee602e33a9550c))
 - **FEAT**(flame_3d): `dart run flame_3d:build_shaders --src <dir> --out <dir>` builds a project's shaders from any folder; the shader compilation test builds into a temporary directory. ([a3347f2e](https://github.com/LordixDemon/flame/commit/a3347f2e5ae1f7324f673a4f1118dadc4bab1b94), [ba7c880e](https://github.com/LordixDemon/flame/commit/ba7c880ee929f492c496a4b480959bca2f4d17af))
 - **FIX**(flame_3d): `Line3D` pointing straight down. ([bcd8ae0c](https://github.com/LordixDemon/flame/commit/bcd8ae0c4a93b5c1e390359198b44ebeebf00125))
 - **CHORE**(flame_3d): Rebuild the shader bundles. ([75b16849](https://github.com/LordixDemon/flame/commit/75b16849ad681bdf408e4793f54d2b30584e09e0), [021ce5e8](https://github.com/LordixDemon/flame/commit/021ce5e853dc382d6c5ebd89c4ab932f0d720cb9), [70a29f61](https://github.com/LordixDemon/flame/commit/70a29f615eb3a83e77122bb833f893a09b455917), [75836d73](https://github.com/LordixDemon/flame/commit/75836d7398e043935fa1f38e6a2ff00160be221f))
 - **FIX**(flame_3d): The vignette of a layer's post-processing is centred on the visible frame, not on the render target. ([a43bfc4c](https://github.com/LordixDemon/flame/commit/a43bfc4c))
 - **FEAT**(flame_3d): Opaque `ParticleMaterial` billboards are in the depth-normal prepass; the prepass encoding is one shared shader chunk. ([20520932](https://github.com/LordixDemon/flame/commit/20520932), [d9458002](https://github.com/LordixDemon/flame/commit/d9458002))


### Materials and lighting

 - **FEAT**(flame_3d): `StylizedMaterial.rimPalette` with `packPaletteAndFade`, a per-instance rim highlight that keeps one material and one draw, and `StylizedMaterial.depthBias`. ([4a4005a9](https://github.com/LordixDemon/flame/commit/4a4005a9cff086468ad56d8ecc45adf93385c9ec), [3361ddfe](https://github.com/LordixDemon/flame/commit/3361ddfefa0abfe80401c19b513a5595072bb10c), [fb7c9273](https://github.com/LordixDemon/flame/commit/fb7c9273fb4dd21ceb485cf779f80e56b68821e2))
 - **FIX**(flame_3d): Reflection probe volumes are chosen per object (`Material.usesReflectionProbes`), light probe grids shade by the surface normal, probe irradiance is divided by pi like direct light, and sRGB environment probes are sampled as linear light. ([ed82836e](https://github.com/LordixDemon/flame/commit/ed82836e29308af410923ccd8a3fa19a10461f2a), [fe538949](https://github.com/LordixDemon/flame/commit/fe5389495694e56ac593e063335ae0b0b4fb4e11), [b5da1fad](https://github.com/LordixDemon/flame/commit/b5da1fadfb43895a9ddaabe976620b7b2086d699), [583e49bd](https://github.com/LordixDemon/flame/commit/583e49bd0bad53127af1989c5bffba3013c82039))
 - **FIX**(flame_3d): KTX2 files in sRGB block formats keep their color space when uploaded as they are (new sRGB `GpuPixelFormat` variants). ([89059c04](https://github.com/LordixDemon/flame/commit/89059c0430011df287ccc4c3166adcdf1c13d5a4))
 - **FIX**(flame_3d): `WaterMaterial` is lit by spot lights, ripples around its `upAxis`, and setting `opacity` updates its render state. ([bfc5960a](https://github.com/LordixDemon/flame/commit/bfc5960aba8c9ba82517d72330eb298c29c4cf28))
 - **FIX**(flame_3d): `OutlineMaterial` extrudes along normals transformed by the inverse transpose; new `flame_3d/outline.glsl` chunk. ([5bb386c5](https://github.com/LordixDemon/flame/commit/5bb386c5e967e416ecdbe2a6181cdefd11c1000d))
 - **FIX**(flame_3d): `BillboardMaterial3D` turns premultiplied textures back into straight colors (`premultipliedTexture`), and `translucent: true` blends premultiplied colors. ([ee075c55](https://github.com/LordixDemon/flame/commit/ee075c557a0628b12ac0b8f8525b197e51dcf9fc))
 - **FIX**(flame_3d): `DecalBatch3D` is sorted at the center of its decals. ([3abb281f](https://github.com/LordixDemon/flame/commit/3abb281f0b50ae57ed10e901ca86433ad007f108))
 - **FIX**(flame_3d): `LightClusterGrid3D` is described as the CPU helper it is (the renderer does not read it) and throws instead of wrapping packed values. ([6f831952](https://github.com/LordixDemon/flame/commit/6f83195228549043ca5fda60965564e6e8dcfcb1))
 - **DOCS**(flame_3d): Correct the joint limit and batching notes in material dartdocs. ([c35609b9](https://github.com/LordixDemon/flame/commit/c35609b9aa1f397e03f4c0e1716427a37532e721))
 - **FIX**(flame_3d): `StylizedMaterial` decodes its accent and rim palette slots in the vertex stage: interpolation could push a packed slot under its boundary, leaving transparent, wrongly coloured pixels at fade 0. ([1b873010](https://github.com/LordixDemon/flame/commit/1b873010))
 - **FEAT**(flame_3d): `DecalMaterial.premultipliedTexture` and `DecalBatch3D(sortByDepth:)`. ([fe415a63](https://github.com/LordixDemon/flame/commit/fe415a63), [8b3f6253](https://github.com/LordixDemon/flame/commit/8b3f6253))
 - **FEAT**(flame_3d): `StylizedMaterial.emissiveColorSource` (`EmissiveColorSource`): the emissive mask glows in each instance's color, accent or rim palette entry instead of `emissiveColor`, so instances of one mesh glow in colors of their own in one draw, exactly as with one material per color. ([349e55c4](https://github.com/LordixDemon/flame/commit/349e55c4))
 - **FEAT**(flame_3d): `BarrierMaterial`, a translucent energy wall around a play area that rises from its foot (`appear`), thins out up the wall and on its near side, carries a slow procedural pattern (`BarrierPattern`: plain, chevrons, diamonds, rune-like dashes), glints edge-on and shows four impacts (`impact`), rings of light from world points; additive by default, out of the shadow passes and the prepass, GLSL ES 1.00 friendly, not on the web. `BarrierMesh.roundedRectangle`, `ring` and `dome` build the walls (`pointOnWall`). ([be778d5c](https://github.com/LordixDemon/flame/commit/be778d5c))
 - **FEAT**(flame_3d): `WaterMaterial` draws clear, shallow water as one translucent draw without the depth prepass or the scene color grab: an animated caustic network, sparkles, a swell of the normals, a color and opacity ramp by the depth under each vertex, foam where a per-vertex mask says (`WaterMaterial.vertexLayout`, `buildSurface`), and `WaterRipples`, rings shared by the materials of a body of water (when full, a new one replaces the weakest). All off by default; a `foamThreshold` of 1 or more turns the crest foam off. ([5398b4cf](https://github.com/LordixDemon/flame/commit/5398b4cf))
 - **FEAT**(flame_3d): `Material.translucentOrder`: translucent draws are drawn in increasing order of it, back to front within one order, so a water surface can lie under the splashes above it. ([4d746aa5](https://github.com/LordixDemon/flame/commit/4d746aa5))
 - **FEAT**(flame_3d): `WaterMaterial.foamLightTint` and `WaterVolumeSettings.waterlineLightTint` say how much of the light's color the lit foam takes (`1`, the default, as before; `0` only its brightness), so foam stays white under a low, colored sun.
 - **FEAT**(flame_3d): `World3D.waterVolume` (`WaterVolumeSettings`): the parts of `StylizedMaterial` surfaces below a water level are tinted and darkened with their depth and lit by the water's caustics, and foam where they cross the level, without a depth buffer or a pass. ([8ddf54a5](https://github.com/LordixDemon/flame/commit/8ddf54a5))


### Shadows

 - **BREAKING** **FIX**(flame_3d): Every receiver (`StylizedMaterial`, `ShadowCatcherMaterial`, `WaterMaterial` and custom shaders that include `flame_3d/shadows.glsl`) reads the shadow atlas and the shadows of spot and point lights. Two cascades are atlas tiles like three and four; `cascadeSplits` of the wrong length or not increasing throw; `needsShadowCascade1`, `beginShadowCascade1` and `endShadowCascade1` are deprecated no-ops. ([7eeaae62](https://github.com/LordixDemon/flame/commit/7eeaae62ff7180004c76e32cc3ab8dbdecaf0503), [6356701f](https://github.com/LordixDemon/flame/commit/6356701f4cccf677642f431ced804fdb1740e6cf))
 - **FIX**(flame_3d): A `ShadowGroup` renders every tile of the atlas, `cacheWhenStatic` works on the atlas, the atlas is sized to its tiles (`ShadowAtlas3D.atlasSize` is 4096), and point-light tiles cull with the light's own bounds. ([74b79ce2](https://github.com/LordixDemon/flame/commit/74b79ce220997c11d28386c3e06c3476bde435eb), [fc36aaac](https://github.com/LordixDemon/flame/commit/fc36aaacd6b16df8d690ce1c5e604f6c88cb3ef2), [d9450781](https://github.com/LordixDemon/flame/commit/d94507819d7b65d77613a42e9336f0b46f0eb2f5), [a2022129](https://github.com/LordixDemon/flame/commit/a20221299163021d8173fc7f0bba1da26fb65e14))
 - **FIX**(flame_3d): Spot-light maps store each pixel's own depth, and spot and point shadows follow the lights the light blocks hold. ([35de91e1](https://github.com/LordixDemon/flame/commit/35de91e1e111190ca74030fa1ef9b108f68c6780), [d5270f44](https://github.com/LordixDemon/flame/commit/d5270f4472b9fc58eae925ac4f1ee29342e28788))
 - **FIX**(flame_3d): Shadow passes leave out draws whose instances do not hold model matrices (billboards, billboard particles, ribbons), and render no shadows when the caster shaders do not load (the web). ([ce46ecc7](https://github.com/LordixDemon/flame/commit/ce46ecc78f3c47bb20189a7a107a875c43a8bff6), [5679d1c2](https://github.com/LordixDemon/flame/commit/5679d1c2b481179a00605b6d633316f9139bd600))
 - **FEAT**(flame_3d): `ShadowCatcherMaterial(nearestOnly: true)` darkens a pixel once where catchers overlap (`Material.depthPrepassGroup`); `LightComponent.point` takes `shadows`. ([88a4412e](https://github.com/LordixDemon/flame/commit/88a4412e7eb205988a7c62268dd2ce7b6ab7d9b5), [e74b7377](https://github.com/LordixDemon/flame/commit/e74b7377d5352486dfb0596a8efad1c09d35b160))
 - **BREAKING** **PERF**(flame_3d): The shadow pass stops allocating per frame; the values of a `ShadowAtlasTile3D` belong to the frame that filled it. ([130c6e04](https://github.com/LordixDemon/flame/commit/130c6e04ea1675bc6599bce361302b02ccd9c892))
 - **FIX**(flame_3d): `LodMeshComponent`, `ChunkedTerrain3D` and `FoliageSystem3D` choose their detail from the main camera in shadow passes (`RenderContext3D.viewerPosition`, `viewerViewProjection`). ([0b445979](https://github.com/LordixDemon/flame/commit/0b4459797d55e8a6b36c0a34d89dea7ccdd22438), [43120260](https://github.com/LordixDemon/flame/commit/4312026090e13f8033734adb9943f09b697b5512))
 - **FIX**(flame_3d): A `ShadowGroup` fitted to the view fits its map (and cascades) once per frame to what all its layers show, instead of to whichever layer rendered first; layers report their view on cache hits too, and retained layers render again when `ShadowGroup.viewsVersion` changes. ([5c3d4412](https://github.com/LordixDemon/flame/commit/5c3d4412))


### Particles

 - **BREAKING** **FIX**(flame_3d): Billboard particles, stroke batches and ribbon trails stay out of shadow maps and the depth-normal prepass; `ParticleMaterial.castsShadows` is always `false`; `RenderStats.particles` counts a system once per frame. ([460c3f0c](https://github.com/LordixDemon/flame/commit/460c3f0cb0eb3da4887d97e651e6cafd39b51a48))
 - **FIX**(flame_3d): `RibbonTrail3D` follows its own position under a 3D parent. ([182099bb](https://github.com/LordixDemon/flame/commit/182099bb53f7555fb68f3a2dee00c83f171381e2))
 - **FIX**(flame_3d): `ParticleSystem3D.burst`, `emit`, `spawn`, `clear`, `reset` and `prewarm` raise the scene version, so a retained layer shows a burst made after the system's update; `Text3DComponent.worldHeight` and `orientation` are notifying setters. ([cf72efff](https://github.com/LordixDemon/flame/commit/cf72efff))
 - **FEAT**(flame_3d): Water splash presets: `ParticlePresets3D.splashCrown`, `runoffDrips`, `foamBurst` and `mistPuff`, dying at a `waterLevel` with `onGroundHit` for ripples; `DiscEmitterShape3D.tilt` and `RectangleEdgeEmitterShape3D`. The example's `barrier` scenario shows them with a barrier around a platform in a pool. ([794d48f3](https://github.com/LordixDemon/flame/commit/794d48f3), [5d986882](https://github.com/LordixDemon/flame/commit/5d986882))


### Models, geometry and animation

 - **FIX**(flame_3d): Skinned meshes ignore the transform of their node, as glTF requires. ([3f4a5f7b](https://github.com/LordixDemon/flame/commit/3f4a5f7bd7b3418dc67264eebfa0b409143ad2e7))
 - **FIX**(flame_3d): `MeshoptDecoder3D` decodes meshoptimizer streams (vertex and index codecs 0 and 1, the three filters) and rejects malformed ones. ([f2ad0a2e](https://github.com/LordixDemon/flame/commit/f2ad0a2e9d7100de564fb5a5596476188ef92897))
 - **BREAKING** **FIX**(flame_3d): Both glTF readers read sparse accessors (`RawAccessor.bufferView` is nullable) and meshopt views, merge `JOINTS_1` and `WEIGHTS_1`, convert strips and fans, and report what they drop through `GltfWarnings`; the external files of a `.gltf` are requested by their asset key (`GltfRoot.resolveUri`). ([a6a4195e](https://github.com/LordixDemon/flame/commit/a6a4195ee4e6c77470f638fcc5a16b2dfe35aaa4), [66bdb1c9](https://github.com/LordixDemon/flame/commit/66bdb1c96f31e2c3e5a49a0a8fb483d9d1d9f945), [7cebd728](https://github.com/LordixDemon/flame/commit/7cebd728f6bfef9b46e4526211bbacf70d6d8ef3))
 - **FIX**(flame_3d): `AsyncModelLoader3D` keeps the BVHs it builds on its isolate (`Surface.adoptBvh`, `SurfaceBvh.fromPrepared`). ([9d90cf1c](https://github.com/LordixDemon/flame/commit/9d90cf1cd3ad159cce05a38d5926f9456bafade0))
 - **FIX**(flame_3d): OBJ quads, polygons and texture coordinates are read correctly; `ObjParser.parseObjString`. ([2e29c7db](https://github.com/LordixDemon/flame/commit/2e29c7dbf688d5539cd85b8e525780b56ca10731))
 - **FIX**(flame_3d): Each `ModelComponent` has its own morph weights (`ModelComponent.nodeMesh`, `Surface.copyWithOwnVertices`), also when cloned. ([e30141e1](https://github.com/LordixDemon/flame/commit/e30141e18559a0894a1c2b68abb36db17e16e6a6), [92e42ce2](https://github.com/LordixDemon/flame/commit/92e42ce2a0cc9ae9631dbc62bbfcfae2c33134ff))
 - **FIX**(flame_3d): Crossfades start from the whole current pose, up to `AnimationState.maxNestedCrossFades` nested fades. ([781c3d5d](https://github.com/LordixDemon/flame/commit/781c3d5d328b7ddf34af7c83339d7a0705902893))
 - **FIX**(flame_3d): Root motion is applied in the component's parent space and turned by its rotation. ([190a2545](https://github.com/LordixDemon/flame/commit/190a25459534861e116d3e378ee68953e2d82ec9), [20a43158](https://github.com/LordixDemon/flame/commit/20a4315852f3802695cb69fac993469ef8ea9f61))
 - **FIX**(flame_3d): `Model.animatedAabb` bounds every keyframe. ([7c771956](https://github.com/LordixDemon/flame/commit/7c77195612cb2369c127f0bab4444c6e0fd8e72a))
 - **PERF**(flame_3d): Bone modifiers, ragdolls and crowds stop allocating per update. ([858115d0](https://github.com/LordixDemon/flame/commit/858115d02e905fd250c73d0a662090c322d9a3b0))
 - **FIX**(flame_3d): `TorusMesh` and `TubeSplineMesh` are wound counter-clockwise, `TubeSplineMesh` frames turn with the curve, and `ConeMesh` is shaded to its tip with continuous UVs. ([0a461357](https://github.com/LordixDemon/flame/commit/0a4613578940004c3feb8a99fd9ed28cd3ea5db2), [d2f88ffd](https://github.com/LordixDemon/flame/commit/d2f88ffd315aec5cc907dce4a140003b0f75a643), [03dcefa3](https://github.com/LordixDemon/flame/commit/03dcefa3a335f83db9654ee96cb8b89e33be703f))
 - **FIX**(flame_3d): Axis-aligned rays that start on a bounds face hit in `SceneSpatialIndex3D`. ([f96e1a59](https://github.com/LordixDemon/flame/commit/f96e1a59ebaadb0d143b7ec83339156b157ee8b3))
 - **DOCS**(flame_3d): Tangent comments no longer claim MikkTSpace. ([a06573ea](https://github.com/LordixDemon/flame/commit/a06573eae1277894f0fc170df609f16856d47a00))

### Input, effects and cinematics

 - **FIX**(flame_3d): `PointerRouter3D` drags follow the pointer, a router may be a sibling of its layer, `isDropPayload` is `false`, every tap-down listener gets an up or a cancel, and hover is kept per pointer. ([a11fe198](https://github.com/LordixDemon/flame/commit/a11fe19825d0731c15ea3bd3c2251c7a9d9ae1fa))
 - **FIX**(flame_3d): Speed-based effect controllers work on the 3D move, rotate and scale effects (`MeasurableEffect`, now exported by Flame's effects library); `FixedTransformInterpolation3D` blends by itself with `HasFixedUpdate`. ([28d1921b](https://github.com/LordixDemon/flame/commit/28d1921b05f92da3c88cf6180a3be676a41bfa0b))
 - **FIX**(flame_3d): `Timeline3D` plays backwards from the end, `AnimationClipTrack3D` owns the model clock (`releaseModelClock`), shot overrides are given back, and rotations take a single tangent. ([3d8b5490](https://github.com/LordixDemon/flame/commit/3d8b5490161b5e221ee63d9fe12ad4b0253020cb))
 - **PERF**(flame_3d): `VirtualCameraBrain3D` finds virtual cameras without walking the world. ([9658e3e4](https://github.com/LordixDemon/flame/commit/9658e3e4aab0336c7cb2006d66938728be1828e1))

### Collisions and physics

 - **FIX**(flame_3d): `ConvexHullShape3D` builds its faces (quickhull) and exact mass properties. ([f6a1b515](https://github.com/LordixDemon/flame/commit/f6a1b5152609065cc2b03da877ede84bc2646767))
 - **FIX**(flame_3d): Box and hull faces are clipped into multi-point contact manifolds with stable `featureId`s. ([fd4a7638](https://github.com/LordixDemon/flame/commit/fd4a763895621eae092e479cc019ae2649f7a509))
 - **BREAKING** **FIX**(flame_3d): Persistent contacts with warm starting, island sleep, static colliders solid for rigid bodies, continuous collision detection resolved through the contact solver, a `linearSlop` parameter, snapshot format 2 (`matchByOrder`), and bodies and buoyancy volumes that register when they mount. ([7e22b70b](https://github.com/LordixDemon/flame/commit/7e22b70bc86c84009ea634cda3a8c6fc8f7148ed))
 - **FIX**(flame_3d): Compound centers of mass and rope frames rotate forwards, joint lever arms are measured from the center of mass, and vehicles honour axle directions and the world's gravity. ([f8737a2d](https://github.com/LordixDemon/flame/commit/f8737a2d218c6a04e328f0d27afad87975d32fe2), [a493623a](https://github.com/LordixDemon/flame/commit/a493623a51bd54f33969d53db04748c9e5eff7ee), [3676b41e](https://github.com/LordixDemon/flame/commit/3676b41e4b49cd168b843aa7091d85922f6272c4))

### Navigation and audio

 - **FIX**(flame_3d): Straight nav-mesh paths, off-mesh links that follow their changes (`snapRadius`), `O(log P)` `sampleHeightAt`, and a read-only `polygonCosts`. ([1c346e01](https://github.com/LordixDemon/flame/commit/1c346e0132b5c03f69986419566cc47a7a52c287))
 - **PERF**(flame_3d): `CrowdSteering3D.update` stops allocating per agent pair. ([54a7e176](https://github.com/LordixDemon/flame/commit/54a7e1769991775853c5537cba5f3ac2df2f753c))
 - **BREAKING** **FIX**(flame_3d): The spatial audio mixer forgets removed emitters, evaluates each emitter once per frame, uses the emitters and zones registered with its world, and reads a separate `audioPriority`. ([2e7a2dd4](https://github.com/LordixDemon/flame/commit/2e7a2dd4a1518b85ac274a6d2e2c237ea1c4a3c1))

### Large worlds, scenes and assets

 - **BREAKING** **FIX**(flame_3d): `SceneSerializer3D` round-trips `LodMeshComponent`, `InstancedGroup3D`, `ShadowCatcherMaterial` and every value of its materials, or throws a `SceneSerializationException3D` listing what it cannot save (`allowLossy`, `findIssues`); schema version 2. ([4701c5e4](https://github.com/LordixDemon/flame/commit/4701c5e405858177849700fba9482bf394cb56c0))
 - **BREAKING** **FIX**(flame_3d): `Component3D.clone` throws an `UnsupportedError` for types it cannot copy instead of returning empty groups. ([f0b1acc6](https://github.com/LordixDemon/flame/commit/f0b1acc62caca6ce7860e49b4aac2da3713c5692))
 - **FIX**(flame_3d): `StaticMeshBatcher3D` draws its pieces with their instance data and uploads only the indices that change (`Surface.updateIndices`). ([8799e7cb](https://github.com/LordixDemon/flame/commit/8799e7cb9cc56bb525ac0d97b08da2c2da389c8f))
 - **FIX**(flame_3d): `OcclusionCuller3D` and `PortalOcclusionGraph3D` never report visible things hidden. ([9aa69140](https://github.com/LordixDemon/flame/commit/9aa6914068bde221aa63509110ed2c20f676b3c2))
 - **FIX**(flame_3d): `FloatingOriginController3D` no longer rebases every frame for a tracked target. ([671e8824](https://github.com/LordixDemon/flame/commit/671e882486e82da56159ab1ae06736524f35d035))
 - **FIX**(flame_3d): `WorldChunkStreamer3D` catches loader errors (`onChunkLoadFailed`, retries) and evicts its chunks when removed. ([3a822246](https://github.com/LordixDemon/flame/commit/3a822246a44eb357c12abc079c52ceca399e4b8e))
 - **FIX**(flame_3d): A `GpuResourceManager3D` lease releases its own entry; `release(key)` is deprecated. ([de76882e](https://github.com/LordixDemon/flame/commit/de76882e6edd065403a280e3df1faf80556894eb))
 - **FEAT**(flame_3d): `ChunkedTerrain3D.markHeightsChanged` rebuilds a terrain after its heights are edited. ([104848cb](https://github.com/LordixDemon/flame/commit/104848cbbe3a9343015a2dfc692ba81c6dcbe2b0))
 - **FIX**(flame_3d): Foliage bounds hold the trample lean and `addBlade` marks the world dirty, volume decals transform terrain normals by the inverse transpose, and the large-world components report changes through `markDrawDirty`. ([047e4cea](https://github.com/LordixDemon/flame/commit/047e4ceaa6341468ae184bd17922204400864f9e), [167617f4](https://github.com/LordixDemon/flame/commit/167617f48517ad50af94dd72693163fa796ccd6c), [f9e24074](https://github.com/LordixDemon/flame/commit/f9e2407434daa91db9582c1269c3b7ae85eb6870))

### 3D UI and debugging

 - **FIX**(flame_3d): `BillboardBatch3D` places its billboards with its transform, camera-facing MSDF text is laid out in the camera plane; new `anchorX` and `BillboardOrientation3D.fixed`. ([adb31357](https://github.com/LordixDemon/flame/commit/adb31357da5ed56a8c9cbcd19c6f16626b21192f))
 - **FIX**(flame_3d): Fixed `MsdfTextBatch3D` text is unlit and drawn with the camera-facing text in one draw. ([eb449f01](https://github.com/LordixDemon/flame/commit/eb449f0122a5e621b0332db9a2cca193eb2d9837))
 - **BREAKING** **FIX**(flame_3d): `Text3DComponent` and `WidgetSurface3D` throw an `UnsupportedError` where the backend cannot use images as textures (the web). ([75c91eec](https://github.com/LordixDemon/flame/commit/75c91eec69ace55713743d2eeb8b87fca510db69), [49c70ad2](https://github.com/LordixDemon/flame/commit/49c70ad21018a414c1f203e02efec302f313eb61))
 - **FIX**(flame_3d): X-ray debug lines are drawn after every opaque draw. ([311286c4](https://github.com/LordixDemon/flame/commit/311286c42a470d4d1dd6ac2cfab8a685a96c66ee))
 - **FIX**(flame_3d): The showcase self-test checks are named for what they check, and the debug-view check reads pixels. ([5fbaa888](https://github.com/LordixDemon/flame/commit/5fbaa888b332074050ab91c55b8c456d92a5c4e6))

## 0.4.0-dev.1

 - **FIX**: Version flame_3d_component as a prerelease and move flame_lint to 1.5.0-dev.0 ([#4100](https://github.com/flame-engine/flame/issues/4100)). ([f3961dbe](https://github.com/flame-engine/flame/commit/f3961dbea689ca3b4ad89edee1fc3688286409f9))
 - **FIX**: Bump the minimum Flutter version to 3.47.0 and Dart to 3.13.0 ([#4087](https://github.com/flame-engine/flame/issues/4087)). ([53cea039](https://github.com/flame-engine/flame/commit/53cea039746da34187e3d0991e355647aa4ffdcc))

## 0.4.0-dev.0

> Note: This release has breaking changes.

 - **FIX**: Use full asset paths in the remaining examples and docs ([#4027](https://github.com/flame-engine/flame/issues/4027)). ([1f8bf379](https://github.com/flame-engine/flame/commit/1f8bf379c01910fd684fc8ede186db9be445e673))
 - **FIX**: Adapt to Flutter 3.47 ([#3995](https://github.com/flame-engine/flame/issues/3995)). ([0453bad6](https://github.com/flame-engine/flame/commit/0453bad6e726ff90610baec86e5c24dc4c89a5a4))
 - **BREAKING** **PERF**: Replace the OrderedSet children container with a flat sorted-array ComponentList ([#4019](https://github.com/flame-engine/flame/issues/4019)). ([ab6ef3e3](https://github.com/flame-engine/flame/commit/ab6ef3e3e38fadb92bebe233f375d6d64d9039b1))
 - **BREAKING** **FEAT**: Kill ScrollDetector in favour of ScrollCallbacks ([#4005](https://github.com/flame-engine/flame/issues/4005)). ([d415867b](https://github.com/flame-engine/flame/commit/d415867b0bd4970aba580a5476180f438d3f5239))
 - **BREAKING** **FEAT**: Rename GameWidget.controlled to GameWidget.managed ([#3961](https://github.com/flame-engine/flame/issues/3961)). ([d99224e5](https://github.com/flame-engine/flame/commit/d99224e5e23c16c86d6d26bf8a807d31c4b4bbc4))
 - **BREAKING** **CHORE**: Rename HasWorldReference to HasWorldRef for consistency with HasGameRef ([#4039](https://github.com/flame-engine/flame/issues/4039)). ([cced5ccd](https://github.com/flame-engine/flame/commit/cced5ccd6fd241deb5f097c77181964d4307e3b8))

## 0.3.2

 - **FIX**: Republish flame_3d with the Flutter 3.47.0 constraint. ([b883d818](https://github.com/flame-engine/flame/commit/b883d818e3e6239587ed30b021a68809f2182607))

## 0.3.1

 - **FIX**: Require Flutter 3.47.0 or newer for flame_3d. ([f9d12195](https://github.com/flame-engine/flame/commit/f9d1219508dbd0d0a14b3f3c52b9618462c03cfb))
 - **FIX**: Adapt to Flutter 3.47 ([#3995](https://github.com/flame-engine/flame/issues/3995)). ([3bf30496](https://github.com/flame-engine/flame/commit/3bf304968867101cdb17aa02927b205bf46f664f))

## 0.3.0

> Note: This release has breaking changes.

 - **REFACTOR**(flame_3d): Abstract GPU implementation away for future proofing different backends ([#3928](https://github.com/flame-engine/flame/issues/3928)). ([f625173d](https://github.com/flame-engine/flame/commit/f625173d2b3ab2685b7b759c213a675b969af432))
 - **REFACTOR**(flame_3d): Shader generation now supports `#include` ([#3924](https://github.com/flame-engine/flame/issues/3924)). ([2be34f8e](https://github.com/flame-engine/flame/commit/2be34f8e780abcc2737c1dbcdf4b12cbd835352f))
 - **FEAT**(flame_3d): Add experimental `web` support using `webgpu` backend ([#3930](https://github.com/flame-engine/flame/issues/3930)). ([f21c5a8a](https://github.com/flame-engine/flame/commit/f21c5a8a5a08f973bd149aa40f1fc87ec160936b))
 - **FEAT**(flame_3d): Expose mesh information as read-only ([#3927](https://github.com/flame-engine/flame/issues/3927)). ([c5c3e662](https://github.com/flame-engine/flame/commit/c5c3e662dc434ec28882ea1fe284159a85517cf3))
 - **FEAT**(flame_3d): Add `UnlitMaterial` support ([#3914](https://github.com/flame-engine/flame/issues/3914)). ([9c88ff8c](https://github.com/flame-engine/flame/commit/9c88ff8cd9f2e6d351592eecf6156940c0361dd9))
 - **BREAKING** **FIX**(flame_3d): Fix material on `Line3D` ([#3916](https://github.com/flame-engine/flame/issues/3916)). ([f6fc6104](https://github.com/flame-engine/flame/commit/f6fc61042728c89c756077ba32071cec30d9bd8f))
 - **BREAKING** **FEAT**(flame_3d): Introduce `RenderContext` to make `GraphicsDevice` focused ([#3872](https://github.com/flame-engine/flame/issues/3872)). ([4338c624](https://github.com/flame-engine/flame/commit/4338c624da5b17e73a88fcb260dca5af14fc5a7f))

## 0.2.0

> Note: This release has breaking changes.

 - **REFACTOR**(flame_3d): Optimize allocation time in shaders ([#3881](https://github.com/flame-engine/flame/issues/3881)). ([043d6e8f](https://github.com/flame-engine/flame/commit/043d6e8f4b7b05cf56a313d5033f205c070b11fb))
 - **REFACTOR**(flame_3d): Simplify uniform slot definitions and allocations ([#3873](https://github.com/flame-engine/flame/issues/3873)). ([9c61971d](https://github.com/flame-engine/flame/commit/9c61971dfca20fc3bb1cd221e5b3e256fcac84ca))
 - **FIX**(flame_3d): Ensure `children` parameter is passed to constructors in `MeshComponent` and `ModelComponent` ([#3884](https://github.com/flame-engine/flame/issues/3884)). ([adc7658b](https://github.com/flame-engine/flame/commit/adc7658b6a4bce939e3f2e80ba8af3d789b0ce0b))
 - **FIX**(flame_3d): Ensure proper ambient light calculation in spatial_material shader ([#3866](https://github.com/flame-engine/flame/issues/3866)). ([be8607ac](https://github.com/flame-engine/flame/commit/be8607ac481224ce3746c501af1f089dd0077fc9))
 - **FEAT**(flame_3d): Allow shader uniform structures use array elements ([#3878](https://github.com/flame-engine/flame/issues/3878)). ([9854f130](https://github.com/flame-engine/flame/commit/9854f130a87b6240611089338ab69555aec3814f))
 - **FEAT**(flame_3d): Add culling scenario and implement AABB frustum culling logic([#3868](https://github.com/flame-engine/flame/issues/3868)). ([ce1d42ad](https://github.com/flame-engine/flame/commit/ce1d42adfb93ebd2856f001fc624da6f9ea22643))
 - **FEAT**(flame_3d): Support cull mode on materials ([#3865](https://github.com/flame-engine/flame/issues/3865)). ([e407a6e1](https://github.com/flame-engine/flame/commit/e407a6e16f6849236b1d56061920db72d74763ec))
 - **BREAKING** **REFACTOR**(flame_3d): Allow `LightComponents` to be nested ([#3883](https://github.com/flame-engine/flame/issues/3883)). ([fbd9b676](https://github.com/flame-engine/flame/commit/fbd9b676fe58978b60f811673a631fad391a3942))
 - **BREAKING** **REFACTOR**(flame_3d): Simplify shader structure and remove no longer needed uniform classes ([#3880](https://github.com/flame-engine/flame/issues/3880)). ([1d799fdc](https://github.com/flame-engine/flame/commit/1d799fdceca6b750f4fa7161f0865b58fa4ec575))
 - **BREAKING** **FIX**(flame_3d): Change type on `Surface` to be non-nullable ([#3882](https://github.com/flame-engine/flame/issues/3882)). ([67938373](https://github.com/flame-engine/flame/commit/679383739af4476088953bdfc4dc93635434305c))
 - **BREAKING** **FEAT**(flame_3d): Allow for nested Component3D by using world matrix calculations ([#3867](https://github.com/flame-engine/flame/issues/3867)). ([48d0a847](https://github.com/flame-engine/flame/commit/48d0a8474b55e7e2e45941f721d889c04e46bdaf))

## 0.1.1+7

 - **FIX**(flame_3d): Use float for numLights uniform to fix GLES crash ([#3810](https://github.com/flame-engine/flame/issues/3810)). ([f241ebd6](https://github.com/flame-engine/flame/commit/f241ebd6d73caa43387972cffeb609af2909ac2f))
 - **FIX**(flame_3d): Fix alpha blend factors for transparent background compositing ([#3812](https://github.com/flame-engine/flame/issues/3812)). ([8d7212a1](https://github.com/flame-engine/flame/commit/8d7212a1c79d561330131ea794a0ed318c3945f8))
 - **FIX**(flame_3d): Remove duplicate baseColor multiply in ambient calculation ([#3814](https://github.com/flame-engine/flame/issues/3814)). ([080bde7f](https://github.com/flame-engine/flame/commit/080bde7f4c14c9f4f91e09d9bf6e737f75449351))
 - **FIX**: Use scaledRadius for CircleHitbox collision detection ([#3808](https://github.com/flame-engine/flame/issues/3808)). ([3498c1e5](https://github.com/flame-engine/flame/commit/3498c1e565985ce7d12212e6a625f538da98c362))
 - **FIX**: Bump Flutter min version to 3.41.0 ([#3807](https://github.com/flame-engine/flame/issues/3807)). ([0d505304](https://github.com/flame-engine/flame/commit/0d50530485e5be9ce1c9138a5b437607c7c5c628))

## 0.1.1+6

 - Update a dependency to the latest release.

## 0.1.1+5

 - Update a dependency to the latest release.

## 0.1.1+4

 - Update a dependency to the latest release.

## 0.1.1+3

 - Update a dependency to the latest release.

## 0.1.1+2

 - **DOCS**: Update README.md of flame_3d with newer instructions ([#3711](https://github.com/flame-engine/flame/issues/3711)). ([ad7dc059](https://github.com/flame-engine/flame/commit/ad7dc059f2f97e7bc78a74bdff149b26adb22fbc))

## 0.1.1+1

 - **FIX**: When parsing OBJs with no normals, fallback to normal generation ([#3708](https://github.com/flame-engine/flame/issues/3708)). ([a59ccaa3](https://github.com/flame-engine/flame/commit/a59ccaa341a562c25ad54f4af567b160084e06d8))
 - **FIX**: Update compiled shaderbundle for flame_3d and add color example ([#3704](https://github.com/flame-engine/flame/issues/3704)). ([a1070d97](https://github.com/flame-engine/flame/commit/a1070d975fd3af52d44f3febb13dd97afd4990a6))

## 0.1.1

 - **FIX**: Cleanup and make OBJ parser more resilient ([#3702](https://github.com/flame-engine/flame/issues/3702)). ([b96421d5](https://github.com/flame-engine/flame/commit/b96421d5035393d764a9ec34aeba8db380222f45))
 - **FIX**: Fix color to byte conversion for shaders ([#3700](https://github.com/flame-engine/flame/issues/3700)). ([2426c06b](https://github.com/flame-engine/flame/commit/2426c06b799797720c9df8fbd73e337422654d00))
 - **FIX**: Add fallback default material to avoid crashes ([#3701](https://github.com/flame-engine/flame/issues/3701)). ([8e6b04e3](https://github.com/flame-engine/flame/commit/8e6b04e38855b6fae6761a9f8d20c82c6bff6d76))
 - **FIX**: Expose Line3D on components.dart ([#3698](https://github.com/flame-engine/flame/issues/3698)). ([d58d7b54](https://github.com/flame-engine/flame/commit/d58d7b5482f646e4536160449f4a17317b8aff2b))
 - **FEAT**: Introduce cone mesh ([#3699](https://github.com/flame-engine/flame/issues/3699)). ([874a97fe](https://github.com/flame-engine/flame/commit/874a97fe421dadbed9f3825c8562f8bd7e6c95c9))
 - **DOCS**: Update instructions on how to use flame_3d ([#3696](https://github.com/flame-engine/flame/issues/3696)). ([11cc2a8f](https://github.com/flame-engine/flame/commit/11cc2a8fae0f1c17106f91ef1ac319e6f8e39036))

## 0.1.0

 - **REFACTOR**: Add collections library to flame_3d ([#3680](https://github.com/flame-engine/flame/issues/3680)). ([89e5e58e](https://github.com/flame-engine/flame/commit/89e5e58efb580ec267a0dca78a3a0f320203d4ee))
 - **FIX**: Update flame_3d to support both old and newer Flutter APIs ([#3663](https://github.com/flame-engine/flame/issues/3663)). ([d9f1fe7f](https://github.com/flame-engine/flame/commit/d9f1fe7f9abd8f0307ecc22ff24d3b492e9ca332))
 - **FEAT**: Add ability to run on flame_3d example ([#3679](https://github.com/flame-engine/flame/issues/3679)). ([801692bf](https://github.com/flame-engine/flame/commit/801692bfa1226e01f1540166a8140ab42e36ed87))
 - **FEAT**: Add support for model parsing and rendering in flame_3d, including skeletal animations ([#3675](https://github.com/flame-engine/flame/issues/3675)). ([cc58aef5](https://github.com/flame-engine/flame/commit/cc58aef5b53f208fb1cbb116bfb9f9af9a351e8e))
 - **FEAT**: Add setup command to flame_3d example ([#3671](https://github.com/flame-engine/flame/issues/3671)). ([2f5ba87b](https://github.com/flame-engine/flame/commit/2f5ba87be8068b12c2604b79f7db9c1f3307a4b6))
 - **FEAT**: Organize components and add destroy command to flame_3d example ([#3665](https://github.com/flame-engine/flame/issues/3665)). ([d5915752](https://github.com/flame-engine/flame/commit/d591575263d8b13aee862efe05842001aa60f89d))
 - **FEAT**: Add keybind to jump on flame_3d example ([#3664](https://github.com/flame-engine/flame/issues/3664)). ([7be0bccd](https://github.com/flame-engine/flame/commit/7be0bccda0040bfc3734f90b6bca7d5e99455bee))

## 0.1.0-dev.14

 - Update a dependency to the latest release.

## 0.1.0-dev.13

 - Update a dependency to the latest release.

## 0.1.0-dev.12

 - **FIX**: Only expose `ReadOnlyOrderedset` from `component.children` ([#3606](https://github.com/flame-engine/flame/issues/3606)). ([79351d19](https://github.com/flame-engine/flame/commit/79351d195ea968b8016129e79a489ef113a0fdf3))

## 0.1.0-dev.11

 - **FEAT**: Add flame_console to flame_3d example to enable more complex setups ([#3580](https://github.com/flame-engine/flame/issues/3580)). ([15a6f8b0](https://github.com/flame-engine/flame/commit/15a6f8b001deb714134976d7cbb5ef0a6ec31c86))
 - **DOCS**: Update flame_3d example to fix movement and camera, organize files ([#3573](https://github.com/flame-engine/flame/issues/3573)). ([54ca8433](https://github.com/flame-engine/flame/commit/54ca8433f20b451eb1a2c3c5f5a47a3430e71a6e))

## 0.1.0-dev.10

 - **FIX**: Update ordered_set, remove ComponentSet ([#3554](https://github.com/flame-engine/flame/issues/3554)). ([728e13f8](https://github.com/flame-engine/flame/commit/728e13f855d988e8f8e24976557b213b98221603))

## 0.1.0-dev.9

 - **FEAT**: Bump to new lint package ([#3545](https://github.com/flame-engine/flame/issues/3545)). ([bf6ee518](https://github.com/flame-engine/flame/commit/bf6ee51897591b7ad6e5f9da2193b1eeeaf026f4))

## 0.1.0-dev.8

 - Update a dependency to the latest release.

## 0.1.0-dev.7

 - **DOCS**: Fix workflow status badge paths ([#3517](https://github.com/flame-engine/flame/issues/3517)). ([149f16fe](https://github.com/flame-engine/flame/commit/149f16fe29f1fb14b3612964b2226c9c5c7daf95))

## 0.1.0-dev.6

 - **FEAT**: Add helper methods to create matrix4 with sensible defaults ([#3486](https://github.com/flame-engine/flame/issues/3486)). ([9345c870](https://github.com/flame-engine/flame/commit/9345c870d4de57d8d3a4d07a014d18cb71c01618))
 - **FEAT**: Add setFromMatrix4 to Transform3D ([#3484](https://github.com/flame-engine/flame/issues/3484)). ([1dbb4433](https://github.com/flame-engine/flame/commit/1dbb4433ca9e06b93a49b430fe9c084885551ff2))
 - **FEAT**: Add Line3D mesh component [flame_3d] ([#3412](https://github.com/flame-engine/flame/issues/3412)). ([c332c965](https://github.com/flame-engine/flame/commit/c332c9651ad8b930281c1d0bc13b89754fd0b2c1))

## 0.1.0-dev.5

> Note: This release has breaking changes.

 - **BREAKING** **FEAT**: Make resource creation be on demand to enable testing (#3411).

## 0.1.0-dev.4

> Note: This release has breaking changes.

 - **REFACTOR**: Fix lint issues from latest flutter release ([#3390](https://github.com/flame-engine/flame/issues/3390)). ([978ad31b](https://github.com/flame-engine/flame/commit/978ad31b429d1801097b0db385a600c85a157867))
 - **FIX**: Use saner default value for camera's target ([#3238](https://github.com/flame-engine/flame/issues/3238)). ([78522c62](https://github.com/flame-engine/flame/commit/78522c624d846c827a1c0d7377837e04a30ba4e7))
 - **FIX**: Use saner default value for camera's target ([#3238](https://github.com/flame-engine/flame/issues/3238)). ([99ca355b](https://github.com/flame-engine/flame/commit/99ca355b3d4a3e9c7677454dc9bc2c874ee2e4a9))
 - **FIX**: Fix albedo texture binding on shader ([#3400](https://github.com/flame-engine/flame/issues/3400)). ([c380c91f](https://github.com/flame-engine/flame/commit/c380c91f7a7e22ab71c3617c0386159861a64abc))
 - **FIX**: Make build_shaders script compatible with other platforms [flame_3d] ([#3395](https://github.com/flame-engine/flame/issues/3395)). ([38331309](https://github.com/flame-engine/flame/commit/38331309ca5ee609e85422ee9d740569a35e5e9e))
 - **FIX**: Make `flame_3d` work with latest stable ([#3387](https://github.com/flame-engine/flame/issues/3387)). ([f940d3f9](https://github.com/flame-engine/flame/commit/f940d3f9420d3ce001f47a9155c582b8b4cd1dcb))
 - **FIX**: MeshComponent.bind should bind to the provided device ([#3278](https://github.com/flame-engine/flame/issues/3278)). ([d06b4ce6](https://github.com/flame-engine/flame/commit/d06b4ce6935987705447772f912719c405d39c9e))
 - **FIX**: Improve behavior of Quaternion.slerp function [flame_3d] ([#3306](https://github.com/flame-engine/flame/issues/3306)). ([8872a45a](https://github.com/flame-engine/flame/commit/8872a45a1b49d7ba7688d62ca25b2a8d31c495cb))
 - **FIX**: Improve quaternion slerp logic to avoid NaN edge cases ([#3303](https://github.com/flame-engine/flame/issues/3303)). ([712b03fb](https://github.com/flame-engine/flame/commit/712b03fbe176cf238a3780aee641254436520366))
 - **FIX**: Make the `build_shader` script work for windows ([#3402](https://github.com/flame-engine/flame/issues/3402)). ([ce7822a0](https://github.com/flame-engine/flame/commit/ce7822a0d0c5ac1c766635a5cf2c242d5e5f98ec))
 - **FIX**: MeshComponent.bind should bind to the provided device ([#3278](https://github.com/flame-engine/flame/issues/3278)). ([3ae3ef54](https://github.com/flame-engine/flame/commit/3ae3ef5476fa5f9ead7069efeee35cc31c0e9dd2))
 - **FIX**: Fix typo on loadTexture ([#3253](https://github.com/flame-engine/flame/issues/3253)). ([3a20a8cd](https://github.com/flame-engine/flame/commit/3a20a8cd61543aad21c1015de5c31ec1cbe71aed))
 - **FIX**: Improve behavior of Quaternion.slerp function [flame_3d] ([#3306](https://github.com/flame-engine/flame/issues/3306)). ([b9d6a0f1](https://github.com/flame-engine/flame/commit/b9d6a0f1d34e009cd91ae9d2ab0eed09b546d110))
 - **FIX**: Improve quaternion slerp logic to avoid NaN edge cases ([#3303](https://github.com/flame-engine/flame/issues/3303)). ([565b68b9](https://github.com/flame-engine/flame/commit/565b68b9da52d44281e93f9ae8617f9dbe9551f3))
 - **FIX**: Fix typo on loadTexture ([#3253](https://github.com/flame-engine/flame/issues/3253)). ([3d1f1437](https://github.com/flame-engine/flame/commit/3d1f143700506467798e030450227d8029b74ef2))
 - **FIX**: Add missing export for CylinderMesh [flame_3d] ([#3256](https://github.com/flame-engine/flame/issues/3256)). ([d8fb65c1](https://github.com/flame-engine/flame/commit/d8fb65c158a3cce442972fb24f55fb522729085f))
 - **FIX**: Add missing export for CylinderMesh [flame_3d] ([#3256](https://github.com/flame-engine/flame/issues/3256)). ([d517c169](https://github.com/flame-engine/flame/commit/d517c169ed9b4d4457df6ac1ae363277577597fa))
 - **FEAT**: More Lights! [flame_3d] ([#3250](https://github.com/flame-engine/flame/issues/3250)). ([5c508e81](https://github.com/flame-engine/flame/commit/5c508e81bddfb17857355da80e57f1ac77ab368d))
 - **FEAT**(flame_3d): Add helpful extension functions to Vector ([#3141](https://github.com/flame-engine/flame/issues/3141)). ([92195989](https://github.com/flame-engine/flame/commit/9219598904131d8fceba8d1ad980bea2805e3515))
 - **FEAT**: Add CylinderMesh [flame_3d] ([#3239](https://github.com/flame-engine/flame/issues/3239)). ([d5de1733](https://github.com/flame-engine/flame/commit/d5de1733c64c4fbaeee83089a3b0f9a3fbb3355d))
 - **FEAT**: Refactor shader uniform binding to support shader arrays [flame_3d] ([#3282](https://github.com/flame-engine/flame/issues/3282)). ([edae1662](https://github.com/flame-engine/flame/commit/edae166252a519d38496bb6bf7c84fe9f401b8d4))
 - **FEAT**(flame_3d): Make shader api more useful ([#3085](https://github.com/flame-engine/flame/issues/3085)). ([fe2e4f20](https://github.com/flame-engine/flame/commit/fe2e4f20195b453268b34e589616343fdce6201a))
 - **FEAT**(flame_3d): Make shader api more useful ([#3085](https://github.com/flame-engine/flame/issues/3085)). ([4042d300](https://github.com/flame-engine/flame/commit/4042d3002ce619bf6b8597aa7dc17a803bc57c69))
 - **FEAT**: Add more useful extensions to VectorN and Quaternion [flame_3d] ([#3296](https://github.com/flame-engine/flame/issues/3296)). ([f5f03e5e](https://github.com/flame-engine/flame/commit/f5f03e5ed7095ede713727d6bbab39db0505e7bf))
 - **FEAT**: Expose vector classes on core file [flame_3d] ([#3211](https://github.com/flame-engine/flame/issues/3211)). ([8f403ac2](https://github.com/flame-engine/flame/commit/8f403ac23ae7cdf5343652c30f9c0ee71d627b0a))
 - **FEAT**(flame_3d): Add helpful extension functions to Vector ([#3141](https://github.com/flame-engine/flame/issues/3141)). ([39e15fb3](https://github.com/flame-engine/flame/commit/39e15fb30256cbfaa86f4d7b8e3453c52942d1a5))
 - **FEAT**: Add CylinderMesh [flame_3d] ([#3239](https://github.com/flame-engine/flame/issues/3239)). ([01872fb6](https://github.com/flame-engine/flame/commit/01872fb6e45e10dc380fee7a176a8b37eeaef880))
 - **FEAT**(flame_3d): initial implementation of 3D support ([#3012](https://github.com/flame-engine/flame/issues/3012)). ([acb8e6fc](https://github.com/flame-engine/flame/commit/acb8e6fc07592a7df041512ed9e033b33eda8799))
 - **FEAT**: Support skeletal animation basics [flame_3d]  ([#3291](https://github.com/flame-engine/flame/issues/3291)). ([9c0d1500](https://github.com/flame-engine/flame/commit/9c0d15006047597097dc0e054c1e03a04491cff9))
 - **FEAT**: Add normals to surfaces when not specified ([#3257](https://github.com/flame-engine/flame/issues/3257)). ([1dd21d7d](https://github.com/flame-engine/flame/commit/1dd21d7d6d4f58c9ac54a38363ee2fd0978a9d0c))
 - **FEAT**(flame_3d): initial implementation of 3D support ([#3012](https://github.com/flame-engine/flame/issues/3012)). ([0242e1dd](https://github.com/flame-engine/flame/commit/0242e1dd12a9b50a411d895b662f9df33536f6d9))
 - **FEAT**: Support skeletal animation basics [flame_3d]  ([#3291](https://github.com/flame-engine/flame/issues/3291)). ([12927e41](https://github.com/flame-engine/flame/commit/12927e4100a7b4b46e4218db6792d25be1623f88))
 - **FEAT**: Add more useful extensions to VectorN and Quaternion [flame_3d] ([#3296](https://github.com/flame-engine/flame/issues/3296)). ([9cb95279](https://github.com/flame-engine/flame/commit/9cb9527909a4faa38609d25ebd7463f1e2e1a1ab))
 - **FEAT**: Make it easier work with the Mesh class [flame_3d] ([#3212](https://github.com/flame-engine/flame/issues/3212)). ([ebf2ee62](https://github.com/flame-engine/flame/commit/ebf2ee62e535fd1d0f499112b314e1d88e59bbc1))
 - **FEAT**: More Lights! [flame_3d] ([#3250](https://github.com/flame-engine/flame/issues/3250)). ([1780630e](https://github.com/flame-engine/flame/commit/1780630e7fcb386a331ba1219c15cb1ae8b139e6))
 - **FEAT**: Add normals to surfaces when not specified ([#3257](https://github.com/flame-engine/flame/issues/3257)). ([844c1d72](https://github.com/flame-engine/flame/commit/844c1d726e04e9c3c5739214720cf26fc62d3f9f))
 - **FEAT**(flame_3d): Fix minor nits on flame_3d ([#3140](https://github.com/flame-engine/flame/issues/3140)). ([11cdfb5e](https://github.com/flame-engine/flame/commit/11cdfb5ebeb62dd1aec2d51fd7fadfbfb17c6da5))
 - **FEAT**: Expose vector classes on core file [flame_3d] ([#3211](https://github.com/flame-engine/flame/issues/3211)). ([c3e68dff](https://github.com/flame-engine/flame/commit/c3e68dffd2e53a8dc8d4d3804c47e956dfc0ebb4))
 - **FEAT**(flame_3d): Fix minor nits on flame_3d ([#3140](https://github.com/flame-engine/flame/issues/3140)). ([b537d20a](https://github.com/flame-engine/flame/commit/b537d20ab65ce0312e9c05ba9156d794234d93e0))
 - **FEAT**: Make it easier work with the Mesh class [flame_3d] ([#3212](https://github.com/flame-engine/flame/issues/3212)). ([7f80b530](https://github.com/flame-engine/flame/commit/7f80b53078c037f81d386a44fa9b749cf7835ffa))
 - **DOCS**: Update docs and comments (flame_3d) ([#3057](https://github.com/flame-engine/flame/issues/3057)). ([14047879](https://github.com/flame-engine/flame/commit/14047879a13e1f13e51ce3411feb7c7962d6d7ee))
 - **DOCS**: Update docs and comments (flame_3d) ([#3057](https://github.com/flame-engine/flame/issues/3057)). ([b5fd457a](https://github.com/flame-engine/flame/commit/b5fd457a6b6bcad73006fc77a538c7e8521178a5))
 - **DOCS**: Update README.md docs to reflect current state of affairs ([#3305](https://github.com/flame-engine/flame/issues/3305)). ([ac3f48ff](https://github.com/flame-engine/flame/commit/ac3f48ffa6527c595035e8a9cc24307343dacb31))
 - **DOCS**: Update wording on README to match newer instructions [flame_3d] ([#3399](https://github.com/flame-engine/flame/issues/3399)). ([9c416cbf](https://github.com/flame-engine/flame/commit/9c416cbfcb4106ab7b1ad14324ca9cb89593b80d))
 - **DOCS**: Update README.md docs to reflect current state of affairs ([#3305](https://github.com/flame-engine/flame/issues/3305)). ([be72daee](https://github.com/flame-engine/flame/commit/be72daee6b92bcef2af3af78c1f64abe94c49d18))
 - **BREAKING** **FEAT**: Allow for custom shaders and materials ([#3384](https://github.com/flame-engine/flame/issues/3384)). ([ae731814](https://github.com/flame-engine/flame/commit/ae73181466c7e32b0e5e9e814f5170310c20f263))
 - **BREAKING** **FEAT**: Refactor the `CameraComponent3D` ([#3394](https://github.com/flame-engine/flame/issues/3394)). ([4a61718d](https://github.com/flame-engine/flame/commit/4a61718d3b8d45d18a74f662f1bf1eb8e6069983))

## 0.1.0-dev.3

 - **FIX**: Improve behavior of Quaternion.slerp function [flame_3d] ([#3306](https://github.com/flame-engine/flame/issues/3306)). ([b9d6a0f1](https://github.com/flame-engine/flame/commit/b9d6a0f1d34e009cd91ae9d2ab0eed09b546d110))
 - **DOCS**: Update README.md docs to reflect current state of affairs ([#3305](https://github.com/flame-engine/flame/issues/3305)). ([be72daee](https://github.com/flame-engine/flame/commit/be72daee6b92bcef2af3af78c1f64abe94c49d18))

## 0.1.0-dev.2

 - **FIX**: Improve quaternion slerp logic to avoid NaN edge cases ([#3303](https://github.com/flame-engine/flame/issues/3303)). ([565b68b9](https://github.com/flame-engine/flame/commit/565b68b9da52d44281e93f9ae8617f9dbe9551f3))
 - **FIX**: MeshComponent.bind should bind to the provided device ([#3278](https://github.com/flame-engine/flame/issues/3278)). ([3ae3ef54](https://github.com/flame-engine/flame/commit/3ae3ef5476fa5f9ead7069efeee35cc31c0e9dd2))
 - **FIX**: Add missing export for CylinderMesh [flame_3d] ([#3256](https://github.com/flame-engine/flame/issues/3256)). ([d517c169](https://github.com/flame-engine/flame/commit/d517c169ed9b4d4457df6ac1ae363277577597fa))
 - **FIX**: Fix typo on loadTexture ([#3253](https://github.com/flame-engine/flame/issues/3253)). ([3a20a8cd](https://github.com/flame-engine/flame/commit/3a20a8cd61543aad21c1015de5c31ec1cbe71aed))
 - **FIX**: Use saner default value for camera's target ([#3238](https://github.com/flame-engine/flame/issues/3238)). ([78522c62](https://github.com/flame-engine/flame/commit/78522c624d846c827a1c0d7377837e04a30ba4e7))
 - **FIX**: Revert "feat(flame_3d): initial implementation of 3D support" ([#3060](https://github.com/flame-engine/flame/issues/3060)). ([741d9384](https://github.com/flame-engine/flame/commit/741d9384dbfea7bb692f181a7689a7b10a947ef0))
 - **FEAT**: Support skeletal animation basics [flame_3d]  ([#3291](https://github.com/flame-engine/flame/issues/3291)). ([12927e41](https://github.com/flame-engine/flame/commit/12927e4100a7b4b46e4218db6792d25be1623f88))
 - **FEAT**: Add more useful extensions to VectorN and Quaternion [flame_3d] ([#3296](https://github.com/flame-engine/flame/issues/3296)). ([9cb95279](https://github.com/flame-engine/flame/commit/9cb9527909a4faa38609d25ebd7463f1e2e1a1ab))
 - **FEAT**: More Lights! [flame_3d] ([#3250](https://github.com/flame-engine/flame/issues/3250)). ([1780630e](https://github.com/flame-engine/flame/commit/1780630e7fcb386a331ba1219c15cb1ae8b139e6))
 - **FEAT**: Add normals to surfaces when not specified ([#3257](https://github.com/flame-engine/flame/issues/3257)). ([844c1d72](https://github.com/flame-engine/flame/commit/844c1d726e04e9c3c5739214720cf26fc62d3f9f))
 - **FEAT**: Add CylinderMesh [flame_3d] ([#3239](https://github.com/flame-engine/flame/issues/3239)). ([01872fb6](https://github.com/flame-engine/flame/commit/01872fb6e45e10dc380fee7a176a8b37eeaef880))
 - **FEAT**(flame_3d): Make shader api more useful ([#3085](https://github.com/flame-engine/flame/issues/3085)). ([fe2e4f20](https://github.com/flame-engine/flame/commit/fe2e4f20195b453268b34e589616343fdce6201a))
 - **FEAT**: Make it easier work with the Mesh class [flame_3d] ([#3212](https://github.com/flame-engine/flame/issues/3212)). ([ebf2ee62](https://github.com/flame-engine/flame/commit/ebf2ee62e535fd1d0f499112b314e1d88e59bbc1))
 - **FEAT**: Expose vector classes on core file [flame_3d] ([#3211](https://github.com/flame-engine/flame/issues/3211)). ([c3e68dff](https://github.com/flame-engine/flame/commit/c3e68dffd2e53a8dc8d4d3804c47e956dfc0ebb4))
 - **FEAT**(flame_3d): Add helpful extension functions to Vector ([#3141](https://github.com/flame-engine/flame/issues/3141)). ([92195989](https://github.com/flame-engine/flame/commit/9219598904131d8fceba8d1ad980bea2805e3515))
 - **FEAT**(flame_3d): Fix minor nits on flame_3d ([#3140](https://github.com/flame-engine/flame/issues/3140)). ([11cdfb5e](https://github.com/flame-engine/flame/commit/11cdfb5ebeb62dd1aec2d51fd7fadfbfb17c6da5))
 - **FEAT**(flame_3d): initial implementation of 3D support ([#3012](https://github.com/flame-engine/flame/issues/3012)). ([0242e1dd](https://github.com/flame-engine/flame/commit/0242e1dd12a9b50a411d895b662f9df33536f6d9))
 - **FEAT**(flame_3d): initial implementation of 3D support ([#3012](https://github.com/flame-engine/flame/issues/3012)). ([e434bafb](https://github.com/flame-engine/flame/commit/e434bafb15fc486c51b43aaa9d9190b8b7e783cb))
 - **DOCS**: Update docs and comments (flame_3d) ([#3057](https://github.com/flame-engine/flame/issues/3057)). ([14047879](https://github.com/flame-engine/flame/commit/14047879a13e1f13e51ce3411feb7c7962d6d7ee))

## 0.1.0-dev.1

- Initial experimental release of `flame_3d`.
