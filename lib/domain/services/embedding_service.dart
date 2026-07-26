import 'package:dio/dio.dart';
import 'package:native_tavern/data/models/vector_storage.dart';

/// Generates text embeddings for RAG / vector storage.
///
/// Supports OpenAI-compatible endpoints (OpenAI, SiliconFlow, custom),
/// Cohere, Google Gemini, and Ollama's /api/embed.
class EmbeddingService {
  final Dio _dio = Dio();

  /// Embed a single text
  Future<List<double>> embed(
    String text,
    VectorStorageSettings settings,
  ) async {
    final results = await embedBatch([text], settings);
    return results.first;
  }

  /// Embed a batch of texts
  Future<List<List<double>>> embedBatch(
    List<String> texts,
    VectorStorageSettings settings,
  ) async {
    if (texts.isEmpty) return [];

    switch (settings.embeddingProvider) {
      case EmbeddingProvider.openai:
      case EmbeddingProvider.siliconflow:
      case EmbeddingProvider.custom:
        return _embedOpenAICompatible(texts, settings);
      case EmbeddingProvider.cohere:
        return _embedCohere(texts, settings);
      case EmbeddingProvider.gemini:
        return _embedGemini(texts, settings);
      case EmbeddingProvider.ollama:
        return _embedOllama(texts, settings);
      case EmbeddingProvider.local:
        throw UnsupportedError(
            'On-device embeddings are not available yet. '
            'Use Ollama or a cloud provider.');
    }
  }

  String _endpoint(VectorStorageSettings settings) {
    final endpoint = settings.embeddingEndpoint;
    if (endpoint != null && endpoint.isNotEmpty) return endpoint;
    return settings.embeddingProvider.defaultEndpoint;
  }

  String _model(VectorStorageSettings settings) {
    final model = settings.embeddingModel;
    if (model != null && model.isNotEmpty) return model;
    return settings.embeddingProvider.defaultModel;
  }

  Future<List<List<double>>> _embedOpenAICompatible(
    List<String> texts,
    VectorStorageSettings settings,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '${_endpoint(settings)}/embeddings',
      options: Options(headers: {
        'Authorization': 'Bearer ${settings.embeddingApiKey ?? ''}',
        'Content-Type': 'application/json',
      }),
      data: {
        'model': _model(settings),
        'input': texts,
      },
    );
    final data = response.data?['data'] as List<dynamic>? ?? [];
    // Preserve input order via the index field
    final results =
        List<List<double>>.filled(texts.length, const [], growable: false);
    for (final item in data) {
      final map = item as Map<String, dynamic>;
      final index = map['index'] as int? ?? 0;
      final embedding = (map['embedding'] as List<dynamic>)
          .map((e) => (e as num).toDouble())
          .toList();
      if (index < results.length) results[index] = embedding;
    }
    return results;
  }

  Future<List<List<double>>> _embedCohere(
    List<String> texts,
    VectorStorageSettings settings,
  ) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '${_endpoint(settings)}/v1/embed',
      options: Options(headers: {
        'Authorization': 'Bearer ${settings.embeddingApiKey ?? ''}',
        'Content-Type': 'application/json',
      }),
      data: {
        'model': _model(settings),
        'texts': texts,
        'input_type': 'search_document',
      },
    );
    final embeddings = response.data?['embeddings'] as List<dynamic>? ?? [];
    return embeddings
        .map((e) => (e as List<dynamic>)
            .map((v) => (v as num).toDouble())
            .toList())
        .toList();
  }

  Future<List<List<double>>> _embedGemini(
    List<String> texts,
    VectorStorageSettings settings,
  ) async {
    final model = _model(settings);
    final response = await _dio.post<Map<String, dynamic>>(
      '${_endpoint(settings)}/models/$model:batchEmbedContents'
      '?key=${settings.embeddingApiKey ?? ''}',
      options: Options(headers: {'Content-Type': 'application/json'}),
      data: {
        'requests': texts
            .map((t) => {
                  'model': 'models/$model',
                  'content': {
                    'parts': [
                      {'text': t}
                    ]
                  },
                })
            .toList(),
      },
    );
    final embeddings = response.data?['embeddings'] as List<dynamic>? ?? [];
    return embeddings
        .map((e) => ((e as Map<String, dynamic>)['values'] as List<dynamic>)
            .map((v) => (v as num).toDouble())
            .toList())
        .toList();
  }

  Future<List<List<double>>> _embedOllama(
    List<String> texts,
    VectorStorageSettings settings,
  ) async {
    // Ollama's /api/embed accepts batched input (ST migrated to this)
    final response = await _dio.post<Map<String, dynamic>>(
      '${_endpoint(settings)}/api/embed',
      options: Options(headers: {'Content-Type': 'application/json'}),
      data: {
        'model': _model(settings),
        'input': texts,
      },
    );
    final embeddings = response.data?['embeddings'] as List<dynamic>? ?? [];
    return embeddings
        .map((e) => (e as List<dynamic>)
            .map((v) => (v as num).toDouble())
            .toList())
        .toList();
  }
}
