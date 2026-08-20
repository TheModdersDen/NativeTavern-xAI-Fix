// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:googleapis/androidpublisher/v3.dart' as play;
import 'package:googleapis_auth/auth_io.dart' as auth;

String _requiredEnvironment(String name) {
  final value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) {
    throw StateError('Missing required environment variable: $name');
  }
  return value.trim();
}

List<play.LocalizedText> _releaseNotes(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Release notes must be a JSON object.');
  }
  final localizations = decoded['localizations'];
  if (localizations is! Map<String, dynamic>) {
    throw const FormatException('Release notes have no localizations object.');
  }

  const googleLocales = <String, String>{
    'en-US': 'en-US',
    'zh-Hans': 'zh-CN',
    'zh-Hant': 'zh-TW',
  };
  return googleLocales.entries.map((entry) {
    final text = localizations[entry.key];
    if (text is! String || text.trim().isEmpty) {
      throw FormatException('Missing release notes for ${entry.key}.');
    }
    if (text.runes.length > 500) {
      throw FormatException('Release notes for ${entry.key} exceed 500 chars.');
    }
    return play.LocalizedText(language: entry.value, text: text.trim());
  }).toList();
}

Map<String, dynamic> _trackSummary(play.Track track) => {
      'track': track.track,
      'releases': [
        for (final release in track.releases ?? const <play.TrackRelease>[])
          {
            'name': release.name,
            'status': release.status,
            'versionCodes': release.versionCodes,
          },
      ],
    };

Future<play.Track> _readTrack(
  play.AndroidPublisherApi api,
  String packageName,
  String trackName,
) async {
  final edit = await api.edits.insert(play.AppEdit(), packageName);
  final editId = edit.id;
  if (editId == null) throw StateError('Google Play returned no edit ID.');
  try {
    return await api.edits.tracks.get(packageName, editId, trackName);
  } finally {
    await api.edits.delete(packageName, editId);
  }
}

Future<void> _publish(
  play.AndroidPublisherApi api,
  String packageName,
  String trackName,
  File bundle,
  File notesFile,
  int expectedVersionCode,
) async {
  if (!bundle.existsSync()) throw StateError('AAB not found: ${bundle.path}');
  if (!notesFile.existsSync()) {
    throw StateError('Release notes not found: ${notesFile.path}');
  }

  final edit = await api.edits.insert(play.AppEdit(), packageName);
  final editId = edit.id;
  if (editId == null) throw StateError('Google Play returned no edit ID.');
  var committed = false;
  try {
    final uploaded = await api.edits.bundles.upload(
      packageName,
      editId,
      uploadMedia: play.Media(
        bundle.openRead(),
        bundle.lengthSync(),
        contentType: 'application/octet-stream',
      ),
      uploadOptions: play.UploadOptions.resumable,
    );
    if (uploaded.versionCode != expectedVersionCode) {
      throw StateError(
        'Uploaded version code ${uploaded.versionCode}; '
        'expected $expectedVersionCode.',
      );
    }

    final notesJson = jsonDecode(notesFile.readAsStringSync());
    final versionName = notesJson is Map<String, dynamic>
        ? notesJson['versionString']?.toString()
        : null;
    await api.edits.tracks.update(
      play.Track(
        track: trackName,
        releases: [
          play.TrackRelease(
            name: '${versionName ?? 'release'} ($expectedVersionCode)',
            releaseNotes: _releaseNotes(notesFile),
            status: 'completed',
            versionCodes: ['$expectedVersionCode'],
          ),
        ],
      ),
      packageName,
      editId,
      trackName,
    );
    await api.edits.validate(packageName, editId);
    await api.edits.commit(
      packageName,
      editId,
      changesNotSentForReview: false,
    );
    committed = true;
  } finally {
    if (!committed) {
      try {
        await api.edits.delete(packageName, editId);
      } catch (_) {
        // The original publishing error is more useful than cleanup failure.
      }
    }
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty ||
      (arguments.first != 'inspect' && arguments.first != 'publish')) {
    stderr.writeln(
      'usage: dart run tool/google_play_release.dart inspect\n'
      '   or: dart run tool/google_play_release.dart publish '
      '<aab> <release-notes.json> <version-code>',
    );
    exitCode = 64;
    return;
  }

  final credentialsFile = File(
    _requiredEnvironment('GOOGLE_PLAY_SERVICE_ACCOUNT_JSON'),
  );
  final packageName = _requiredEnvironment('GOOGLE_PLAY_PACKAGE_NAME');
  final trackName = _requiredEnvironment('GOOGLE_PLAY_TRACK');
  final credentials = auth.ServiceAccountCredentials.fromJson(
    jsonDecode(credentialsFile.readAsStringSync()),
  );
  final client = await auth.clientViaServiceAccount(
    credentials,
    [play.AndroidPublisherApi.androidpublisherScope],
  );
  final api = play.AndroidPublisherApi(client);

  try {
    if (arguments.first == 'publish') {
      if (arguments.length != 4) {
        throw const FormatException('publish requires AAB, notes, and code.');
      }
      final versionCode = int.tryParse(arguments[3]);
      if (versionCode == null || versionCode <= 0) {
        throw FormatException('Invalid version code: ${arguments[3]}');
      }
      await _publish(
        api,
        packageName,
        trackName,
        File(arguments[1]),
        File(arguments[2]),
        versionCode,
      );
    }

    final track = await _readTrack(api, packageName, trackName);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(
      _trackSummary(track),
    ));
  } finally {
    client.close();
  }
}
