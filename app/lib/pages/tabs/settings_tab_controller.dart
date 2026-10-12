import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/pages/language_page.dart';
import 'package:localsend_app/pages/tabs/settings_tab_vm.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/autostart_helper.dart';
import 'package:localsend_app/util/native/context_menu_helper.dart';
import 'package:localsend_app/util/ui/dynamic_colors.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/dialogs/custom_color_dialog.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/util/sleep.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

final settingsTabControllerProvider = ReduxProvider<SettingsTabController, SettingsTabVm>((ref) {
  final settings = ref.notifier(settingsProvider);
  final server = ref.notifier(serverProvider);
  final isolateController = ref.notifier(parentIsolateProvider);
  final localIpService = ref.notifier(localIpProvider);
  final initialDeviceInfo = ref.read(deviceInfoProvider);
  final supportsDynamicColors = ref.read(dynamicColorsProvider) != null;

  return SettingsTabController(
    settingsService: settings,
    serverNotifier: server,
    isolateController: isolateController,
    localIpService: localIpService,
    initialDeviceInfo: initialDeviceInfo,
    supportsDynamicColors: supportsDynamicColors,
  );
});

class SettingsTabController extends ReduxNotifier<SettingsTabVm> {
  final SettingsService _settingsService;
  final ServerService _serverService;
  final IsolateController _isolateController;
  final LocalIpService _localIpService;
  final DeviceInfoResult _initialDeviceInfo;
  final bool _supportsDynamicColors;
  bool _autoStartBusy = true;

  SettingsTabController({
    required SettingsService settingsService,
    required ServerService serverNotifier,
    required IsolateController isolateController,
    required LocalIpService localIpService,
    required DeviceInfoResult initialDeviceInfo,
    required bool supportsDynamicColors,
  }) : _settingsService = settingsService,
       _serverService = serverNotifier,
       _isolateController = isolateController,
       _localIpService = localIpService,
       _initialDeviceInfo = initialDeviceInfo,
       _supportsDynamicColors = supportsDynamicColors;

  @override
  SettingsTabVm init() {
    return SettingsTabVm(
      advanced: _settingsService.state.advancedSettings,
      aliasController: TextEditingController(text: _settingsService.state.alias),
      deviceModelController: TextEditingController(text: _initialDeviceInfo.deviceModel),
      portController: TextEditingController(text: _settingsService.state.port.toString()),
      timeoutController: TextEditingController(text: _settingsService.state.discoveryTimeout.toString()),
      multicastController: TextEditingController(text: _settingsService.state.multicastGroup),
      settings: _settingsService.state,
      serverState: _serverService.state,
      deviceInfo: _initialDeviceInfo,
      colorModes: _supportsDynamicColors ? ColorMode.values : ColorMode.values.where((e) => e != ColorMode.system).toList(),
      autoStart: null,
      autoStartLaunchHidden: false,
      autoStartCanModify: false,
      autoStartBusy: true,
      showInContextMenu: false,
      onChangeTheme: (context, theme) async {
        await _settingsService.setTheme(theme);
        await sleepAsync(500); // workaround: brightness takes some time to be updated
        if (context.mounted) {
          await updateSystemOverlayStyle(context);
        }
      },
      onChangeColorMode: (context, colorMode) async {
        if (colorMode == ColorMode.custom) {
          final color = await showDialog<Color>(
            context: context,
            builder: (_) => CustomColorDialog(initialColor: _settingsService.state.customColor),
          );
          if (color == null) {
            return;
          }
          await _settingsService.setCustomColor(color);
        }
        await _settingsService.setColorMode(colorMode);
        if (colorMode == ColorMode.oled) {
          await _settingsService.setTheme(ThemeMode.dark);
          await updateSystemOverlayStyleWithBrightness(Brightness.dark);
        }
      },
      onTapLanguage: (context) async {
        await context.push(() => const LanguagePage());
      },
      onToggleAutoStart: (context) async {
        if (disposed || _autoStartBusy || !state.autoStartCanModify || state.autoStart == null) {
          return;
        }
        final enabled = !state.autoStart!;
        final hidden = state.autoStartLaunchHidden;
        await _changeAutoStart(context, enabled: enabled, hidden: hidden);
      },
      onToggleAutoStartLaunchHidden: (context) async {
        if (disposed || _autoStartBusy || !state.autoStartCanModify || state.autoStart != true) {
          return;
        }
        final hidden = !state.autoStartLaunchHidden;
        await _changeAutoStart(context, enabled: true, hidden: hidden);
      },
      onToggleShowInContextMenu: (context) async {
        final bool success;
        if (state.showInContextMenu) {
          success = await disableContextMenu();
        } else {
          success = await enableContextMenu();
        }
        if (success) {
          redux.dispatch(_SetShowInContextMenuAction(!state.showInContextMenu));
        }
      },
      onTapRestartServer: (context) async {
        try {
          final newServerState = await _serverService.restartServer(
            alias: _settingsService.state.alias,
            port: _settingsService.state.port,
            https: _settingsService.state.https,
          );

          if (newServerState != null) {
            // the new state is always valid, so we can "repair" user's setting
            state.aliasController.text = newServerState.alias;
            state.portController.text = newServerState.port.toString();
            await _settingsService.setAlias(newServerState.alias);
            await _settingsService.setPort(newServerState.port);
            external(_isolateController).dispatch(IsolateDiscoveryRestartAction());
            external(_localIpService).dispatchAsync(FetchLocalIpAction()); // ignore: unawaited_futures
          }
        } catch (e) {
          // ignore: use_build_context_synchronously
          context.showSnackBar(e.toString());
        }
      },
      onTapStartServer: (context) async {
        try {
          await _serverService.startServerFromSettings();
        } catch (e) {
          // ignore: use_build_context_synchronously
          context.showSnackBar(e.toString());
        }
      },
      onTapStopServer: () async => await _serverService.stopServer(),
      onTapAdvanced: (advanced) => redux.dispatch(SetAdvancedAction(advanced)),
    );
  }

