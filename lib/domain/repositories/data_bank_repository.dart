import 'package:native_tavern/data/models/data_bank.dart';

/// Persistence boundary for Data Bank document metadata.
abstract interface class DataBankDocumentRepository {
  Future<DataBankDocument?> getDocument(String documentId);

  Future<List<DataBankDocument>> listDocuments({bool includeDeleted = false});

  Future<void> saveDocument(DataBankDocument document);
}

/// Persistence boundary for immutable source versions of a document.
abstract interface class DataBankVersionRepository {
  Future<DataBankDocumentVersion?> getVersion(String versionId);

  Future<List<DataBankDocumentVersion>> listVersions(String documentId);

  Future<void> saveVersion(DataBankDocumentVersion version);
}

/// Persistence boundary for parsed sections and their source locations.
abstract interface class DataBankSectionRepository {
  Future<List<DataBankSection>> listSections(String documentVersionId);

  Future<void> replaceSections(
    String documentVersionId,
    List<DataBankSection> sections,
  );
}

/// Persistence boundary for citation-preserving source text chunks.
abstract interface class DataBankChunkRepository {
  Future<DataBankTextChunk?> getChunk(String chunkId);

  Future<List<DataBankTextChunk>> listChunks(String documentVersionId);

  Future<void> replaceChunks(
    String documentVersionId,
    List<DataBankTextChunk> chunks,
  );
}

/// Persistence boundary for global, character, and chat bindings.
abstract interface class DataBankBindingRepository {
  Future<List<DataBankBinding>> listBindingsForDocument(
    String documentId, {
    bool includeDisabled = false,
  });

  Future<List<DataBankBinding>> listBindingsForScope(
    DataBankBindingScope scope, {
    String? targetId,
    bool includeDisabled = false,
  });

  Future<void> saveBinding(DataBankBinding binding);

  Future<void> deleteBinding(String bindingId);
}

/// Atomic lifecycle operations that coordinate document and version records.
///
/// Implementations must reject transitions that fail
/// [DataBankProcessingStateTransitions.canTransitionTo]. Replacing a version
/// must preserve the previous version and atomically update the document's
/// current version pointer.
abstract interface class DataBankLifecycleRepository {
  Future<void> replaceCurrentVersion({
    required String documentId,
    required String expectedCurrentVersionId,
    required DataBankDocumentVersion replacement,
  });

  Future<void> transitionDocument({
    required String documentId,
    required DataBankProcessingState from,
    required DataBankProcessingState to,
    DataBankFailure? failure,
  });

  Future<void> transitionVersion({
    required String versionId,
    required DataBankProcessingState from,
    required DataBankProcessingState to,
    DataBankFailure? failure,
  });

  Future<void> requestReprocessing({
    required String documentId,
    required String versionId,
    required String reason,
    required DateTime requestedAt,
  });

  Future<void> setDocumentEnabled(String documentId, bool enabled);

  Future<void> markDocumentDeleted(String documentId);
}
