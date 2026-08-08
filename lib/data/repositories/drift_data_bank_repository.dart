import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:native_tavern/data/database/database.dart';
import 'package:native_tavern/data/models/data_bank.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';

final class DriftDataBankRepository
    implements
        DataBankDocumentRepository,
        DataBankVersionRepository,
        DataBankSectionRepository,
        DataBankChunkRepository,
        DataBankBindingRepository,
        DataBankLifecycleRepository {
  const DriftDataBankRepository(this._database);

  final AppDatabase _database;

  @override
  Future<DataBankDocument?> getDocument(String documentId) async {
    final row = await (_database.select(_database.dataBankDocuments)
          ..where(
            (table) =>
                table.id.equals(documentId) & table.isPlaceholder.equals(false),
          ))
        .getSingleOrNull();
    return row == null ? null : _documentFromRow(row);
  }

  @override
  Future<List<DataBankDocument>> listDocuments({
    bool includeDeleted = false,
  }) async {
    final query = _database.select(_database.dataBankDocuments)
      ..where((table) => table.isPlaceholder.equals(false));
    if (!includeDeleted) {
      query.where(
        (table) => table.processingState
            .isNotValue(DataBankProcessingState.deleted.name),
      );
    }
    query.orderBy([(table) => OrderingTerm.asc(table.id)]);
    return (await query.get()).map(_documentFromRow).toList();
  }

  @override
  Future<void> saveDocument(DataBankDocument document) async {
    final version = await _requireVersion(document.currentVersionId);
    if (version.documentId != document.id) {
      throw ArgumentError('The current version belongs to another document.');
    }
    await _database.into(_database.dataBankDocuments).insertOnConflictUpdate(
          _documentCompanion(document),
        );
  }

  @override
  Future<DataBankDocumentVersion?> getVersion(String versionId) async {
    final row = await (_database.select(_database.dataBankDocumentVersions)
          ..where((table) => table.id.equals(versionId)))
        .getSingleOrNull();
    return row == null ? null : _versionFromRow(row);
  }

  @override
  Future<List<DataBankDocumentVersion>> listVersions(String documentId) async {
    final rows = await (_database.select(_database.dataBankDocumentVersions)
          ..where((table) => table.documentId.equals(documentId))
          ..orderBy([
            (table) => OrderingTerm.asc(table.versionNumber),
            (table) => OrderingTerm.asc(table.id),
          ]))
        .get();
    return rows.map(_versionFromRow).toList();
  }

  @override
  Future<void> saveVersion(DataBankDocumentVersion version) async {
    await _database.transaction(() async {
      final existingDocument = await (_database.select(
        _database.dataBankDocuments,
      )..where((table) => table.id.equals(version.documentId)))
          .getSingleOrNull();
      if (existingDocument == null) {
        await _database.into(_database.dataBankDocuments).insert(
              DataBankDocumentsCompanion.insert(
                id: version.documentId,
                currentVersionId: const Value(null),
                processingState: DataBankProcessingState.pending.name,
                indexState: DataBankIndexState.notIndexed.name,
                reprocessingJson:
                    jsonEncode(DataBankReprocessingMetadata().toJson()),
                createdAt: version.importedAt,
                updatedAt: version.importedAt,
                isPlaceholder: const Value(true),
              ),
            );
      }
      await _writeVersion(version);
      if (existingDocument == null || existingDocument.isPlaceholder) {
        await (_database.update(_database.dataBankDocuments)
              ..where((table) => table.id.equals(version.documentId)))
            .write(
          DataBankDocumentsCompanion(
            currentVersionId: Value(version.id),
          ),
        );
      }
    });
  }

  @override
  Future<List<DataBankSection>> listSections(String documentVersionId) async {
    final rows = await (_database.select(_database.dataBankSections)
          ..where(
            (table) => table.documentVersionId.equals(documentVersionId),
          )
          ..orderBy([
            (table) => OrderingTerm.asc(table.ordinal),
            (table) => OrderingTerm.asc(table.id),
          ]))
        .get();
    return rows.map(_sectionFromRow).toList();
  }

  @override
  Future<void> replaceSections(
    String documentVersionId,
    List<DataBankSection> sections,
  ) async {
    await _requireVersion(documentVersionId);
    if (sections.any(
      (section) => section.documentVersionId != documentVersionId,
    )) {
      throw ArgumentError('Every section must belong to $documentVersionId.');
    }
    await _database.transaction(() async {
      await (_database.delete(_database.dataBankSections)
            ..where(
              (table) => table.documentVersionId.equals(documentVersionId),
            ))
          .go();
      for (final section in sections) {
        await _database.into(_database.dataBankSections).insert(
              DataBankSectionsCompanion.insert(
                id: section.id,
                documentVersionId: section.documentVersionId,
                kind: section.kind.name,
                title: Value(section.title),
                ordinal: section.ordinal,
                parentSectionId: Value(section.parentSectionId),
                locatorJson: jsonEncode(section.locator.toJson()),
              ),
            );
      }
    });
  }

  @override
  Future<DataBankTextChunk?> getChunk(String chunkId) async {
    final row = await (_database.select(_database.dataBankTextChunks)
          ..where((table) => table.id.equals(chunkId)))
        .getSingleOrNull();
    return row == null ? null : _chunkFromRow(row);
  }

  @override
  Future<List<DataBankTextChunk>> listChunks(
    String documentVersionId,
  ) async {
    final rows = await (_database.select(_database.dataBankTextChunks)
          ..where(
            (table) => table.documentVersionId.equals(documentVersionId),
          )
          ..orderBy([
            (table) => OrderingTerm.asc(table.ordinal),
            (table) => OrderingTerm.asc(table.id),
          ]))
        .get();
    return rows.map(_chunkFromRow).toList();
  }

  @override
  Future<void> replaceChunks(
    String documentVersionId,
    List<DataBankTextChunk> chunks,
  ) async {
    await _requireVersion(documentVersionId);
    if (chunks.any((chunk) => chunk.documentVersionId != documentVersionId)) {
      throw ArgumentError('Every chunk must belong to $documentVersionId.');
    }
    await _database.transaction(() async {
      await (_database.delete(_database.dataBankTextChunks)
            ..where(
              (table) => table.documentVersionId.equals(documentVersionId),
            ))
          .go();
      for (final chunk in chunks) {
        await _database.into(_database.dataBankTextChunks).insert(
              DataBankTextChunksCompanion.insert(
                id: chunk.id,
                documentVersionId: chunk.documentVersionId,
                sectionId: Value(chunk.sectionId),
                ordinal: chunk.ordinal,
                textContent: chunk.text,
                locatorJson: jsonEncode(chunk.locator.toJson()),
              ),
            );
      }
    });
  }

  @override
  Future<List<DataBankBinding>> listBindingsForDocument(
    String documentId, {
    bool includeDisabled = false,
  }) async {
    final query = _database.select(_database.dataBankBindings)
      ..where((table) => table.documentId.equals(documentId));
    if (!includeDisabled) {
      query.where((table) => table.enabled.equals(true));
    }
    query.orderBy([(table) => OrderingTerm.asc(table.id)]);
    return (await query.get()).map(_bindingFromRow).toList();
  }

  @override
  Future<List<DataBankBinding>> listBindingsForScope(
    DataBankBindingScope scope, {
    String? targetId,
    bool includeDisabled = false,
  }) async {
    if ((scope == DataBankBindingScope.global) != (targetId == null)) {
      throw ArgumentError(
        'Global scope requires no target; other scopes require one.',
      );
    }
    final query = _database.select(_database.dataBankBindings)
      ..where((table) => table.scope.equals(scope.name));
    switch (scope) {
      case DataBankBindingScope.global:
        break;
      case DataBankBindingScope.character:
        query.where((table) => table.characterId.equals(targetId!));
      case DataBankBindingScope.chat:
        query.where((table) => table.chatId.equals(targetId!));
    }
    if (!includeDisabled) {
      query.where((table) => table.enabled.equals(true));
    }
    query.orderBy([(table) => OrderingTerm.asc(table.id)]);
    return (await query.get()).map(_bindingFromRow).toList();
  }

  @override
  Future<void> saveBinding(DataBankBinding binding) async {
    await _requireDocument(binding.documentId);
    await _database.into(_database.dataBankBindings).insertOnConflictUpdate(
          DataBankBindingsCompanion.insert(
            id: binding.id,
            documentId: binding.documentId,
            scope: binding.scope.name,
            characterId: Value(binding.characterId),
            chatId: Value(binding.chatId),
            enabled: Value(binding.enabled),
            createdAt: binding.createdAt,
            updatedAt: binding.updatedAt,
          ),
        );
  }

  @override
  Future<void> deleteBinding(String bindingId) async {
    await (_database.delete(_database.dataBankBindings)
          ..where((table) => table.id.equals(bindingId)))
        .go();
  }

  @override
  Future<void> replaceCurrentVersion({
    required String documentId,
    required String expectedCurrentVersionId,
    required DataBankDocumentVersion replacement,
  }) async {
    await _database.transaction(() async {
      final document = await _requireDocument(documentId);
      final previous = await _requireVersion(expectedCurrentVersionId);
      if (document.currentVersionId != expectedCurrentVersionId) {
        throw StateError('The current version changed before replacement.');
      }
      if (replacement.documentId != documentId ||
          replacement.supersedesVersionId != previous.id ||
          replacement.versionNumber != previous.versionNumber + 1) {
        throw ArgumentError('Replacement version lineage is invalid.');
      }
      await _writeVersion(replacement);
      await saveDocument(
        DataBankDocument(
          id: document.id,
          currentVersionId: replacement.id,
          processingState: replacement.processingState,
          indexState: replacement.indexState,
          failure: replacement.failure,
          reprocessing: replacement.reprocessing,
          createdAt: document.createdAt,
          updatedAt: replacement.importedAt,
        ),
      );
    });
  }

  @override
  Future<void> transitionDocument({
    required String documentId,
    required DataBankProcessingState from,
    required DataBankProcessingState to,
    DataBankFailure? failure,
  }) async {
    final document = await _requireDocument(documentId);
    if (document.processingState != from) {
      throw StateError('Document $documentId is not in ${from.name}.');
    }
    from.validateTransitionTo(to);
    await saveDocument(_transitionedDocument(document, to, failure));
  }

  @override
  Future<void> transitionVersion({
    required String versionId,
    required DataBankProcessingState from,
    required DataBankProcessingState to,
    DataBankFailure? failure,
  }) async {
    final version = await _requireVersion(versionId);
    if (version.processingState != from) {
      throw StateError('Version $versionId is not in ${from.name}.');
    }
    from.validateTransitionTo(to);
    await _writeVersion(_transitionedVersion(version, to, failure));
  }

  @override
  Future<void> requestReprocessing({
    required String documentId,
    required String versionId,
    required String reason,
    required DateTime requestedAt,
  }) async {
    await _database.transaction(() async {
      final document = await _requireDocument(documentId);
      final version = await _requireVersion(versionId);
      if (version.documentId != documentId ||
          document.currentVersionId != versionId) {
        throw ArgumentError('Only the current document version can reprocess.');
      }
      document.processingState.validateTransitionTo(
        DataBankProcessingState.pending,
      );
      version.processingState.validateTransitionTo(
        DataBankProcessingState.pending,
      );
      final metadata = DataBankReprocessingMetadata(
        attemptCount: version.reprocessing.attemptCount + 1,
        requestedAt: requestedAt,
        lastAttemptAt: requestedAt,
        reason: reason,
      );
      await saveDocument(
        DataBankDocument(
          id: document.id,
          currentVersionId: document.currentVersionId,
          processingState: DataBankProcessingState.pending,
          indexState: DataBankIndexState.stale,
          reprocessing: metadata,
          createdAt: document.createdAt,
          updatedAt: requestedAt,
        ),
      );
      await _writeVersion(
        DataBankDocumentVersion(
          id: version.id,
          documentId: version.documentId,
          versionNumber: version.versionNumber,
          supersedesVersionId: version.supersedesVersionId,
          originalFileName: version.originalFileName,
          mediaType: version.mediaType,
          byteSize: version.byteSize,
          contentHash: version.contentHash,
          importedAt: version.importedAt,
          processingState: DataBankProcessingState.pending,
          indexState: DataBankIndexState.stale,
          reprocessing: metadata,
        ),
      );
    });
  }

  @override
  Future<void> setDocumentEnabled(String documentId, bool enabled) async {
    final document = await _requireDocument(documentId);
    if (document.processingState == DataBankProcessingState.deleted) {
      throw StateError('Deleted documents cannot be enabled or disabled.');
    }
    if (enabled == document.isEnabled) return;
    final next = enabled
        ? DataBankProcessingState.pending
        : DataBankProcessingState.disabled;
    document.processingState.validateTransitionTo(next);
    await saveDocument(_transitionedDocument(document, next, null));
  }

  @override
  Future<void> markDocumentDeleted(String documentId) async {
    final document = await _requireDocument(documentId);
    document.processingState.validateTransitionTo(
      DataBankProcessingState.deleted,
    );
    await saveDocument(
      _transitionedDocument(
        document,
        DataBankProcessingState.deleted,
        null,
      ),
    );
  }

  Future<void> _writeVersion(DataBankDocumentVersion version) async {
    await _database
        .into(_database.dataBankDocumentVersions)
        .insertOnConflictUpdate(_versionCompanion(version));
  }

  Future<DataBankDocument> _requireDocument(String id) async {
    final document = await getDocument(id);
    if (document == null) throw StateError('Document $id does not exist.');
    return document;
  }

  Future<DataBankDocumentVersion> _requireVersion(String id) async {
    final version = await getVersion(id);
    if (version == null) throw StateError('Version $id does not exist.');
    return version;
  }
}

