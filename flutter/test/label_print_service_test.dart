import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/services/label_print_service.dart';

void main() {
  const printer = LabelPrinter(
    id: 'zebra',
    name: 'Zebra ZD621',
    host: '192.0.2.10',
    speed: 4,
    darkness: 18,
  );

  test('inventory label uses 203 dpi dimensions and purchase year fallback',
      () {
    final label = LabelData.fromItem({
      'inventoryNumber': '10050035-02-02-0001',
      'name': 'Kettensäge',
      'manufacturer': 'Stihl',
      'purchaseDate': '2024-06-01',
      'itemType': 'bulk',
      'quantity': 3,
    }, LabelType.inventory);

    final zpl = LabelPrintService.instance.buildZpl(label, printer, 3);

    expect(label.year, '2024');
    expect(label.suggestedCopies, 3);
    expect(zpl, contains('^PW406'));
    expect(zpl, contains('^LL203'));
    expect(zpl, contains('^MNY'));
    expect(zpl, contains('^MTT'));
    expect(zpl, contains('^BCN,43'));
    expect(zpl, contains('^FD10050035-02-02-0001^FS'));
    expect(zpl, contains('^FDBJ:2024^FS'));
    expect(zpl, contains('^PQ3'));
    expect(zpl, isNot(contains('GR:')));
  });

  test('clothing label includes size and explicit manufacturing year', () {
    final label = LabelData.fromItem({
      'inventoryNumber': '10050035-04-01-0001',
      'name': 'Softshelljacke',
      'manufacturer': 'JET',
      'manufacturingYear': '2026',
      'purchaseDate': '2025-01-01',
      'size': '134/146',
    }, LabelType.clothing);

    final zpl = LabelPrintService.instance.buildZpl(label, printer, 1);

    expect(label.year, '2026');
    expect(zpl, contains('^FDSoftshelljacke^FS'));
    expect(zpl, contains('^FDJET^FS'));
    expect(zpl, contains('^FDBJ:2026^FS'));
    expect(zpl, contains('^FDGR:134/146^FS'));
  });
}
