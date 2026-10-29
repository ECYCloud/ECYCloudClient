import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../app_scope.dart';
import 'legal_document_page.dart';

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) => LegalDocumentPage(
    title: L10n.t('隐私政策'),
    emptyMessage: L10n.t('暂无隐私政策'),
    loadContent: AppScope.of(context).auth.fetchPrivacyPolicy,
  );
}
