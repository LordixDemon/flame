/// Spatial audio parameters for 3D scenes: listeners, sound emitters, reverb
/// zones and a voice mixer that compute gain, pan, pitch, low-pass cutoff and
/// reverb values every update. Nothing here plays sound: an
/// `AudioVoiceBackend3D` written for an audio engine does.
library;

export 'src/audio/spatial_audio_3d.dart';
export 'src/audio/spatial_audio_mixer_3d.dart';
