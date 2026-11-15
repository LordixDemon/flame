/// Impeller-native 3D camera projection, Möller–Trumbore raycasting, procedural
/// MatCap shaders, multi-material depth-sorted mesh batching, quaternion/morph/
/// skeletal deformation, volumetric 3D billowing fog, and Struct-of-Arrays 3D
/// particle batching on Flutter's standard `Canvas` (`drawVertices` /
/// `drawRawAtlas`) without requiring `--enable-flutter-gpu`.
library;

export 'src/canvas3d/animation_3d.dart';
export 'src/canvas3d/batch_mesh_renderer_3d.dart';
export 'src/canvas3d/camera_rig_3d.dart';
export 'src/canvas3d/decal_3d.dart';
export 'src/canvas3d/matcap_shader_3d.dart';
export 'src/canvas3d/material_3d.dart';
export 'src/canvas3d/mesh_3d.dart';
export 'src/canvas3d/mesh_bvh_3d.dart';
export 'src/canvas3d/mesh_lod_chain_3d.dart';
export 'src/canvas3d/morph_mesh_3d.dart';
export 'src/canvas3d/node_3d.dart';
export 'src/canvas3d/particle_pool_3d.dart';
export 'src/canvas3d/primitives_3d.dart';
export 'src/canvas3d/quaternion_3d.dart';
export 'src/canvas3d/raycast_3d.dart';
export 'src/canvas3d/scene_environment_3d.dart';
export 'src/canvas3d/skinned_mesh_3d.dart';
export 'src/canvas3d/spatial_hit_testing_3d.dart';
export 'src/canvas3d/sprite_billboard_3d.dart';
export 'src/canvas3d/static_mesh_chunk_3d.dart';
export 'src/canvas3d/volumetric_fog_3d.dart';
