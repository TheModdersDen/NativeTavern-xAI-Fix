import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// TTS Provider types
enum TTSProvider {
  system('system', 'System TTS'),
  elevenlabs('elevenlabs', 'ElevenLabs'),
  azure('azure', 'Azure Speech'),
  volcengine('volcengine', 'Volcengine (火山引擎)'),
  gptSovits('gpt_sovits', 'GPT-SoVITS'),
  openaiCompatible('openai_compatible', 'OpenAI Compatible'),
  ;

  final String id;
  final String displayName;

  const TTSProvider(this.id, this.displayName);

  static TTSProvider? fromId(String id) {
    try {
      return TTSProvider.values.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }
}

/// TTS Voice configuration
class TTSVoice {
  final String id;
  final String name;
  final String? language;
  final String? gender;
  final TTSProvider provider;

  const TTSVoice({
    required this.id,
    required this.name,
    this.language,
    this.gender,
    required this.provider,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'language': language,
        'gender': gender,
        'provider': provider.id,
      };

  factory TTSVoice.fromJson(Map<String, dynamic> json) => TTSVoice(
        id: json['id'] as String,
        name: json['name'] as String,
        language: json['language'] as String?,
        gender: json['gender'] as String?,
        provider: TTSProvider.fromId(json['provider'] as String) ?? TTSProvider.system,
      );
}

/// TTS Settings
class TTSSettings {
  final bool enabled;
  final TTSProvider provider;
  final String? voiceId;
  final double rate;
  final double pitch;
  final double volume;
  final bool autoPlay;
  final bool queueMessages;
  final String? apiKey;
  final String? apiEndpoint;

  /// Provider-specific extras (e.g. Volcengine appId/cluster,
  /// GPT-SoVITS reference audio settings, OpenAI-compatible model name)
  final Map<String, String> providerOptions;

  const TTSSettings({
    this.enabled = false,
    this.provider = TTSProvider.system,
    this.voiceId,
    this.rate = 1.0,
    this.pitch = 1.0,
    this.volume = 1.0,
    this.autoPlay = false,
    this.queueMessages = true,
    this.apiKey,
    this.apiEndpoint,
    this.providerOptions = const {},
  });

  TTSSettings copyWith({
    bool? enabled,
    TTSProvider? provider,
    String? voiceId,
    double? rate,
    double? pitch,
    double? volume,
    bool? autoPlay,
    bool? queueMessages,
    String? apiKey,
    String? apiEndpoint,
    Map<String, String>? providerOptions,
  }) {
    return TTSSettings(
      enabled: enabled ?? this.enabled,
      provider: provider ?? this.provider,
      voiceId: voiceId ?? this.voiceId,
      rate: rate ?? this.rate,
      pitch: pitch ?? this.pitch,
      volume: volume ?? this.volume,
      autoPlay: autoPlay ?? this.autoPlay,
      queueMessages: queueMessages ?? this.queueMessages,
      apiKey: apiKey ?? this.apiKey,
      apiEndpoint: apiEndpoint ?? this.apiEndpoint,
      providerOptions: providerOptions ?? this.providerOptions,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'provider': provider.id,
        'voiceId': voiceId,
        'rate': rate,
        'pitch': pitch,
        'volume': volume,
        'autoPlay': autoPlay,
        'queueMessages': queueMessages,
        'apiKey': apiKey,
        'apiEndpoint': apiEndpoint,
        'providerOptions': providerOptions,
      };

  factory TTSSettings.fromJson(Map<String, dynamic> json) => TTSSettings(
        enabled: json['enabled'] as bool? ?? false,
        provider: TTSProvider.fromId(json['provider'] as String? ?? 'system') ?? TTSProvider.system,
        voiceId: json['voiceId'] as String?,
        rate: (json['rate'] as num?)?.toDouble() ?? 1.0,
        pitch: (json['pitch'] as num?)?.toDouble() ?? 1.0,
        volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
        autoPlay: json['autoPlay'] as bool? ?? false,
        queueMessages: json['queueMessages'] as bool? ?? true,
        apiKey: json['apiKey'] as String?,
        apiEndpoint: json['apiEndpoint'] as String?,
        providerOptions:
            (json['providerOptions'] as Map<String, dynamic>?)
                    ?.map((k, v) => MapEntry(k, v.toString())) ??
                const {},
      );
}

/// Character voice settings
class CharacterVoiceSettings {
  final String characterId;
  final String? voiceId;
  final double? rate;
  final double? pitch;
  final double? volume;