DataBankDocumentsCompanion _documentCompanion(DataBankDocument document) {
  return DataBankDocumentsCompanion.insert(
    id: document.id,
    currentVersionId: Value(document.currentVersionId),
    processingState: document.processingState.name,
    indexState: document.indexState.name,
    failureJson: Value(_encodeNullable(document.failure?.toJson())),
    reprocessingJson: jsonEncode(document.reprocessing.toJson()),
    createdAt: document.createdAt,
    updatedAt: document.updatedAt,
    isPlaceholder: const Value(false),
  );
}

DataBankDocument _documentFromRow(DataBankDocumentRow row) {
  final currentVersionId = row.currentVersionId;
  if (currentVersionId == null) {
    throw StateError('Data Bank document ${row.id} has no current version.');
  }
  return DataBankDocument(
    id: row.id,
    currentVersionId: currentVersionId,
    processingState:
        _enumByName(DataBankProcessingState.values, row.processingState),
    indexState: _enumByName(DataBankIndexState.values, row.indexState),
    failure: _decodeNullable(row.failureJson, DataBankFailure.fromJson),
    reprocessing: DataBankReprocessingMetadata.fromJson(
      _decodeMap(row.reprocessingJson),
    ),
    createdAt: row.createdAt.toUtc(),
    updatedAt: row.updatedAt.toUtc(),
  );
}