  @override
  get initialAction => _SettingsTabInitAction();

  Future<void> _changeAutoStart(BuildContext context, {required bool enabled, required bool hidden}) async {
    // Hold the gate through the readback so rapid taps cannot overlap native writes.
    _autoStartBusy = true;
    redux.dispatch(_SetAutoStartBusyAction(true));
    try {
      try {
        final success = enabled ? await enableAutoStart(startHidden: hidden) : await disableAutoStart();
        if (!success && context.mounted) {
          context.showSnackBar(t.general.error);
        }
      } catch (e) {
        if (context.mounted) {
          context.showSnackBar(e.toString());
        }
      }

      // Read the effective state even after a failed write or revoked permission.
      final snapshot = await getAutoStartSnapshot();
      if (!disposed) {
        redux.dispatch(_SetAutoStartSnapshotAction(snapshot));
      }
    } catch (e) {
      if (!disposed) {
        redux.dispatch(_SetAutoStartSnapshotAction(const AutoStartSnapshot(enabled: null, hidden: false, canModify: false)));
      }
      if (context.mounted) {
        context.showSnackBar(e.toString());
      }
    } finally {
      _autoStartBusy = false;
      if (!disposed) {
        redux.dispatch(_SetAutoStartBusyAction(false));
      }
    }
  }

  @override
  void dispose() {
    state.aliasController.dispose();
    state.deviceModelController.dispose();
    state.portController.dispose();
    state.timeoutController.dispose();
    state.multicastController.dispose();
    super.dispose();
  }
}

class _SettingsTabInitAction extends AsyncReduxAction<SettingsTabController, SettingsTabVm> {
  @override
  Future<SettingsTabVm> reduce() async {
    dispatch(_SettingsTabWatchAction());
    AutoStartSnapshot snapshot;
    try {
      snapshot = await getAutoStartSnapshot();
    } catch (_) {
      snapshot = const AutoStartSnapshot(enabled: null, hidden: false, canModify: false);
    }
    if (notifier.disposed) {
      return state;
    }
    dispatch(_SetAutoStartSnapshotAction(snapshot));
    notifier._autoStartBusy = false;
    dispatch(_SetAutoStartBusyAction(false));
    final showInContextMenu = await isContextMenuEnabled();
    if (notifier.disposed) {
      return state;
    }
    return state.copyWith(
      showInContextMenu: showInContextMenu,
    );
  }
}

class _SettingsTabWatchAction extends WatchAction<SettingsTabController, SettingsTabVm> {
  @override
  SettingsTabVm reduce() {
    return state.copyWith(
      settings: ref.watch(settingsProvider),
      serverState: ref.watch(serverProvider),
      deviceInfo: ref.watch(deviceInfoProvider),
    );
  }
}

class SetAdvancedAction extends ReduxAction<SettingsTabController, SettingsTabVm> {
  final bool advanced;

  SetAdvancedAction(this.advanced);

  @override
  SettingsTabVm reduce() {
    return state.copyWith(advanced: advanced);
  }
}

class _SetAutoStartSnapshotAction extends ReduxAction<SettingsTabController, SettingsTabVm> {
  final AutoStartSnapshot snapshot;

  _SetAutoStartSnapshotAction(this.snapshot);

  @override
  SettingsTabVm reduce() {
    return state.copyWith(
      autoStart: snapshot.enabled,
      autoStartLaunchHidden: snapshot.hidden,
      autoStartCanModify: snapshot.canModify,
    );
  }
}

class _SetAutoStartBusyAction extends ReduxAction<SettingsTabController, SettingsTabVm> {
  final bool busy;

  _SetAutoStartBusyAction(this.busy);

  @override
  SettingsTabVm reduce() {
    return state.copyWith(autoStartBusy: busy);
  }
}

class _SetShowInContextMenuAction extends ReduxAction<SettingsTabController, SettingsTabVm> {
  final bool enabled;

  _SetShowInContextMenuAction(this.enabled);

  @override
  SettingsTabVm reduce() {
    return state.copyWith(showInContextMenu: enabled);
  }
}
