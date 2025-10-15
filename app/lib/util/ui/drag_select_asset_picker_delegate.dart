import 'package:flutter/material.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// A custom asset picker builder delegate that enables drag-to-select functionality.
/// 
/// This allows users to long-press on an item and drag across multiple items
/// to select them, similar to the behavior in Android's native gallery apps.
class DragSelectAssetPickerBuilderDelegate extends DefaultAssetPickerBuilderDelegate {
  DragSelectAssetPickerBuilderDelegate({
    required super.provider,
    required super.initialPermission,
    super.gridCount,
    super.pickerTheme,
    super.specialItemPosition,
    super.specialItemBuilder,
    super.loadingIndicatorBuilder,
    super.selectPredicate,
    super.shouldRevertGrid,
    super.limitedPermissionOverlayPredicate,
    super.pathNameBuilder,
    super.themeColor,
    super.locale,
  });

  // Track drag selection state
  bool _isDragging = false;
  int? _dragStartIndex;
  final Set<int> _dragSelectedIndices = {};
  bool _initialSelectionState = false;

  @override
  Widget assetsGridBuilder(BuildContext context) {
    final Widget grid = super.assetsGridBuilder(context);
    
    // Wrap the grid with a listener to handle pointer up/cancel events
    return Listener(
      onPointerUp: (_) => _endDragSelection(),
      onPointerCancel: (_) => _endDragSelection(),
      child: grid,
    );
  }

  void _endDragSelection() {
    _isDragging = false;
    _dragStartIndex = null;
    _dragSelectedIndices.clear();
  }

  @override
  Widget assetGridItemBuilder(
    BuildContext context,
    int index,
    List<AssetEntity> currentAssets,
  ) {
    final Widget item = super.assetGridItemBuilder(context, index, currentAssets);
    final AssetEntity asset = currentAssets[index];

    return GestureDetector(
      // Start drag selection on long press
      onLongPressStart: (_) => _startDragSelection(index, asset),
      
      // Handle pointer entering this item during drag
      onLongPressMoveUpdate: (details) {
        if (_isDragging) {
          _handleDragOver(index, asset);
        }
      },
      
      // Also handle when pointer moves over the item
      onPanUpdate: (details) {
        if (_isDragging) {
          _handleDragOver(index, asset);
        }
      },
      
      child: item,
    );
  }

  void _startDragSelection(int index, AssetEntity asset) {
    _isDragging = true;
    _dragStartIndex = index;
    _dragSelectedIndices.clear();
    _dragSelectedIndices.add(index);
    
    // Remember the initial selection state - if the first item was selected,
    // dragging will deselect items; if it was unselected, dragging will select them
    _initialSelectionState = !provider.selectedAssets.contains(asset);
    
    // Toggle the first item
    if (provider.selectedAssets.contains(asset)) {
      provider.unSelectAsset(asset);
    } else {
      provider.selectAsset(asset);
    }
  }

  void _handleDragOver(int index, AssetEntity asset) {
    if (!_isDragging || _dragStartIndex == null) return;
    
    // Skip if we've already processed this index
    if (_dragSelectedIndices.contains(index)) return;
    
    _dragSelectedIndices.add(index);
    
    // Apply the same action (select/unselect) as the initial item
    final bool isCurrentlySelected = provider.selectedAssets.contains(asset);
    
    if (_initialSelectionState && !isCurrentlySelected) {
      // We're in selection mode and this item isn't selected - select it
      provider.selectAsset(asset);
    } else if (!_initialSelectionState && isCurrentlySelected) {
      // We're in deselection mode and this item is selected - unselect it
      provider.unSelectAsset(asset);
    }
  }
}
