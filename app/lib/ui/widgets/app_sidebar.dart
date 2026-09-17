import 'package:flutter/material.dart';

import '../theme.dart';
import 'nav_glyph.dart';
import 'overlay_scroll_view.dart';

class AppSidebarItem {
  const AppSidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badge = false,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool badge;
}

class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.items,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<AppSidebarItem> items;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surface,
      child: SizedBox(
        width: AppTheme.sidebarWidth,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            return OverlayScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight,
                  minWidth: constraints.maxWidth - AppTheme.overlayScrollGutter,
                  maxWidth: constraints.maxWidth - AppTheme.overlayScrollGutter,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const _BrandRow(),
                    const SizedBox(height: 8),
                    for (int i = 0; i < items.length; i++)
                      _NavTile(
                        item: items[i],
                        selected: selectedIndex == i,
                        onTap: () => onSelected(i),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BrandRow extends StatelessWidget {
  const _BrandRow();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    final TextStyle brandStyle = theme.textTheme.titleLarge!.copyWith(
      fontSize: AppTheme.pageTitleSize,
      fontWeight: FontWeight.w600,
      height: 1.1,
      letterSpacing: AppTheme.pageTitleSize * -0.03,
    );
    final TextPainter painter = TextPainter(
      text: TextSpan(text: 'ECY Cloud', style: brandStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final List<TextBox> boxes = painter.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 9),
    );
    double iconSize = 0;
    for (final TextBox box in boxes) {
      final double h = box.bottom - box.top;
      if (h > iconSize) {
        iconSize = h;
      }
    }
    if (iconSize <= 0) {
      iconSize = AppTheme.pageTitleSize;
    }

    return SizedBox(
      height: AppTheme.headerHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: <Widget>[
            Image(
              image: const AssetImage('assets/app_icon.png'),
              width: iconSize,
              height: iconSize,
              filterQuality: FilterQuality.medium,
              excludeFromSemantics: true,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'ECY Cloud',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: brandStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavTile extends StatefulWidget {
  const _NavTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final AppSidebarItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color hover = scheme.surfaceContainerHighest;
    final BorderRadius radius = BorderRadius.circular(AppTheme.menuRadius);
    final bool filled = widget.selected || _pressed || _hovered;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          onHighlightChanged: (bool value) {
            setState(() => _pressed = value);
          },
          onHover: (bool value) {
            setState(() => _hovered = value);
          },
          borderRadius: radius,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: hover,
          child: Ink(
            decoration: BoxDecoration(
              color: widget.selected ? hover : Colors.transparent,
              borderRadius: radius,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: <Widget>[
                  NavGlyph(
                    filled ? widget.item.selectedIcon : widget.item.icon,
                    filled: filled,
                    size: 16,
                    color: scheme.onSurface,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            widget.item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontSize: AppTheme.navLabelSize,
                              fontWeight: FontWeight.w400,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        if (widget.item.badge)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Badge(
                              isLabelVisible: true,
                              backgroundColor: Color(0xFFE53935),
                              smallSize: 8,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
