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
  Offset? _dragStartPosition;
  final Set<int> _dragSelectedIndices = {};
  bool _initialSelectionState = false;
  List<AssetEntity> _currentAssets = [];
  
  // Grid configuration - we'll need to calculate this
  int _crossAxisCount = 4;
  double _mainAxisSpacing = 2.0;
  double _crossAxisSpacing = 2.0;

  @override
  Widget assetsGridBuilder(BuildContext context) {
    final Widget grid = super.assetsGridBuilder(context);
    
    // Extract grid count from the provider or use default
    _crossAxisCount = gridCount;
    
    // Wrap the grid with a gesture detector and listener
    return Listener(
      onPointerUp: (_) => _endDragSelection(),
      onPointerCancel: (_) => _endDragSelection(),
      child: Stack(
        children: [
          grid,
          // Transparent overlay for drag selection
          // Only active during long press
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onLongPressStart: (details) {
                _startDragSelection(details.localPosition, context);
              },
              onLongPressMoveUpdate: (details) {
                if (_isDragging) {
                  _updateDragSelection(details.localPosition, context);
                }
              },
              onLongPressEnd: (details) {
                _endDragSelection();
              },
              // Ignore pointer events when not in drag mode to allow normal taps
              child: IgnorePointer(
                child: Container(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _startDragSelection(Offset position, BuildContext context) {
    _isDragging = true;
    _dragStartPosition = position;
    _dragSelectedIndices.clear();
    
    // Get the current assets list
    _currentAssets = provider.currentAssets.toList();
    
    // Calculate which item was initially pressed
    final int? index = _getIndexFromPosition(position, context);
    if (index != null && index < _currentAssets.length) {
      final asset = _currentAssets[index];
      _dragSelectedIndices.add(index);
      
      // Remember if we're selecting or deselecting
      _initialSelectionState = !provider.selectedAssets.contains(asset);
      
      // Toggle the first item
      if (provider.selectedAssets.contains(asset)) {
        provider.unSelectAsset(asset);
      } else {
        provider.selectAsset(asset);
      }
    }
  }

  void _updateDragSelection(Offset position, BuildContext context) {
    if (!_isDragging || _dragStartPosition == null) return;
    
    final int? index = _getIndexFromPosition(position, context);
    if (index == null || index >= _currentAssets.length) return;
    
    // Skip if already processed
    if (_dragSelectedIndices.contains(index)) return;
    
    _dragSelectedIndices.add(index);
    final asset = _currentAssets[index];
    
    // Apply selection/deselection based on initial state
    final bool isCurrentlySelected = provider.selectedAssets.contains(asset);
    
    if (_initialSelectionState && !isCurrentlySelected) {
      provider.selectAsset(asset);
    } else if (!_initialSelectionState && isCurrentlySelected) {
      provider.unSelectAsset(asset);
    }
  }

  void _endDragSelection() {
    _isDragging = false;
    _dragStartPosition = null;
    _dragSelectedIndices.clear();
  }

  /// Calculate which grid item index corresponds to the given position
  int? _getIndexFromPosition(Offset position, BuildContext context) {
    // Get the render box to calculate positions
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return null;
    
    final size = renderBox.size;
    
    // Estimate item size based on grid count
    // This is a simplification - actual calculation depends on GridView configuration
    final double itemWidth = (size.width - (_crossAxisCount - 1) * _crossAxisSpacing) / _crossAxisCount;
    final double itemHeight = itemWidth; // Assuming square items
    
    // Calculate row and column
    final int column = (position.dx / (itemWidth + _crossAxisSpacing)).floor();
    final int row = (position.dy / (itemHeight + _mainAxisSpacing)).floor();
    
    if (column < 0 || column >= _crossAxisCount || row < 0) return null;
    
    final int index = row * _crossAxisCount + column;
    return index < _currentAssets.length ? index : null;
  }
}
