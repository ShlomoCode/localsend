// Temporary issue1864 causal probe. Both source builds use this delegate;
// only ISSUE1864_FOCUS_PROBE changes thumbnail focus and activation behavior.
import 'package:flutter/material.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

Future<List<AssetEntity>?> pickDiagnosticMedia(BuildContext context, AssetPickerConfig config) async {
  final permission = await AssetPicker.permissionCheck();
  if (!context.mounted) return null;
  return AssetPicker.pickAssetsWithDelegate<AssetEntity, AssetPathEntity, DefaultAssetPickerProvider, _DiagnosticPickerDelegate>(
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
    ),
  );
}

class _DiagnosticPickerDelegate extends DefaultAssetPickerBuilderDelegate<DefaultAssetPickerProvider> {
  _DiagnosticPickerDelegate({required super.provider, required super.initialPermission, super.textDelegate, super.locale});

  @override
  Widget assetGridItemBuilder({
    required BuildContext context,
    required int index,
    required List<AssetEntity> currentAssets,
    required List<SpecialItemFinalized> specialItemsFinalized,
  }) {
    final child = super.assetGridItemBuilder(context: context, index: index, currentAssets: currentAssets, specialItemsFinalized: specialItemsFinalized);
    if (!const bool.fromEnvironment('ISSUE1864_FOCUS_PROBE')) return child;
    final asset = currentAssets[index];
    return _DiagnosticFocusableAsset(
      key: ValueKey(asset.id),
      onActivate: () => selectAsset(context, asset, index, provider.selectedAssets.contains(asset)),
      child: child,
    );
  }
}

class _DiagnosticFocusableAsset extends StatefulWidget {
  const _DiagnosticFocusableAsset({super.key, required this.child, required this.onActivate});
  final Widget child;
  final VoidCallback onActivate;

  @override
  State<_DiagnosticFocusableAsset> createState() => _DiagnosticFocusableAssetState();
}

class _DiagnosticFocusableAssetState extends State<_DiagnosticFocusableAsset> {
  bool focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      onFocusChange: (value) => setState(() => focused = value),
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) { widget.onActivate(); return null; })},
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
