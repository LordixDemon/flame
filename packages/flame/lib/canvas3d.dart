/// Impeller-native 3D camera projection, Möller–Trumbore raycasting, procedural
/// MatCap shaders, and Struct-of-Arrays 3D particle batching on Flutter's
/// standard `Canvas` (`drawVertices`) without requiring `--enable-flutter-gpu`.
library;

export 'src/canvas3d/batch_mesh_renderer_3d.dart';
export 'src/canvas3d/camera_rig_3d.dart';
export 'src/canvas3d/matcap_shader_3d.dart';
export 'src/canvas3d/mesh_3d.dart';
export 'src/canvas3d/particle_pool_3d.dart';
export 'src/canvas3d/raycast_3d.dart';
export 'src/canvas3d/spatial_hit_testing_3d.dart';
