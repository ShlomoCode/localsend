import 'package:flutter/material.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// Opens the image and video picker with keyboard navigation and selection.
Future<List<AssetEntity>?> pickMediaWithKeyboardNavigation(
  BuildContext context, {
  required int maxAssets,
  required AssetPickerTextDelegate textDelegate,
}) async {
  const permissionRequestOption = PermissionRequestOption(
    androidPermission: AndroidPermission(type: RequestType.common, mediaLocation: false),
  );
  final permission = await AssetPicker.permissionCheck(requestOption: permissionRequestOption);
  if (!context.mounted) return null;

  return AssetPicker.pickAssetsWithDelegate<AssetEntity, AssetPathEntity, DefaultAssetPickerProvider, _KeyboardAssetPickerDelegate>(
    context,
    permissionRequestOption: permissionRequestOption,
    delegate: _KeyboardAssetPickerDelegate(
      provider: DefaultAssetPickerProvider(maxAssets: maxAssets, requestType: RequestType.common),
      initialPermission: permission,
      textDelegate: textDelegate,
      locale: Localizations.maybeLocaleOf(context),
    ),
  );
}

class _KeyboardAssetPickerDelegate extends DefaultAssetPickerBuilderDelegate<DefaultAssetPickerProvider> {
  _KeyboardAssetPickerDelegate({required super.provider, required super.initialPermission, required super.textDelegate, super.locale});

  @override
  Widget pathEntityListWidget(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isSwitchingPath,
      child: super.pathEntityListWidget(context),
      // The collapsed list remains mounted, so its folder rows need focus exclusion.
      builder: (_, bool expanded, Widget? child) => ExcludeFocus(excluding: !expanded, child: child!),
    );
  }

  @override
  Widget assetGridItemSemanticsBuilder(
    BuildContext context,
    int index,
    AssetEntity asset,
    Widget child,
    List<SpecialItemFinalized> specialItemsFinalized,
  ) {
    return ValueListenableBuilder<bool>(
      valueListenable: isSwitchingPath,
      child: _KeyboardAssetTile(
        key: ValueKey(asset.id),
        onActivate: () => selectAsset(context, asset, index, provider.selectedAssets.contains(asset)),
        child: super.assetGridItemSemanticsBuilder(context, index, asset, child, specialItemsFinalized),
      ),
      builder: (_, bool expanded, Widget? child) => ExcludeFocus(excluding: expanded, child: child!),
    );
  }
}

class _KeyboardAssetTile extends StatefulWidget {
  const _KeyboardAssetTile({super.key, required this.onActivate, required this.child});

  final VoidCallback onActivate;
  final Widget child;

  @override
  State<_KeyboardAssetTile> createState() => _KeyboardAssetTileState();
}

class _KeyboardAssetTileState extends State<_KeyboardAssetTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FocusableActionDetector(
      onFocusChange: (focused) => setState(() => _focused = focused),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onActivate();
          return null;
        }),
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_focused)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(border: Border.all(color: colors.primary, width: 3)),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: DecoratedBox(decoration: BoxDecoration(border: Border.all(color: colors.onPrimary))),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
