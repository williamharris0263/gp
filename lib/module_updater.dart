import 'dart:async';

import 'core_bridge.dart';
import 'diary_service.dart';
import 'local_store.dart';
import 'models.dart';
import 'source_modules.dart';

class ModuleUpdater {
  ModuleUpdater(
    this.repository,
    this.store, {
    this.startDelay = const Duration(seconds: 20),
    this.interval = const Duration(hours: 6),
    DateTime Function()? clock,
  }) : _epoch = store.profileEpoch,
       _clock = clock ?? DateTime.now;

  final AppRepository repository;
  final LocalStore store;
  final Duration startDelay;
  final Duration interval;
  final DateTime Function() _clock;
  final int _epoch;
  Timer? _timer;
  DateTime? _lastAttempt;
  bool _running = false;
  bool _disposed = false;

  bool get _valid =>
      !_disposed &&
      !store.locked &&
      store.profile.admin &&
      _epoch == store.profileEpoch;

  void start() {
    if (_timer != null || !repository.supportsSourceManagement || !_valid) {
      return;
    }
    _timer = Timer(startDelay, () {
      if (_disposed) return;
      _timer = Timer.periodic(interval, (_) => _tick());
      _tick();
    });
  }

  void resume() {
    final last = _lastAttempt;
    if (last == null || !_clock().isBefore(last.add(interval))) _tick();
  }

  void _tick() => unawaited(
    run().catchError((Object failure) {
      DiaryService.add('[Modules] 自动检查更新失败：$failure');
      return 0;
    }),
  );

  Future<int> run() async {
    if (_running ||
        !_valid ||
        !repository.supportsSourceManagement ||
        !store.autoUpdateModules) {
      return 0;
    }
    final now = _clock();
    final last = _lastAttempt;
    if (last != null && now.isBefore(last.add(interval))) return 0;
    _running = true;
    _lastAttempt = now;
    try {
      final installed = {
        for (final module in await repository.modules()) module.id: module,
      };
      final index = await repository.moduleIndex();
      if (!_valid || !store.autoUpdateModules) return 0;
      if (index.warning.isNotEmpty) {
        DiaryService.add('[Modules] 在线仓库不可用，本次不更新：${index.warning}');
      }
      final latest = <String, ModuleIndexEntry>{};
      for (final entry in index.entries) {
        if (entry.bundled) continue;
        final current = latest[entry.id];
        if (current == null ||
            isNewerModuleVersion(entry.version, current.version)) {
          latest[entry.id] = entry;
        }
      }
      var updated = 0;
      for (final entry in latest.values) {
        final module = installed[entry.id];
        if (module == null ||
            module.error.isNotEmpty ||
            !isNewerModuleVersion(entry.version, module.version)) {
          continue;
        }
        if (!_valid || !store.autoUpdateModules) return updated;
        try {
          final prepared = await repository.prepareModule(indexed: entry.id);
          if (!_valid || !store.autoUpdateModules) return updated;
          if (!isNewerModuleVersion(prepared.version, module.version)) continue;
          await repository.installModule(prepared.token);
          updated++;
          DiaryService.add(
            '[Modules] ${module.name} 已自动更新到 ${prepared.version}',
          );
        } catch (failure) {
          DiaryService.add('[Modules] ${module.name} 自动更新失败：$failure');
          continue;
        }
        final site = SourceSite.byId(entry.id);
        if (site.devices) {
          try {
            if (!await repository.sourceDevices(entry.id) &&
                !await repository.sourceDevices(entry.id, register: true)) {
              throw AppFailure('设备注册未完成');
            }
          } catch (failure) {
            DiaryService.add('[Modules] ${module.name} 已更新，但设备注册失败：$failure');
          }
        }
      }
      return updated;
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