  const CharacterVoiceSettings({
    required this.characterId,
    this.voiceId,
    this.rate,
    this.pitch,
    this.volume,
  });

  Map<String, dynamic> toJson() => {
        'characterId': characterId,
        'voiceId': voiceId,
        'rate': rate,
        'pitch': pitch,
        'volume': volume,
      };

  factory CharacterVoiceSettings.fromJson(Map<String, dynamic> json) => CharacterVoiceSettings(
        characterId: json['characterId'] as String,
        voiceId: json['voiceId'] as String?,
        rate: (json['rate'] as num?)?.toDouble(),
        pitch: (json['pitch'] as num?)?.toDouble(),
        volume: (json['volume'] as num?)?.toDouble(),
      );
}

/// TTS Service for text-to-speech functionality
class TTSService {
  bool _isInitialized = false;
  bool _isSpeaking = false;
  final List<String> _queue = [];
  TTSSettings _settings = const TTSSettings();
  final Map<String, CharacterVoiceSettings> _characterVoices = {};

  /// System TTS engine
  final FlutterTts _flutterTts = FlutterTts();

  /// Player for remote-synthesized audio
  final AudioPlayer _audioPlayer = AudioPlayer();

  /// Available voices (populated after initialization)
  List<TTSVoice> _availableVoices = [];

  /// Callbacks
  VoidCallback? onStart;
  VoidCallback? onComplete;
  VoidCallback? onCancel;
  void Function(String)? onError;

  bool get isInitialized => _isInitialized;
  bool get isSpeaking => _isSpeaking;
  List<TTSVoice> get availableVoices => _availableVoices;
  TTSSettings get settings => _settings;

  /// Initialize the TTS service
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Make speak() futures complete when playback finishes
      await _flutterTts.awaitSpeakCompletion(true);
      _availableVoices = await _loadSystemVoices();
      if (_availableVoices.isEmpty) {
        _availableVoices = _getDefaultVoices();
      }
      _isInitialized = true;
    } catch (e) {
      // Keep the service usable for remote providers even if the
      // system engine fails to initialize
      _availableVoices = _getDefaultVoices();
      _isInitialized = true;
      onError?.call('Failed to initialize system TTS: $e');
    }
  }

