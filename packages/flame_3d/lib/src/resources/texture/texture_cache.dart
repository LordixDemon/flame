import 'package:flame/cache.dart';
import 'package:flame_3d/src/resources/texture/image_texture.dart';
import 'package:flame_3d/src/resources/texture/texture.dart';

extension TextureCache on Images {
  Future<Texture> loadTexture(String path) {
    return load(path).then(ImageTexture.create);
  }
}