DataBankDocumentVersionsCompanion _versionCompanion(
  DataBankDocumentVersion version,
) {
  return DataBankDocumentVersionsCompanion.insert(
    id: version.id,
    documentId: version.documentId,
    versionNumber: version.versionNumber,
    supersedesVersionId: Value(version.supersedesVersionId),
    originalFileName: version.originalFileName,
    mediaType: version.mediaType,
    byteSize: version.byteSize,
    hashAlgorithm: version.contentHash.algorithm.name,
    hashDigest: version.contentHash.digest,
    importedAt: version.importedAt,
    processingState: version.processingState.name,
    indexState: version.indexState.name,
    failureJson: Value(_encodeNullable(version.failure?.toJson())),
    reprocessingJson: jsonEncode(version.reprocessing.toJson()),
  );
}

DataBankDocumentVersion _versionFromRow(DataBankDocumentVersionRow row) {
  return DataBankDocumentVersion(
    id: row.id,
    documentId: row.documentId,
    versionNumber: row.versionNumber,
    supersedesVersionId: row.supersedesVersionId,
    originalFileName: row.originalFileName,
    mediaType: row.mediaType,
    byteSize: row.byteSize,
    contentHash: DataBankContentHash(
      algorithm: _enumByName(DataBankHashAlgorithm.values, row.hashAlgorithm),
      digest: row.hashDigest,
    ),
    importedAt: row.importedAt.toUtc(),
    processingState:
        _enumByName(DataBankProcessingState.values, row.processingState),
    indexState: _enumByName(DataBankIndexState.values, row.indexState),
    failure: _decodeNullable(row.failureJson, DataBankFailure.fromJson),
    reprocessing: DataBankReprocessingMetadata.fromJson(
      _decodeMap(row.reprocessingJson),
    ),
  );
}

