import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_tavern/core/services/initialization_service.dart';
import 'package:native_tavern/data/repositories/drift_data_bank_repository.dart';
import 'package:native_tavern/domain/repositories/data_bank_repository.dart';
import 'package:native_tavern/domain/services/data_bank_library_service.dart';
import 'package:path/path.dart' as path;

final dataBankRepositoryProvider = Provider<DataBankRepository>((ref) {
  return DriftDataBankRepository(ref.watch(databaseProvider));
});

final dataBankManagedFileStoreProvider =
    Provider<DataBankManagedFileStore>((ref) {
  return FileDataBankManagedFileStore(
    root: Directory(path.join(ref.watch(dataPathProvider), 'data_bank')),
  );
});

final dataBankLibraryServiceProvider =
    Provider<DataBankLibraryOperations>((ref) {
  return DataBankLibraryService(
    repository: ref.watch(dataBankRepositoryProvider),
    files: ref.watch(dataBankManagedFileStoreProvider),
  );
});
