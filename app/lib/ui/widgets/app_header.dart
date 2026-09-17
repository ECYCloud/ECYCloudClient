import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'page_header.dart';
import 'user_avatar.dart';

class AppHeader extends StatelessWidget {
  const AppHeader({super.key, required this.bar});

  final ShellChromeBar bar;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color fill = dark
        ? const Color.fromRGBO(22, 22, 23, 0.72)
        : const Color.fromRGBO(255, 255, 255, 0.72);

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: ColoredBox(
          color: fill,
          child: SizedBox(
            height: AppTheme.headerHeight,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                AppTheme.pageScrollPadding.left,
                0,
                AppTheme.pageScrollPadding.right,
                0,
              ),
              child: ListenableBuilder(
                listenable: bar,
                builder: (BuildContext context, _) {
                  final double titleSize = AppTheme.pageTitleSizeOf(context);
                  return Row(
                    children: <Widget>[
                      Expanded(
                        child: bar.title.isEmpty
                            ? const SizedBox.shrink()
                            : Text(
                                bar.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(
                                      fontSize: titleSize,
                                      fontWeight: FontWeight.w600,
                                      height: 1.1,
                                      letterSpacing: titleSize * -0.03,
                                    ),
                              ),
                      ),
                      if (bar.actions.isNotEmpty) ...<Widget>[
                        ...bar.actions,
                        const SizedBox(width: PageHeader.edge),
                      ],
                      const UserAvatarButton(),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