DataBankSection _sectionFromRow(DataBankSectionRow row) {
  return DataBankSection(
    id: row.id,
    documentVersionId: row.documentVersionId,
    kind: _enumByName(DataBankSectionKind.values, row.kind),
    title: row.title,
    ordinal: row.ordinal,
    parentSectionId: row.parentSectionId,
    locator: DataBankSourceLocator.fromJson(_decodeMap(row.locatorJson)),
  );
}

DataBankTextChunk _chunkFromRow(DataBankTextChunkRow row) {
  return DataBankTextChunk(
    id: row.id,
    documentVersionId: row.documentVersionId,
    sectionId: row.sectionId,
    ordinal: row.ordinal,
    text: row.textContent,
    locator: DataBankSourceLocator.fromJson(_decodeMap(row.locatorJson)),
  );
}

DataBankBinding _bindingFromRow(DataBankBindingRow row) {
  return DataBankBinding(
    id: row.id,
    documentId: row.documentId,
    scope: _enumByName(DataBankBindingScope.values, row.scope),
    characterId: row.characterId,
    chatId: row.chatId,
    enabled: row.enabled,
    createdAt: row.createdAt.toUtc(),
    updatedAt: row.updatedAt.toUtc(),
  );
}

DataBankDocument _transitionedDocument(
  DataBankDocument document,
  DataBankProcessingState to,
  DataBankFailure? failure,
) {
  return DataBankDocument(
    id: document.id,
    currentVersionId: document.currentVersionId,
    processingState: to,
    indexState: _indexStateAfterTransition(document.indexState, to),
    failure: failure,
    reprocessing: document.reprocessing,
    createdAt: document.createdAt,
    updatedAt: document.updatedAt,
  );
}

