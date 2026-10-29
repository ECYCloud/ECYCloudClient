import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../app_scope.dart';
import 'legal_document_page.dart';

class TosPage extends StatelessWidget {
  const TosPage({super.key});

  @override
  Widget build(BuildContext context) => LegalDocumentPage(
    title: L10n.t('服务条款'),
    emptyMessage: L10n.t('暂无服务条款'),
    loadContent: AppScope.of(context).auth.fetchTos,
  );
}
