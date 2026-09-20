import 'package:flutter_test/flutter_test.dart';
import 'package:stylepos/services/branches.dart';

/// Branch-sales overview plumbing: the RPC row parser and the classifier
/// that decides when the cloud predates `branch_sales_overview` (so the
/// UI offers the guided fix-SQL flow instead of surfacing an error).
void main() {
  test('BranchSales.fromMap parses a full RPC row', () {
    final b = BranchSales.fromMap({
      'shop_id': 'b7a1c9e0-1111-2222-3333-444455556666',
      'name': 'Westlands branch',
      'code': 'WE1K2F',
      'is_current': true,
      'all_orders': 12,
      'all_revenue': 45500.75,
      'today_orders': 3,
      'today_revenue': 8200.5,
    });
    expect(b.name, 'Westlands branch');
    expect(b.code, 'WE1K2F');
    expect(b.isCurrent, isTrue);
    expect(b.orders, 12);
    expect(b.revenue, 45500.75);
    expect(b.todayOrders, 3);
    expect(b.todayRevenue, 8200.5);
  });

  test('null / missing numeric and text fields fall back safely', () {
    final b = BranchSales.fromMap({
      'shop_id': 'x',
    });
    expect(b.id, 'x');
    expect(b.name, 'Branch');
    expect(b.code, '');
    expect(b.isCurrent, isFalse);
    expect(b.orders, 0);
    expect(b.revenue, 0.0);
    expect(b.todayOrders, 0);
    expect(b.todayRevenue, 0.0);
  });

  test('isMissingRpcError catches the PostgREST no-such-function family',
      () {
    expect(
        Branches.isMissingRpcError(
            'Could not find the function branch_sales_overview(double '
            'precision) in the schema cache'),
        isTrue);
    expect(Branches.isMissingRpcError(
        'PostgREST error PGRST202: function not found'), isTrue);
    expect(
        Branches.isMissingRpcError(
            'function public.branch_sales_overview does not exist'),
        isTrue);
    expect(
        Branches.isMissingRpcError('relation "sales" does not exist'), isTrue);
  });

  test('isMissingRpcError does NOT misclassify other failures', () {
    expect(
        Branches.isMissingRpcError('Only a manager can view branch sales.'),
        isFalse);
    expect(Branches.isMissingRpcError('JWT expired or invalid'), isFalse);
    expect(Branches.isMissingRpcError('Client is offline'), isFalse);
  });
}