DataBankDocumentVersion _transitionedVersion(
  DataBankDocumentVersion version,
  DataBankProcessingState to,
  DataBankFailure? failure,
) {
  return DataBankDocumentVersion(
    id: version.id,
    documentId: version.documentId,
    versionNumber: version.versionNumber,
    supersedesVersionId: version.supersedesVersionId,
    originalFileName: version.originalFileName,
    mediaType: version.mediaType,
    byteSize: version.byteSize,
    contentHash: version.contentHash,
    importedAt: version.importedAt,
    processingState: to,
    indexState: _indexStateAfterTransition(version.indexState, to),
    failure: failure,
    reprocessing: version.reprocessing,
  );
}

DataBankIndexState _indexStateAfterTransition(
  DataBankIndexState current,
  DataBankProcessingState processing,
) {
  return switch (processing) {
    DataBankProcessingState.disabled => DataBankIndexState.disabled,
    DataBankProcessingState.deleted => DataBankIndexState.deleted,
    _
        when current == DataBankIndexState.disabled ||
            current == DataBankIndexState.deleted =>
      DataBankIndexState.notIndexed,
    _ => current,
  };
}

String? _encodeNullable(Map<String, dynamic>? value) {
  return value == null ? null : jsonEncode(value);
}

Map<String, dynamic> _decodeMap(String encoded) {
  return jsonDecode(encoded) as Map<String, dynamic>;
}

T? _decodeNullable<T>(
  String? encoded,
  T Function(Map<String, dynamic>) decode,
) {
  return encoded == null ? null : decode(_decodeMap(encoded));
}

T _enumByName<T extends Enum>(Iterable<T> values, String name) {
  return values.firstWhere(
    (value) => value.name == name,
    orElse: () => throw StateError('Unsupported persisted enum value: $name'),
  );
}