  /// Query real system voices from the platform TTS engine
  Future<List<TTSVoice>> _loadSystemVoices() async {
    final voices = <TTSVoice>[];
    final raw = await _flutterTts.getVoices;
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          final name = item['name']?.toString();
          final locale = item['locale']?.toString();
          if (name == null || name.isEmpty) continue;
          voices.add(TTSVoice(
            id: name,
            name: locale != null ? '$name ($locale)' : name,
            language: locale,
            provider: TTSProvider.system,
          ));
        }
      }
    }
    voices.sort((a, b) => (a.language ?? '').compareTo(b.language ?? ''));
    return voices;
  }

  /// Get default system voices (placeholder)
  List<TTSVoice> _getDefaultVoices() {
    return [
      const TTSVoice(
        id: 'default',
        name: 'Default',
        language: 'en-US',
        gender: 'neutral',
        provider: TTSProvider.system,
      ),
      const TTSVoice(
        id: 'en-us-female',
        name: 'English (US) Female',
        language: 'en-US',
        gender: 'female',
        provider: TTSProvider.system,
      ),
      const TTSVoice(
        id: 'en-us-male',
        name: 'English (US) Male',
        language: 'en-US',
        gender: 'male',
        provider: TTSProvider.system,
      ),
      const TTSVoice(
        id: 'en-gb-female',
        name: 'English (UK) Female',
        language: 'en-GB',
        gender: 'female',
        provider: TTSProvider.system,
      ),
      const TTSVoice(
        id: 'en-gb-male',
        name: 'English (UK) Male',
        language: 'en-GB',
        gender: 'male',
        provider: TTSProvider.system,
      ),
    ];
  }

  /// Update settings
  void updateSettings(TTSSettings settings) {
    _settings = settings;
  }

  /// Set character voice settings
  void setCharacterVoice(CharacterVoiceSettings voiceSettings) {
    _characterVoices[voiceSettings.characterId] = voiceSettings;
  }

  /// Get character voice settings
  CharacterVoiceSettings? getCharacterVoice(String characterId) {
    return _characterVoices[characterId];
  }

  /// Speak text
  Future<void> speak(String text, {String? characterId}) async {
    if (!_isInitialized || !_settings.enabled) return;
    if (text.isEmpty) return;

    // Clean text for TTS (remove markdown, special characters, etc.)
    final cleanText = _cleanTextForTTS(text);
    if (cleanText.isEmpty) return;

    if (_settings.queueMessages) {
      _queue.add(cleanText);
      if (!_isSpeaking) {
        await _processQueue(characterId: characterId);
      }
    } else {
      await stop();
      await _speakText(cleanText, characterId: characterId);
    }
  }

  /// Process the speech queue
  Future<void> _processQueue({String? characterId}) async {
    while (_queue.isNotEmpty) {
      final text = _queue.removeAt(0);
      await _speakText(text, characterId: characterId);
    }
  }

  /// Actually speak the text
  Future<void> _speakText(String text, {String? characterId}) async {
    _isSpeaking = true;
    onStart?.call();

    try {
      // Get voice settings (character-specific or default)
      final charVoice = characterId != null ? _characterVoices[characterId] : null;
      final voiceId = charVoice?.voiceId ?? _settings.voiceId;
      final rate = charVoice?.rate ?? _settings.rate;
      final pitch = charVoice?.pitch ?? _settings.pitch;
      final volume = charVoice?.volume ?? _settings.volume;

      if (_settings.provider == TTSProvider.system) {
        await _speakWithSystemTts(text,
            voiceId: voiceId, rate: rate, pitch: pitch, volume: volume);
      } else {
        await _speakWithRemoteTts(text,
            characterId: characterId, volume: volume);
      }

      onComplete?.call();
    } catch (e) {
      onError?.call('TTS error: $e');
    } finally {
      _isSpeaking = false;
    }
  }

  /// Speak with the platform TTS engine (flutter_tts)
  Future<void> _speakWithSystemTts(
    String text, {
    String? voiceId,
    required double rate,
    required double pitch,
    required double volume,
  }) async {
    // flutter_tts rate range is 0.0-1.0 with ~0.5 as normal speed;
    // our settings use 1.0 as normal, so halve it
    await _flutterTts.setSpeechRate((rate * 0.5).clamp(0.0, 1.0));
    await _flutterTts.setPitch(pitch.clamp(0.5, 2.0));
    await _flutterTts.setVolume(volume.clamp(0.0, 1.0));

    if (voiceId != null && voiceId.isNotEmpty) {
      final voice = _availableVoices
          .where((v) => v.id == voiceId && v.provider == TTSProvider.system)
          .toList();
      if (voice.isNotEmpty) {
        await _flutterTts.setVoice({
          'name': voice.first.id,
          'locale': voice.first.language ?? 'en-US',
        });
      }
    }

    await _flutterTts.speak(text);
  }

  /// Synthesize remotely and play the returned audio bytes
  Future<void> _speakWithRemoteTts(
    String text, {
    String? characterId,
    required double volume,
  }) async {
    final bytes = await synthesize(text, characterId: characterId);
    if (bytes == null || bytes.isEmpty) {
      throw Exception('TTS provider returned no audio');
    }

    // just_audio plays from files/URLs; write to a temp file
    final dir = await getTemporaryDirectory();
    final file = File(p.join(
        dir.path, 'tts_${DateTime.now().millisecondsSinceEpoch}.audio'));
    await file.writeAsBytes(bytes);

    try {
      await _audioPlayer.setVolume(volume.clamp(0.0, 1.0));
      await _audioPlayer.setFilePath(file.path);
      await _audioPlayer.play();
      await _audioPlayer.stop();
    } finally {
      // Best-effort temp cleanup
      file.delete().catchError((_) => file);
    }
  }

  /// Stop speaking
  Future<void> stop() async {
    _queue.clear();
    if (_isSpeaking) {
      _isSpeaking = false;
      onCancel?.call();
    }
    try {
      await _flutterTts.stop();
      await _audioPlayer.stop();
    } catch (_) {
      // Stopping is best-effort
    }
  }

  /// Pause speaking
  Future<void> pause() async {
    try {
      await _flutterTts.pause();
      await _audioPlayer.pause();
    } catch (_) {}
  }

  /// Resume speaking
  Future<void> resume() async {
    try {
      await _audioPlayer.play();
    } catch (_) {}
  }

  /// Clean text for TTS
  String _cleanTextForTTS(String text) {
    var cleaned = text;

    // Remove markdown formatting
    cleaned = cleaned.replaceAll(RegExp(r'\*\*([^*]+)\*\*'), r'$1'); // Bold
    cleaned = cleaned.replaceAll(RegExp(r'\*([^*]+)\*'), r'$1'); // Italic
    cleaned = cleaned.replaceAll(RegExp(r'__([^_]+)__'), r'$1'); // Underline
    cleaned = cleaned.replaceAll(RegExp(r'~~([^~]+)~~'), r'$1'); // Strikethrough
    cleaned = cleaned.replaceAll(RegExp(r'`([^`]+)`'), r'$1'); // Code
    cleaned = cleaned.replaceAll(RegExp(r'```[^`]*```'), ''); // Code blocks

    // Remove links but keep text
    cleaned = cleaned.replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1');

    // Remove HTML tags
    cleaned = cleaned.replaceAll(RegExp(r'<[^>]+>'), '');

    // Remove action markers but keep content
    cleaned = cleaned.replaceAll(RegExp(r'\*([^*]+)\*'), r'$1');

    // Remove multiple spaces
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ');

    // Remove leading/trailing whitespace
    cleaned = cleaned.trim();

    return cleaned;
  }

  // ==================== Remote synthesis ====================

  final Dio _dio = Dio();

  /// Synthesize [text] to audio bytes with the configured remote provider.
  /// Returns null for providers without a remote API (system TTS).
  /// Playback is handled by the caller once an audio player is available.
  Future<Uint8List?> synthesize(String text, {String? characterId}) async {
    final charVoice =
        characterId != null ? _characterVoices[characterId] : null;
    final voiceId = charVoice?.voiceId ?? _settings.voiceId;

    switch (_settings.provider) {
      case TTSProvider.system:
        return null;
      case TTSProvider.elevenlabs:
        return _synthesizeElevenLabs(text, voiceId);
      case TTSProvider.azure:
        return _synthesizeAzure(text, voiceId);
      case TTSProvider.volcengine:
        return _synthesizeVolcengine(text, voiceId);
      case TTSProvider.gptSovits:
        return _synthesizeGptSovits(text, voiceId);
      case TTSProvider.openaiCompatible:
        return _synthesizeOpenAICompatible(text, voiceId);
    }
  }

  Future<Uint8List?> _synthesizeElevenLabs(
      String text, String? voiceId) async {
    final endpoint = _settings.apiEndpoint ?? 'https://api.elevenlabs.io';
    final voice = voiceId ?? '21m00Tcm4TlvDq8ikWAM';
    final response = await _dio.post<List<int>>(
      '$endpoint/v1/text-to-speech/$voice',
      options: Options(
        headers: {
          'xi-api-key': _settings.apiKey ?? '',
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.bytes,
      ),
      data: {
        'text': text,
        'model_id':
            _settings.providerOptions['model'] ?? 'eleven_multilingual_v2',
      },
    );
    return response.data != null ? Uint8List.fromList(response.data!) : null;
  }

  Future<Uint8List?> _synthesizeAzure(String text, String? voiceId) async {
    final region = _settings.providerOptions['region'] ?? 'eastus';
    final endpoint = _settings.apiEndpoint ??
        'https://$region.tts.speech.microsoft.com';
    final voice = voiceId ?? 'en-US-JennyNeural';
    final ssml =
        '<speak version="1.0" xml:lang="en-US"><voice name="$voice">'
        '${_escapeXml(text)}</voice></speak>';
    final response = await _dio.post<List<int>>(
      '$endpoint/cognitiveservices/v1',
      options: Options(
        headers: {
          'Ocp-Apim-Subscription-Key': _settings.apiKey ?? '',
          'Content-Type': 'application/ssml+xml',
          'X-Microsoft-OutputFormat': 'audio-24khz-96kbitrate-mono-mp3',
        },
        responseType: ResponseType.bytes,
      ),
      data: ssml,
    );
    return response.data != null ? Uint8List.fromList(response.data!) : null;
  }

  /// Volcengine (火山引擎) TTS - openspeech binary API
  Future<Uint8List?> _synthesizeVolcengine(
      String text, String? voiceId) async {
    final endpoint = _settings.apiEndpoint ??
        'https://openspeech.bytedance.com/api/v1/tts';
    final appId = _settings.providerOptions['appId'] ?? '';
    final cluster =
        _settings.providerOptions['cluster'] ?? 'volcano_tts';
    final response = await _dio.post<Map<String, dynamic>>(
      endpoint,
      options: Options(
        headers: {
          'Authorization': 'Bearer;${_settings.apiKey ?? ''}',
          'Content-Type': 'application/json',
        },
      ),
      data: {
        'app': {'appid': appId, 'cluster': cluster},
        'user': {'uid': 'native_tavern'},
        'audio': {
          'voice_type': voiceId ?? 'BV001_streaming',
          'encoding': 'mp3',
          'speed_ratio': _settings.rate,
          'volume_ratio': _settings.volume,
          'pitch_ratio': _settings.pitch,
        },
        'request': {
          'reqid': DateTime.now().millisecondsSinceEpoch.toString(),
          'text': text,
          'operation': 'query',
        },
      },
    );
    // Response carries base64 audio in the `data` field
    final b64 = response.data?['data'] as String?;
    if (b64 == null || b64.isEmpty) return null;
    return Uint8List.fromList(const Base64Decoder().convert(b64));
  }

  /// GPT-SoVITS local inference server (api_v2 style)
  Future<Uint8List?> _synthesizeGptSovits(
      String text, String? voiceId) async {
    final endpoint = _settings.apiEndpoint ?? 'http://127.0.0.1:9880';
    final options = _settings.providerOptions;
    final response = await _dio.post<List<int>>(
      '$endpoint/tts',
      options: Options(responseType: ResponseType.bytes),
      data: {
        'text': text,
        'text_lang': options['textLang'] ?? 'zh',
        'ref_audio_path': options['refAudioPath'] ?? '',
        'prompt_text': options['promptText'] ?? '',
        'prompt_lang': options['promptLang'] ?? 'zh',
        'media_type': 'wav',
        'speed_factor': _settings.rate,
      },
    );
    return response.data != null ? Uint8List.fromList(response.data!) : null;
  }

  /// OpenAI-compatible /v1/audio/speech endpoint
  Future<Uint8List?> _synthesizeOpenAICompatible(
      String text, String? voiceId) async {
    final endpoint = _settings.apiEndpoint ?? 'https://api.openai.com/v1';
    final response = await _dio.post<List<int>>(
      '$endpoint/audio/speech',
      options: Options(
        headers: {
          'Authorization': 'Bearer ${_settings.apiKey ?? ''}',
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.bytes,
      ),
      data: {
        'model': _settings.providerOptions['model'] ?? 'tts-1',
        'input': text,
        'voice': voiceId ?? 'alloy',
        'speed': _settings.rate,
      },
    );
    return response.data != null ? Uint8List.fromList(response.data!) : null;
  }

  String _escapeXml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// Preview voice with sample text
  Future<void> previewVoice(String voiceId, {String? sampleText}) async {
    final text = sampleText ?? 'Hello! This is a preview of the selected voice.';
    final originalVoice = _settings.voiceId;
    
    _settings = _settings.copyWith(voiceId: voiceId);
    await _speakText(text);
    _settings = _settings.copyWith(voiceId: originalVoice);
  }

  /// Dispose the service
  void dispose() {
    stop();
    _audioPlayer.dispose();
    _isInitialized = false;
  }
}