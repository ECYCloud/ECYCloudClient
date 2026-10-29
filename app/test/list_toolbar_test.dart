import 'package:ecycloud_client/ui/theme.dart';
import 'package:ecycloud_client/ui/widgets/list_toolbar.dart';
import 'package:ecycloud_client/ui/widgets/search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<double> fieldWidth(WidgetTester tester, double viewWidth) async {
    await tester.binding.setSurfaceSize(Size(viewWidth, 800));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: ListView(
            padding: AppTheme.pageScrollPadding.copyWith(left: 0, top: 0),
            children: <Widget>[
              ListToolbar(
                currentPage: 1,
                lastPage: 3,
                total: 40,
                searchHint: 'User ID',
                onSearchChanged: (_) {},
                onPageChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    return tester.getSize(find.byType(SearchField)).width;
  }

  testWidgets('搜索框铺满工具条宽度', (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    expect(await fieldWidth(tester, 360), 330);
    expect(await fieldWidth(tester, 700), 670);
    expect(await fieldWidth(tester, 1100), 1070);
  });

  testWidgets(
    '数字分页渲染为圆形，当前页使用选中底色',
    (WidgetTester tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final ThemeData theme in <ThemeData>[
        AppTheme.light(),
        AppTheme.dark(),
      ]) {
        for (final double width in <double>[360, 1100]) {
          await tester.binding.setSurfaceSize(Size(width, 800));
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: ListView(
                  padding: AppTheme.pageScrollPadding,
                  children: <Widget>[
                    ListToolbar(
                      currentPage: 1,
                      lastPage: 3,
                      total: 23,
                      showSearch: false,
                      onSearchChanged: (_) {},
                      onPageChanged: (_) {},
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          Material materialOf(String label) => tester.widget<Material>(
            find
                .descendant(
                  of: find.widgetWithText(OutlinedButton, label),
                  matching: find.byType(Material),
                )
                .first,
          );
          final Finder current = find.widgetWithText(OutlinedButton, '1');
          final Size size = tester.getSize(current);
          expect(size.width, size.height);
          expect(
            size.height,
            defaultTargetPlatform == TargetPlatform.windows ? 32 : 48,
          );
          final Path outline = materialOf('1').shape!
              .getOuterPath(Offset.zero & size);
          expect(
            outline.contains(Offset(size.width / 8, size.height / 8)),
            isFalse,
          );
          expect(
            outline.contains(Offset(size.width / 2, size.height / 8)),
            isTrue,
          );
          expect(materialOf('1').color, theme.colorScheme.onSurface);
          expect(
            materialOf('2').color,
            theme.colorScheme.surfaceContainerLowest,
          );
          expect(tester.takeException(), isNull);
        }
      }
    },
    variant: TargetPlatformVariant(<TargetPlatform>{
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  testWidgets(
    '长页码按内容扩宽并保持单行',
    (WidgetTester tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final ThemeData theme in <ThemeData>[
        AppTheme.light(),
        AppTheme.dark(),
      ]) {
        for (final double width in <double>[360, 1100]) {
          await tester.binding.setSurfaceSize(Size(width, 800));
          for (final int page in <int>[99999, 999999, 123456789012345678]) {
            int? requestedPage;
            await tester.pumpWidget(
              MaterialApp(
                theme: theme,
                home: Scaffold(
                  body: ListView(
                    padding: AppTheme.pageScrollPadding,
                    children: <Widget>[
                      ListToolbar(
                        currentPage: page,
                        lastPage: page + 1,
                        total: (page + 1) * ListToolbar.pageSize,
                        showSearch: false,
                        onSearchChanged: (_) {},
                        onPageChanged: (int value) => requestedPage = value,
                      ),
                    ],
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            for (final int label in <int>[page, page + 1]) {
              final Finder button = find.widgetWithText(
                OutlinedButton,
                '$label',
              );
              final Size size = tester.getSize(button);
              final RenderParagraph text = tester.renderObject<RenderParagraph>(
                find.descendant(of: button, matching: find.text('$label')),
              );
              final Size textSize = tester.getSize(find.text('$label'));
              expect(size.height, AppTheme.minTapTarget);
              expect(size.width, greaterThan(size.height));
              expect(
                text.getBoxesForSelection(
                  TextSelection(baseOffset: 0, extentOffset: '$label'.length),
                ),
                hasLength(1),
              );
              expect(textSize.width, lessThan(size.width));
              expect(textSize.height, lessThan(size.height));
            }
            await tester.tap(
              find.widgetWithText(OutlinedButton, '${page + 1}'),
            );
            expect(requestedPage, page + 1);
            expect(tester.takeException(), isNull);
          }
        }
      }
    },
    variant: TargetPlatformVariant(<TargetPlatform>{
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );
}
