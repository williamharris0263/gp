import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/module_updater.dart';
import 'package:duanju_app/source_modules.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'support/source_fixture.dart';

SourceModule _installed(String id, String version, {String error = ''}) =>
    SourceModule(id: id, name: id, version: version, error: error);

ModuleIndexEntry _indexed(String id, String version, {bool bundled = false}) =>
    ModuleIndexEntry(id: id, name: id, version: version, bundled: bundled);

class _ModuleRepository extends FakeRepository {
  _ModuleRepository(this.installedModules, this.entries);

  final List<SourceModule> installedModules;
  final List<ModuleIndexEntry> entries;
  final prepared = <String>[];
  final installedTokens = <String>[];
  final prepareFailures = <String, String>{};
  final preparedVersions = <String, String>{};
  int indexRequests = 0;

  @override
  bool get supportsSourceManagement => true;

  @override
  Future<List<SourceModule>> modules() async => List.of(installedModules);

  @override
  Future<ModuleStore> moduleIndex() async {
    indexRequests++;
    return ModuleStore(entries);
  }

  @override
  Future<SourceModule> prepareModule({
    String file = '',
    String url = '',
    String indexed = '',
    bool bundled = false,
  }) async {
    prepared.add(indexed);
    if (prepareFailures[indexed] case final failure?) throw AppFailure(failure);
    final candidates = [
      for (final entry in entries)
        if (!entry.bundled && entry.id == indexed) entry,
    ]..sort((a, b) => isNewerModuleVersion(a.version, b.version) ? -1 : 1);
    return SourceModule(
      id: indexed,
      name: indexed,
      version: preparedVersions[indexed] ?? candidates.first.version,
      installed: true,
      token: 'token-$indexed',
    );
  }

  @override
  Future<String> installModule(String token) async {
    installedTokens.add(token);
    return token.substring('token-'.length);
  }
}

void main() {
  test(
    'updates only newer online modules without changing source switches',
    () async {
      installSourceFixture();
      final store = await openStore();
      await store.setSourceEnabled('hongguo', false);
      final repository = _ModuleRepository(
        [
          _installed('hongguo', '1.0.0'),
          _installed('alpha', '1.0.0'),
          _installed('broken', '1.0.0', error: 'bad module'),
        ],
        [
          _indexed('hongguo', '1.0.1'),
          _indexed('hongguo', '9.0.0', bundled: true),
          _indexed('hongguo', '1.0.2'),
          _indexed('alpha', '1.0.0'),
          _indexed('broken', '2.0.0'),
          _indexed('new-source', '3.0.0'),
        ],
      );
      final updater = ModuleUpdater(repository, store);
      addTearDown(updater.dispose);

      expect(await updater.run(), 1);
      expect(repository.prepared, ['hongguo']);
      expect(repository.installedTokens, ['token-hongguo']);
      expect(store.sourceEnabled('hongguo'), isFalse);
    },
  );

  test('the setting disables updates and survives a restart', () async {
    final store = await openStore();
    await store.setAutoUpdateModules(false);
    expect((await restartStore(store)).autoUpdateModules, isFalse);
    final repository = _ModuleRepository(
      [_installed('hongguo', '1.0.0')],
      [_indexed('hongguo', '2.0.0')],
    );
    final updater = ModuleUpdater(repository, store);
    addTearDown(updater.dispose);

    expect(await updater.run(), 0);
    expect(repository.indexRequests, 0);
  });

  test('foreground checks are throttled until the interval elapses', () async {
    var now = DateTime(2026, 11, 18, 12);
    final store = await openStore();
    final repository = _ModuleRepository(const [], const []);
    final updater = ModuleUpdater(repository, store, clock: () => now);
    addTearDown(updater.dispose);

    await updater.run();
    await updater.run();
    expect(repository.indexRequests, 1);
    now = now.add(const Duration(hours: 6));
    await updater.run();
    expect(repository.indexRequests, 2);
  });

  test('one failed module does not block later updates', () async {
    final store = await openStore();
    final repository = _ModuleRepository(
      [_installed('alpha', '1.0.0'), _installed('beta', '1.0.0')],
      [_indexed('alpha', '2.0.0'), _indexed('beta', '2.0.0')],
    )..prepareFailures['alpha'] = 'download failed';
    final updater = ModuleUpdater(repository, store);
    addTearDown(updater.dispose);

    expect(await updater.run(), 1);
    expect(repository.prepared, ['alpha', 'beta']);
    expect(repository.installedTokens, ['token-beta']);
  });

  test('non-admin profiles never query or install modules', () async {
    final store = await openStore(viewerPreferences);
    final repository = _ModuleRepository(
      [_installed('hongguo', '1.0.0')],
      [_indexed('hongguo', '2.0.0')],
    );
    final updater = ModuleUpdater(repository, store);
    addTearDown(updater.dispose);

    expect(await updater.run(), 0);
    expect(repository.indexRequests, 0);
  });
}
