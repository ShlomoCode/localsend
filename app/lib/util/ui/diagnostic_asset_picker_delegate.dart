// Temporary issue1864 causal probe. Both source builds use this delegate;
// only ISSUE1864_FOCUS_PROBE changes thumbnail focus and activation behavior.
import 'package:flutter/material.dart';
import 'package:localsend_app/util/ui/diagnostic_picker_focus_trace.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

Future<List<AssetEntity>?> pickDiagnosticMedia(BuildContext context, AssetPickerConfig config) async {
  final permission = await AssetPicker.permissionCheck();
  if (!context.mounted) return null;
  final trace = const bool.fromEnvironment('ISSUE1864_TRACE') ? DiagnosticPickerFocusTrace() : null;
  trace?.start();
  try {
    final result = await AssetPicker.pickAssetsWithDelegate<AssetEntity, AssetPathEntity, DefaultAssetPickerProvider, _DiagnosticPickerDelegate>(
      context,
      delegate: _DiagnosticPickerDelegate(
        provider: DefaultAssetPickerProvider(
          maxAssets: config.maxAssets,
          pageSize: config.pageSize,
          pathThumbnailSize: config.pathThumbnailSize,
          selectedAssets: config.selectedAssets,
          requestType: config.requestType,
          sortPathDelegate: config.sortPathDelegate,
          filterOptions: config.filterOptions,
        ),
        initialPermission: permission,
        textDelegate: config.textDelegate,
        locale: Localizations.maybeLocaleOf(context),
        trace: trace,
      ),
    );
    if (trace != null) tracePicker('picker-return', {'ids': result?.map((asset) => asset.id).toList()});
    return result;
  } finally {
    trace?.dispose();
  }
}

class _DiagnosticPickerDelegate extends DefaultAssetPickerBuilderDelegate<DefaultAssetPickerProvider> {
  _DiagnosticPickerDelegate({required super.provider, required super.initialPermission, super.textDelegate, super.locale, this.trace}) {
    if (trace != null) provider.addListener(_traceProvider);
  }
  final DiagnosticPickerFocusTrace? trace;

  void _traceProvider() {
    tracePicker('provider-change', {'folder': provider.currentPath?.path.name, 'selectedIds': provider.selectedAssets.map((asset) => asset.id).toList()});
    trace?.snapshotAfterFrame('provider-change');
  }

  @override
  Widget build(BuildContext context) {
    final child = super.build(context);
    return trace?.wrap(child) ?? child;
  }

  @override
  Future<void> selectAsset(BuildContext context, AssetEntity asset, int index, bool selected) async {
    if (trace != null) tracePicker('select-before', {'id': asset.id, 'index': index, 'selected': selected});
    await super.selectAsset(context, asset, index, selected);
    if (trace != null) tracePicker('select-after', {'ids': provider.selectedAssets.map((asset) => asset.id).toList()});
  }

  @override
  void dispose() {
    if (trace != null) provider.removeListener(_traceProvider);
    super.dispose();
  }

  @override
  Widget assetGridItemBuilder({
    required BuildContext context,
    required int index,
    required List<AssetEntity> currentAssets,
    required List<SpecialItemFinalized> specialItemsFinalized,
  }) {
    final child = super.assetGridItemBuilder(context: context, index: index, currentAssets: currentAssets, specialItemsFinalized: specialItemsFinalized);
    if (trace != null) tracePicker('grid-hook', {'index': index, 'focusProbe': const bool.fromEnvironment('ISSUE1864_FOCUS_PROBE')});
    if (!const bool.fromEnvironment('ISSUE1864_FOCUS_PROBE')) return child;
    final asset = currentAssets[index];
    return _DiagnosticFocusableAsset(
      key: ValueKey(asset.id),
      trace: trace,
      label: 'tile-$index-${asset.id}',
      onActivate: () => selectAsset(context, asset, index, provider.selectedAssets.contains(asset)),
      child: child,
    );
  }
}

class _DiagnosticFocusableAsset extends StatefulWidget {
  const _DiagnosticFocusableAsset({super.key, required this.child, required this.onActivate, required this.trace, required this.label});
  final DiagnosticPickerFocusTrace? trace;
  final String label;
  final Widget child;
  final VoidCallback onActivate;

  @override
  State<_DiagnosticFocusableAsset> createState() => _DiagnosticFocusableAssetState();
}

class _DiagnosticFocusableAssetState extends State<_DiagnosticFocusableAsset> {
  bool focused = false;
  late final FocusNode node;

  @override
  void initState() {
    super.initState();
    node = FocusNode(debugLabel: widget.label);
    widget.trace?.observeNode(widget.label, node);
  }

  @override
  void dispose() {
    widget.trace?.unobserveNode(node);
    node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      focusNode: node,
      onFocusChange: (value) {
        if (widget.trace != null) tracePicker('tile-focus', {'label': widget.label, 'focused': value});
        setState(() => focused = value);
      },
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
        if (widget.trace != null) tracePicker('tile-activate', {'label': widget.label});
        widget.onActivate(); return null;
      })},
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (focused)
            Positioned.fill(child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(border: Border.all(color: Colors.cyanAccent, width: 8))))),
        ],
      ),
    );
  }
}
